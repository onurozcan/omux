//! Managed Codex sessions: each session gets its own private `codex
//! app-server`, omux follows it over the protocol (status, approvals,
//! subagents, usage) and the Codex TUI in the terminal attaches to the same
//! server. The client itself is `codex_client`; this file connects it to the
//! app. Blocking client calls always run on worker threads.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::Path;
use std::rc::Rc;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use adw::prelude::*;
use gtk::glib;
use uuid::Uuid;

use crate::app::App;
use crate::codex_client::{Catalog, CodexAgent, CodexState, CodexUsage, TabClient, Update};
use crate::model::SessionProvider;
use crate::term::status::State;
use crate::ui::panel::background;

#[derive(Default)]
struct Session {
    client: TabClient,
    starting: bool,
    /// Bumped by every start and close, so a start that finishes after its
    /// session was closed, killed or restarted is recognised as stale.
    generation: u64,
    /// A worktree setup command typed before the TUI once the server is ready.
    setup: Option<String>,
    agents: Vec<CodexAgent>,
    answering: bool,
}

#[derive(Default)]
struct Codex {
    sessions: HashMap<Uuid, Session>,
    usage: Option<Result<CodexUsage, String>>,
    /// Kept across errors, as on the Mac.
    plan: Option<String>,
    usage_checked: Option<Instant>,
}

thread_local! {
    static CODEX: RefCell<Codex> = RefCell::new(Codex::default());
}

/// The shared server behind Recent conversations and usage, started on
/// first use.
static CATALOG: OnceLock<Catalog> = OnceLock::new();

fn catalog() -> &'static Catalog {
    CATALOG.get_or_init(Catalog::new)
}

fn with<R>(id: Uuid, f: impl FnOnce(&mut Session) -> R) -> R {
    CODEX.with(|c| f(c.borrow_mut().sessions.entry(id).or_default()))
}

fn client(id: Uuid) -> TabClient {
    with(id, |s| s.client.clone())
}

/// The bearer token for a session's private app-server, kept in memory only
/// and handed to its shell as `OMUX_CODEX_TOKEN`.
pub fn token_for(_app: &Rc<App>, id: Uuid) -> String {
    client(id).token()
}

pub fn set_pending_setup(_app: &Rc<App>, id: Uuid, setup: String) {
    with(id, |s| s.setup = Some(setup));
}

pub fn is_starting(_app: &Rc<App>, id: Uuid) -> bool {
    CODEX.with(|c| c.borrow().sessions.get(&id).is_some_and(|s| s.starting))
}

/// Whether the session's server is up and its protocol client connected.
pub fn is_connected(id: Uuid) -> bool {
    CODEX.with(|c| {
        c.borrow()
            .sessions
            .get(&id)
            .is_some_and(|s| s.client.is_ready())
    })
}

fn map_state(state: CodexState) -> State {
    match state {
        CodexState::Idle => State::Idle,
        CodexState::Working => State::Working,
        CodexState::Blocked => State::Blocked,
        CodexState::Done => State::Done,
        CodexState::Error => State::Error,
    }
}

/// The protocol decides a Codex session's status and whether it is busy.
fn set_status(
    app: &Rc<App>,
    id: Uuid,
    state: Option<State>,
    kind: Option<String>,
    detail: Option<String>,
) {
    if app.find(id).is_none() {
        return;
    }
    app.apply_status(id, |rt| {
        rt.status_state = state;
        rt.status_kind = kind;
        rt.status_detail = detail;
        rt.status_children.clear();
        rt.busy = matches!(state, Some(State::Working | State::Blocked));
    });
}

fn current(app: &App, id: Uuid, generation: u64) -> bool {
    app.find(id).is_some()
        && app.terminal(id).is_some()
        && CODEX.with(|c| {
            c.borrow()
                .sessions
                .get(&id)
                .is_some_and(|s| s.generation == generation)
        })
}

