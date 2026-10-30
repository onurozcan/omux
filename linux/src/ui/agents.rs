//! Claude Code subagents: the 2-second monitor, sidebar rows, the header
//! pill with its list, and the transcript view.

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

use adw::prelude::*;
use gtk::glib;
use uuid::Uuid;

use crate::app::App;
use crate::claude::{AgentScanner, JsonlReader, SubAgent, TranscriptEvent};
use crate::model::SessionProvider;
use crate::term::status::State;

type ScanRequest = Vec<(Uuid, Uuid, bool)>;
type ScanResult = HashMap<Uuid, Vec<SubAgent>>;

#[derive(Default)]
struct Monitor {
    agents: HashMap<Uuid, Vec<SubAgent>>,
    requests: Option<mpsc::Sender<ScanRequest>>,
    scanning: bool,
    /// Sessions whose sidebar list shows every agent ("+N more" opened).
    expanded: HashSet<Uuid>,
}

thread_local! {
    static MONITOR: RefCell<Monitor> = RefCell::new(Monitor::default());
}

/// Starts the scanner thread and the 2-second poll.
pub fn install(app: &Rc<App>) {
    let (requests, inbox) = mpsc::channel::<ScanRequest>();
    let (results, outbox) = async_channel::unbounded::<ScanResult>();
    std::thread::Builder::new()
        .name("omux-agents".into())
        .spawn(move || {
            let mut scanner = AgentScanner::default();
            while let Ok(sessions) = inbox.recv() {
                let mut found = HashMap::new();
                for (tab, session, active) in sessions {
                    let agents = scanner.scan(session, active);
                    if !agents.is_empty() {
                        found.insert(tab, agents);
                    }
                }
                if results.send_blocking(found).is_err() {
                    break;
                }
            }
        })
        .expect("agent scanner thread");
    MONITOR.with(|m| m.borrow_mut().requests = Some(requests));

    let weak = Rc::downgrade(app);
    glib::spawn_future_local(async move {
        while let Ok(found) = outbox.recv().await {
            let Some(app) = weak.upgrade() else { break };
            apply(&app, found);
        }
    });
    let weak = Rc::downgrade(app);
    glib::timeout_add_local(Duration::from_secs(2), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        poll(&app);
        glib::ControlFlow::Continue
    });
}

/// Scans Claude sessions that are active, or that still list agents.
fn poll(app: &Rc<App>) {
    let sessions: ScanRequest = {
        let ws = app.ws.borrow();
        ws.groups
            .iter()
            .flat_map(|g| g.tabs.iter().map(move |t| (g, t)))
            .filter(|(g, t)| t.resolved_provider(g) == SessionProvider::Claude)
            .filter_map(|(_, t)| {
                let rt = app.rt(t.id);
                let active = !rt.exited
                    && (rt.busy
                        || matches!(rt.status_state, Some(State::Working | State::Blocked)));
                let known = MONITOR.with(|m| m.borrow().agents.contains_key(&t.id));
                (active || known).then_some((t.id, t.claude_session_id, active))
            })
            .collect()
    };
    MONITOR.with(|m| {
        let mut m = m.borrow_mut();
        if m.scanning {
            return;
        }
        if sessions.is_empty() && m.agents.is_empty() {
            return;
        }
        if let Some(requests) = &m.requests {
            if requests.send(sessions).is_ok() {
                m.scanning = true;
            }
        }
    });
}

fn apply(app: &Rc<App>, mut found: ScanResult) {
    // Blocked: an OSC 7501 child record that's blocked and describes the agent.
    for (tab, agents) in found.iter_mut() {
        let children = app.rt(*tab).status_children;
        for agent in agents.iter_mut().filter(|a| !a.finished) {
            agent.blocked = children.iter().any(|c| {
                c.state == State::Blocked
                    && agent.matches(&c.id, c.title.as_deref(), c.message.as_deref())
            });
        }
    }
    let changed: Vec<Uuid> = MONITOR.with(|m| {
        let mut m = m.borrow_mut();
        m.scanning = false;
        let mut changed: Vec<Uuid> = found
            .iter()
            .filter(|(id, agents)| m.agents.get(id) != Some(agents))
            .map(|(id, _)| *id)
            .collect();
        changed.extend(m.agents.keys().filter(|id| !found.contains_key(id)));
        m.agents = found;
        changed
    });
    for id in changed {
        app.refresh_session(id);
    }
}

pub fn agents(id: Uuid) -> Vec<SubAgent> {
    MONITOR.with(|m| m.borrow().agents.get(&id).cloned().unwrap_or_default())
}

