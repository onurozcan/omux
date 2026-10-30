//! The Changes tab: what the session changed (against its worktree's base
//! branch, else uncommitted changes), a diff per file, and review notes the
//! user leaves on lines and sends to the agent in one message.
//!
//! Unlike the Mac, which watches the folder with FSEvents, the tab polls
//! every 2 s while it's on screen: a recursive inotify watch over a large
//! repository (node_modules included) can run out of watches.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::time::Duration;

use adw::prelude::*;
use gtk::{gio, glib};
use uuid::Uuid;

use crate::app::App;
use crate::git::{self, ChangedFile, DiffKind, DiffLine};
use crate::model::SessionProvider;
use crate::ui::panel::background;

type NoteKey = (String, usize);
type Note = (Option<usize>, String);

/// Review notes by (file path, diff row) → (line number, text), in the
/// order they were written: an edited note moves to the end, as on the Mac,
/// which is the order the agent receives them in.
#[derive(Clone, Default)]
struct Notes(Vec<(NoteKey, Note)>);

impl Notes {
    fn get(&self, key: &NoteKey) -> Option<&Note> {
        self.0.iter().find(|(k, _)| k == key).map(|(_, v)| v)
    }
    fn contains_key(&self, key: &NoteKey) -> bool {
        self.get(key).is_some()
    }
    fn insert(&mut self, key: NoteKey, note: Note) {
        self.remove(&key);
        self.0.push((key, note));
    }
    fn remove(&mut self, key: &NoteKey) {
        self.0.retain(|(k, _)| k != key);
    }
    fn keys(&self) -> impl Iterator<Item = &NoteKey> {
        self.0.iter().map(|(k, _)| k)
    }
    fn iter(&self) -> impl Iterator<Item = &(NoteKey, Note)> {
        self.0.iter()
    }
    fn len(&self) -> usize {
        self.0.len()
    }
    fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

struct Changes {
    app: Weak<App>,
    tab: Option<Uuid>,
    dir: Option<PathBuf>,
    base: Option<String>,
    is_repo: bool,
    files: Vec<ChangedFile>,
    selected: Option<String>,
    diff: Vec<DiffLine>,
    notes: HashMap<Uuid, Notes>,
    refreshing: bool,
    /// A refresh was asked for while one ran; run once more when it ends.
    again: bool,
    /// Push or merge in progress: shown instead of the footer buttons.
    activity: HashMap<Uuid, String>,
    stack: gtk::Stack,
    diff_view: gtk::TextView,
    list: gtk::ListBox,
    list_header: gtk::Label,
    footer: gtk::Box,
}

thread_local! {
    static CHANGES: RefCell<Option<Changes>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut Changes) -> R) -> Option<R> {
    CHANGES.with(|c| c.borrow_mut().as_mut().map(f))
}

