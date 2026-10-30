//! The app's central model, the Linux counterpart of `Store.swift`: projects
//! and sessions, each session's terminal and live state, attention and
//! notifications, and saving.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

use adw::prelude::*;
use gtk::{gio, glib};
use uuid::Uuid;
use vte::prelude::*;

use crate::model::{SessionProvider, TabGroup, TabItem, Workspace};
use crate::notify;
use crate::persistence::{self, expand_tilde, home_dir};
use crate::runtime::TabRuntime;
use crate::session_env;
use crate::settings::Settings;
use crate::term::status::State;
use crate::term::{SessionTerminal, TermEvent};
use crate::ui::window::Ui;

pub struct App {
    pub gtk_app: adw::Application,
    pub ui: Ui,
    pub ws: Rc<RefCell<Workspace>>,
    pub settings: RefCell<Settings>,
    pub runtime: RefCell<HashMap<Uuid, TabRuntime>>,
    pub terminals: RefCell<HashMap<Uuid, Rc<SessionTerminal>>>,
    pub selected: Cell<Option<Uuid>>,
    /// The pending debounced save. The timer clears it when it fires, so a
    /// fired source is never removed (glib panics on that).
    save_source: Rc<RefCell<Option<glib::SourceId>>>,
    /// Ids of the sessions whose name is being edited in the sidebar.
    pub renaming: Cell<Option<Uuid>>,
    pub renaming_group: Cell<Option<Uuid>>,
}

impl App {
    pub fn new(gtk_app: &adw::Application) -> Rc<Self> {
        let settings = Settings::load();
        let saved = persistence::load_workspace();
        let fresh = saved.is_none();
        let ws = saved.unwrap_or_else(|| Workspace {
            groups: vec![TabGroup::new(
                "Default",
                None,
                vec![TabItem::new("Session 1")],
            )],
            selected_tab_id: None,
        });
        let ui = Ui::build(gtk_app);
        let app = Rc::new(Self {
            gtk_app: gtk_app.clone(),
            ui,
            ws: Rc::new(RefCell::new(ws)),
            settings: RefCell::new(settings),
            runtime: RefCell::new(HashMap::new()),
            terminals: RefCell::new(HashMap::new()),
            selected: Cell::new(None),
            save_source: Rc::new(RefCell::new(None)),
            renaming: Cell::new(None),
            renaming_group: Cell::new(None),
        });

        // Restored sessions stay stopped until started, unless auto-resume is on.
        let ids = app.all_tab_ids();
        let resume = app.settings.borrow().auto_resume;
        for id in &ids {
            let rt = if resume {
                TabRuntime::default()
            } else {
                TabRuntime::stopped()
            };
            app.runtime.borrow_mut().insert(*id, rt);
        }
        let selection = {
            let ws = app.ws.borrow();
            ws.selected_tab_id
                .filter(|id| ids.contains(id))
                .or_else(|| ws.groups.iter().find_map(|g| g.tabs.first().map(|t| t.id)))
        };

        crate::ui::window::connect(&app);
        crate::actions::install(&app);
        crate::ui::agents::install(&app);
        crate::usage::install(&app);
        app.apply_theme();
        if fresh {
            app.save_now();
        }

        let auto_resume = app.settings.borrow().auto_resume;
        if let Some(id) = selection {
            app.select(id);
        }
        if auto_resume {
            app.start_all_sessions(selection);
        }
        app.refresh_all();

        let welcomed = app.settings.borrow().welcomed;
        if !welcomed {
            app.settings.borrow_mut().welcomed = true;
            app.settings.borrow().save();
            if fresh {
                let weak = Rc::downgrade(&app);
                glib::timeout_add_local_once(Duration::from_millis(500), move || {
                    if let Some(app) = weak.upgrade() {
                        crate::ui::welcome::present(&app);
                    }
                });
            }
        }

        // Busy is "something other than the shell is in the foreground"; it
        // is cheap to read, so poll it instead of guessing from events.
        let weak = Rc::downgrade(&app);
        glib::timeout_add_local(Duration::from_secs(1), move || {
            let Some(app) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            app.refresh_busy_all();
            glib::ControlFlow::Continue
        });
        app
    }

    // MARK: lookup

