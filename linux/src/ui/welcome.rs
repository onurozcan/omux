//! The welcome sheet: shown on a fresh install, and from the main menu.

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;

use crate::app::App;
use crate::usage::Usage;

thread_local! {
    /// The usage row of an open welcome sheet, updated when a check returns.
    static USAGE_ROW: RefCell<Option<glib::WeakRef<adw::ActionRow>>> = const { RefCell::new(None) };
    static CODEX_ROW: RefCell<Option<glib::WeakRef<adw::ActionRow>>> = const { RefCell::new(None) };
}

/// `command -v <tool>` in the login shell, so the user's PATH applies.
fn tool_path(tool: &str) -> Option<String> {
    let output = std::process::Command::new(crate::session_env::shell())
        .args(["-lc", &format!("command -v {tool}")])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    path.starts_with('/').then_some(path)
}

pub fn present(app: &Rc<App>) {
    let dialog = adw::Dialog::new();
    dialog.set_title("Welcome to omux");
    dialog.set_content_width(520);
    dialog.set_content_height(600);
    let page = adw::PreferencesPage::new();
    page.set_description(
        "A terminal for running many Claude Code and Codex sessions side by side. A few checks before you start.",
    );

    let agents = adw::PreferencesGroup::new();
    agents.set_title("Agents");
    for (name, tool, install) in [
        (
            "Claude Code",
            "claude",
            "npm install -g @anthropic-ai/claude-code",
        ),
        ("Codex", "codex", "npm install -g @openai/codex"),
    ] {
        let row = adw::ActionRow::new();
        row.set_title(name);
        row.set_subtitle("Checking…");
        row.set_subtitle_selectable(true);
        agents.add(&row);
        let (tx, rx) = async_channel::bounded(1);
        let tool = tool.to_string();
        std::thread::spawn(move || {
            let _ = tx.send_blocking(tool_path(&tool));
        });
        let install = install.to_string();
        glib::spawn_future_local(async move {
            let Ok(path) = rx.recv().await else { return };
            match path {
                Some(path) => row.set_subtitle(&path),
                None => row.set_subtitle(&format!("Not found. Install with: {install}")),
            }
        });
    }
    page.add(&agents);

    let notifications = adw::PreferencesGroup::new();
    notifications.set_title("Notifications");
    let row = adw::ActionRow::new();
    row.set_title("Enabled");
    row.set_subtitle("omux tells you when a session you aren't looking at needs you.");
    let play = gtk::Button::with_label("Play the sound");
    play.set_valign(gtk::Align::Center);
    let weak = Rc::downgrade(app);
    play.connect_clicked(move |_| {
        if let Some(app) = weak.upgrade() {
            crate::notify::play_sound(&app.settings.borrow().notify_sound);
        }
    });
    row.add_suffix(&play);
    notifications.add(&row);
    page.add(&notifications);

    let usage = adw::PreferencesGroup::new();
    usage.set_title("Usage limits");
    let row = adw::ActionRow::new();
    row.set_title("Claude plan limits");
    set_usage(&row, crate::usage::claude());
    let check = gtk::Button::with_label("Check now");
    check.set_valign(gtk::Align::Center);
    let weak = Rc::downgrade(app);
    check.connect_clicked(move |_| {
        if let Some(app) = weak.upgrade() {
            crate::usage::refresh(&app);
        }
    });
    row.add_suffix(&check);
    usage.add(&row);
    USAGE_ROW.with(|r| *r.borrow_mut() = Some(row.downgrade()));
    let codex = adw::ActionRow::new();
    codex.set_title("Codex plan limits");
    set_usage(&codex, crate::codex::usage(app).0);
    usage.add(&codex);
    CODEX_ROW.with(|r| *r.borrow_mut() = Some(codex.downgrade()));
    page.add(&usage);

    let first = adw::PreferencesGroup::new();
    first.set_title("First project");
    for (label, action) in [
        ("Open a folder…", "app.open-folder"),
        ("Recent conversations…", "app.open-recent"),
    ] {
        let row = adw::ActionRow::new();
        row.set_title(label);
        row.set_activatable(true);
        row.set_action_name(Some(action));
        row.add_suffix(&gtk::Image::from_icon_name("go-next-symbolic"));
        first.add(&row);
    }
    first.set_description(Some(
        "Open this again from the main menu › Welcome to omux.",
    ));
    page.add(&first);

    let view = adw::ToolbarView::new();
    let bar = adw::HeaderBar::new();
    let done = gtk::Button::with_label("Done");
    done.add_css_class("suggested-action");
    let d = dialog.downgrade();
    done.connect_clicked(move |_| {
        if let Some(d) = d.upgrade() {
            d.close();
        }
    });
    bar.pack_end(&done);
    bar.set_show_end_title_buttons(false);
    view.add_top_bar(&bar);
    view.set_content(Some(&page));
    dialog.set_child(Some(&view));
    dialog.present(Some(&app.ui.window));
}

fn set_usage(row: &adw::ActionRow, usage: Option<Usage>) {
    match usage {
        Some(Usage::Limits(limits)) => row.set_subtitle(&crate::usage::summary(&limits)),
        Some(Usage::Problem(_, long)) => row.set_subtitle(&long),
        None => row.set_subtitle("Not checked yet"),
    }
}

pub fn usage_changed(app: &Rc<App>) {
    let row = USAGE_ROW.with(|r| r.borrow().as_ref().and_then(|w| w.upgrade()));
    if let Some(row) = row {
        set_usage(&row, crate::usage::claude());
    }
    let codex = CODEX_ROW.with(|r| r.borrow().as_ref().and_then(|w| w.upgrade()));
    if let Some(codex) = codex {
        set_usage(&codex, crate::codex::usage(app).0);
    }
}
