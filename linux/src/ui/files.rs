//! The Files tab: a preview on top, the session's folder below with files
//! the session mentioned listed first.

use std::cell::RefCell;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::rc::{Rc, Weak};
use std::time::{Duration, SystemTime};

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use notify::Watcher;
use uuid::Uuid;
use vte::prelude::*;

use crate::app::App;
use crate::claude::SubAgent;

/// Names never listed, as on the Mac.
const SKIPPED: [&str; 7] = [
    "node_modules",
    ".git",
    ".build",
    "DerivedData",
    "__pycache__",
    ".venv",
    "venv",
];
const MAX_ENTRIES: usize = 500;

struct Files {
    app: Weak<App>,
    paned: gtk::Paned,
    preview: gtk::Box,
    list: gtk::ListBox,
    tree_box: gtk::Box,
    root_label: gtk::Label,
    chevron: gtk::Button,
    by_date: gtk::ToggleButton,
    root: Option<PathBuf>,
    expanded: HashSet<PathBuf>,
    mentioned: Vec<PathBuf>,
    selected: Option<PathBuf>,
    watcher: Option<notify::RecommendedWatcher>,
    watched: HashSet<PathBuf>,
    rebuild_pending: bool,
}

thread_local! {
    static FILES: RefCell<Option<Files>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut Files) -> R) -> Option<R> {
    FILES.with(|cell| cell.borrow_mut().as_mut().map(f))
}

pub fn app() -> Option<Rc<App>> {
    FILES.with(|cell| cell.borrow().as_ref().and_then(|f| f.app.upgrade()))
}

