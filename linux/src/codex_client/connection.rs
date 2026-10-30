//! IO for one private `codex app-server`: child process, readiness probe,
//! WebSocket and JSON-RPC request/response matching (`CodexConnection.swift`).
//!
//! No async runtime: one IO thread owns the WebSocket (short read timeout,
//! outgoing messages drained between reads), a watcher thread per child waits
//! for its exit, and callers block on a channel with the 20 s request deadline.
//! Callbacks run on the IO thread and must not block on a request.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender, TryRecvError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tungstenite::http::{header::AUTHORIZATION, HeaderValue};
use tungstenite::{client::IntoClientRequest, Message, WebSocket};

use super::protocol::RequestId;
use super::CodexError;

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const READ_POLL: Duration = Duration::from_millis(30);

/// A decoded frame from the server.
#[derive(Debug, PartialEq)]
pub enum Incoming {
    Response(i64, Result<Value, CodexError>),
    /// Notification or server-to-client request (anything with a `method`).
    Message(Value),
}

/// Responses have an integer `id` and no `method`; everything else goes to the
/// message handler.
pub fn classify(value: Value) -> Option<Incoming> {
    let object = value.as_object()?;
    if !object.contains_key("method") {
        if let Some(id) = object.get("id").and_then(Value::as_i64) {
            let result = if let Some(error) = object.get("error").filter(|e| e.is_object()) {
                let message = error
                    .get("message")
                    .and_then(Value::as_str)
                    .unwrap_or("Codex request failed");
                Err(CodexError::Server(message.to_string()))
            } else {
                Ok(object
                    .get("result")
                    .filter(|r| r.is_object())
                    .cloned()
                    .unwrap_or_else(|| json!({})))
            };
            return Some(Incoming::Response(id, result));
        }
    }
    Some(Incoming::Message(value))
}

pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

pub fn token_digest(token: &str) -> String {
    Sha256::digest(token.as_bytes())
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// The command line the login shell `exec`s to start the private server.
pub fn server_command(endpoint: &str, digest: &str) -> String {
    format!(
        "exec codex app-server --listen {endpoint} --ws-auth capability-token --ws-token-sha256 {digest} -c 'analytics.enabled=false'"
    )
}

/// The line typed into the tab's shell to attach the TUI to the same server.
pub fn resume_command(endpoint: &str, thread_id: &str) -> String {
    format!(
        "codex resume --remote {} --remote-auth-token-env OMUX_CODEX_TOKEN --no-alt-screen {}",
        shell_quote(endpoint),
        shell_quote(thread_id)
    )
}

fn request_text(id: i64, method: &str, params: &Value) -> String {
    json!({"id": id, "method": method, "params": params}).to_string()
}

struct ExitFlag {
    done: Mutex<bool>,
    changed: Condvar,
}

impl ExitFlag {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            done: Mutex::new(false),
            changed: Condvar::new(),
        })
    }

    fn set(&self) {
        *lock(&self.done) = true;
        self.changed.notify_all();
    }

    fn is_set(&self) -> bool {
        *lock(&self.done)
    }
}

struct Link {
    gen: u64,
    out: Sender<String>,
    pid: u32,
    exit: Arc<ExitFlag>,
    endpoint: String,
}

type Reply = Sender<Result<Value, CodexError>>;

#[derive(Default)]
struct Inner {
    link: Option<Link>,
    next_id: i64,
    pending: HashMap<i64, Reply>,
    retiring: Vec<Arc<ExitFlag>>,
    ready: bool,
    gen: u64,
}

pub struct Handlers {
    pub on_message: Box<dyn Fn(Value) + Send + Sync>,
    pub on_disconnect: Box<dyn Fn() + Send + Sync>,
}

/// Owns only the app-server launched by omux. A random bearer token protects
/// the loopback listener; neither it nor Codex credentials go in arguments.
pub struct Conn {
    pub token: String,
    environment: Option<HashMap<String, String>>,
    client_version: Mutex<String>,
    handlers: Handlers,
    inner: Mutex<Inner>,
    connect_lock: Mutex<()>,
}

impl Conn {
    pub fn new(
        token: String,
        environment: Option<HashMap<String, String>>,
        handlers: Handlers,
    ) -> Arc<Self> {
        Arc::new(Self {
            token,
            environment,
            client_version: Mutex::new("0".to_string()),
            handlers,
            inner: Mutex::new(Inner::default()),
            connect_lock: Mutex::new(()),
        })
    }

    pub fn set_client_version(&self, version: &str) {
        *lock(&self.client_version) = version.to_string();
    }

    pub fn is_ready(&self) -> bool {
        lock(&self.inner).ready
    }

