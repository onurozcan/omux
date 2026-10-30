//! Sheets: Edit Session, Edit Project, the quick switcher, confirmations.

use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use uuid::Uuid;

use crate::app::App;
use crate::model::SessionProvider;
use crate::persistence::abbreviate_home;

/// A dialog with Cancel / primary buttons in its header and `page` as content.
fn form(title: &str, primary: &str, page: &adw::PreferencesPage) -> (adw::Dialog, gtk::Button) {
    let dialog = adw::Dialog::new();
    dialog.set_title(title);
    dialog.set_content_width(480);
    let bar = adw::HeaderBar::new();
    bar.set_show_end_title_buttons(false);
    bar.set_show_start_title_buttons(false);
    let cancel = gtk::Button::with_label("Cancel");
    let d = dialog.downgrade();
    cancel.connect_clicked(move |_| {
        if let Some(d) = d.upgrade() {
            d.close();
        }
    });
    bar.pack_start(&cancel);
    let save = gtk::Button::with_label(primary);
    save.add_css_class("suggested-action");
    bar.pack_end(&save);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&bar);
    view.set_content(Some(page));
    dialog.set_child(Some(&view));
    dialog.set_default_widget(Some(&save));
    (dialog, save)
}

/// An entry row with a "Choose…" folder button.
fn folder_row(app: &Rc<App>, title: &str, value: Option<&str>, placeholder: &str) -> adw::EntryRow {
    let row = adw::EntryRow::new();
    row.set_title(&format!("{title} ({placeholder})"));
    if let Some(value) = value {
        row.set_text(value);
    }
    let choose = gtk::Button::with_label("Choose…");
    choose.set_valign(gtk::Align::Center);
    choose.add_css_class("flat");
    let weak = Rc::downgrade(app);
    let target = row.downgrade();
    choose.connect_clicked(move |_| {
        let (Some(app), Some(row)) = (weak.upgrade(), target.upgrade()) else {
            return;
        };
        choose_folder(&app, move |path| row.set_text(&abbreviate_home(&path)));
    });
    row.add_suffix(&choose);
    row
}

pub fn choose_folder(app: &Rc<App>, done: impl FnOnce(std::path::PathBuf) + 'static) {
    let dialog = gtk::FileDialog::builder()
        .title("Choose a folder")
        .modal(true)
        .build();
    dialog.select_folder(
        Some(&app.ui.window),
        gio::Cancellable::NONE,
        move |result| {
            if let Some(path) = result.ok().and_then(|f| f.path()) {
                done(path);
            }
        },
    );
}