pub fn build(app: &Rc<App>) -> gtk::Widget {
    let diff_view = gtk::TextView::new();
    diff_view.set_editable(false);
    diff_view.set_cursor_visible(false);
    diff_view.set_monospace(true);
    diff_view.set_top_margin(6);
    diff_view.set_bottom_margin(6);
    let buffer = diff_view.buffer();
    let tags = buffer.tag_table();
    for (name, class) in [
        ("added", "added"),
        ("removed", "removed"),
        ("hunk", "hunk"),
        ("info", "info"),
    ] {
        let tag = gtk::TextTag::new(Some(name));
        let rgba = |r, g, b, a| gtk::gdk::RGBA::new(r, g, b, a);
        match class {
            "added" => tag.set_paragraph_background_rgba(Some(&rgba(0.19, 0.82, 0.35, 0.13))),
            "removed" => tag.set_paragraph_background_rgba(Some(&rgba(1.0, 0.27, 0.23, 0.13))),
            "hunk" => tag.set_paragraph_background_rgba(Some(&rgba(0.04, 0.52, 1.0, 0.08))),
            _ => tag.set_foreground_rgba(Some(&rgba(0.55, 0.55, 0.55, 1.0))),
        }
        tags.add(&tag);
    }
    let number = gtk::TextTag::new(Some("number"));
    number.set_foreground_rgba(Some(&gtk::gdk::RGBA::new(0.55, 0.55, 0.55, 1.0)));
    tags.add(&number);
    let note = gtk::TextTag::new(Some("note"));
    note.set_paragraph_background_rgba(Some(&gtk::gdk::RGBA::new(1.0, 0.84, 0.04, 0.14)));
    note.set_family(Some("sans"));
    note.set_left_margin(52);
    tags.add(&note);
    let diff_scroller = gtk::ScrolledWindow::builder()
        .child(&diff_view)
        .vexpand(true)
        .build();

    let list = gtk::ListBox::new();
    list.add_css_class("navigation-sidebar");
    let list_scroller = gtk::ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    let list_header = gtk::Label::new(None);
    list_header.add_css_class("omux-project");
    list_header.set_xalign(0.0);
    list_header.set_hexpand(true);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    header.add_css_class("omux-panel-strip");
    header.set_margin_start(8);
    header.set_margin_end(4);
    header.append(&list_header);
    let refresh_button = gtk::Button::from_icon_name("view-refresh-symbolic");
    let open_button = gtk::Button::from_icon_name("folder-open-symbolic");
    for b in [&refresh_button, &open_button] {
        b.add_css_class("flat");
        b.add_css_class("omux-small");
        header.append(b);
    }
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    footer.set_margin_start(8);
    footer.set_margin_end(8);
    footer.set_margin_top(4);
    footer.set_margin_bottom(4);
    let bottom = gtk::Box::new(gtk::Orientation::Vertical, 0);
    bottom.append(&header);
    bottom.append(&list_scroller);
    bottom.append(&footer);

    let paned = gtk::Paned::new(gtk::Orientation::Vertical);
    paned.set_start_child(Some(&diff_scroller));
    paned.set_end_child(Some(&bottom));
    paned.set_shrink_start_child(false);
    paned.set_shrink_end_child(false);
    paned.set_position(380);

    let not_repo = adw::StatusPage::builder()
        .title("Not a Git repository")
        .description("Changes show up for sessions inside a Git repository.")
        .icon_name("folder-symbolic")
        .build();
    not_repo.add_css_class("compact");
    let stack = gtk::Stack::new();
    stack.add_named(&paned, Some("changes"));
    stack.add_named(&not_repo, Some("not-repo"));

    CHANGES.with(|c| {
        *c.borrow_mut() = Some(Changes {
            app: Rc::downgrade(app),
            tab: None,
            dir: None,
            base: None,
            is_repo: false,
            files: Vec::new(),
            selected: None,
            diff: Vec::new(),
            notes: HashMap::new(),
            refreshing: false,
            again: false,
            activity: HashMap::new(),
            stack: stack.clone(),
            diff_view: diff_view.clone(),
            list: list.clone(),
            list_header,
            footer,
        })
    });

    refresh_button.connect_clicked(|_| refresh());
    open_button.connect_clicked(|_| {
        let (app, dir) = with(|c| (c.app.upgrade(), c.dir.clone())).unwrap_or((None, None));
        if let (Some(app), Some(dir)) = (app, dir) {
            app.open_uri(&gio::File::for_path(dir).uri());
        }
    });
    list.connect_row_activated(|_, row| {
        let path = row.widget_name().to_string();
        with(|c| c.selected = Some(path));
        load_diff();
    });
    diff_click(&diff_view);

    let weak = Rc::downgrade(app);
    glib::timeout_add_local(Duration::from_secs(2), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if crate::ui::panel::is_showing(&app, "changes") {
            refresh();
        }
        glib::ControlFlow::Continue
    });
    stack.upcast()
}

pub fn selection_changed(app: &Rc<App>) {
    let Some(id) = app.selected.get() else { return };
    let Some((_, tab)) = app.tab(id) else { return };
    let dir = crate::ui::panel::root_for(app, id);
    let base = tab.worktree.as_ref().map(|w| w.base.clone());
    let changed = with(|c| {
        let changed = c.tab != Some(id) || c.dir != dir;
        if changed {
            c.tab = Some(id);
            c.dir = dir.clone();
            c.base = base.clone();
            c.files.clear();
            c.selected = None;
            c.diff.clear();
            c.is_repo = false;
        }
        changed
    })
    .unwrap_or(false);
    if changed {
        render_list();
        render_diff();
    }
    refresh();
}

pub fn session_closed(id: Uuid) {
    with(|c| {
        c.notes.remove(&id);
        c.activity.remove(&id);
    });
}

pub fn app_activated(_app: &Rc<App>) {
    refresh();
}