/// Connects to (or starts) the session's conversation, then types the
/// command that attaches the Codex TUI to the session's server.
pub fn start(app: &Rc<App>, id: Uuid, dir: &Path) {
    let Some((_, tab)) = app.tab(id) else { return };
    let Some(generation) = with(id, |s| {
        if s.starting {
            return None;
        }
        s.starting = true;
        s.generation += 1;
        Some(s.generation)
    }) else {
        return;
    };
    set_status(
        app,
        id,
        Some(State::Working),
        None,
        Some("Connecting to Codex…".into()),
    );
    let client = client(id);
    let (updates, inbox) = async_channel::unbounded();
    let dir = dir.to_path_buf();
    let saved = tab.codex_thread_id.clone();
    let name = tab.name.clone();
    let weak = Rc::downgrade(app);
    let stale_client = client.clone();
    background(
        move || client.start(&dir, saved, &name, env!("CARGO_PKG_VERSION"), updates),
        move |result| {
            let Some(app) = weak.upgrade() else { return };
            if !current(&app, id, generation) {
                // Closed, killed or restarted while connecting.
                if result.is_ok() {
                    stale_client.close();
                }
                return;
            }
            let setup = with(id, |s| {
                s.starting = false;
                s.setup.take()
            });
            match result {
                Ok((thread, command)) => {
                    app.update_tab(id, |t| t.codex_thread_id = Some(thread));
                    app.save_now();
                    let line = match setup {
                        Some(setup) => format!("{setup} && {command}\n"),
                        None => format!("{command}\n"),
                    };
                    if let Some(term) = app.terminal(id) {
                        term.write(line.as_bytes());
                    }
                    app.update_rt(id, |rt| {
                        rt.agent_connected = true;
                        rt.busy = false;
                    });
                }
                Err(err) => set_status(&app, id, Some(State::Error), None, Some(err.to_string())),
            }
        },
    );
    let weak = Rc::downgrade(app);
    glib::spawn_future_local(async move {
        while let Ok(update) = inbox.recv().await {
            let Some(app) = weak.upgrade() else { break };
            if !current(&app, id, generation) {
                break;
            }
            handle(&app, id, update);
        }
    });
}

fn handle(app: &Rc<App>, id: Uuid, update: Update) {
    match update {
        Update::Status {
            state,
            kind,
            detail,
        } => set_status(app, id, state.map(map_state), kind, detail),
        Update::ThreadChanged(thread) => {
            app.update_tab(id, |t| t.codex_thread_id = Some(thread));
            app.save_now();
        }
        Update::Agents(agents) => {
            with(id, |s| s.agents = agents);
            app.refresh_session(id);
        }
        Update::Disconnected(_) => app.update_rt(id, |rt| rt.agent_connected = false),
        Update::Usage(usage) => {
            CODEX.with(|c| {
                let mut c = c.borrow_mut();
                if usage.plan.is_some() {
                    c.plan = usage.plan.clone();
                }
                c.usage = Some(Ok(usage));
            });
            crate::usage::redraw(app);
        }
    }
}

/// Stops the session's server and forgets any start in progress.
pub fn close(_app: &Rc<App>, id: Uuid) {
    let existing = CODEX.with(|c| {
        c.borrow_mut().sessions.get_mut(&id).map(|s| {
            s.generation += 1;
            s.starting = false;
            s.agents.clear();
            s.client.clone()
        })
    });
    if let Some(client) = existing {
        client.close();
    }
}

/// After the session is closed for good.
pub fn forget(id: Uuid) {
    CODEX.with(|c| c.borrow_mut().sessions.remove(&id));
}

fn alert(app: &Rc<App>, heading: &str, err: &str) {
    crate::ui::dialogs::info(app, heading, err);
}

/// Interrupts every running turn of the session (root and subagents). A
/// start still connecting is cancelled instead, as on the Mac.
pub fn interrupt(app: &Rc<App>, id: Uuid) {
    if is_starting(app, id) {
        app.kill(id);
        return;
    }
    let client = client(id);
    if !client.is_ready() {
        // The TUI runs without its server: stop it like any program.
        if let Some(term) = app.terminal(id) {
            term.write(b"\x03");
        }
        return;
    }
    let weak = Rc::downgrade(app);
    background(
        move || client.interrupt(),
        move |result| {
            if let (Err(err), Some(app)) = (result, weak.upgrade()) {
                alert(&app, "Couldn't interrupt Codex", &err.to_string());
            }
        },
    );
}

