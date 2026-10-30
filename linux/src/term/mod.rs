//! A session's terminal: a VTE widget fed from a PTY that omux owns.
//!
//! VTE runs without a PTY of its own. Output from the PTY is fed to it, and
//! everything VTE would send to the program (keys, pastes, replies to
//! terminal queries) arrives through its `commit` signal and is written to
//! the PTY.

pub mod osc;
pub mod pty;
pub mod status;

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::rc::Rc;

use gtk::glib;
use gtk::prelude::*;
use vte::prelude::*;

use pty::{Output, Pty, Spawn};
use status::{Record, Store};

/// Lines kept above the screen, as on the Mac.
pub const SCROLLBACK_LINES: i64 = 5000;

#[derive(Debug, Clone)]
pub enum TermEvent {
    /// OSC 0/2 window title.
    Title(String),
    /// OSC 7 working directory.
    Cwd(String),
    Bell,
    /// The current OSC 7501 records, oldest update first.
    Status(Vec<Record>),
    /// OSC 9 / OSC 777.
    Notification {
        title: Option<String>,
        body: String,
    },
    Exited,
}

type Handler = Rc<dyn Fn(TermEvent)>;

pub struct SessionTerminal {
    pub widget: vte::Terminal,
    pty: RefCell<Option<Pty>>,
    status: RefCell<Store>,
    size: Cell<(i64, i64)>,
    handler: RefCell<Option<Handler>>,
    /// Popovers parented to the terminal; unparented before it goes away.
    popovers: RefCell<Vec<gtk::Popover>>,
}

impl SessionTerminal {
    pub fn new() -> Rc<Self> {
        let widget = vte::Terminal::new();
        widget.set_scrollback_lines(SCROLLBACK_LINES);
        widget.set_vexpand(true);
        widget.set_hexpand(true);
        widget.set_mouse_autohide(true);
        widget.set_allow_hyperlink(true);
        widget.set_enable_fallback_scrolling(true);

        let this = Rc::new(Self {
            widget,
            pty: RefCell::new(None),
            status: RefCell::new(Store::default()),
            size: Cell::new((0, 0)),
            handler: RefCell::new(None),
            popovers: RefCell::new(Vec::new()),
        });

        let weak = Rc::downgrade(&this);
        this.widget.connect_commit(move |_, text, _| {
            if let Some(this) = weak.upgrade() {
                this.write(text.as_bytes());
            }
        });

        let weak = Rc::downgrade(&this);
        this.widget.connect_window_title_changed(move |term| {
            if let Some(this) = weak.upgrade() {
                let title = term
                    .window_title()
                    .map(|t| t.to_string())
                    .unwrap_or_default();
                this.emit(TermEvent::Title(title));
            }
        });

        let weak = Rc::downgrade(&this);
        this.widget
            .connect_current_directory_uri_changed(move |term| {
                if let Some(this) = weak.upgrade() {
                    if let Some(uri) = term.current_directory_uri() {
                        let path = glib::filename_from_uri(&uri)
                            .map(|(path, _)| path.display().to_string())
                            .unwrap_or_else(|_| uri.to_string());
                        this.emit(TermEvent::Cwd(path));
                    }
                }
            });

        let weak = Rc::downgrade(&this);
        this.widget.connect_bell(move |_| {
            if let Some(this) = weak.upgrade() {
                this.emit(TermEvent::Bell);
            }
        });

        // VTE works out rows and columns from its allocation; pass changes on.
        let weak = Rc::downgrade(&this);
        this.widget.add_tick_callback(move |term, _| {
            let Some(this) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let size = (term.row_count(), term.column_count());
            if size != this.size.get() {
                this.size.set(size);
                if let Some(pty) = this.pty.borrow().as_ref() {
                    pty.resize(size.0 as u16, size.1 as u16);
                }
            }
            glib::ControlFlow::Continue
        });

        this
    }

