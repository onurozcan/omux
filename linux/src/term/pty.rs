//! A session's pseudo-terminal. omux owns the PTY (instead of letting VTE
//! spawn the shell) so it can watch the output for OSC 7501 and friends; see
//! docs/ROADMAP.md, decision 1.
//!
//! Three threads per session, so the GTK thread never blocks on the PTY:
//! a reader (scans output and hands it to the main loop, which applies
//! backpressure through a bounded channel), a writer (keys, pastes and
//! replies, in order), and a waiter that reports the shell's exit even when
//! a background job keeps the terminal open.

use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::time::Duration;

use super::osc::{Event, Scanner};

/// What the PTY threads report to the main loop.
pub enum Output {
    Bytes(Vec<u8>, Vec<Event>),
    Exited,
}

pub struct Pty {
    master: Arc<File>,
    writer: mpsc::Sender<Vec<u8>>,
    pid: i32,
    exited: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
}

pub struct Spawn<'a> {
    pub shell: &'a str,
    pub cwd: &'a Path,
    pub env: Vec<(std::ffi::OsString, std::ffi::OsString)>,
    pub rows: u16,
    pub cols: u16,
}

impl Pty {
    /// Starts `shell -l` as the session leader of a new PTY. Output arrives on
    /// `sink`, already scanned for OSC events; give it a bounded channel so a
    /// flood of output waits for the UI instead of filling memory.
    pub fn spawn(spec: Spawn<'_>, sink: async_channel::Sender<Output>) -> io::Result<Self> {
        let (master, slave) = open_pty(spec.rows, spec.cols)?;

        let mut command = Command::new(spec.shell);
        command
            .arg("-l")
            .current_dir(spec.cwd)
            .env_clear()
            .envs(spec.env.iter().map(|(k, v)| (k, v)))
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        // Become the session leader with the PTY as controlling terminal, so
        // job control works and killpg reaches everything the shell started.
        unsafe {
            command.pre_exec(move || {
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        // The waiter reaps the shell by pid; the Child handle isn't needed.
        let pid = command.spawn()?.id() as i32;
        drop(command);
        let master = Arc::new(File::from(master));
        let exited = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));

        let (writer, inbox) = mpsc::channel::<Vec<u8>>();
        let out = master.clone();
        std::thread::Builder::new()
            .name(format!("omux-pty-w{pid}"))
            .spawn(move || {
                while let Ok(bytes) = inbox.recv() {
                    if (&*out).write_all(&bytes).is_err() {
                        break;
                    }
                }
            })?;

        let (reader, replies, reader_sink, reader_stop) =
            (master.clone(), writer.clone(), sink.clone(), stop.clone());
        std::thread::Builder::new()
            .name(format!("omux-pty-r{pid}"))
            .spawn(move || read_loop(reader, replies, reader_sink, reader_stop))?;

        let waiter_exited = exited.clone();
        std::thread::Builder::new()
            .name(format!("omux-pty-x{pid}"))
            .spawn(move || {
                let mut status = 0;
                while unsafe { libc::waitpid(pid, &mut status, 0) } < 0
                    && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted
                {
                }
                waiter_exited.store(true, Ordering::SeqCst);
                // Let the reader hand over the shell's last output first.
                std::thread::sleep(Duration::from_millis(60));
                let _ = sink.send_blocking(Output::Exited);
            })?;

        Ok(Self {
            master,
            writer,
            pid,
            exited,
            stop,
        })
    }

    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Queues bytes for the program; never blocks.
    pub fn write(&self, bytes: &[u8]) {
        let _ = self.writer.send(bytes.to_vec());
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        let size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ, &size);
        }
    }

    /// Whether something other than the shell runs in the foreground, such as
    /// an agent or a build. (The Mac checks for any child of the shell.)
    pub fn is_busy(&self) -> bool {
        let group = unsafe { libc::tcgetpgrp(self.master.as_raw_fd()) };
        group > 0 && group != self.pid
    }

    /// Hangs up the shell's process group, then makes sure the shell goes,
    /// as the Mac does. A reaped pid is never signalled (it may be reused).
    pub fn kill_tree(&self) {
        if self.exited.load(Ordering::SeqCst) {
            return;
        }
        unsafe {
            libc::killpg(self.pid, libc::SIGHUP);
            libc::kill(self.pid, libc::SIGTERM);
        }
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        self.kill_tree();
        self.stop.store(true, Ordering::SeqCst);
    }
}