/// Reloads the file list (and the open diff) off the main thread.
pub fn refresh() {
    // One refresh at a time; one asked for meanwhile runs when it ends.
    let Some((dir, worktree_base)) = with(|c| {
        if c.refreshing {
            c.again = true;
            return None;
        }
        let dir = c.dir.clone()?;
        c.refreshing = true;
        Some((dir, c.base.clone()))
    })
    .flatten() else {
        return;
    };
    background(
        move || {
            let repo = git::top_level(&dir).is_some();
            if !repo {
                return (dir, false, None, Vec::new());
            }
            let base = git::diff_base(&dir, worktree_base.as_deref());
            let files = git::changed_files(&dir, base.as_deref());
            (dir, true, base, files)
        },
        |(dir, repo, _base, files)| {
            let again = with(|c| {
                c.refreshing = false;
                std::mem::replace(&mut c.again, false)
            })
            .unwrap_or(false);
            if again {
                glib::idle_add_local_once(refresh);
            }
            let changed = with(|c| {
                if c.dir.as_deref() != Some(dir.as_path()) {
                    return false;
                }
                let changed = c.files != files || c.is_repo != repo;
                c.is_repo = repo;
                c.files = files;
                // Show a diff right away: the first file, or keep the selection.
                let keep = c
                    .selected
                    .as_ref()
                    .is_some_and(|s| c.files.iter().any(|f| f.path == *s));
                if !keep {
                    c.selected = c.files.first().map(|f| f.path.clone());
                }
                changed
            })
            .unwrap_or(false);
            if changed {
                render_list();
                load_diff();
            }
        },
    );
}

fn base_name() -> String {
    with(|c| c.base.clone())
        .flatten()
        .unwrap_or_else(|| "HEAD".into())
}

fn render_list() {
    let Some((files, is_repo, selected, notes)) = with(|c| {
        let notes = c
            .tab
            .and_then(|t| c.notes.get(&t).cloned())
            .unwrap_or_default();
        (c.files.clone(), c.is_repo, c.selected.clone(), notes)
    }) else {
        return;
    };
    crate::ui::panel::set_changes_badge(files.len());
    with(|c| {
        c.stack
            .set_visible_child_name(if is_repo { "changes" } else { "not-repo" });
        c.list.remove_all();
        let count = files.len();
        c.list_header.set_text(&format!(
            "{count} changed file{}  vs {}",
            if count == 1 { "" } else { "s" },
            c.base.clone().unwrap_or_else(|| "HEAD".into())
        ));
    });
    if files.is_empty() && is_repo {
        let page = adw::StatusPage::builder()
            .title("No changes")
            .description(format!("Nothing differs from {} yet.", base_name()))
            .build();
        page.add_css_class("compact");
        with(|c| {
            let row = gtk::ListBoxRow::new();
            row.set_child(Some(&page));
            row.set_activatable(false);
            c.list.append(&row);
        });
    }
    for file in &files {
        let row = gtk::ListBoxRow::new();
        row.set_widget_name(&file.path);
        let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        hbox.set_margin_start(4);
        let (letter, color) = match file.status {
            'A' => ("A", "omux-green"),
            'D' => ("D", "omux-red"),
            'U' => ("U", "omux-green"),
            _ => ("M", "omux-orange"),
        };
        let status = gtk::Label::new(Some(letter));
        status.add_css_class(color);
        status.add_css_class("omux-mono");
        hbox.append(&status);
        let path = Path::new(&file.path);
        let name = gtk::Label::new(Some(
            &path
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
        ));
        hbox.append(&name);
        let folder = gtk::Label::new(Some(
            &path
                .parent()
                .map(|p| p.display().to_string())
                .unwrap_or_default(),
        ));
        folder.add_css_class("omux-status");
        folder.set_ellipsize(gtk::pango::EllipsizeMode::Start);
        folder.set_hexpand(true);
        folder.set_xalign(0.0);
        hbox.append(&folder);
        if notes.keys().any(|(p, _)| *p == file.path) {
            let icon = gtk::Image::from_icon_name("document-edit-symbolic");
            icon.add_css_class("omux-yellow");
            hbox.append(&icon);
        }
        // Zero counts are left out, as on the Mac.
        let counts = match (file.added, file.removed) {
            (None, _) => "binary".to_string(),
            (Some(a), r) => [
                (a > 0).then(|| format!("+{a}")),
                r.filter(|r| *r > 0).map(|r| format!("−{r}")),
            ]
            .into_iter()
            .flatten()
            .collect::<Vec<_>>()
            .join(" "),
        };
        let counts = gtk::Label::new(Some(&counts));
        counts.add_css_class("omux-status");
        hbox.append(&counts);
        row.set_child(Some(&hbox));
        with(|c| {
            c.list.append(&row);
            if selected.as_deref() == Some(file.path.as_str()) {
                c.list.select_row(Some(&row));
            }
        });
    }
    render_footer();
}