    pub fn endpoint(&self) -> Option<String> {
        lock(&self.inner).link.as_ref().map(|l| l.endpoint.clone())
    }

    /// Identifies the current server; changes on every (re)connect.
    pub fn link_gen(&self) -> Option<u64> {
        lock(&self.inner).link.as_ref().map(|l| l.gen)
    }

    pub fn connect(self: &Arc<Self>) -> Result<(), CodexError> {
        let _serial = lock(&self.connect_lock);
        if lock(&self.inner).link.is_some() {
            return Ok(());
        }
        self.open()
    }

    fn open(self: &Arc<Self>) -> Result<(), CodexError> {
        self.wait_for_shutdown()?;
        // The port is picked by bind-then-close, so another process can take
        // it first; a server that dies right away gets a fresh port.
        for _ in 0..3 {
            let port = available_port()?;
            let endpoint = format!("ws://127.0.0.1:{port}");
            let gen = {
                let mut inner = lock(&self.inner);
                inner.gen += 1;
                inner.gen
            };
            let exit = ExitFlag::new();
            let pid = self.spawn_server(&endpoint, gen, &exit)?;
            match self.finish_open(port, &endpoint, gen, pid, &exit) {
                Ok(()) => return Ok(()),
                Err(CodexError::Unavailable) if exit.is_set() => continue,
                Err(error) => {
                    self.close(false);
                    self.retire(pid, &exit);
                    return Err(error);
                }
            }
        }
        Err(CodexError::Unavailable)
    }