pub fn running_count(_app: &App, id: Uuid) -> usize {
    MONITOR.with(|m| {
        m.borrow()
            .agents
            .get(&id)
            .map_or(0, |a| a.iter().filter(|a| !a.finished).count())
    })
}

fn agent_dot(agent: &SubAgent) -> gtk::Box {
    let dot = crate::ui::sidebar::dot();
    crate::ui::sidebar::set_dot(&dot, Some(agent.color()));
    if agent.background {
        dot.add_css_class("ring");
    }
    dot
}

/// The selected session lists all its agents; others only blocked ones.
/// Three at most until "+N more" is clicked.
pub fn update_sidebar(app: &App, id: Uuid, container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
    crate::ui::worktree_actions::sidebar_extras(app, id, container);
    container.set_visible(container.first_child().is_some());
    let selected = app.selected.get() == Some(id);
    if selected {
        for agent in crate::codex::agents(id) {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
            let dot = crate::ui::sidebar::dot();
            crate::ui::sidebar::set_dot(&dot, Some(if agent.finished { "green" } else { "blue" }));
            row.append(&dot);
            let name = gtk::Label::new(Some(&agent.name));
            name.add_css_class("omux-status");
            name.set_ellipsize(gtk::pango::EllipsizeMode::End);
            name.set_xalign(0.0);
            name.set_hexpand(true);
            row.append(&name);
            let state = gtk::Label::new(Some(&agent.state));
            state.add_css_class("omux-status");
            row.append(&state);
            container.append(&row);
            container.set_visible(true);
        }
    }
    let mut list: Vec<SubAgent> = agents(id);
    if !selected {
        list.retain(|a| a.blocked);
    }
    if list.is_empty() {
        return;
    }
    container.set_visible(true);
    let expanded = MONITOR.with(|m| m.borrow().expanded.contains(&id));
    let shown = if expanded {
        list.len()
    } else {
        list.len().min(3)
    };
    for agent in &list[..shown] {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.set_margin_start(((agent.depth.min(3) - 1) * 10) as i32);
        row.append(&agent_dot(agent));
        let label = gtk::Label::new(Some(&agent.description));
        label.add_css_class("omux-status");
        label.set_ellipsize(gtk::pango::EllipsizeMode::End);
        label.set_xalign(0.0);
        label.set_hexpand(true);
        row.append(&label);
        let activity = gtk::Label::new(Some(&agent.short_activity()));
        activity.add_css_class("omux-status");
        row.append(&activity);
        row.set_tooltip_text(Some(&format!(
            "{} · {}",
            agent.kind,
            agent.activity.as_deref().unwrap_or("starting")
        )));
        let click = gtk::GestureClick::new();
        let agent = agent.clone();
        click.connect_released(move |_, _, _, _| open_transcript(id, &agent));
        row.add_controller(click);
        container.append(&row);
    }
    if list.len() > 3 {
        let toggle = gtk::Button::with_label(&if expanded {
            "Show less".to_string()
        } else {
            format!("+{} more", list.len() - 3)
        });
        toggle.add_css_class("flat");
        toggle.add_css_class("omux-small");
        toggle.set_halign(gtk::Align::Start);
        let weak = app.ui.window.downgrade();
        toggle.connect_clicked(move |_| {
            MONITOR.with(|m| {
                let mut m = m.borrow_mut();
                if !m.expanded.remove(&id) {
                    m.expanded.insert(id);
                }
            });
            if let Some(window) = weak.upgrade() {
                let _ = WidgetExt::activate_action(&window, "app.refresh-sidebar", None);
            }
        });
        container.append(&toggle);
    }
}

/// The header's agent pill: up to eight dots and a count, opening the list.
pub fn update_header(app: &App, id: Uuid, container: &gtk::Box) {
    while let Some(child) = container.first_child() {
        container.remove(&child);
    }
    let list = agents(id);
    if !list.is_empty() {
        let pill = gtk::Box::new(gtk::Orientation::Horizontal, 3);
        for agent in list.iter().take(8) {
            pill.append(&agent_dot(agent));
        }
        let running = list.iter().filter(|a| !a.finished).count();
        let text = match running {
            0 => "agents done".to_string(),
            1 => "1 agent".to_string(),
            n => format!("{n} agents"),
        };
        let label = gtk::Label::new(Some(&text));
        label.add_css_class("omux-status");
        label.set_margin_start(4);
        pill.append(&label);
        let button = gtk::MenuButton::builder()
            .child(&pill)
            .tooltip_text("Subagents in this session")
            .build();
        button.add_css_class("flat");
        button.set_create_popup_func(move |button| {
            let popover = agent_list(id);
            // Elapsed times tick and states change while the list is open.
            let weak = popover.downgrade();
            glib::timeout_add_local(Duration::from_secs(1), move || {
                let Some(popover) = weak.upgrade() else {
                    return glib::ControlFlow::Break;
                };
                if popover.is_visible() {
                    if let Some(fresh) = agent_list(id).child() {
                        fresh.unparent();
                        popover.set_child(Some(&fresh));
                    }
                }
                glib::ControlFlow::Continue
            });
            button.set_popover(Some(&popover));
        });
        container.append(&button);
    }
    crate::codex::header_agents(app, id, container);
    crate::ui::worktree_actions::header_chips(app, id, container);
}

