//! The right panel: Files, Changes and Browser tabs for the selected session.

use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use uuid::Uuid;

use crate::app::App;
use crate::claude::SubAgent;

pub const TABS: [(&str, &str); 3] = [
    ("files", "Files"),
    ("changes", "Changes"),
    ("browser", "Browser"),
];

struct Panel {
    buttons: Vec<(String, gtk::ToggleButton)>,
    changes_badge: gtk::Label,
    stack: gtk::Stack,
}

thread_local! {
    static PANEL: RefCell<Option<Panel>> = const { RefCell::new(None) };
}

pub fn build(app: &Rc<App>) {
    let strip = gtk::Box::new(gtk::Orientation::Horizontal, 2);
    strip.add_css_class("omux-panel-strip");
    strip.set_margin_start(6);
    strip.set_margin_end(6);
    strip.set_margin_top(4);
    strip.set_margin_bottom(4);
    let stack = gtk::Stack::new();
    stack.set_vexpand(true);
    let mut buttons = Vec::new();
    let changes_badge = gtk::Label::new(None);
    changes_badge.add_css_class("omux-status");
    let mut first: Option<gtk::ToggleButton> = None;
    for (key, label) in TABS {
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        content.append(&gtk::Label::new(Some(label)));
        if key == "changes" {
            content.append(&changes_badge);
        }
        let button = gtk::ToggleButton::new();
        button.set_child(Some(&content));
        button.add_css_class("flat");
        button.add_css_class("omux-small");
        if let Some(first) = &first {
            button.set_group(Some(first));
        } else {
            first = Some(button.clone());
        }
        let weak = Rc::downgrade(app);
        button.connect_toggled(move |b| {
            if b.is_active() {
                if let Some(app) = weak.upgrade() {
                    show_tab(&app, key);
                }
            }
        });
        strip.append(&button);
        buttons.push((key.to_string(), button));
    }
    let hairline = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    hairline.add_css_class("omux-hairline");

    stack.add_named(&crate::ui::files::build(app), Some("files"));
    stack.add_named(&crate::ui::changes::build(app), Some("changes"));
    stack.add_named(&crate::ui::browser::build(app), Some("browser"));

    app.ui.panel.append(&strip);
    app.ui.panel.append(&hairline);
    app.ui.panel.append(&stack);
    PANEL.with(|p| {
        *p.borrow_mut() = Some(Panel {
            buttons,
            changes_badge,
            stack,
        })
    });
    let tab = app.settings.borrow().panel_tab.clone();
    show_tab(app, &tab);
}

/// Shows a tab, opening the panel if needed (Ctrl+Alt+1/2/3).
pub fn show_tab(app: &Rc<App>, tab: &str) {
    let tab = if TABS.iter().any(|(k, _)| *k == tab) {
        tab
    } else {
        "files"
    };
    if app.settings.borrow().panel_tab != tab {
        let value = tab.to_string();
        app.update_settings(|s| s.panel_tab = value);
    }
    if !app.settings.borrow().show_files {
        gtk::prelude::ActionGroupExt::activate_action(&app.gtk_app, "toggle-panel", None);
    }
    PANEL.with(|p| {
        if let Some(panel) = p.borrow().as_ref() {
            panel.stack.set_visible_child_name(tab);
            for (key, button) in &panel.buttons {
                if key == tab && !button.is_active() {
                    button.set_active(true);
                }
            }
        }
    });
    selection_changed(app);
}

pub fn current_tab(app: &App) -> String {
    app.settings.borrow().panel_tab.clone()
}

pub fn is_showing(app: &App, tab: &str) -> bool {
    app.settings.borrow().show_files && current_tab(app) == tab
}

pub fn set_changes_badge(count: usize) {
    PANEL.with(|p| {
        if let Some(panel) = p.borrow().as_ref() {
            panel.changes_badge.set_text(&if count > 0 {
                count.to_string()
            } else {
                String::new()
            });
        }
    });
}

/// The folder the panel shows for a session: its own, its project's, or home.
pub fn root_for(app: &App, id: Uuid) -> Option<PathBuf> {
    let (group, tab) = app.tab(id)?;
    Some(
        tab.directory
            .as_deref()
            .or(group.directory.as_deref())
            .map(crate::persistence::expand_tilde)
            .unwrap_or_else(crate::persistence::home_dir),
    )
}

pub fn selection_changed(app: &Rc<App>) {
    // Changes follows the session even while hidden: the branch chip and
    // the tab badge use its totals.
    crate::ui::changes::selection_changed(app);
    if !app.settings.borrow().show_files {
        return;
    }
    crate::ui::files::selection_changed(app);
    crate::ui::browser::selection_changed(app);
}

pub fn session_closed(app: &Rc<App>, id: Uuid) {
    crate::ui::browser::session_closed(app, id);
    crate::ui::changes::session_closed(id);
}

pub fn app_activated(app: &Rc<App>) {
    crate::ui::changes::app_activated(app);
}

/// Opens a file in the Files tab's preview (Ctrl+click in the terminal).
pub fn preview_file(app: &Rc<App>, path: &Path) {
    show_tab(app, "files");
    crate::ui::files::preview(app, path);
}

pub fn show_transcript(id: Uuid, agent: &SubAgent) {
    let app = crate::ui::files::app();
    if let Some(app) = app.filter(|a| a.selected.get() == Some(id)) {
        show_tab(&app, "files");
        crate::ui::files::show_transcript(&app, agent);
    }
}

/// Runs `work` on a thread and hands its result to `done` on the main loop.
pub fn background<T: Send + 'static>(
    work: impl FnOnce() -> T + Send + 'static,
    done: impl FnOnce(T) + 'static,
) {
    let (tx, rx) = async_channel::bounded(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(work());
    });
    glib::spawn_future_local(async move {
        if let Ok(value) = rx.recv().await {
            done(value);
        }
    });
}