fn open_pty(rows: u16, cols: u16) -> io::Result<(OwnedFd, OwnedFd)> {
    let mut master: RawFd = -1;
    let mut slave: RawFd = -1;
    let size = libc::winsize {
        ws_row: rows.max(1),
        ws_col: cols.max(1),
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let result = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null(),
            &size,
        )
    };
    if result < 0 {
        return Err(io::Error::last_os_error());
    }
    unsafe {
        // Neither side may leak into other programs omux starts (git, codex,
        // the agent scanner's children). The shell gets the slave as its
        // stdio through dup2, which clears the flag on the copies.
        libc::fcntl(master, libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(slave, libc::F_SETFD, libc::FD_CLOEXEC);
        Ok((OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)))
    }
}

fn read_loop(
    master: Arc<File>,
    replies: mpsc::Sender<Vec<u8>>,
    sink: async_channel::Sender<Output>,
    stop: Arc<AtomicBool>,
) {
    let mut scanner = Scanner::default();
    let mut buffer = vec![0u8; 64 * 1024];
    let fd = master.as_raw_fd();
    while !stop.load(Ordering::SeqCst) {
        // Poll with a timeout so a dropped session stops this thread even
        // while a background job keeps the terminal open.
        let mut pollfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        let ready = unsafe { libc::poll(&mut pollfd, 1, 250) };
        if ready == 0 {
            continue;
        }
        if ready < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        match (&*master).read(&mut buffer) {
            Ok(0) => break,
            Ok(n) => {
                let bytes = buffer[..n].to_vec();
                let mut events = Vec::new();
                scanner.feed(&bytes, &mut events);
                // SwiftTerm answers the program status query itself.
                for event in &events {
                    if let Event::StatusQuery { bel } = event {
                        let ending: &[u8] = if *bel { b"\x07" } else { b"\x1b\\" };
                        let _ = replies.send([b"\x1b]7501;?", ending].concat());
                    }
                }
                if sink.send_blocking(Output::Bytes(bytes, events)).is_err() {
                    break;
                }
            }
            Err(err) if err.kind() == io::ErrorKind::Interrupted => continue,
            // EIO once the last process holding the slave side exits.
            Err(_) => break,
        }
    }
}

/// The login name for `USER`/`LOGNAME` when the environment lacks them.
pub fn login_name() -> Option<String> {
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_name.is_null() {
            return None;
        }
        let name = std::ffi::CStr::from_ptr((*pw).pw_name);
        name.to_str().ok().map(str::to_string)
    }
}

/// The user's login shell from the password database, for when `$SHELL` is unset.
pub fn passwd_shell() -> Option<String> {
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if pw.is_null() || (*pw).pw_shell.is_null() {
            return None;
        }
        let shell = std::ffi::CStr::from_ptr((*pw).pw_shell);
        shell
            .to_str()
            .ok()
            .filter(|s| !s.is_empty())
            .map(str::to_string)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runs_a_shell_and_reports_output_and_exit() {
        let (tx, rx) = async_channel::unbounded();
        let pty = Pty::spawn(
            Spawn {
                shell: "/bin/sh",
                cwd: Path::new("/"),
                env: vec![("PATH".into(), "/usr/bin:/bin".into())],
                rows: 24,
                cols: 80,
            },
            tx,
        )
        .unwrap();
        pty.write(b"printf '\\033]7501;state=done\\007'; echo hi; exit 3\n");
        let mut text = Vec::new();
        let mut saw_status = false;
        while let Output::Bytes(bytes, events) = rx.recv_blocking().unwrap() {
            text.extend(bytes);
            saw_status |= events.iter().any(|e| matches!(e, Event::Status(_)));
        }
        assert!(String::from_utf8_lossy(&text).contains("hi"));
        assert!(saw_status);
    }

    #[test]
    fn exit_is_reported_while_a_background_job_holds_the_terminal() {
        let (tx, rx) = async_channel::unbounded();
        let pty = Pty::spawn(
            Spawn {
                shell: "/bin/sh",
                cwd: Path::new("/"),
                env: vec![("PATH".into(), "/usr/bin:/bin".into())],
                rows: 24,
                cols: 80,
            },
            tx,
        )
        .unwrap();
        pty.write(b"sleep 30 & exit\n");
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        loop {
            assert!(std::time::Instant::now() < deadline, "no exit reported");
            match rx.recv_blocking().unwrap() {
                Output::Exited => break,
                Output::Bytes(..) => {}
            }
        }
        assert!(!pty.is_busy());
    }
}