pub fn build(app: &Rc<App>) -> gtk::Widget {
    let preview = gtk::Box::new(gtk::Orientation::Vertical, 0);
    preview.set_vexpand(true);
    preview.set_size_request(-1, 200);
    preview.append(&placeholder());

    let tree_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 4);
    header.add_css_class("omux-panel-strip");
    header.set_margin_start(4);
    header.set_margin_end(4);
    let chevron = gtk::Button::from_icon_name("pan-down-symbolic");
    chevron.add_css_class("flat");
    chevron.add_css_class("omux-small");
    header.append(&chevron);
    let root_label = gtk::Label::new(None);
    root_label.add_css_class("omux-project");
    root_label.set_hexpand(true);
    root_label.set_xalign(0.0);
    root_label.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    header.append(&root_label);
    let by_name = gtk::ToggleButton::with_label("Name");
    let by_date = gtk::ToggleButton::with_label("Date");
    by_date.set_group(Some(&by_name));
    let sort = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    sort.add_css_class("linked");
    for b in [&by_name, &by_date] {
        b.add_css_class("omux-small");
        sort.append(b);
    }
    if app.settings.borrow().files_by_date {
        by_date.set_active(true);
    } else {
        by_name.set_active(true);
    }
    header.append(&sort);
    let open = gtk::Button::from_icon_name("folder-open-symbolic");
    open.add_css_class("flat");
    open.add_css_class("omux-small");
    open.set_tooltip_text(Some("Open folder"));
    header.append(&open);
    tree_box.append(&header);

    let list = gtk::ListBox::new();
    list.add_css_class("navigation-sidebar");
    let scroller = gtk::ScrolledWindow::builder()
        .child(&list)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .build();
    tree_box.append(&scroller);

    let paned = gtk::Paned::new(gtk::Orientation::Vertical);
    paned.set_start_child(Some(&preview));
    paned.set_end_child(Some(&tree_box));
    paned.set_resize_end_child(false);
    paned.set_shrink_start_child(false);
    paned.set_shrink_end_child(false);

    FILES.with(|cell| {
        *cell.borrow_mut() = Some(Files {
            app: Rc::downgrade(app),
            paned: paned.clone(),
            preview,
            list: list.clone(),
            tree_box: tree_box.clone(),
            root_label,
            chevron: chevron.clone(),
            by_date: by_date.clone(),
            root: None,
            expanded: HashSet::new(),
            mentioned: Vec::new(),
            selected: None,
            watcher: None,
            watched: HashSet::new(),
            rebuild_pending: false,
        })
    });

    let weak = Rc::downgrade(app);
    by_date.connect_toggled(move |b| {
        if let Some(app) = weak.upgrade() {
            let on = b.is_active();
            app.update_settings(|s| s.files_by_date = on);
            rebuild();
        }
    });
    let weak = Rc::downgrade(app);
    chevron.connect_clicked(move |_| {
        if let Some(app) = weak.upgrade() {
            let collapsed = !app.settings.borrow().files_browser_collapsed;
            app.update_settings(|s| s.files_browser_collapsed = collapsed);
            apply_collapsed(collapsed);
        }
    });
    let weak = Rc::downgrade(app);
    open.connect_clicked(move |_| {
        let root = with(|f| f.root.clone()).flatten();
        if let (Some(app), Some(root)) = (weak.upgrade(), root) {
            app.open_uri(&gio::File::for_path(root).uri());
        }
    });
    list.connect_row_activated(|_, row| {
        let path = PathBuf::from(row.widget_name().as_str());
        if path.is_dir() {
            with(|f| {
                if !f.expanded.remove(&path) {
                    f.expanded.insert(path.clone());
                }
            });
            rebuild();
        } else if let Some(app) = crate::ui::files::app() {
            crate::ui::files::preview(&app, &path);
        }
    });
    row_menu(&list);
    // Files dropped onto the panel are previewed.
    let drop = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    drop.connect_drop(|_, value, _, _| {
        let Ok(list) = value.get::<gdk::FileList>() else {
            return false;
        };
        let Some(path) = list.files().first().and_then(|f| f.path()) else {
            return false;
        };
        if let Some(app) = crate::ui::files::app() {
            crate::ui::files::preview(&app, &path);
        }
        true
    });
    paned.add_controller(drop);

    apply_collapsed(app.settings.borrow().files_browser_collapsed);
    // The list starts at about 220 px, the preview takes the rest.
    paned.add_tick_callback(|paned, _| {
        let height = paned.height();
        if height <= 0 {
            return glib::ControlFlow::Continue;
        }
        paned.set_position((height - 220).max(200));
        glib::ControlFlow::Break
    });

    // Mentioned paths: re-scanned every 4 s while the tab is on screen.
    let weak = Rc::downgrade(app);
    glib::timeout_add_local(Duration::from_secs(4), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if crate::ui::panel::is_showing(&app, "files") {
            scan_mentions(&app);
        }
        glib::ControlFlow::Continue
    });
    paned.upcast()
}

fn apply_collapsed(collapsed: bool) {
    with(|f| {
        f.chevron.set_icon_name(if collapsed {
            "pan-end-symbolic"
        } else {
            "pan-down-symbolic"
        });
        let list_scroller = f.list.parent().and_then(|p| p.parent());
        if let Some(scroller) = list_scroller {
            scroller.set_visible(!collapsed);
        }
        if collapsed {
            let height = f.paned.height();
            if height > 0 {
                f.paned.set_position(height - 30);
            }
        } else if f.paned.position() > f.paned.height() - 120 {
            f.paned.set_position((f.paned.height() - 220).max(200));
        }
        f.tree_box.set_vexpand(!collapsed);
    });
}

fn placeholder() -> gtk::Widget {
    let label = gtk::Label::new(Some("Select a file to preview"));
    label.add_css_class("dim-label");
    label.set_vexpand(true);
    label.upcast()
}

pub fn set_preview_widget(widget: &impl IsA<gtk::Widget>) {
    set_preview(widget);
}

fn set_preview(widget: &impl IsA<gtk::Widget>) {
    with(|f| {
        while let Some(child) = f.preview.first_child() {
            f.preview.remove(&child);
        }
        f.preview.append(widget);
    });
}

