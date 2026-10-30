//! Open Recent Conversation (Ctrl+Alt+O): Claude Code conversations from
//! `~/.claude/projects`, Codex conversations from the Codex app-server.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};

use adw::prelude::*;
use gtk::glib;
use uuid::Uuid;

use crate::app::App;
use crate::model::{SessionProvider, TabGroup, TabItem};
use crate::persistence::abbreviate_home;

#[derive(Clone)]
pub struct Conversation {
    pub provider: SessionProvider,
    /// Claude session UUID or Codex thread id.
    pub id: String,
    pub cwd: String,
    pub prompt: String,
    /// Seconds since the epoch.
    pub date: i64,
}

fn load(provider: SessionProvider) -> Result<Vec<Conversation>, String> {
    if provider == SessionProvider::Codex {
        return crate::codex::recent();
    }
    Ok(crate::claude::recent_sessions()
        .into_iter()
        .map(|s| Conversation {
            provider,
            id: s.id.to_string().to_lowercase(),
            cwd: s.cwd,
            prompt: s.prompt,
            date: s
                .date
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_secs() as i64)
                .unwrap_or(0),
        })
        .collect())
}

pub fn relative(date: i64) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let seconds = (now - date).max(0);
    match seconds {
        0..=59 => "just now".into(),
        60..=3599 => format!("{} min. ago", seconds / 60),
        3600..=86_399 => format!("{} hr. ago", seconds / 3600),
        86_400..=172_799 => "yesterday".into(),
        _ => format!("{} days ago", seconds / 86_400),
    }
}

struct Sheet {
    list: gtk::ListBox,
    search: gtk::SearchEntry,
    by_folder: gtk::ToggleButton,
    codex: gtk::ToggleButton,
    stack: gtk::Stack,
    status: adw::StatusPage,
    items: RefCell<Vec<Conversation>>,
    error: RefCell<Option<String>>,
}