fn load_diff() {
    let Some(job) = with(|c| {
        let path = c.selected.clone()?;
        let file = c.files.iter().find(|f| f.path == path)?.clone();
        Some((c.dir.clone()?, c.base.clone(), file))
    })
    .flatten() else {
        with(|c| c.diff.clear());
        render_diff();
        return;
    };
    let (dir, worktree_base, file) = job;
    background(
        move || {
            let base = git::diff_base(&dir, worktree_base.as_deref());
            let lines = git::diff(&dir, base.as_deref(), &file);
            (file.path, lines)
        },
        |(path, lines)| {
            let same = with(|c| c.selected.as_deref() == Some(path.as_str())).unwrap_or(false);
            if same && with(|c| c.diff != lines).unwrap_or(false) {
                with(|c| c.diff = lines);
                render_diff();
            }
        },
    );
}

fn render_diff() {
    with(|c| {
        let buffer = c.diff_view.buffer();
        buffer.set_text("");
        let wrap = c
            .app
            .upgrade()
            .map(|a| a.settings.borrow().preview_wrap_lines)
            .unwrap_or(true);
        c.diff_view.set_wrap_mode(if wrap {
            gtk::WrapMode::WordChar
        } else {
            gtk::WrapMode::None
        });
        let notes = c
            .tab
            .and_then(|t| c.notes.get(&t).cloned())
            .unwrap_or_default();
        let path = c.selected.clone().unwrap_or_default();
        let mut end = buffer.end_iter();
        for (row, line) in c.diff.iter().enumerate() {
            let (sign, tag) = match line.kind {
                DiffKind::Added => ("+", Some("added")),
                DiffKind::Removed => ("−", Some("removed")),
                DiffKind::Hunk => (" ", Some("hunk")),
                DiffKind::Info => (" ", Some("info")),
                DiffKind::Context => (" ", None),
            };
            let number = line
                .number()
                .map(|n| format!("{n:>5} "))
                .unwrap_or_else(|| "      ".into());
            let start = end.offset();
            buffer.insert_with_tags_by_name(&mut end, &number, &["number"]);
            buffer.insert(&mut end, &format!("{sign} {}\n", line.text));
            if let Some(tag) = tag {
                let from = buffer.iter_at_offset(start);
                buffer.apply_tag_by_name(tag, &from, &end);
            }
            if let Some((_, text)) = notes.get(&(path.clone(), row)) {
                buffer.insert_with_tags_by_name(&mut end, &format!("✎ {text}\n"), &["note"]);
            }
        }
    });
}

/// Clicking a code line opens a field for a note on it.
fn diff_click(view: &gtk::TextView) {
    let click = gtk::GestureClick::new();
    let weak_view = view.downgrade();
    click.connect_released(move |_, _, x, y| {
        let Some(view) = weak_view.upgrade() else {
            return;
        };
        let (bx, by) =
            view.window_to_buffer_coords(gtk::TextWindowType::Widget, x as i32, y as i32);
        let Some(iter) = view.iter_at_location(bx, by) else {
            return;
        };
        let buffer_line = iter.line() as usize;
        // Map the buffer line back to a diff row, skipping note lines.
        let Some((row, line, path)) = with(|c| {
            let notes = c
                .tab
                .and_then(|t| c.notes.get(&t).cloned())
                .unwrap_or_default();
            let path = c.selected.clone()?;
            let mut buffer_index = 0;
            for (row, line) in c.diff.iter().enumerate() {
                if buffer_index == buffer_line {
                    return matches!(
                        line.kind,
                        DiffKind::Added | DiffKind::Removed | DiffKind::Context
                    )
                    .then(|| (row, line.number(), path.clone()));
                }
                buffer_index += 1;
                if notes.contains_key(&(path.clone(), row)) {
                    if buffer_index == buffer_line {
                        return Some((row, line.number(), path.clone()));
                    }
                    buffer_index += 1;
                }
            }
            None
        })
        .flatten() else {
            return;
        };
        let existing = with(|c| {
            c.tab
                .and_then(|t| c.notes.get(&t))
                .and_then(|n| n.get(&(path.clone(), row)))
                .map(|(_, t)| t.clone())
        })
        .flatten();
        let entry = gtk::Entry::new();
        entry.set_placeholder_text(Some("Review note"));
        entry.set_text(existing.as_deref().unwrap_or(""));
        entry.set_width_chars(40);
        let add = gtk::Button::with_label("Add");
        add.add_css_class("suggested-action");
        let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        hbox.append(&entry);
        hbox.append(&add);
        let popover = gtk::Popover::new();
        popover.set_child(Some(&hbox));
        popover.set_parent(&view);
        let location = view.iter_location(&iter);
        let (wx, wy) =
            view.buffer_to_window_coords(gtk::TextWindowType::Widget, location.x(), location.y());
        popover.set_pointing_to(Some(&gtk::gdk::Rectangle::new(
            wx.max(0),
            wy,
            1,
            location.height(),
        )));
        let save = {
            let popover = popover.downgrade();
            let entry = entry.downgrade();
            let path = path.clone();
            move || {
                let (Some(popover), Some(entry)) = (popover.upgrade(), entry.upgrade()) else {
                    return;
                };
                let text = entry.text().trim().to_string();
                with(|c| {
                    if let Some(tab) = c.tab {
                        let notes = c.notes.entry(tab).or_default();
                        if text.is_empty() {
                            notes.remove(&(path.clone(), row));
                        } else {
                            notes.insert((path.clone(), row), (line, text));
                        }
                    }
                });
                popover.popdown();
                render_diff();
                render_list();
            }
        };
        let s = save.clone();
        entry.connect_activate(move |_| s());
        add.connect_clicked(move |_| save());
        popover.connect_closed(|p| {
            let p = p.clone();
            glib::idle_add_local_once(move || p.unparent());
        });
        popover.popup();
        entry.grab_focus();
    });
    view.add_controller(click);
}