    fn spawn_server(
        self: &Arc<Self>,
        endpoint: &str,
        gen: u64,
        exit: &Arc<ExitFlag>,
    ) -> Result<u32, CodexError> {
        let mut env: HashMap<String, String> = self
            .environment
            .clone()
            .unwrap_or_else(|| std::env::vars().collect());
        let home = env.get("HOME").cloned().unwrap_or_else(|| "/".to_string());
        let path = env.get("PATH").map_or("/usr/bin:/bin", String::as_str);
        let path = format!("{home}/.local/bin:/usr/local/bin:{path}");
        env.insert("PATH".to_string(), path);
        let shell = env
            .get("SHELL")
            .cloned()
            .or_else(|| std::env::var("SHELL").ok())
            .unwrap_or_else(|| "/bin/sh".to_string());
        let mut child = Command::new(shell)
            .arg("-lc")
            .arg(server_command(endpoint, &token_digest(&self.token)))
            .env_clear()
            .envs(&env)
            .current_dir(&home)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| CodexError::Unavailable)?;
        let pid = child.id();
        let (conn, exit) = (Arc::clone(self), Arc::clone(exit));
        thread::spawn(move || {
            let _ = child.wait();
            exit.set();
            conn.lost(gen);
        });
        Ok(pid)
    }

    fn finish_open(
        self: &Arc<Self>,
        port: u16,
        endpoint: &str,
        gen: u64,
        pid: u32,
        exit: &Arc<ExitFlag>,
    ) -> Result<(), CodexError> {
        // Probe readiness before opening the authenticated WebSocket. Never
        // send a model prompt, create a thread, or alter authentication here.
        let mut ready = false;
        for _ in 0..80 {
            if exit.is_set() {
                return Err(CodexError::Unavailable);
            }
            if probe_ready(port) {
                ready = true;
                break;
            }
            thread::sleep(Duration::from_millis(100));
        }
        if !ready {
            return Err(CodexError::Unavailable);
        }
        let socket = self.websocket(port, endpoint)?;
        let (out, queue) = mpsc::channel();
        {
            let mut inner = lock(&self.inner);
            inner.link = Some(Link {
                gen,
                out,
                pid,
                exit: Arc::clone(exit),
                endpoint: endpoint.to_string(),
            });
        }
        let conn = Arc::clone(self);
        thread::spawn(move || conn.io_loop(gen, socket, queue));
        if exit.is_set() {
            return Err(CodexError::Unavailable);
        }
        let version = lock(&self.client_version).clone();
        self.request(
            "initialize",
            json!({"clientInfo": {"name": "omux", "title": "omux", "version": version}}),
        )?;
        self.send_text(json!({"method": "initialized"}).to_string())?;
        lock(&self.inner).ready = true;
        Ok(())
    }

    fn websocket(&self, port: u16, endpoint: &str) -> Result<WebSocket<TcpStream>, CodexError> {
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))
            .map_err(|_| CodexError::Unavailable)?;
        let _ = stream.set_nodelay(true);
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .map_err(|_| CodexError::Unavailable)?;
        let mut request = endpoint
            .into_client_request()
            .map_err(|_| CodexError::Unavailable)?;
        let value = HeaderValue::from_str(&format!("Bearer {}", self.token))
            .map_err(|_| CodexError::Unavailable)?;
        request.headers_mut().insert(AUTHORIZATION, value);
        let (socket, _) =
            tungstenite::client(request, stream).map_err(|_| CodexError::Unavailable)?;
        socket
            .get_ref()
            .set_read_timeout(Some(READ_POLL))
            .map_err(|_| CodexError::Unavailable)?;
        Ok(socket)
    }

    fn io_loop(
        self: Arc<Self>,
        gen: u64,
        mut socket: WebSocket<TcpStream>,
        queue: Receiver<String>,
    ) {
        loop {
            loop {
                match queue.try_recv() {
                    Ok(text) => {
                        if socket.send(Message::Text(text.into())).is_err() {
                            self.lost(gen);
                            return;
                        }
                    }
                    Err(TryRecvError::Empty) => break,
                    Err(TryRecvError::Disconnected) => {
                        let _ = socket.close(None);
                        let _ = socket.flush();
                        return;
                    }
                }
            }
            match socket.read() {
                Ok(Message::Text(text)) => self.dispatch(text.as_str().as_bytes()),
                Ok(Message::Binary(bytes)) => self.dispatch(&bytes),
                Ok(Message::Close(_)) => {
                    self.lost(gen);
                    return;
                }
                Ok(_) => {}
                Err(tungstenite::Error::Io(e))
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => {
                    self.lost(gen);
                    return;
                }
            }
        }
    }

    fn dispatch(&self, bytes: &[u8]) {
        let Ok(value) = serde_json::from_slice::<Value>(bytes) else {
            return;
        };
        match classify(value) {
            Some(Incoming::Response(id, result)) => {
                let reply = lock(&self.inner).pending.remove(&id);
                if let Some(reply) = reply {
                    let _ = reply.send(result);
                }
            }
            Some(Incoming::Message(message)) => (self.handlers.on_message)(message),
            None => {}
        }
    }

    fn send_text(&self, text: String) -> Result<(), CodexError> {
        let inner = lock(&self.inner);
        let link = inner.link.as_ref().ok_or(CodexError::Disconnected)?;
        link.out.send(text).map_err(|_| CodexError::Disconnected)
    }

    /// Blocking JSON-RPC request with the 20 s deadline.
    pub fn request(&self, method: &str, params: Value) -> Result<Value, CodexError> {
        let (reply, answer) = mpsc::channel();
        let id = {
            let mut inner = lock(&self.inner);
            let Some(link) = inner.link.as_ref() else {
                return Err(CodexError::Disconnected);
            };
            let out = link.out.clone();
            inner.next_id += 1;
            let id = inner.next_id;
            inner.pending.insert(id, reply);
            if out.send(request_text(id, method, &params)).is_err() {
                inner.pending.remove(&id);
                return Err(CodexError::Disconnected);
            }
            id
        };
        match answer.recv_timeout(REQUEST_TIMEOUT) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) => {
                lock(&self.inner).pending.remove(&id);
                Err(CodexError::Timeout)
            }
            Err(RecvTimeoutError::Disconnected) => Err(CodexError::Disconnected),
        }
    }

    /// Reply to a server-to-client request, echoing its id as received.
    pub fn respond(&self, id: &RequestId, result: Value) -> Result<(), CodexError> {
        self.send_text(json!({"id": id.to_json(), "result": result}).to_string())
    }

    /// The link died (socket error or server exit). Ignored if already replaced.
    fn lost(&self, gen: u64) {
        let current = lock(&self.inner).link.as_ref().map(|l| l.gen);
        if current == Some(gen) {
            self.close(true);
        }
    }

    pub fn close(&self, notify: bool) {
        let (link, pending) = {
            let mut inner = lock(&self.inner);
            inner.ready = false;
            let link = inner.link.take();
            let pending: Vec<Reply> = inner.pending.drain().map(|(_, r)| r).collect();
            (link, pending)
        };
        let had_link = link.is_some();
        if let Some(link) = link {
            // Dropping `out` makes the IO thread close the socket and exit.
            self.retire(link.pid, &link.exit);
        }
        for reply in pending {
            let _ = reply.send(Err(CodexError::Disconnected));
        }
        if notify && had_link {
            (self.handlers.on_disconnect)();
        }
    }

    /// SIGTERM the server and remember it until it has really exited.
    fn retire(&self, pid: u32, exit: &Arc<ExitFlag>) {
        if !exit.is_set() {
            // SAFETY: plain signal to a child we spawned and have not reaped
            // (the watcher sets `exit` only after wait() returned).
            unsafe {
                libc::kill(pid as libc::pid_t, libc::SIGTERM);
            }
            lock(&self.inner).retiring.push(Arc::clone(exit));
        }
    }

    /// Wait up to 10 s for servers stopped earlier by this connection.
    pub fn wait_for_shutdown(&self) -> Result<(), CodexError> {
        for _ in 0..100 {
            let mut inner = lock(&self.inner);
            inner.retiring.retain(|flag| !flag.is_set());
            if inner.retiring.is_empty() {
                return Ok(());
            }
            drop(inner);
            thread::sleep(Duration::from_millis(100));
        }
        Err(CodexError::PreviousServerStopping)
    }
}