pub fn present(app: &Rc<App>) {
    let dialog = adw::Dialog::new();
    dialog.set_title("Recent Conversations");
    dialog.set_content_width(560);
    dialog.set_content_height(440);

    let search = gtk::SearchEntry::new();
    search.set_placeholder_text(Some("Search recent conversations…"));
    search.set_hexpand(true);
    let segmented = |a: &str, b: &str| {
        let first = gtk::ToggleButton::with_label(a);
        let second = gtk::ToggleButton::with_label(b);
        second.set_group(Some(&first));
        first.set_active(true);
        let linked = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        linked.add_css_class("linked");
        linked.append(&first);
        linked.append(&second);
        (linked, second)
    };
    let (order_box, by_folder) = segmented("Recent", "By folder");
    let (provider_box, codex) = segmented("Claude Code", "Codex");
    let current_codex = app
        .selected
        .get()
        .and_then(|id| app.tab(id))
        .is_some_and(|(g, t)| t.resolved_provider(&g) == SessionProvider::Codex);
    codex.set_active(current_codex);

    let controls = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    controls.set_margin_start(12);
    controls.set_margin_end(12);
    controls.set_margin_top(6);
    controls.append(&order_box);
    let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    spacer.set_hexpand(true);
    controls.append(&spacer);
    controls.append(&provider_box);

    let list = gtk::ListBox::new();
    list.add_css_class("navigation-sidebar");
    let scroller = gtk::ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .build();
    let status = adw::StatusPage::new();
    status.add_css_class("compact");
    let spinner = gtk::Spinner::new();
    spinner.start();
    spinner.set_size_request(32, 32);
    spinner.set_halign(gtk::Align::Center);
    spinner.set_valign(gtk::Align::Center);
    let stack = gtk::Stack::new();
    stack.add_named(&scroller, Some("list"));
    stack.add_named(&status, Some("status"));
    stack.add_named(&spinner, Some("loading"));

    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 8);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    top.set_margin_start(12);
    top.set_margin_end(12);
    top.append(&search);
    vbox.append(&top);
    vbox.append(&controls);
    vbox.append(&stack);
    let view = adw::ToolbarView::new();
    view.add_top_bar(&adw::HeaderBar::new());
    view.set_content(Some(&vbox));
    dialog.set_child(Some(&view));

    let sheet = Rc::new(Sheet {
        list,
        search,
        by_folder,
        codex,
        stack,
        status,
        items: RefCell::new(Vec::new()),
        error: RefCell::new(None),
    });

    // A slow load (Codex may start a server) must not replace a newer one.
    let generation = Rc::new(std::cell::Cell::new(0u64));
    let reload = {
        let sheet = sheet.clone();
        let weak = Rc::downgrade(app);
        move || {
            let current = generation.get() + 1;
            generation.set(current);
            let generation = generation.clone();
            let provider = if sheet.codex.is_active() {
                SessionProvider::Codex
            } else {
                SessionProvider::Claude
            };
            sheet.stack.set_visible_child_name("loading");
            let (tx, rx) = async_channel::bounded(1);
            std::thread::spawn(move || {
                let _ = tx.send_blocking(load(provider));
            });
            let sheet = sheet.clone();
            let weak = weak.clone();
            glib::spawn_future_local(async move {
                let Ok(result) = rx.recv().await else { return };
                if generation.get() != current {
                    return;
                }
                match result {
                    Ok(items) => {
                        *sheet.items.borrow_mut() = items;
                        *sheet.error.borrow_mut() = None;
                    }
                    Err(err) => {
                        sheet.items.borrow_mut().clear();
                        *sheet.error.borrow_mut() = Some(err);
                    }
                }
                if let Some(app) = weak.upgrade() {
                    fill(&app, &sheet);
                }
            });
        }
    };
    reload();
    let r = reload.clone();
    sheet.codex.connect_toggled(move |_| r());
    let weak = Rc::downgrade(app);
    let s = sheet.clone();
    sheet.by_folder.connect_toggled(move |_| {
        if let Some(app) = weak.upgrade() {
            fill(&app, &s);
        }
    });
    let weak = Rc::downgrade(app);
    let s = sheet.clone();
    sheet.search.connect_search_changed(move |_| {
        if let Some(app) = weak.upgrade() {
            fill(&app, &s);
        }
    });

    let open_row = {
        let weak = Rc::downgrade(app);
        let sheet = sheet.clone();
        let d = dialog.downgrade();
        move |row: &gtk::ListBoxRow| {
            let Some(app) = weak.upgrade() else { return };
            let Ok(index) = row.widget_name().parse::<usize>() else {
                return;
            };
            let Some(item) = sheet.items.borrow().get(index).cloned() else {
                return;
            };
            if let Some(d) = d.upgrade() {
                d.close();
            }
            open(&app, &item);
        }
    };
    let o = open_row.clone();
    sheet.list.connect_row_activated(move |_, row| o(row));
    let l = sheet.list.clone();
    sheet.search.connect_activate(move |_| {
        let mut child = l.first_child();
        while let Some(widget) = child {
            if let Ok(row) = widget.clone().downcast::<gtk::ListBoxRow>() {
                if row.is_activatable() {
                    open_row(&row);
                    return;
                }
            }
            child = widget.next_sibling();
        }
    });
    dialog.present(Some(&app.ui.window));
    sheet.search.grab_focus();
}

fn fill(app: &Rc<App>, sheet: &Rc<Sheet>) {
    sheet.list.remove_all();
    let provider_name = if sheet.codex.is_active() {
        "Codex"
    } else {
        "Claude Code"
    };
    if let Some(error) = sheet.error.borrow().as_ref() {
        sheet
            .status
            .set_title(&format!("No {provider_name} conversations"));
        sheet.status.set_description(Some(error));
        sheet.stack.set_visible_child_name("status");
        return;
    }
    let query = sheet.search.text().to_lowercase();
    let items = sheet.items.borrow();
    let mut matches: Vec<(usize, &Conversation)> = items
        .iter()
        .enumerate()
        .filter(|(_, c)| {
            query.is_empty()
                || c.prompt.to_lowercase().contains(&query)
                || abbreviate_home(Path::new(&c.cwd))
                    .to_lowercase()
                    .contains(&query)
        })
        .collect();
    if matches.is_empty() {
        let title = if items.is_empty() {
            format!("No {provider_name} conversations found")
        } else {
            "No matches".to_string()
        };
        sheet.status.set_title(&title);
        sheet.status.set_description(None);
        sheet.stack.set_visible_child_name("status");
        return;
    }
    let open_ids = open_ids(app);
    if sheet.by_folder.is_active() {
        // Folders ordered by their most recent conversation.
        let mut folders: Vec<String> = Vec::new();
        for (_, c) in &matches {
            if !folders.contains(&c.cwd) {
                folders.push(c.cwd.clone());
            }
        }
        matches.sort_by_key(|(_, c)| folders.iter().position(|f| *f == c.cwd));
        let mut last: Option<String> = None;
        for (index, c) in matches {
            if last.as_deref() != Some(c.cwd.as_str()) {
                let header = gtk::Label::new(Some(&abbreviate_home(Path::new(&c.cwd))));
                header.add_css_class("omux-project");
                header.set_xalign(0.0);
                header.set_margin_top(8);
                let row = gtk::ListBoxRow::new();
                row.set_child(Some(&header));
                row.set_activatable(false);
                row.set_selectable(false);
                sheet.list.append(&row);
                last = Some(c.cwd.clone());
            }
            sheet
                .list
                .append(&row_for(index, c, open_ids.contains(&c.id), false));
        }
    } else {
        for (index, c) in matches {
            sheet
                .list
                .append(&row_for(index, c, open_ids.contains(&c.id), true));
        }
    }
    sheet.stack.set_visible_child_name("list");
}