fn agent_list(id: Uuid) -> gtk::Popover {
    let list = agents(id);
    let running = list.iter().filter(|a| !a.finished).count();
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 8);
    vbox.set_margin_start(12);
    vbox.set_margin_end(12);
    vbox.set_margin_top(10);
    vbox.set_margin_bottom(10);
    let title = gtk::Label::new(None);
    title.set_markup(&format!(
        "<b>Agents</b>  <span alpha=\"60%\">{running} running · {} done</span>",
        list.len() - running
    ));
    title.set_xalign(0.0);
    vbox.append(&title);
    let rows = gtk::ListBox::new();
    rows.add_css_class("boxed-list");
    rows.set_selection_mode(gtk::SelectionMode::None);
    for agent in &list {
        let row = adw::ActionRow::new();
        row.set_title(&glib::markup_escape_text(&agent.description));
        let state = if agent.blocked {
            "Needs permission".to_string()
        } else if agent.finished {
            "Done".to_string()
        } else {
            agent.activity.clone().unwrap_or_else(|| "starting".into())
        };
        let mut subtitle = format!("{} · {state}", agent.kind);
        if agent.tool_count > 0 {
            subtitle.push_str(&format!(
                " · {} tool{}",
                agent.tool_count,
                if agent.tool_count == 1 { "" } else { "s" }
            ));
        }
        if agent.background {
            subtitle.push_str(" · background");
        }
        row.set_subtitle(&glib::markup_escape_text(&subtitle));
        row.add_prefix(&agent_dot(agent));
        let elapsed = gtk::Label::new(Some(&agent.elapsed_text()));
        elapsed.add_css_class("omux-status");
        row.add_suffix(&elapsed);
        row.set_activatable(true);
        let agent = agent.clone();
        row.connect_activated(move |_| open_transcript(id, &agent));
        rows.append(&row);
    }
    let scroller = gtk::ScrolledWindow::builder()
        .child(&rows)
        .min_content_width(400)
        .max_content_height(420)
        .propagate_natural_height(true)
        .build();
    vbox.append(&scroller);
    let footer = gtk::Label::new(Some("Click an agent to open its transcript"));
    footer.add_css_class("omux-status");
    vbox.append(&footer);
    let popover = gtk::Popover::new();
    popover.set_child(Some(&vbox));
    popover
}

fn open_transcript(id: Uuid, agent: &SubAgent) {
    crate::ui::panel::show_transcript(id, agent);
}

// MARK: transcript view

struct Entry {
    kind: &'static str,
    title: String,
    result: Option<String>,
    error: bool,
}