/// Interrupts, closes the server and waits for it to exit (before a
/// worktree is deleted).
pub fn detach(id: Uuid, done: impl FnOnce(Result<(), String>) + 'static) {
    let client = client(id);
    with(id, |s| s.generation += 1);
    background(move || client.detach().map_err(|e| e.to_string()), done);
}

/// Allow or Deny the pending approval over the protocol.
pub fn answer(app: &Rc<App>, id: Uuid, allow: bool) {
    if with(id, |s| std::mem::replace(&mut s.answering, true)) {
        return;
    }
    let client = client(id);
    let weak = Rc::downgrade(app);
    background(
        move || client.answer(allow),
        move |result| {
            with(id, |s| s.answering = false);
            let Some(app) = weak.upgrade() else { return };
            if let Err(err) = result {
                alert(&app, "Couldn't answer Codex", &err.to_string());
            }
            app.refresh_session(id);
        },
    );
}

/// The pending approval's detail text, if Codex is waiting for one.
pub fn pending_approval(_app: &App, id: Uuid) -> Option<String> {
    CODEX.with(|c| {
        c.borrow()
            .sessions
            .get(&id)
            .filter(|s| !s.answering)
            .and_then(|s| s.client.pending_approval())
            .map(|a| a.detail)
    })
}

pub fn shutdown(_app: &App) {
    CODEX.with(|c| {
        for session in c.borrow().sessions.values() {
            session.client.close();
        }
    });
    if let Some(catalog) = CATALOG.get() {
        catalog.shutdown();
    }
}

/// Recent Codex conversations (from the catalog app-server). Blocking.
pub fn recent() -> Result<Vec<crate::ui::recent::Conversation>, String> {
    catalog()
        .recent(300)
        .map(|list| {
            list.into_iter()
                .map(|c| crate::ui::recent::Conversation {
                    provider: SessionProvider::Codex,
                    id: c.id,
                    cwd: c.cwd,
                    prompt: c.name,
                    date: c.updated_at,
                })
                .collect()
        })
        .map_err(|e| e.to_string())
}

/// Checks Codex usage now (a click on the usage strip).
pub fn refresh_usage() {
    CODEX.with(|c| c.borrow_mut().usage_checked = None);
}

/// The selected Codex session's plan limits and plan name. Checks again
/// when the last check is older than the usage interval (30 s at least).
pub fn usage(app: &App) -> (Option<crate::usage::Usage>, Option<String>) {
    let interval = app.settings.borrow().usage_interval.max(30.0);
    let stale = CODEX.with(|c| {
        c.borrow()
            .usage_checked
            .is_none_or(|t| t.elapsed() > Duration::from_secs_f64(interval))
    });
    if stale {
        CODEX.with(|c| c.borrow_mut().usage_checked = Some(Instant::now()));
        background(
            || catalog().usage().map_err(|e| e.to_string()),
            |result| {
                CODEX.with(|c| {
                    let mut c = c.borrow_mut();
                    if let Ok(usage) = &result {
                        if usage.plan.is_some() {
                            c.plan = usage.plan.clone();
                        }
                    }
                    c.usage = Some(result);
                });
                if let Some(app) = crate::ui::files::app() {
                    crate::usage::redraw(&app);
                    crate::ui::welcome::usage_changed(&app);
                }
            },
        );
    }
    CODEX.with(|c| {
        let c = c.borrow();
        let plan = c.plan.clone();
        match c.usage.clone() {
            Some(Ok(usage)) => {
                let limits = usage
                    .limits
                    .iter()
                    .map(|l| crate::usage::Limit {
                        label: l.label.clone(),
                        percent: l.percent,
                        resets_at: l.resets_at,
                    })
                    .collect();
                (Some(crate::usage::Usage::Limits(limits)), plan)
            }
            Some(Err(err)) => (Some(crate::usage::Usage::Problem(err.clone(), err)), plan),
            None => (None, plan),
        }
    })
}

pub fn agents(id: Uuid) -> Vec<CodexAgent> {
    CODEX.with(|c| {
        c.borrow()
            .sessions
            .get(&id)
            .map(|s| s.agents.clone())
            .unwrap_or_default()
    })
}