fn trimmed(row: &adw::EntryRow) -> Option<String> {
    let text = row.text().trim().to_string();
    (!text.is_empty()).then_some(text)
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CommandChoice {
    Inherit,
    Claude,
    Codex,
    Shell,
    Custom,
}

const SESSION_CHOICES: [(CommandChoice, &str); 5] = [
    (CommandChoice::Inherit, "Project default"),
    (CommandChoice::Claude, "Claude Code"),
    (CommandChoice::Codex, "Codex"),
    (CommandChoice::Shell, "Plain shell"),
    (CommandChoice::Custom, "Custom"),
];

fn session_choice(provider: Option<SessionProvider>, command: Option<&str>) -> CommandChoice {
    match (provider, command) {
        (Some(SessionProvider::Claude), Some(c)) if c != "claude" => CommandChoice::Custom,
        (Some(SessionProvider::Claude), _) => CommandChoice::Claude,
        (Some(SessionProvider::Codex), _) => CommandChoice::Codex,
        (Some(SessionProvider::Shell), _) => CommandChoice::Shell,
        (Some(SessionProvider::Custom), _) => CommandChoice::Custom,
        (None, None) => CommandChoice::Inherit,
        (None, Some("")) => CommandChoice::Shell,
        (None, Some("codex")) => CommandChoice::Codex,
        (None, Some("claude")) => CommandChoice::Claude,
        (None, Some(_)) => CommandChoice::Custom,
    }
}

fn combo(labels: &[&str], selected: usize) -> adw::ComboRow {
    let model = gtk::StringList::new(labels);
    let row = adw::ComboRow::new();
    row.set_model(Some(&model));
    row.set_selected(selected as u32);
    row
}

pub fn edit_session(app: &Rc<App>, id: Uuid) {
    let Some((group, tab)) = app.tab(id) else {
        return;
    };
    let page = adw::PreferencesPage::new();
    let main = adw::PreferencesGroup::new();
    let name = adw::EntryRow::new();
    name.set_title("Name");
    name.set_text(&tab.name);
    main.add(&name);
    let project_dir = group.directory.clone().unwrap_or_else(|| "~".into());
    let folder = folder_row(app, "Folder", tab.directory.as_deref(), &project_dir);
    main.add(&folder);
    page.add(&main);

    let command_group = adw::PreferencesGroup::new();
    let choice = session_choice(tab.provider, tab.command.as_deref());
    let labels: Vec<&str> = SESSION_CHOICES.iter().map(|(_, l)| *l).collect();
    let index = SESSION_CHOICES
        .iter()
        .position(|(c, _)| *c == choice)
        .unwrap_or(0);
    let command = combo(&labels, index);
    command.set_title("Command");
    let inherited = match group.command.as_deref() {
        Some(c) if !c.is_empty() => c.to_string(),
        _ => "plain shell".into(),
    };
    command.set_subtitle(&format!("Project default: {inherited}"));
    command_group.add(&command);
    let custom = adw::EntryRow::new();
    custom.set_title("Custom command (claude)");
    if choice == CommandChoice::Custom {
        custom.set_text(tab.command.as_deref().unwrap_or(""));
    }
    custom.set_visible(choice == CommandChoice::Custom);
    command_group.add(&custom);
    let c = custom.clone();
    command.connect_selected_notify(move |row| {
        c.set_visible(SESSION_CHOICES[row.selected() as usize].0 == CommandChoice::Custom);
    });
    page.add(&command_group);

    let provider = tab.resolved_provider(&group);
    let conversation = adw::PreferencesGroup::new();
    let fresh = adw::SwitchRow::new();
    if matches!(provider, SessionProvider::Claude | SessionProvider::Codex) {
        conversation.set_title("Conversation");
        let id_text = match provider {
            SessionProvider::Claude => tab.claude_session_id.to_string().to_lowercase(),
            _ => tab
                .codex_thread_id
                .clone()
                .unwrap_or_else(|| "New conversation".into()),
        };
        let row = adw::ActionRow::new();
        row.set_title(&id_text);
        row.add_css_class("property");
        row.set_subtitle_selectable(true);
        row.set_title_selectable(true);
        conversation.add(&row);
        fresh.set_title("Start a fresh conversation on next restart");
        conversation.add(&fresh);
        page.add(&conversation);
    }

    let (dialog, save) = form("Edit Session", "Save", &page);
    let weak = Rc::downgrade(app);
    let d = dialog.downgrade();
    save.connect_clicked(move |_| {
        let Some(app) = weak.upgrade() else { return };
        let choice = SESSION_CHOICES[command.selected() as usize].0;
        let custom_text = custom.text().trim().to_string();
        let start_fresh = fresh.is_active();
        let group_provider = app
            .tab(id)
            .map_or(SessionProvider::Claude, |(g, _)| g.provider);
        let name = trimmed(&name);
        let folder = trimmed(&folder);
        app.update_tab(id, |tab| {
            if let Some(name) = name {
                tab.name = name;
            }
            tab.directory = folder;
            let (command, provider) = match choice {
                CommandChoice::Inherit => (None, None),
                CommandChoice::Claude => {
                    (Some("claude".to_string()), Some(SessionProvider::Claude))
                }
                CommandChoice::Codex => (Some("codex".to_string()), Some(SessionProvider::Codex)),
                CommandChoice::Shell => (Some(String::new()), Some(SessionProvider::Shell)),
                CommandChoice::Custom => {
                    let provider = SessionProvider::infer(Some(&custom_text));
                    (Some(custom_text.clone()), Some(provider))
                }
            };
            tab.command = command;
            tab.provider = provider;
            if start_fresh {
                let resolved = provider.unwrap_or(group_provider);
                match resolved {
                    SessionProvider::Codex => tab.codex_thread_id = None,
                    _ => tab.claude_session_id = Uuid::new_v4(),
                }
            }
        });
        app.refresh_sidebar();
        app.ui.header.update(&app);
        if let Some(d) = d.upgrade() {
            d.close();
        }
    });
    dialog.present(Some(&app.ui.window));
}

const PROJECT_CHOICES: [SessionProvider; 4] = [
    SessionProvider::Claude,
    SessionProvider::Codex,
    SessionProvider::Shell,
    SessionProvider::Custom,
];

pub fn edit_project(app: &Rc<App>, group_id: Uuid) {
    let Some(gi) = app.group_index(group_id) else {
        return;
    };
    let group = app.ws.borrow().groups[gi].clone();
    let page = adw::PreferencesPage::new();
    let main = adw::PreferencesGroup::new();
    let name = adw::EntryRow::new();
    name.set_title("Name");
    name.set_text(&group.name);
    main.add(&name);
    let folder = folder_row(app, "Folder", group.directory.as_deref(), "~");
    main.add(&folder);
    page.add(&main);

    let sessions = adw::PreferencesGroup::new();
    sessions.set_description(Some(
        "Applies when a session starts. Existing sessions keep running.",
    ));
    let current = if group.command.as_deref().unwrap_or("") == group.provider.command() {
        group.provider
    } else {
        SessionProvider::Custom
    };
    let labels: Vec<&str> = PROJECT_CHOICES
        .iter()
        .map(|p| {
            if *p == SessionProvider::Custom {
                "Custom command"
            } else {
                p.label()
            }
        })
        .collect();
    let index = PROJECT_CHOICES
        .iter()
        .position(|p| *p == current)
        .unwrap_or(0);
    let provider = combo(&labels, index);
    provider.set_title("New sessions");
    sessions.add(&provider);
    let custom = adw::EntryRow::new();
    custom.set_title("Custom command");
    if current == SessionProvider::Custom {
        custom.set_text(group.command.as_deref().unwrap_or(""));
    }
    custom.set_visible(current == SessionProvider::Custom);
    sessions.add(&custom);
    let c = custom.clone();
    provider.connect_selected_notify(move |row| {
        c.set_visible(PROJECT_CHOICES[row.selected() as usize] == SessionProvider::Custom);
    });
    page.add(&sessions);

    let worktrees = adw::PreferencesGroup::new();
    let use_worktrees = adw::SwitchRow::new();
    use_worktrees.set_title("Give new sessions their own Git worktree");
    use_worktrees.set_active(group.use_worktrees);
    worktrees.add(&use_worktrees);
    let setup = adw::EntryRow::new();
    setup.set_title("Worktree setup (cp \"$OMUX_REPO/.env\" . && npm install)");
    setup.set_text(&group.worktree_setup);
    setup.add_css_class("omux-mono");
    worktrees.add(&setup);
    worktrees.set_description(Some(
        "Runs in each new worktree before the session starts, and only starts it if setup succeeds. \
         $OMUX_REPO is the main checkout, for copying files Git ignores.",
    ));
    page.add(&worktrees);

    let (dialog, save) = form("Edit Project", "Save", &page);
    let weak = Rc::downgrade(app);
    let d = dialog.downgrade();
    save.connect_clicked(move |_| {
        let Some(app) = weak.upgrade() else { return };
        let choice = PROJECT_CHOICES[provider.selected() as usize];
        let custom_text = custom.text().trim().to_string();
        let name = trimmed(&name);
        let folder = trimmed(&folder);
        let use_worktrees = use_worktrees.is_active();
        let setup = setup.text().trim().to_string();
        app.update_group(group_id, |g| {
            if let Some(name) = name {
                g.name = name;
            }
            g.directory = folder;
            if choice == SessionProvider::Custom {
                g.provider = SessionProvider::infer(Some(&custom_text));
                g.command = Some(custom_text.clone());
            } else {
                g.provider = choice;
                g.command = Some(choice.command().to_string());
            }
            g.use_worktrees = use_worktrees;
            g.worktree_setup = setup;
        });
        app.refresh_sidebar();
        app.ui.header.update(&app);
        if let Some(d) = d.upgrade() {
            d.close();
        }
    });
    dialog.present(Some(&app.ui.window));
}

pub fn confirm_delete_group(app: &Rc<App>, group_id: Uuid) {
    let Some(gi) = app.group_index(group_id) else {
        return;
    };
    let (name, ids): (String, Vec<Uuid>) = {
        let ws = app.ws.borrow();
        (
            ws.groups[gi].name.clone(),
            ws.groups[gi].tabs.iter().map(|t| t.id).collect(),
        )
    };
    let running = ids
        .iter()
        .filter(|id| app.terminal(**id).is_some_and(|t| t.is_running()) && !app.rt(**id).exited)
        .count();
    if running == 0 {
        app.delete_group(group_id);
        return;
    }
    let text = if running == 1 {
        "1 running session will be closed.".to_string()
    } else {
        format!("{running} running sessions will be closed.")
    };
    let dialog = adw::AlertDialog::new(Some(&format!("Delete “{name}”?")), Some(&text));
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("delete", "Delete");
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    dialog.set_close_response("cancel");
    let weak = Rc::downgrade(app);
    dialog.connect_response(Some("delete"), move |_, _| {
        if let Some(app) = weak.upgrade() {
            app.delete_group(group_id);
        }
    });
    dialog.present(Some(&app.ui.window));
}

pub fn info(app: &Rc<App>, heading: &str, body: &str) {
    let dialog = adw::AlertDialog::new(Some(heading), Some(body));
    dialog.add_response("ok", "OK");
    dialog.present(Some(&app.ui.window));
}

/// Ctrl+Shift+P: filter sessions by name, project and terminal title.
pub fn quick_switcher(app: &Rc<App>) {
    let dialog = adw::Dialog::new();
    dialog.set_title("Jump to Session");
    dialog.set_content_width(460);
    dialog.set_content_height(380);
    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some("Jump to session…"));
    search.set_margin_start(12);
    search.set_margin_end(12);
    search.set_margin_top(12);
    let list = gtk::ListBox::new();
    list.add_css_class("navigation-sidebar");
    let scroller = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .child(&list)
        .build();
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 8);
    vbox.append(&search);
    vbox.append(&scroller);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&adw::HeaderBar::new());
    view.set_content(Some(&vbox));
    dialog.set_child(Some(&view));

    let fill = {
        let weak = Rc::downgrade(app);
        let list = list.clone();
        move |query: &str| {
            let Some(app) = weak.upgrade() else { return };
            list.remove_all();
            let query = query.to_lowercase();
            let groups = app.ws.borrow().groups.clone();
            let matches = groups
                .iter()
                .flat_map(|g| g.tabs.iter().map(move |t| (g, t)))
                .filter(|(g, t)| {
                    let rt = app.rt(t.id);
                    format!("{} {} {}", t.name, g.name, rt.title)
                        .to_lowercase()
                        .contains(&query)
                })
                .take(15);
            for (group, tab) in matches {
                let rt = app.rt(tab.id);
                let row = adw::ActionRow::new();
                row.set_title(&glib::markup_escape_text(&tab.name));
                row.set_subtitle(&glib::markup_escape_text(&format!(
                    "{} · {}",
                    group.name,
                    rt.status_line(false)
                )));
                let dot = crate::ui::sidebar::dot();
                crate::ui::sidebar::set_dot(&dot, crate::ui::sidebar::dot_color(&rt, tab));
                row.add_prefix(&dot);
                row.set_activatable(true);
                row.set_widget_name(&tab.id.to_string());
                list.append(&row);
            }
        }
    };
    fill("");
    let f = fill.clone();
    search.connect_search_changed(move |entry| f(&entry.text()));

    let pick = {
        let weak = Rc::downgrade(app);
        let d = dialog.downgrade();
        move |row: &gtk::ListBoxRow| {
            let (Some(app), Some(d)) = (weak.upgrade(), d.upgrade()) else {
                return;
            };
            if let Ok(id) = Uuid::parse_str(&row.widget_name()) {
                d.close();
                app.select(id);
            }
        }
    };
    let p = pick.clone();
    list.connect_row_activated(move |_, row| p(row));
    let l = list.clone();
    search.connect_activate(move |_| {
        if let Some(row) = l.row_at_index(0) {
            pick(&row);
        }
    });
    let keys = gtk::EventControllerKey::new();
    let l = list.clone();
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gdk::Key::Down {
            if let Some(row) = l.row_at_index(0) {
                row.grab_focus();
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    search.add_controller(keys);
    dialog.present(Some(&app.ui.window));
    search.grab_focus();
}