fn available_port() -> Result<u16, CodexError> {
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|_| CodexError::Unavailable)?;
    listener
        .local_addr()
        .map(|a| a.port())
        .map_err(|_| CodexError::Unavailable)
}

/// `GET /readyz` over a raw socket: success is an HTTP 200 status line.
fn probe_ready(port: u16) -> bool {
    let timeout = Duration::from_millis(300);
    let address = SocketAddr::from(([127, 0, 0, 1], port));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, timeout) else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let request =
        format!("GET /readyz HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    if stream.write_all(request.as_bytes()).is_err() {
        return false;
    }
    let mut status = [0u8; 12];
    stream.read_exact(&mut status).is_ok()
        && (status == *b"HTTP/1.1 200" || status == *b"HTTP/1.0 200")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn success_responses_carry_their_result() {
        let incoming = classify(json!({"id": 3, "result": {"thread": {"id": "t"}}}));
        assert_eq!(
            incoming,
            Some(Incoming::Response(3, Ok(json!({"thread": {"id": "t"}}))))
        );
    }

    #[test]
    fn missing_or_non_object_result_becomes_empty_object() {
        assert_eq!(
            classify(json!({"id": 4})),
            Some(Incoming::Response(4, Ok(json!({}))))
        );
        assert_eq!(
            classify(json!({"id": 5, "result": "ok"})),
            Some(Incoming::Response(5, Ok(json!({}))))
        );
    }

    #[test]
    fn error_responses_use_the_server_message() {
        assert_eq!(
            classify(json!({"id": 1, "error": {"code": -1, "message": "nope"}})),
            Some(Incoming::Response(
                1,
                Err(CodexError::Server("nope".into()))
            ))
        );
        assert_eq!(
            classify(json!({"id": 2, "error": {"code": -1}})),
            Some(Incoming::Response(
                2,
                Err(CodexError::Server("Codex request failed".into()))
            ))
        );
    }

    #[test]
    fn requests_and_notifications_with_a_method_are_messages() {
        let request = json!({"id": 9, "method": "item/fileChange/requestApproval", "params": {}});
        assert_eq!(classify(request.clone()), Some(Incoming::Message(request)));
        let note = json!({"method": "turn/started", "params": {}});
        assert_eq!(classify(note.clone()), Some(Incoming::Message(note)));
    }

    #[test]
    fn string_ids_without_a_method_are_not_responses() {
        let value = json!({"id": "abc", "result": {}});
        assert_eq!(classify(value.clone()), Some(Incoming::Message(value)));
        assert_eq!(classify(json!([1, 2])), None);
    }

    #[test]
    fn quoting_escapes_single_quotes() {
        assert_eq!(shell_quote("plain"), "'plain'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn token_digest_is_lowercase_hex_sha256() {
        assert_eq!(
            token_digest("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn launch_and_resume_lines_match_the_mac_app() {
        assert_eq!(
            server_command("ws://127.0.0.1:4000", "dead"),
            "exec codex app-server --listen ws://127.0.0.1:4000 --ws-auth capability-token --ws-token-sha256 dead -c 'analytics.enabled=false'"
        );
        assert_eq!(
            resume_command("ws://127.0.0.1:4000", "thr'1"),
            "codex resume --remote 'ws://127.0.0.1:4000' --remote-auth-token-env OMUX_CODEX_TOKEN --no-alt-screen 'thr'\\''1'"
        );
    }

    #[test]
    fn requests_fail_fast_without_a_server() {
        let conn = Conn::new(
            "t".into(),
            None,
            Handlers {
                on_message: Box::new(|_| {}),
                on_disconnect: Box::new(|| {}),
            },
        );
        assert_eq!(
            conn.request("initialize", json!({})),
            Err(CodexError::Disconnected)
        );
        assert_eq!(
            conn.respond(&RequestId::Number(1), json!({})),
            Err(CodexError::Disconnected)
        );
        assert!(!conn.is_ready());
        assert_eq!(conn.endpoint(), None);
    }

    #[test]
    fn a_free_port_is_found() {
        assert!(available_port().unwrap() > 0);
    }
}