pub fn selection_changed(app: &Rc<App>) {
    let root = app
        .selected
        .get()
        .and_then(|id| crate::ui::panel::root_for(app, id));
    let changed = with(|f| {
        if f.root == root {
            return false;
        }
        f.root = root.clone();
        f.expanded.clear();
        f.mentioned.clear();
        // Another session's file or transcript doesn't stay on screen.
        f.selected = None;
        f.root_label.set_text(
            &root
                .as_ref()
                .and_then(|r| r.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
        );
        true
    })
    .unwrap_or(false);
    if changed {
        set_preview(&placeholder());
        rebuild();
    }
    scan_mentions(app);
}

/// The terminal's text including scrollback.
fn terminal_text(app: &App, id: Uuid) -> Option<String> {
    let term = app.terminal(id)?;
    let adjustment = term.widget.vadjustment()?;
    let (text, _) = term.widget.text_range_format(
        vte::Format::Text,
        adjustment.lower() as i64,
        0,
        adjustment.upper() as i64,
        term.widget.column_count(),
    );
    text.map(|t| t.to_string())
}

fn scan_mentions(app: &Rc<App>) {
    let Some(id) = app.selected.get() else { return };
    let text = terminal_text(app, id).unwrap_or_default();
    let weak = Rc::downgrade(app);
    crate::ui::panel::background(
        move || crate::mentions::paths(&text),
        move |paths| {
            // The user may have switched sessions while this ran.
            if weak
                .upgrade()
                .is_none_or(|app| app.selected.get() != Some(id))
            {
                return;
            }
            let changed = with(|f| {
                if f.mentioned == paths {
                    return false;
                }
                f.mentioned = paths;
                true
            })
            .unwrap_or(false);
            if changed {
                rebuild();
            }
        },
    );
}

/// Children of a folder: no hidden or skipped names, folders first, then by
/// name (natural order) or newest first, at most 500.
fn children(dir: &Path, by_date: bool) -> Vec<(PathBuf, bool, SystemTime)> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut items: Vec<(PathBuf, bool, SystemTime)> = entries
        .flatten()
        .filter(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            !name.starts_with('.') && !SKIPPED.contains(&name.as_str())
        })
        .map(|e| {
            let meta = e.metadata().ok();
            let is_dir = e.path().is_dir();
            let date = meta
                .and_then(|m| m.modified().ok())
                .unwrap_or(SystemTime::UNIX_EPOCH);
            (e.path(), is_dir, date)
        })
        .collect();
    items.sort_by(|a, b| {
        b.1.cmp(&a.1).then_with(|| {
            if by_date {
                b.2.cmp(&a.2)
            } else {
                natural_cmp(&name_of(&a.0), &name_of(&b.0))
            }
        })
    });
    items.truncate(MAX_ENTRIES);
    items
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

/// Case-insensitive comparison with runs of digits compared as numbers.
pub fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return std::cmp::Ordering::Equal,
            (None, _) => return std::cmp::Ordering::Less,
            (_, None) => return std::cmp::Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let take = |it: &mut std::iter::Peekable<std::str::Chars>| {
                    let mut n = String::new();
                    while let Some(c) = it.peek().copied().filter(char::is_ascii_digit) {
                        n.push(c);
                        it.next();
                    }
                    n.trim_start_matches('0').to_string()
                };
                let (nx, ny) = (take(&mut a), take(&mut b));
                let order = nx.len().cmp(&ny.len()).then_with(|| nx.cmp(&ny));
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
            }
            (Some(x), Some(y)) => {
                let order = x.to_lowercase().cmp(y.to_lowercase());
                if order != std::cmp::Ordering::Equal {
                    return order;
                }
                a.next();
                b.next();
            }
        }
    }
}

