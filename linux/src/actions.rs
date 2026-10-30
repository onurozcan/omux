//! App actions, their keyboard shortcuts (PARITY.md 11.4: GNOME Terminal
//! conventions, so readline keys stay with the shell), and the actions the
//! sidebar menus call with a session or project id.

use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use uuid::Uuid;
use vte::prelude::*;

use crate::app::App;
use crate::model::{SessionProvider, TabColor};
use crate::ui::dialogs;

pub const SHORTCUTS: &[(&str, &[&str], &str)] = &[
    ("app.new-session", &["<Control><Shift>t"], "New session"),
    ("app.new-shell", &["<Control><Alt><Shift>t"], "New shell"),
    (
        "app.new-worktree",
        &["<Control><Shift>b"],
        "New session in worktree",
    ),
    ("app.new-project", &["<Control><Shift>n"], "New project"),
    (
        "app.open-folder",
        &["<Control><Shift>o"],
        "Open folder as project",
    ),
    (
        "app.open-recent",
        &["<Control><Alt>o"],
        "Open recent conversation",
    ),
    ("app.close-session", &["<Control><Shift>w"], "Close session"),
    ("app.close-window", &["<Control><Alt>w"], "Close window"),
    ("app.quit", &["<Control><Shift>q"], "Quit"),
    ("app.toggle-panel", &["F9"], "Files panel"),
    ("app.panel-tab::files", &["<Control><Alt>1"], "Files"),
    ("app.panel-tab::changes", &["<Control><Alt>2"], "Changes"),
    ("app.panel-tab::browser", &["<Control><Alt>3"], "Browser"),
    ("app.rename", &["F2"], "Rename session"),
    ("app.edit-session", &["<Control><Alt>e"], "Edit session"),
    ("app.restart", &["<Control><Shift>r"], "Restart session"),
    (
        "app.interrupt",
        &["<Control><Shift>period"],
        "Interrupt (Ctrl-C)",
    ),
    (
        "app.start",
        &["<Control><Shift>Return"],
        "Start or continue session",
    ),
    (
        "app.quick-switch",
        &["<Control><Shift>p"],
        "Jump to session",
    ),
    ("app.next-session", &["<Control>Page_Down"], "Next session"),
    (
        "app.prev-session",
        &["<Control>Page_Up"],
        "Previous session",
    ),
    ("app.settings", &["<Control>comma"], "Settings"),
    ("app.copy", &["<Control><Shift>c"], "Copy"),
    ("app.paste", &["<Control><Shift>v"], "Paste"),
];

fn add(app: &Rc<App>, name: &str, f: impl Fn(&Rc<App>) + 'static) {
    let action = gio::SimpleAction::new(name, None);
    let weak = Rc::downgrade(app);
    action.connect_activate(move |_, _| {
        if let Some(app) = weak.upgrade() {
            f(&app);
        }
    });
    app.gtk_app.add_action(&action);
}

/// An action taking a string, e.g. a session id.
fn add_str(app: &Rc<App>, name: &str, f: impl Fn(&Rc<App>, &str) + 'static) {
    let action = gio::SimpleAction::new(name, Some(glib::VariantTy::STRING));
    let weak = Rc::downgrade(app);
    action.connect_activate(move |_, param| {
        let (Some(app), Some(text)) = (weak.upgrade(), param.and_then(|p| p.str())) else {
            return;
        };
        f(&app, text);
    });
    app.gtk_app.add_action(&action);
}

fn add_id(app: &Rc<App>, name: &str, f: impl Fn(&Rc<App>, Uuid) + 'static) {
    add_str(app, name, move |app, text| {
        if let Ok(id) = Uuid::parse_str(text) {
            f(app, id);
        }
    });
}

/// "id:value" targets.
fn add_pair(app: &Rc<App>, name: &str, f: impl Fn(&Rc<App>, Uuid, &str) + 'static) {
    add_str(app, name, move |app, text| {
        if let Some((id, value)) = text.split_once(':') {
            if let Ok(id) = Uuid::parse_str(id) {
                f(app, id, value);
            }
        }
    });
}

fn with_selected(app: &Rc<App>, f: impl FnOnce(Uuid)) {
    if let Some(id) = app.selected.get() {
        f(id);
    }
}