    pub fn all_tab_ids(&self) -> Vec<Uuid> {
        self.ws
            .borrow()
            .groups
            .iter()
            .flat_map(|g| g.tabs.iter().map(|t| t.id))
            .collect()
    }

    pub fn find(&self, id: Uuid) -> Option<(usize, usize)> {
        self.ws
            .borrow()
            .groups
            .iter()
            .enumerate()
            .find_map(|(gi, g)| g.tabs.iter().position(|t| t.id == id).map(|ti| (gi, ti)))
    }

    /// A copy of a session and its project.
    pub fn tab(&self, id: Uuid) -> Option<(TabGroup, TabItem)> {
        let (gi, ti) = self.find(id)?;
        let ws = self.ws.borrow();
        let group = ws.groups[gi].clone();
        let tab = group.tabs[ti].clone();
        Some((group, tab))
    }

    pub fn group_index(&self, group_id: Uuid) -> Option<usize> {
        self.ws
            .borrow()
            .groups
            .iter()
            .position(|g| g.id == group_id)
    }

    pub fn update_tab(&self, id: Uuid, change: impl FnOnce(&mut TabItem)) {
        if let Some((gi, ti)) = self.find(id) {
            change(&mut self.ws.borrow_mut().groups[gi].tabs[ti]);
            self.schedule_save();
        }
    }

    pub fn update_group(&self, group_id: Uuid, change: impl FnOnce(&mut TabGroup)) {
        if let Some(gi) = self.group_index(group_id) {
            change(&mut self.ws.borrow_mut().groups[gi]);
            self.schedule_save();
        }
    }

    pub fn rt(&self, id: Uuid) -> TabRuntime {
        self.runtime.borrow().get(&id).cloned().unwrap_or_default()
    }

    /// Changes a session's live state and redraws it if anything changed.
    pub fn update_rt(&self, id: Uuid, change: impl FnOnce(&mut TabRuntime)) {
        // A late update for a closed session must not bring its state back.
        if self.find(id).is_none() {
            return;
        }
        let changed = {
            let mut runtime = self.runtime.borrow_mut();
            let rt = runtime.entry(id).or_default();
            let before = format!("{rt:?}");
            change(rt);
            before != format!("{rt:?}")
        };
        if changed {
            self.refresh_session(id);
            self.update_badge();
        }
    }

    pub fn terminal(&self, id: Uuid) -> Option<Rc<SessionTerminal>> {
        self.terminals.borrow().get(&id).cloned()
    }

    pub fn directory(&self, group: &TabGroup, tab: &TabItem) -> PathBuf {
        tab.directory
            .as_deref()
            .or(group.directory.as_deref())
            .map(expand_tilde)
            .filter(|p| p.is_dir())
            .unwrap_or_else(home_dir)
    }

    // MARK: selection and attention

    pub fn select(self: &Rc<Self>, id: Uuid) {
        if self.find(id).is_none() {
            return;
        }
        let previous = self.selected.replace(Some(id));
        self.ws.borrow_mut().selected_tab_id = Some(id);
        self.schedule_save();
        if self.terminal(id).is_none() {
            let exited = self.rt(id).exited;
            // A restored session opens its plain shell; ▶ starts the agent.
            self.create_terminal(id, if exited { Some(String::new()) } else { None });
        }
        self.ui.show_terminal(self, id);
        // Deferred so the selection renders first, as on the Mac.
        let weak = Rc::downgrade(self);
        glib::idle_add_local_once(move || {
            if let Some(app) = weak.upgrade() {
                app.clear_attention(id);
            }
        });
        self.refresh_sidebar_selection();
        // Agent rows and counts differ between the selected session and others.
        if let Some(previous) = previous.filter(|p| *p != id) {
            self.refresh_session(previous);
        }
        self.refresh_session(id);
        self.ui.header.update(self);
        crate::ui::panel::selection_changed(self);
        crate::usage::redraw(self);
    }

    pub fn clear_attention(&self, id: Uuid) {
        self.update_rt(id, |rt| {
            rt.has_activity = false;
            rt.needs_attention = false;
        });
        self.gtk_app.withdraw_notification(&id.to_string());
    }

    /// Selected, and omux is the active window.
    pub fn is_watching(&self, id: Uuid) -> bool {
        self.selected.get() == Some(id) && self.ui.window.is_active()
    }