fn row(
    path: &Path,
    depth: usize,
    is_dir: bool,
    expanded: bool,
    label: Option<String>,
) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    row.set_widget_name(&path.display().to_string());
    let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    hbox.set_margin_start(6 + depth as i32 * 14);
    hbox.set_margin_top(1);
    hbox.set_margin_bottom(1);
    let arrow = gtk::Image::from_icon_name(if !is_dir {
        ""
    } else if expanded {
        "pan-down-symbolic"
    } else {
        "pan-end-symbolic"
    });
    arrow.set_pixel_size(12);
    arrow.set_opacity(if is_dir { 0.5 } else { 0.0 });
    hbox.append(&arrow);
    // Guessed from the name: asking GIO about each file would read it.
    let icon = if is_dir {
        gtk::Image::from_icon_name("folder-symbolic")
    } else {
        let (content_type, _) = gio::content_type_guess(Some(path), None::<&[u8]>);
        gtk::Image::from_gicon(&gio::content_type_get_symbolic_icon(&content_type))
    };
    hbox.append(&icon);
    let text = label.unwrap_or_else(|| name_of(path));
    let name = gtk::Label::new(Some(&text));
    name.set_xalign(0.0);
    name.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    hbox.append(&name);
    row.set_child(Some(&hbox));
    row.set_tooltip_text(Some(&path.display().to_string()));
    row
}

fn section(title: &str) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    let label = gtk::Label::new(Some(title));
    label.add_css_class("omux-project");
    label.set_xalign(0.0);
    label.set_margin_start(6);
    label.set_margin_top(6);
    row.set_child(Some(&label));
    row.set_activatable(false);
    row.set_selectable(false);
    row
}

fn rebuild() {
    with(|f| {
        f.rebuild_pending = false;
        f.list.remove_all();
        let Some(root) = f.root.clone() else { return };
        let by_date = f.by_date.is_active();
        if !f.mentioned.is_empty() {
            f.list.append(&section("Mentioned in session"));
            for path in f.mentioned.iter().rev() {
                let label = path
                    .strip_prefix(&root)
                    .map(|p| p.display().to_string())
                    .unwrap_or_else(|_| crate::persistence::abbreviate_home(path));
                f.list.append(&row(path, 0, false, false, Some(label)));
            }
            f.list.append(&section(&name_of(&root)));
        }
        let mut out = Vec::new();
        flatten(&root, 0, by_date, &f.expanded, &mut out);
        for (path, depth, is_dir, expanded) in out {
            f.list.append(&row(&path, depth, is_dir, expanded, None));
        }
        if let Some(selected) = &f.selected {
            let mut child = f.list.first_child();
            while let Some(widget) = child {
                if widget.widget_name() == selected.display().to_string() {
                    if let Ok(row) = widget.clone().downcast::<gtk::ListBoxRow>() {
                        f.list.select_row(Some(&row));
                    }
                    break;
                }
                child = widget.next_sibling();
            }
        }
    });
    watch();
}

fn flatten(
    dir: &Path,
    depth: usize,
    by_date: bool,
    expanded: &HashSet<PathBuf>,
    out: &mut Vec<(PathBuf, usize, bool, bool)>,
) {
    for (path, is_dir, _) in children(dir, by_date) {
        let open = is_dir && expanded.contains(&path);
        out.push((path.clone(), depth, is_dir, open));
        if open {
            flatten(&path, depth + 1, by_date, expanded, out);
        }
    }
}

/// Watches the root and expanded folders (not recursively, so huge trees
/// don't exhaust inotify watches); changes rebuild after a second.
fn watch() {
    with(|f| {
        let Some(root) = f.root.clone() else { return };
        let mut wanted: HashSet<PathBuf> = f.expanded.iter().cloned().collect();
        wanted.insert(root);
        if wanted == f.watched && f.watcher.is_some() {
            return;
        }
        let (tx, rx) = async_channel::unbounded::<()>();
        let watcher = notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
            if event.is_ok() {
                let _ = tx.send_blocking(());
            }
        });
        let Ok(mut watcher) = watcher else { return };
        for dir in &wanted {
            let _ = watcher.watch(dir, notify::RecursiveMode::NonRecursive);
        }
        f.watcher = Some(watcher);
        f.watched = wanted;
        glib::spawn_future_local(async move {
            while rx.recv().await.is_ok() {
                let first =
                    with(|f| !std::mem::replace(&mut f.rebuild_pending, true)).unwrap_or(false);
                if first {
                    glib::timeout_add_local_once(Duration::from_secs(1), rebuild);
                }
            }
        });
    });
}