fn rename_tab(app: &Rc<App>, id: Uuid) {
    app.renaming.set(Some(id));
    app.refresh_sidebar();
}

pub fn install(app: &Rc<App>) {
    // New things
    add(app, "new-session", |app| {
        if let Some(group) = app.selected_group() {
            app.new_tab(group, None, None);
        }
    });
    add(app, "new-shell", |app| {
        if let Some(group) = app.selected_group() {
            app.new_tab(group, None, Some(String::new()));
        }
    });
    add(app, "new-claude", |app| {
        if let Some(group) = app.selected_group() {
            app.new_tab(group, Some(SessionProvider::Claude), None);
        }
    });
    add(app, "new-codex", |app| {
        if let Some(group) = app.selected_group() {
            app.new_tab(group, Some(SessionProvider::Codex), None);
        }
    });
    add(app, "new-worktree", |app| {
        if let Some(group) = app.selected_group() {
            crate::ui::worktree_sheet::present(app, group, None);
        }
    });
    add(app, "new-project", |app| app.new_group());
    add(app, "open-folder", |app| {
        let weak = Rc::downgrade(app);
        dialogs::choose_folder(app, move |path| {
            if let Some(app) = weak.upgrade() {
                app.open_folder(&path);
            }
        });
    });
    add(app, "open-recent", crate::ui::recent::present);

    // The selected session
    add(app, "close-session", |app| {
        with_selected(app, |id| {
            crate::ui::worktree_actions::request_close(app, id)
        });
    });
    add(app, "rename", |app| {
        with_selected(app, |id| rename_tab(app, id))
    });
    add(app, "edit-session", |app| {
        with_selected(app, |id| dialogs::edit_session(app, id))
    });
    add(app, "restart", |app| {
        with_selected(app, |id| app.restart(id))
    });
    add(app, "interrupt", |app| {
        with_selected(app, |id| app.stop(id))
    });
    add(app, "start", |app| with_selected(app, |id| app.start(id)));
    add(app, "start-or-stop", |app| {
        with_selected(app, |id| {
            if app.rt(id).busy {
                app.stop(id);
            } else {
                app.start(id);
            }
        });
    });
    add(app, "kill", |app| with_selected(app, |id| app.kill(id)));
    add(app, "allow", |app| {
        with_selected(app, |id| app.answer_permission(id, true))
    });
    add(app, "deny", |app| {
        with_selected(app, |id| app.answer_permission(id, false))
    });
    add(app, "quick-switch", dialogs::quick_switcher);
    add(app, "refresh-sidebar", |app| app.refresh_sidebar());
    add(app, "next-session", |app| app.select_relative(1));
    add(app, "prev-session", |app| app.select_relative(-1));
    for n in 1..=9 {
        let action = format!("session-{n}");
        add(app, &action, move |app| app.select_index(n));
        app.gtk_app
            .set_accels_for_action(&format!("app.{action}"), &[&format!("<Alt>{n}")]);
    }
    add(app, "copy", |app| {
        if let Some(term) = app.selected.get().and_then(|id| app.terminal(id)) {
            term.widget.copy_clipboard_format(vte::Format::Text);
        }
    });
    add(app, "paste", |app| {
        if let Some(term) = app.selected.get().and_then(|id| app.terminal(id)) {
            crate::ui::paste::paste(&term);
        }
    });
    add(app, "select-all", |app| {
        if let Some(term) = app.selected.get().and_then(|id| app.terminal(id)) {
            term.widget.select_all();
        }
    });

    // Panel
    let show = app.settings.borrow().show_files;
    let toggle = gio::SimpleAction::new_stateful("toggle-panel", None, &show.to_variant());
    let weak = Rc::downgrade(app);
    toggle.connect_activate(move |action, _| {
        let Some(app) = weak.upgrade() else { return };
        let on = !action
            .state()
            .and_then(|s| s.get::<bool>())
            .unwrap_or(false);
        action.set_state(&on.to_variant());
        app.update_settings(|s| s.show_files = on);
        app.ui.set_panel_visible(on);
        crate::ui::panel::selection_changed(&app);
    });
    app.gtk_app.add_action(&toggle);
    add_str(app, "panel-tab", |app, tab| {
        crate::ui::panel::show_tab(app, tab)
    });

    // App
    add(app, "settings", crate::ui::settings_dialog::present);
    add(app, "welcome", crate::ui::welcome::present);
    add(app, "github", |app| {
        app.open_uri("https://github.com/onurozcan/omux")
    });
    add(app, "about", about);
    add(app, "shortcuts", shortcuts);
    add(app, "quit", |app| {
        if !crate::ui::window::confirm_quit(app, &app.ui.window) {
            app.prepare_for_quit();
            app.gtk_app.quit();
        }
    });
    add_id(app, "reveal", |app, id| app.reveal(id));
    add(app, "close-window", |app| app.ui.window.close());

    // Sidebar menus: sessions
    add_id(app, "tab-rename", rename_tab);
    add_id(app, "tab-edit", dialogs::edit_session);
    add_pair(app, "tab-color", |app, id, raw| {
        let color = TabColor::ALL
            .into_iter()
            .find(|c| c.raw() == raw)
            .unwrap_or_default();
        app.update_tab(id, |t| t.color = color);
        app.refresh_session(id);
        app.ui.header.update(app);
    });
    add_pair(app, "tab-move", |app, id, group| {
        if let Ok(group) = Uuid::parse_str(group) {
            app.move_tab(id, group);
        }
    });
    add_id(app, "tab-interrupt", |app, id| app.stop(id));
    add_id(app, "tab-restart", |app, id| app.restart(id));
    add_id(app, "tab-kill", |app, id| app.kill(id));
    add_id(app, "tab-close", crate::ui::worktree_actions::request_close);

    // Sidebar menus: projects
    add_id(app, "group-new-session", |app, id| {
        app.new_tab(id, None, None)
    });
    add_id(app, "group-new-shell", |app, id| {
        app.new_tab(id, None, Some(String::new()))
    });
    add_id(app, "group-new-worktree", |app, id| {
        crate::ui::worktree_sheet::present(app, id, None)
    });
    add_id(app, "group-rename", |app, id| {
        app.renaming_group.set(Some(id));
        app.refresh_sidebar();
    });
    add_id(app, "group-edit", dialogs::edit_project);
    add_id(app, "group-up", |app, id| app.move_group(id, -1));
    add_id(app, "group-down", |app, id| app.move_group(id, 1));
    add_id(app, "group-delete", dialogs::confirm_delete_group);

    crate::ui::worktree_actions::install(app);

    for (action, accels, _) in SHORTCUTS {
        app.gtk_app.set_accels_for_action(action, accels);
    }
}