    pub fn request_attention(&self, id: Uuid) {
        if !self.is_watching(id) {
            self.update_rt(id, |rt| rt.needs_attention = true);
        }
    }

    pub fn update_badge(&self) {
        let count = self
            .runtime
            .borrow()
            .values()
            .filter(|rt| rt.needs_attention)
            .count();
        let title = if count > 0 {
            format!("({count}) omux")
        } else {
            "omux".to_string()
        };
        if self.ui.window.title().as_deref() != Some(title.as_str()) {
            self.ui.window.set_title(Some(&title));
            notify::launcher_count(&self.gtk_app, count);
        }
    }

    // MARK: terminals and processes

    fn create_terminal(self: &Rc<Self>, id: Uuid, command: Option<String>) -> Rc<SessionTerminal> {
        let terminal = SessionTerminal::new();
        crate::ui::terminal::configure(self, id, &terminal);
        let weak = Rc::downgrade(self);
        let term_ref = Rc::downgrade(&terminal);
        terminal.set_handler(move |event| {
            let (Some(app), Some(term)) = (weak.upgrade(), term_ref.upgrade()) else {
                return;
            };
            // A replaced terminal (restart) may still report; ignore it.
            if app
                .terminal(id)
                .is_some_and(|current| Rc::ptr_eq(&current, &term))
            {
                app.on_term_event(id, event);
            }
        });
        self.ui.add_terminal(id, &terminal);
        self.terminals.borrow_mut().insert(id, terminal.clone());
        self.launch(id, command);
        terminal
    }

    fn remove_terminal(&self, id: Uuid) {
        if let Some(terminal) = self.terminals.borrow_mut().remove(&id) {
            terminal.dispose();
            self.ui.remove_terminal(&terminal);
        }
    }

    /// Starts the session's login shell, then types its command into it, so
    /// that when the agent exits the user is back at a prompt.
    fn launch(self: &Rc<Self>, id: Uuid, command: Option<String>) {
        let Some((group, tab)) = self.tab(id) else {
            return;
        };
        let Some(terminal) = self.terminal(id) else {
            return;
        };
        let dir = self.directory(&group, &tab);
        let provider = tab.resolved_provider(&group);
        let token = (provider == SessionProvider::Codex).then(|| crate::codex::token_for(self, id));
        let env = session_env::build(session_env::Extra {
            codex_token: token.as_deref(),
            repo: tab.worktree.as_ref().map(|w| w.repo.as_str()),
        });
        let started = terminal.spawn(&session_env::shell(), &dir, env);
        self.update_rt(id, |rt| {
            *rt = TabRuntime {
                provider: Some(provider),
                exited: started.is_err(),
                cwd: Some(dir.display().to_string()),
                needs_attention: rt.needs_attention,
                ..TabRuntime::default()
            };
        });
        if let Err(err) = started {
            terminal.widget.feed(
                format!("omux: couldn't start {}: {err}\r\n", session_env::shell()).as_bytes(),
            );
            return;
        }
        if provider == SessionProvider::Codex && command.is_none() {
            crate::codex::start(self, id, &dir);
            return;
        }
        let command = command.or_else(|| self.startup_command(id));
        if let Some(command) = command.filter(|c| !c.is_empty()) {
            self.type_later(id, format!("{command}\n"), Duration::from_millis(300));
        }
    }