/// A subagent's transcript, re-read every 1.5 s while it's on screen.
pub fn transcript_view(path: PathBuf) -> gtk::Widget {
    let list = gtk::Box::new(gtk::Orientation::Vertical, 10);
    list.set_margin_start(14);
    list.set_margin_end(14);
    list.set_margin_top(12);
    list.set_margin_bottom(12);
    let scroller = gtk::ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    // The file is read on a worker thread; a large transcript would
    // otherwise stall the UI every 1.5 s.
    let reader = Arc::new(Mutex::new(JsonlReader::default()));
    let entries: Rc<RefCell<Vec<Entry>>> = Rc::default();
    let tools: Rc<RefCell<HashMap<String, usize>>> = Rc::default();
    let loading = Rc::new(Cell::new(false));
    let load = {
        let list = list.clone();
        let scroller = scroller.clone();
        move || {
            if loading.replace(true) {
                return;
            }
            let (reader, path) = (reader.clone(), path.clone());
            let (list, scroller, entries, tools, loading) = (
                list.clone(),
                scroller.clone(),
                entries.clone(),
                tools.clone(),
                loading.clone(),
            );
            crate::ui::panel::background(
                move || reader.lock().map(|mut r| r.read(&path)).unwrap_or_default(),
                move |objects| {
                    loading.set(false);
                    let mut entries = entries.borrow_mut();
                    let events = crate::claude::transcript_events(&objects, !entries.is_empty());
                    if events.is_empty() {
                        return;
                    }
                    for event in events {
                        match event {
                            TranscriptEvent::Task(text) => entries.push(Entry {
                                kind: "task",
                                title: text,
                                result: None,
                                error: false,
                            }),
                            TranscriptEvent::Text(text) => entries.push(Entry {
                                kind: "text",
                                title: text,
                                result: None,
                                error: false,
                            }),
                            TranscriptEvent::Tool { id, title } => {
                                tools.borrow_mut().insert(id, entries.len());
                                entries.push(Entry {
                                    kind: "tool",
                                    title,
                                    result: None,
                                    error: false,
                                });
                            }
                            TranscriptEvent::Result { id, text, error } => {
                                if let Some(index) = tools.borrow().get(&id) {
                                    let first =
                                        text.trim().lines().next().unwrap_or("").to_string();
                                    let first = if first.is_empty() {
                                        "Done".to_string()
                                    } else {
                                        first
                                    };
                                    entries[*index].result = Some(truncate(&first, 140));
                                    entries[*index].error = error;
                                }
                            }
                        }
                    }
                    render(&list, &entries);
                    let adjustment = scroller.vadjustment();
                    glib::idle_add_local_once(move || adjustment.set_value(adjustment.upper()));
                },
            );
        }
    };
    load();
    let alive = scroller.downgrade();
    glib::timeout_add_local(Duration::from_millis(1500), move || {
        if alive.upgrade().is_none() {
            return glib::ControlFlow::Break;
        }
        load();
        glib::ControlFlow::Continue
    });
    scroller.upcast()
}

fn truncate(text: &str, max: usize) -> String {
    if text.chars().count() > max {
        format!("{}…", text.chars().take(max).collect::<String>())
    } else {
        text.to_string()
    }
}

fn render(list: &gtk::Box, entries: &[Entry]) {
    while let Some(child) = list.first_child() {
        list.remove(&child);
    }
    for entry in entries {
        match entry.kind {
            "task" => {
                let card = gtk::Box::new(gtk::Orientation::Vertical, 4);
                card.add_css_class("card");
                card.set_margin_bottom(4);
                let title = gtk::Label::new(Some("TASK"));
                title.add_css_class("caption-heading");
                title.set_xalign(0.0);
                title.set_margin_start(10);
                title.set_margin_top(8);
                card.append(&title);
                let text = selectable(&truncate(&entry.title, 1500));
                text.set_margin_start(10);
                text.set_margin_end(10);
                text.set_margin_bottom(8);
                card.append(&text);
                list.append(&card);
            }
            "text" => list.append(&selectable(&truncate(&entry.title, 3000))),
            _ => {
                let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
                let dot = crate::ui::sidebar::dot();
                let color = match (&entry.result, entry.error) {
                    (_, true) => "red",
                    (None, _) => "blue",
                    _ => "green",
                };
                crate::ui::sidebar::set_dot(&dot, Some(color));
                dot.set_valign(gtk::Align::Start);
                dot.set_margin_top(5);
                row.append(&dot);
                let vbox = gtk::Box::new(gtk::Orientation::Vertical, 2);
                let title = gtk::Label::new(Some(&entry.title));
                title.add_css_class("omux-mono");
                title.set_xalign(0.0);
                title.set_wrap(true);
                title.set_lines(3);
                title.set_ellipsize(gtk::pango::EllipsizeMode::End);
                vbox.append(&title);
                let result = gtk::Label::new(Some(&format!(
                    "⎿  {}",
                    entry.result.as_deref().unwrap_or("Running…")
                )));
                result.add_css_class("omux-status");
                result.add_css_class("omux-mono");
                result.set_xalign(0.0);
                result.set_wrap(true);
                result.set_lines(2);
                result.set_ellipsize(gtk::pango::EllipsizeMode::End);
                vbox.append(&result);
                row.append(&vbox);
                list.append(&row);
            }
        }
    }
}

fn selectable(text: &str) -> gtk::Label {
    let label = gtk::Label::new(Some(text));
    label.set_selectable(true);
    label.set_wrap(true);
    label.set_wrap_mode(gtk::pango::WrapMode::WordChar);
    label.set_xalign(0.0);
    label
}