fn row_menu(list: &gtk::ListBox) {
    let click = gtk::GestureClick::new();
    click.set_button(3);
    let list_ref = list.downgrade();
    click.connect_pressed(move |gesture, _, x, y| {
        let Some(list) = list_ref.upgrade() else {
            return;
        };
        let Some(row) = list.row_at_y(y as i32) else {
            return;
        };
        let name = row.widget_name().to_string();
        if name.is_empty() || !Path::new(&name).exists() {
            return;
        }
        gesture.set_state(gtk::EventSequenceState::Claimed);
        let path = PathBuf::from(name);
        let popover = gtk::Popover::new();
        let vbox = gtk::Box::new(gtk::Orientation::Vertical, 0);
        for (label, action) in [("Open", 0), ("Show in Files", 1), ("Copy Path", 2)] {
            let button = gtk::Button::with_label(label);
            button.add_css_class("flat");
            let path = path.clone();
            let pop = popover.downgrade();
            button.connect_clicked(move |b| {
                match action {
                    0 => {
                        let _ = gio::AppInfo::launch_default_for_uri(
                            &gio::File::for_path(&path).uri(),
                            gio::AppLaunchContext::NONE,
                        );
                    }
                    1 => show_in_files(&path),
                    _ => b.clipboard().set_text(&path.display().to_string()),
                }
                if let Some(p) = pop.upgrade() {
                    p.popdown();
                }
            });
            vbox.append(&button);
        }
        popover.set_child(Some(&vbox));
        popover.set_parent(&row);
        popover.set_has_arrow(false);
        let point = gtk::graphene::Point::new(x as f32, y as f32);
        let local = list.compute_point(&row, &point).unwrap_or(point);
        popover.set_pointing_to(Some(&gdk::Rectangle::new(
            local.x() as i32,
            local.y() as i32,
            1,
            1,
        )));
        popover.connect_closed(|p| {
            let p = p.clone();
            glib::idle_add_local_once(move || p.unparent());
        });
        popover.popup();
    });
    list.add_controller(click);
}

pub fn show_in_files(path: &Path) {
    let launcher = gtk::FileLauncher::new(Some(&gio::File::for_path(path)));
    launcher.open_containing_folder(gtk::Window::NONE, gio::Cancellable::NONE, |_| {});
}

/// Shows a file in the preview area and selects it in the list.
pub fn preview(app: &Rc<App>, path: &Path) {
    with(|f| f.selected = Some(path.to_path_buf()));
    let wrap = app.settings.borrow().preview_wrap_lines;
    set_preview(&crate::ui::preview::view(app, path, wrap));
}

pub fn show_transcript(_app: &Rc<App>, agent: &SubAgent) {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    header.set_margin_start(10);
    header.set_margin_end(6);
    header.set_margin_top(4);
    header.set_margin_bottom(4);
    let title = gtk::Label::new(Some(&format!("{} · {}", agent.kind, agent.description)));
    title.add_css_class("omux-header-name");
    title.set_ellipsize(gtk::pango::EllipsizeMode::End);
    title.set_hexpand(true);
    title.set_xalign(0.0);
    header.append(&title);
    let close = gtk::Button::from_icon_name("window-close-symbolic");
    close.add_css_class("flat");
    close.add_css_class("omux-small");
    close.connect_clicked(|_| set_preview(&placeholder()));
    header.append(&close);
    vbox.append(&header);
    vbox.append(&crate::ui::agents::transcript_view(
        agent.transcript.clone(),
    ));
    set_preview(&vbox);
}

#[cfg(test)]
mod tests {
    use super::natural_cmp;
    use std::cmp::Ordering;

    #[test]
    fn natural_order() {
        assert_eq!(natural_cmp("file2", "file10"), Ordering::Less);
        assert_eq!(natural_cmp("B", "a"), Ordering::Greater);
        assert_eq!(natural_cmp("a01", "a1"), Ordering::Equal);
    }
}