    pub fn add_popover(&self, popover: &gtk::Popover) {
        popover.set_parent(&self.widget);
        self.popovers.borrow_mut().push(popover.clone());
    }

    /// Kills the process and detaches child widgets before the terminal is dropped.
    pub fn dispose(&self) {
        self.kill();
        for popover in self.popovers.borrow_mut().drain(..) {
            popover.unparent();
        }
    }

    pub fn set_handler(&self, handler: impl Fn(TermEvent) + 'static) {
        *self.handler.borrow_mut() = Some(Rc::new(handler));
    }

    fn emit(&self, event: TermEvent) {
        let handler = self.handler.borrow().clone();
        if let Some(handler) = handler {
            handler(event);
        }
    }

    /// Starts the login shell. Any previous process is killed first.
    pub fn spawn(
        self: &Rc<Self>,
        shell: &str,
        cwd: &Path,
        env: crate::session_env::Env,
    ) -> std::io::Result<i32> {
        self.kill();
        // Bounded: a flood of output waits in the PTY until the UI catches up.
        let (tx, rx) = async_channel::bounded(16);
        let rows = self.widget.row_count().max(1) as u16;
        let cols = self.widget.column_count().max(1) as u16;
        let pty = Pty::spawn(
            Spawn {
                shell,
                cwd,
                env,
                rows,
                cols,
            },
            tx,
        )?;
        let pid = pty.pid();
        *self.pty.borrow_mut() = Some(pty);
        self.size.set((0, 0));
        // Records belong to the process that reported them.
        if self.status.borrow_mut().clear("") {
            self.emit_status();
        }

        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok(output) = rx.recv().await {
                let Some(this) = weak.upgrade() else { break };
                match output {
                    Output::Bytes(bytes, events) => {
                        // Output still queued from a killed or replaced process.
                        if this.pty.borrow().as_ref().map(Pty::pid) != Some(pid) {
                            continue;
                        }
                        this.widget.feed(&bytes);
                        this.handle(events);
                    }
                    Output::Exited => {
                        // A restart replaced this process; only the current one reports.
                        let current = this.pty.borrow().as_ref().map(Pty::pid) == Some(pid);
                        if current {
                            this.pty.borrow_mut().take();
                            if this.status.borrow_mut().remove_active() {
                                this.emit_status();
                            }
                            this.emit(TermEvent::Exited);
                        }
                        break;
                    }
                }
            }
        });
        Ok(pid)
    }

    fn handle(&self, events: Vec<osc::Event>) {
        for event in events {
            match event {
                osc::Event::Status(report) => {
                    if self.status.borrow_mut().apply(report) {
                        self.emit_status();
                    }
                }
                osc::Event::PromptStart => {
                    if self.status.borrow_mut().remove_active() {
                        self.emit_status();
                    }
                }
                osc::Event::Notification { title, body } => {
                    self.emit(TermEvent::Notification { title, body });
                }
                osc::Event::StatusQuery { .. } => {}
            }
        }
    }

    fn emit_status(&self) {
        let records = self.status.borrow().snapshots();
        self.emit(TermEvent::Status(records));
    }

    pub fn is_running(&self) -> bool {
        self.pty.borrow().is_some()
    }

    pub fn is_busy(&self) -> bool {
        self.pty.borrow().as_ref().is_some_and(Pty::is_busy)
    }

    pub fn write(&self, bytes: &[u8]) {
        if let Some(pty) = self.pty.borrow().as_ref() {
            pty.write(bytes);
        }
    }

    /// Pastes text the way the user would, bracketed when the program asked
    /// for bracketed paste. VTE wraps it and sends it through `commit`.
    pub fn paste(&self, text: &str) {
        self.widget.paste_text(text);
    }

    pub fn kill(&self) {
        let pty = self.pty.borrow_mut().take();
        if let Some(pty) = pty {
            pty.kill_tree();
            if self.status.borrow_mut().clear("") {
                self.emit_status();
            }
        }
    }
}