fn render_footer() {
    let Some((app, tab, notes, activity)) = with(|c| {
        let notes = c
            .tab
            .and_then(|t| c.notes.get(&t).cloned())
            .unwrap_or_default();
        let activity = c.tab.and_then(|t| c.activity.get(&t).cloned());
        (c.app.upgrade(), c.tab, notes, activity)
    }) else {
        return;
    };
    let (Some(app), Some(id)) = (app, tab) else {
        return;
    };
    with(|c| {
        while let Some(child) = c.footer.first_child() {
            c.footer.remove(&child);
        }
    });
    let footer = with(|c| c.footer.clone()).expect("footer");
    if notes.is_empty() {
        let hint = gtk::Label::new(Some("Click a line to leave a note"));
        hint.add_css_class("omux-status");
        hint.set_hexpand(true);
        hint.set_xalign(0.0);
        footer.append(&hint);
    } else {
        let count = gtk::Label::new(Some(&format!(
            "{} note{}",
            notes.len(),
            if notes.len() == 1 { "" } else { "s" }
        )));
        count.add_css_class("omux-status");
        count.set_hexpand(true);
        count.set_xalign(0.0);
        footer.append(&count);
        let codex = app
            .tab(id)
            .is_some_and(|(g, t)| t.resolved_provider(&g) == SessionProvider::Codex);
        let send = gtk::Button::with_label(if codex {
            "Send to Codex"
        } else {
            "Send to Claude"
        });
        send.add_css_class("suggested-action");
        send.add_css_class("omux-small");
        send.set_tooltip_text(Some("Types the notes into the session and sends them"));
        let weak = Rc::downgrade(&app);
        send.connect_clicked(move |_| {
            let Some(app) = weak.upgrade() else { return };
            let notes: Vec<(String, Option<usize>, String)> = with(|c| {
                c.notes
                    .get(&id)
                    .map(|n| {
                        n.iter()
                            .map(|((p, _), (l, t))| (p.clone(), *l, t.clone()))
                            .collect()
                    })
                    .unwrap_or_default()
            })
            .unwrap_or_default();
            if app.send_text(id, &git::review_message(&notes), true) {
                with(|c| c.notes.remove(&id));
                render_diff();
                render_list();
            }
        });
        footer.append(&send);
    }
    if let Some(widget) = crate::ui::worktree_actions::changes_footer(&app, id, activity) {
        footer.append(&widget);
    }
}

/// Shows (or clears) "Pushing …" / "Merging …" for a session.
pub fn set_activity(id: Uuid, text: Option<String>) {
    with(|c| match text {
        Some(text) => {
            c.activity.insert(id, text);
        }
        None => {
            c.activity.remove(&id);
        }
    });
    render_footer();
}

/// Changed-line totals for the branch chip: (+added, −removed).
pub fn totals(id: Uuid) -> Option<(usize, usize)> {
    with(|c| {
        (c.tab == Some(id)).then(|| {
            c.files.iter().fold((0, 0), |(a, r), f| {
                (a + f.added.unwrap_or(0), r + f.removed.unwrap_or(0))
            })
        })
    })
    .flatten()
}