fn about(app: &Rc<App>) {
    let about = adw::AboutDialog::builder()
        .application_name("omux")
        .application_icon(crate::APP_ID)
        .version(env!("CARGO_PKG_VERSION"))
        .comments("A terminal for running many Claude Code and Codex sessions side by side.")
        .website("https://github.com/onurozcan/omux")
        .issue_url("https://github.com/onurozcan/omux/issues")
        .license_type(gtk::License::MitX11)
        .developers(vec!["Onur Özcan", "omux contributors"])
        .build();
    about.present(Some(&app.ui.window));
}

fn shortcuts(app: &Rc<App>) {
    let dialog = adw::Dialog::new();
    dialog.set_title("Keyboard Shortcuts");
    dialog.set_content_width(460);
    let page = adw::PreferencesPage::new();
    let group = adw::PreferencesGroup::new();
    let mut rows: Vec<(String, String)> = SHORTCUTS
        .iter()
        .map(|(_, accels, label)| (label.to_string(), accels[0].to_string()))
        .collect();
    rows.push(("Session 1–9 in this project".into(), "<Alt>1…9".into()));
    for (label, accel) in rows {
        let row = adw::ActionRow::new();
        row.set_title(&label);
        let text = accel
            .replace("<Control>", "Ctrl+")
            .replace("<Shift>", "Shift+")
            .replace("<Alt>", "Alt+")
            .replace("period", ".")
            .replace("comma", ",")
            .replace("Page_Down", "Page Down")
            .replace("Page_Up", "Page Up")
            .replace("Return", "Enter");
        let key = gtk::Label::new(Some(&text));
        key.add_css_class("dim-label");
        row.add_suffix(&key);
        group.add(&row);
    }
    page.add(&group);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&adw::HeaderBar::new());
    view.set_content(Some(&page));
    dialog.set_child(Some(&view));
    dialog.present(Some(&app.ui.window));
}