fn row_for(index: usize, c: &Conversation, is_open: bool, show_folder: bool) -> gtk::ListBoxRow {
    let row = adw::ActionRow::new();
    row.set_title(&glib::markup_escape_text(&c.prompt));
    row.set_title_lines(1);
    let mut subtitle = relative(c.date);
    if show_folder {
        subtitle = format!("{} · {subtitle}", abbreviate_home(Path::new(&c.cwd)));
    }
    row.set_subtitle(&glib::markup_escape_text(&subtitle));
    if is_open {
        let badge = gtk::Label::new(Some("open"));
        badge.add_css_class("omux-status");
        row.add_suffix(&badge);
    }
    row.set_activatable(true);
    row.set_widget_name(&index.to_string());
    row.upcast()
}

/// Conversation ids that already have a session.
fn open_ids(app: &App) -> Vec<String> {
    app.ws
        .borrow()
        .groups
        .iter()
        .flat_map(|g| g.tabs.iter())
        .flat_map(|t| {
            [
                Some(t.claude_session_id.to_string().to_lowercase()),
                t.codex_thread_id.clone(),
            ]
        })
        .flatten()
        .collect()
}

/// Selects the conversation's session, or adds one in the project for its
/// folder (made if needed) and starts it.
pub fn open(app: &Rc<App>, c: &Conversation) {
    let existing = app
        .ws
        .borrow()
        .groups
        .iter()
        .flat_map(|g| g.tabs.iter())
        .find(|t| match c.provider {
            SessionProvider::Codex => t.codex_thread_id.as_deref() == Some(c.id.as_str()),
            _ => t.claude_session_id.to_string().to_lowercase() == c.id,
        })
        .map(|t| t.id);
    if let Some(id) = existing {
        app.select(id);
        return;
    }
    let codex = c.provider == SessionProvider::Codex;
    let group_id = app
        .ws
        .borrow()
        .groups
        .iter()
        .find(|g| g.directory.as_deref() == Some(c.cwd.as_str()))
        .map(|g| g.id);
    let group_id = group_id.unwrap_or_else(|| {
        let name = Path::new(&c.cwd)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| c.cwd.clone());
        let mut group = TabGroup::new(name, Some(c.cwd.clone()), vec![]);
        if codex {
            group.provider = SessionProvider::Codex;
            group.command = Some("codex".into());
        }
        let id = group.id;
        app.ws.borrow_mut().groups.push(group);
        id
    });
    let mut tab = if codex {
        let mut tab = TabItem::new(c.prompt.chars().take(60).collect::<String>());
        tab.codex_thread_id = Some(c.id.clone());
        tab
    } else {
        let session = crate::claude::RecentSession {
            id: Uuid::parse_str(&c.id).unwrap_or_else(|_| Uuid::new_v4()),
            cwd: c.cwd.clone(),
            prompt: c.prompt.clone(),
            date: SystemTime::now(),
        };
        let mut tab = TabItem::new(session.tab_name());
        tab.claude_session_id = session.id;
        tab
    };
    tab.provider = Some(c.provider);
    tab.command = Some(c.provider.command().to_string());
    app.add_session(group_id, tab, None, None);
}