/// "N agents" in the session header, listing Codex subagents; clicking one
/// shows its recent activity.
pub fn header_agents(_app: &App, id: Uuid, container: &gtk::Box) {
    let list = agents(id);
    if list.is_empty() {
        return;
    }
    let running = list.iter().filter(|a| !a.finished).count();
    let label = match running {
        0 => "agents done".to_string(),
        1 => "1 agent".to_string(),
        n => format!("{n} agents"),
    };
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    content.append(&gtk::Image::from_icon_name("system-users-symbolic"));
    let text = gtk::Label::new(Some(&label));
    text.add_css_class("omux-status");
    content.append(&text);
    let button = gtk::MenuButton::builder().child(&content).build();
    button.add_css_class("flat");
    button.set_create_popup_func(move |button| {
        let rows = gtk::ListBox::new();
        rows.add_css_class("boxed-list");
        rows.set_selection_mode(gtk::SelectionMode::None);
        for agent in agents(id) {
            let row = adw::ActionRow::new();
            row.set_title(&glib::markup_escape_text(&agent.name));
            row.set_subtitle(&agent.state);
            let dot = crate::ui::sidebar::dot();
            crate::ui::sidebar::set_dot(&dot, Some(if agent.finished { "green" } else { "blue" }));
            row.add_prefix(&dot);
            row.set_activatable(true);
            let thread = agent.thread_id.clone();
            let name = agent.name.clone();
            row.connect_activated(move |_| show_transcript(id, &thread, &name));
            rows.append(&row);
        }
        let scroller = gtk::ScrolledWindow::builder()
            .child(&rows)
            .min_content_width(320)
            .max_content_height(360)
            .propagate_natural_height(true)
            .build();
        scroller.set_margin_start(8);
        scroller.set_margin_end(8);
        scroller.set_margin_top(8);
        scroller.set_margin_bottom(8);
        let popover = gtk::Popover::new();
        popover.set_child(Some(&scroller));
        button.set_popover(Some(&popover));
    });
    container.append(&button);
}

/// A Codex subagent's recent activity (up to 100 items), refreshed every
/// 2 s while shown, in the Files tab's preview area.
fn show_transcript(id: Uuid, thread: &str, name: &str) {
    let Some(app) = crate::ui::files::app() else {
        return;
    };
    crate::ui::panel::show_tab(&app, "files");
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let title = gtk::Label::new(Some(&format!("{name} · Recent activity · up to 100 items")));
    title.add_css_class("omux-header-name");
    title.set_xalign(0.0);
    title.set_margin_start(10);
    title.set_margin_top(6);
    title.set_margin_bottom(6);
    vbox.append(&title);
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    holder.set_vexpand(true);
    let waiting = gtk::Label::new(Some("Waiting for the agent's transcript…"));
    waiting.add_css_class("dim-label");
    waiting.set_vexpand(true);
    holder.append(&waiting);
    vbox.append(&holder);
    crate::ui::files::set_preview_widget(&vbox);

    let thread = thread.to_string();
    let last = Rc::new(RefCell::new(String::new()));
    let in_flight = Rc::new(std::cell::Cell::new(false));
    let refresh = move || {
        let alive = holder.root().is_some();
        if !alive {
            return false;
        }
        // One request at a time: a stuck server must not pile up workers.
        if in_flight.replace(true) {
            return true;
        }
        let done = in_flight.clone();
        let client = client(id);
        let thread = thread.clone();
        let holder = holder.downgrade();
        let last = last.clone();
        background(
            move || client.transcript(&thread),
            move |result| {
                done.set(false);
                let Some(holder) = holder.upgrade() else {
                    return;
                };
                let text = match result {
                    Ok(text) => text,
                    Err(err) => format!("_{err}_"),
                };
                if *last.borrow() == text || text.is_empty() {
                    return;
                }
                *last.borrow_mut() = text.clone();
                while let Some(child) = holder.first_child() {
                    holder.remove(&child);
                }
                let view = crate::ui::markdown::render(&text, true);
                let scroller = gtk::ScrolledWindow::builder()
                    .child(&view)
                    .vexpand(true)
                    .build();
                holder.append(&scroller);
            },
        );
        true
    };
    refresh();
    glib::timeout_add_local(Duration::from_secs(2), move || {
        if refresh() {
            glib::ControlFlow::Continue
        } else {
            glib::ControlFlow::Break
        }
    });
}