    /// Types text into the session's shell after a delay.
    pub fn type_later(self: &Rc<Self>, id: Uuid, text: String, delay: Duration) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(delay, move || {
            if let Some(term) = weak.upgrade().and_then(|app| app.terminal(id)) {
                term.write(text.as_bytes());
            }
        });
    }

    /// The command a session starts with: none for shells, custom commands
    /// verbatim, Claude pinned to the session's conversation.
    pub fn startup_command(&self, id: Uuid) -> Option<String> {
        let (group, tab) = self.tab(id)?;
        let raw = tab
            .command
            .clone()
            .or(group.command.clone())
            .unwrap_or_default()
            .trim_matches(' ')
            .to_string();
        let provider = tab.resolved_provider(&group);
        if provider == SessionProvider::Shell || raw.is_empty() {
            return None;
        }
        if provider != SessionProvider::Claude {
            return Some(raw);
        }
        let exists = crate::claude::conversation_exists(tab.claude_session_id);
        Some(SessionProvider::claude_command(
            &raw,
            tab.claude_session_id,
            exists,
        ))
    }

    pub fn start_all_sessions(self: &Rc<Self>, first: Option<Uuid>) {
        let mut ids = self.all_tab_ids();
        if let Some(first) = first {
            ids.retain(|id| *id != first);
            ids.insert(0, first);
        }
        for (i, id) in ids.into_iter().enumerate() {
            let weak = Rc::downgrade(self);
            glib::timeout_add_local_once(Duration::from_millis(250 * i as u64), move || {
                let Some(app) = weak.upgrade() else { return };
                // Already started (selected, or clicked meanwhile) or closed.
                if app.terminal(id).is_some() || app.find(id).is_none() {
                    return;
                }
                app.create_terminal(id, None);
                app.refresh_session(id);
            });
        }
    }

    /// ▶: start the agent, or continue its conversation.
    pub fn start(self: &Rc<Self>, id: Uuid) {
        let Some((group, tab)) = self.tab(id) else {
            return;
        };
        let provider = tab.resolved_provider(&group);
        let rt = self.rt(id);
        let live = self.terminal(id).filter(|t| t.is_running());
        if let Some(term) = &live {
            if provider == SessionProvider::Codex
                && rt.status_state == Some(State::Error)
                && !crate::codex::is_connected(id)
            {
                return self.restart(id);
            }
            if term.is_busy() || crate::codex::is_starting(self, id) {
                return;
            }
            if rt.provider.is_some_and(|p| p != provider) {
                return self.restart(id);
            }
        }
        if provider != SessionProvider::Claude {
            match live {
                Some(_) if provider == SessionProvider::Codex => {
                    let dir = rt
                        .cwd
                        .map(PathBuf::from)
                        .unwrap_or_else(|| self.directory(&group, &tab));
                    crate::codex::start(self, id, &dir);
                }
                Some(term) => {
                    if let Some(command) = self.startup_command(id) {
                        term.write(format!("{command}\n").as_bytes());
                    }
                }
                None => self.restart(id),
            }
            return;
        }
        let command = self.startup_command(id).unwrap_or_else(|| {
            format!(
                "claude --session-id {}",
                tab.claude_session_id.to_string().to_lowercase()
            )
        });
        match live {
            Some(term) => {
                if !rt.busy {
                    term.write(format!("{command}\n").as_bytes());
                }
            }
            None => {
                self.remove_terminal(id);
                self.create_terminal(id, Some(command));
                if self.selected.get() == Some(id) {
                    self.ui.show_terminal(self, id);
                }
            }
        }
        self.refresh_busy_later(id);
    }

    pub fn restart(self: &Rc<Self>, id: Uuid) {
        crate::codex::close(self, id);
        self.remove_terminal(id);
        self.create_terminal(id, None);
        if self.selected.get() == Some(id) {
            self.ui.show_terminal(self, id);
        }
    }

    /// Interrupt. Claude Code asks for a second Ctrl-C to exit.
    pub fn stop(self: &Rc<Self>, id: Uuid) {
        if self
            .tab(id)
            .is_some_and(|(g, t)| t.resolved_provider(&g) == SessionProvider::Codex)
        {
            crate::codex::interrupt(self, id);
            return;
        }
        let Some(term) = self.terminal(id) else {
            return;
        };
        term.write(b"\x03");
        let weak = Rc::downgrade(&term);
        glib::timeout_add_local_once(Duration::from_millis(350), move || {
            if let Some(term) = weak.upgrade() {
                term.write(b"\x03");
            }
        });
        self.refresh_busy_later(id);
    }

    pub fn kill(self: &Rc<Self>, id: Uuid) {
        crate::codex::close(self, id);
        if let Some(term) = self.terminal(id) {
            term.kill();
        }
        self.update_rt(id, |rt| {
            rt.exited = true;
            rt.clear_status();
            rt.busy = false;
            rt.agent_connected = false;
        });
    }

    fn refresh_busy_later(self: &Rc<Self>, id: Uuid) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_millis(1500), move || {
            if let Some(app) = weak.upgrade() {
                app.refresh_busy(id);
            }
        });
    }

    pub fn refresh_busy(&self, id: Uuid) {
        let busy = self.terminal(id).is_some_and(|t| t.is_busy());
        let codex = self.rt(id).provider == Some(SessionProvider::Codex);
        self.update_rt(id, |rt| {
            if codex {
                // The protocol decides busy; the TUI leaving the foreground
                // means it is no longer attached.
                if !busy {
                    rt.agent_connected = false;
                }
                return;
            }
            rt.busy = busy;
        });
    }

    fn refresh_busy_all(&self) {
        let ids: Vec<Uuid> = self.terminals.borrow().keys().copied().collect();
        for id in ids {
            self.refresh_busy(id);
        }
    }

    pub fn running_count(&self) -> usize {
        self.terminals
            .borrow()
            .iter()
            .filter(|(id, t)| t.is_running() && !self.rt(**id).exited)
            .count()
    }

    // MARK: terminal events

    fn on_term_event(self: &Rc<Self>, id: Uuid, event: TermEvent) {
        match event {
            TermEvent::Title(title) => {
                let watching = self.is_watching(id);
                self.update_rt(id, |rt| {
                    if rt.title != title && !watching {
                        rt.has_activity = true;
                    }
                    rt.title = title;
                });
                self.refresh_busy(id);
            }
            TermEvent::Cwd(cwd) => self.update_rt(id, |rt| rt.cwd = Some(cwd)),
            TermEvent::Bell => {
                self.request_attention(id);
                self.ui.window.error_bell();
            }
            TermEvent::Status(records) => {
                // For Codex sessions the app-server protocol is authoritative.
                if self.rt(id).provider == Some(SessionProvider::Codex) {
                    return;
                }
                self.apply_status(id, |rt| rt.apply_records(&records));
            }
            TermEvent::Notification { title, body } => {
                self.request_attention(id);
                if self.settings.borrow().notify_programs && !self.is_watching(id) {
                    self.post_notification(id, title, &body);
                }
            }
            TermEvent::Exited => self.update_rt(id, |rt| {
                rt.exited = true;
                rt.clear_status();
                rt.busy = false;
                rt.agent_connected = false;
            }),
        }
    }

    /// Updates status fields; blocked and done ask for attention when the
    /// session isn't watched, and a changed state may notify.
    pub fn apply_status(self: &Rc<Self>, id: Uuid, change: impl FnOnce(&mut TabRuntime)) {
        let before = self.rt(id).status_state;
        let watching = self.is_watching(id);
        self.update_rt(id, |rt| {
            change(rt);
            if matches!(rt.status_state, Some(State::Blocked | State::Done)) && !watching {
                rt.needs_attention = true;
            }
        });
        let after = self.rt(id).status_state;
        if after != before {
            self.notify_status_change(id);
        }
    }

    fn notify_status_change(&self, id: Uuid) {
        if self.is_watching(id) {
            return;
        }
        let rt = self.rt(id);
        let settings = self.settings.borrow();
        let wanted = match rt.status_state {
            Some(State::Blocked) => settings.notify_needs_you,
            Some(State::Done | State::Error) => settings.notify_done,
            _ => false,
        };
        drop(settings);
        if wanted {
            self.post_notification(id, None, &rt.status_line(false));
        }
    }

    fn post_notification(&self, id: Uuid, subtitle: Option<String>, body: &str) {
        let Some((group, tab)) = self.tab(id) else {
            return;
        };
        let subtitle = subtitle.unwrap_or(group.name);
        let settings = self.settings.borrow().clone();
        notify::post(&self.gtk_app, &settings, id, &tab.name, &subtitle, body);
    }

    /// Allow sends Return (Claude's default "Yes"); Deny sends Escape.
    pub fn answer_permission(self: &Rc<Self>, id: Uuid, allow: bool) {
        if self.rt(id).provider == Some(SessionProvider::Codex) {
            crate::codex::answer(self, id, allow);
            return;
        }
        if !self.rt(id).awaits_permission() {
            return;
        }
        if let Some(term) = self.terminal(id) {
            term.write(if allow { b"\r" } else { b"\x1b" });
        }
    }

    /// Pastes text into a live session, then presses Return if `submit`.
    pub fn send_text(self: &Rc<Self>, id: Uuid, text: &str, submit: bool) -> bool {
        let Some(term) = self.terminal(id).filter(|t| t.is_running()) else {
            return false;
        };
        if self.rt(id).exited {
            return false;
        }
        term.paste(text);
        if submit {
            self.type_later(id, "\r".into(), Duration::from_millis(150));
        }
        true
    }

    // MARK: projects and sessions

    /// A new session in a project. Projects using worktrees open the
    /// worktree sheet instead (except for New Shell).
    pub fn new_tab(
        self: &Rc<Self>,
        group_id: Uuid,
        provider: Option<SessionProvider>,
        command: Option<String>,
    ) {
        let Some(gi) = self.group_index(group_id) else {
            return;
        };
        let (count, worktrees) = {
            let ws = self.ws.borrow();
            (ws.groups[gi].tabs.len(), ws.groups[gi].use_worktrees)
        };
        if worktrees && command.as_deref() != Some("") {
            crate::ui::worktree_sheet::present(self, group_id, provider);
            return;
        }
        let mut tab = TabItem::new(format!("Session {}", count + 1));
        if let Some(provider) = provider {
            tab.provider = Some(provider);
            tab.command = Some(provider.command().to_string());
        }
        if command.as_deref() == Some("") {
            tab.command = Some(String::new());
            tab.provider = Some(SessionProvider::Shell);
        }
        self.add_session(group_id, tab, command, None);
    }

    /// Adds a session, starts it and selects it. A worktree setup command
    /// runs before the agent, which only starts if setup succeeds.
    pub fn add_session(
        self: &Rc<Self>,
        group_id: Uuid,
        tab: TabItem,
        command: Option<String>,
        setup: Option<&str>,
    ) {
        let Some(gi) = self.group_index(group_id) else {
            return;
        };
        let id = tab.id;
        {
            let mut ws = self.ws.borrow_mut();
            ws.groups[gi].is_collapsed = false;
            ws.groups[gi].tabs.push(tab);
        }
        self.runtime.borrow_mut().insert(id, TabRuntime::default());
        let setup = setup
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let command = match (&setup, command) {
            (Some(setup), command) => {
                let (group, tab) = self.tab(id).expect("just added");
                if tab.resolved_provider(&group) == SessionProvider::Codex {
                    crate::codex::set_pending_setup(self, id, setup.clone());
                    None
                } else {
                    let agent = command.or_else(|| self.startup_command(id));
                    Some(
                        [Some(setup.clone()), agent.filter(|c| !c.is_empty())]
                            .into_iter()
                            .flatten()
                            .collect::<Vec<_>>()
                            .join(" && "),
                    )
                }
            }
            (None, command) => command,
        };
        self.create_terminal(id, command);
        self.schedule_save();
        self.refresh_sidebar();
        self.select(id);
    }

    pub fn new_group(self: &Rc<Self>) {
        let count = self.ws.borrow().groups.len();
        let tab = TabItem::new("Session 1");
        let id = tab.id;
        let group = TabGroup::new(format!("Project {}", count + 1), None, vec![tab]);
        let group_id = group.id;
        self.ws.borrow_mut().groups.push(group);
        self.runtime.borrow_mut().insert(id, TabRuntime::default());
        self.create_terminal(id, None);
        self.renaming_group.set(Some(group_id));
        self.schedule_save();
        self.refresh_sidebar();
        self.select(id);
    }

    /// Opens a folder as a project, or as a new session in the project that
    /// already has exactly that folder.
    pub fn open_folder(self: &Rc<Self>, path: &Path) {
        if !path.is_dir() {
            return;
        }
        let text = path.display().to_string();
        let existing = self
            .ws
            .borrow()
            .groups
            .iter()
            .find(|g| g.directory.as_deref() == Some(text.as_str()))
            .map(|g| g.id);
        if let Some(group_id) = existing {
            self.new_tab(group_id, None, None);
            return;
        }
        let name = path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| text.clone());
        let group = TabGroup::new(name, Some(text), vec![]);
        let group_id = group.id;
        self.ws.borrow_mut().groups.push(group);
        self.add_session(group_id, TabItem::new("Session 1"), None, None);
    }

    pub fn close_tab(self: &Rc<Self>, id: Uuid) {
        self.close_tab_selecting(id, true);
    }

    /// `reselect` false when the siblings are about to close too (deleting a
    /// project), so no shell is started for them.
    fn close_tab_selecting(self: &Rc<Self>, id: Uuid, reselect: bool) {
        let Some((gi, ti)) = self.find(id) else {
            return;
        };
        crate::codex::close(self, id);
        crate::codex::forget(id);
        self.remove_terminal(id);
        self.runtime.borrow_mut().remove(&id);
        self.gtk_app.withdraw_notification(&id.to_string());
        crate::ui::panel::session_closed(self, id);
        let next = {
            let mut ws = self.ws.borrow_mut();
            ws.groups[gi].tabs.remove(ti);
            let tabs = &ws.groups[gi].tabs;
            if !tabs.is_empty() {
                Some(tabs[ti.min(tabs.len() - 1)].id)
            } else {
                ws.groups.iter().find_map(|g| g.tabs.first().map(|t| t.id))
            }
        };
        if self.selected.get() == Some(id) {
            self.selected.set(None);
            self.ws.borrow_mut().selected_tab_id = None;
            match next.filter(|_| reselect) {
                Some(next) => self.select(next),
                None => self.ui.show_empty(),
            }
        }
        self.schedule_save();
        self.refresh_sidebar();
        self.ui.header.update(self);
        self.update_badge();
    }

    pub fn delete_group(self: &Rc<Self>, group_id: Uuid) {
        let Some(gi) = self.group_index(group_id) else {
            return;
        };
        let ids: Vec<Uuid> = self.ws.borrow().groups[gi]
            .tabs
            .iter()
            .map(|t| t.id)
            .collect();
        let was_selected = self.selected.get().is_some_and(|s| ids.contains(&s));
        for id in ids {
            self.close_tab_selecting(id, false);
        }
        if let Some(gi) = self.group_index(group_id) {
            self.ws.borrow_mut().groups.remove(gi);
        }
        if was_selected {
            let next = self
                .ws
                .borrow()
                .groups
                .iter()
                .find_map(|g| g.tabs.first().map(|t| t.id));
            if let Some(next) = next {
                self.select(next);
            }
        }
        if self.ws.borrow().groups.is_empty() {
            self.new_group();
        }
        self.schedule_save();
        self.refresh_sidebar();
    }

    pub fn move_group(self: &Rc<Self>, group_id: Uuid, offset: isize) {
        let Some(gi) = self.group_index(group_id) else {
            return;
        };
        let target = gi as isize + offset;
        let len = self.ws.borrow().groups.len() as isize;
        if target < 0 || target >= len {
            return;
        }
        self.ws.borrow_mut().groups.swap(gi, target as usize);
        self.schedule_save();
        self.refresh_sidebar();
    }

    /// Moves a session to the end of another project.
    pub fn move_tab(self: &Rc<Self>, id: Uuid, group_id: Uuid) {
        let Some((gi, ti)) = self.find(id) else {
            return;
        };
        let Some(target) = self.group_index(group_id) else {
            return;
        };
        if gi == target {
            return;
        }
        let mut ws = self.ws.borrow_mut();
        let tab = ws.groups[gi].tabs.remove(ti);
        ws.groups[target].tabs.push(tab);
        ws.groups[target].is_collapsed = false;
        drop(ws);
        self.schedule_save();
        self.refresh_sidebar();
    }

    /// Places a dragged session right after `after` (a session) or at the top
    /// of a project.
    pub fn drop_tab(self: &Rc<Self>, id: Uuid, group_id: Uuid, after: Option<Uuid>) {
        if after == Some(id) {
            return;
        }
        let Some((gi, ti)) = self.find(id) else {
            return;
        };
        let mut ws = self.ws.borrow_mut();
        let tab = ws.groups[gi].tabs.remove(ti);
        let Some(target) = ws.groups.iter().position(|g| g.id == group_id) else {
            ws.groups[gi].tabs.insert(ti, tab);
            return;
        };
        let index = after
            .and_then(|after| ws.groups[target].tabs.iter().position(|t| t.id == after))
            .map_or(0, |i| i + 1);
        ws.groups[target].tabs.insert(index, tab);
        ws.groups[target].is_collapsed = false;
        drop(ws);
        self.schedule_save();
        self.refresh_sidebar();
    }

    /// Places a dragged project before another one.
    pub fn drop_group(self: &Rc<Self>, group_id: Uuid, before: Uuid) {
        if group_id == before {
            return;
        }
        let mut ws = self.ws.borrow_mut();
        let Some(from) = ws.groups.iter().position(|g| g.id == group_id) else {
            return;
        };
        // Like List.onMove: the project takes the target's place, so moving
        // down onto the next project puts it after that project.
        let to = ws
            .groups
            .iter()
            .position(|g| g.id == before)
            .unwrap_or(ws.groups.len());
        let group = ws.groups.remove(from);
        let len = ws.groups.len();
        ws.groups.insert(to.min(len), group);
        drop(ws);
        self.schedule_save();
        self.refresh_sidebar();
    }

    pub fn selected_group(&self) -> Option<Uuid> {
        self.selected
            .get()
            .and_then(|id| self.tab(id))
            .map(|(g, _)| g.id)
            .or_else(|| self.ws.borrow().groups.first().map(|g| g.id))
    }

    /// Next or previous session across projects, wrapping around.
    pub fn select_relative(self: &Rc<Self>, offset: isize) {
        let ids = self.all_tab_ids();
        if ids.is_empty() {
            return;
        }
        let current = self
            .selected
            .get()
            .and_then(|id| ids.iter().position(|i| *i == id))
            .unwrap_or(0) as isize;
        let next = (current + offset).rem_euclid(ids.len() as isize) as usize;
        self.select(ids[next]);
    }

    /// Session N (1-based) in the current project.
    pub fn select_index(self: &Rc<Self>, index: usize) {
        let Some(group_id) = self.selected_group() else {
            return;
        };
        let id = self
            .ws
            .borrow()
            .groups
            .iter()
            .find(|g| g.id == group_id)
            .and_then(|g| g.tabs.get(index.saturating_sub(1)))
            .map(|t| t.id);
        if let Some(id) = id {
            self.select(id);
        }
    }

    // MARK: saving

    pub fn schedule_save(&self) {
        if let Some(source) = self.save_source.borrow_mut().take() {
            source.remove();
        }
        let ws = self.ws.clone();
        let pending = self.save_source.clone();
        let source = glib::timeout_add_local_once(Duration::from_millis(400), move || {
            pending.borrow_mut().take();
            persistence::save_workspace(&ws.borrow());
        });
        *self.save_source.borrow_mut() = Some(source);
    }

    pub fn save_now(&self) {
        if let Some(source) = self.save_source.borrow_mut().take() {
            source.remove();
        }
        persistence::save_workspace(&self.ws.borrow());
    }

    pub fn update_settings(self: &Rc<Self>, change: impl FnOnce(&mut Settings)) {
        change(&mut self.settings.borrow_mut());
        self.settings.borrow().save();
    }

    /// Saves, stops Codex servers and ends every session.
    pub fn prepare_for_quit(&self) {
        self.save_now();
        crate::codex::shutdown(self);
        for terminal in self.terminals.borrow().values() {
            terminal.kill();
        }
    }

    // MARK: drawing

    pub fn refresh_all(self: &Rc<Self>) {
        self.refresh_sidebar();
        self.ui.header.update(self);
        self.update_badge();
    }

    pub fn refresh_sidebar(self: &Rc<Self>) {
        crate::ui::sidebar::rebuild(self);
    }

    fn refresh_sidebar_selection(&self) {
        self.ui.sidebar.select_row(self.selected.get());
    }

    pub fn refresh_session(&self, id: Uuid) {
        self.ui.sidebar.update_row(self, id);
        if self.selected.get() == Some(id) {
            self.ui.header.update_status(self);
        }
    }

    pub fn apply_theme(&self) {
        let settings = self.settings.borrow().clone();
        crate::ui::style::apply(&settings);
        for terminal in self.terminals.borrow().values() {
            crate::ui::terminal::apply_appearance(&settings, terminal);
        }
    }

    pub fn reveal(self: &Rc<Self>, id: Uuid) {
        self.ui.window.present();
        self.select(id);
    }

    pub fn open_uri(&self, uri: &str) {
        let launcher = gtk::UriLauncher::new(uri);
        launcher.launch(Some(&self.ui.window), gio::Cancellable::NONE, |_| {});
    }
}
