//! The sidebar: projects with their sessions, each with its live status.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use uuid::Uuid;

use crate::app::App;
use crate::model::{TabColor, TabGroup, TabItem};
use crate::runtime::{StatusColor, TabRuntime};

pub struct Sidebar {
    pub root: gtk::Box,
    pub list: gtk::ListBox,
    /// Holds the usage strip (filled by `usage`).
    pub footer: gtk::Box,
    rows: RefCell<HashMap<Uuid, SessionRow>>,
    menu: gtk::PopoverMenu,
    hovered: Cell<Option<Uuid>>,
    /// Set while the sidebar selects a row itself, so it isn't taken as a click.
    syncing: Cell<bool>,
}

struct SessionRow {
    row: gtk::ListBoxRow,
    dot: gtk::Box,
    name: gtk::Label,
    status: gtk::Label,
    permission: gtk::Box,
    trailing: gtk::Stack,
    start_stop: gtk::Button,
    /// Subagent rows and PR badges, filled by later layers.
    pub extras: gtk::Box,
}

const DOT_CLASSES: [&str; 14] = [
    "blue", "orange", "green", "red", "purple", "yellow", "mint", "teal", "cyan", "indigo", "pink",
    "brown", "gray", "ring",
];

pub fn set_dot(dot: &gtk::Box, color: Option<&str>) {
    for class in DOT_CLASSES {
        dot.remove_css_class(class);
    }
    if let Some(color) = color {
        dot.add_css_class(color);
    }
}

pub fn status_class(color: StatusColor) -> &'static str {
    match color {
        StatusColor::Orange => "orange",
        StatusColor::Blue => "blue",
        StatusColor::Green => "green",
        StatusColor::Red => "red",
    }
}

/// Status color, else the session's color, else neutral.
pub fn dot_color(rt: &TabRuntime, tab: &TabItem) -> Option<&'static str> {
    rt.status_color()
        .map(status_class)
        .or_else(|| (tab.color != TabColor::None).then_some(tab.color.raw()))
}

pub fn dot() -> gtk::Box {
    let dot = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    dot.add_css_class("omux-dot");
    dot.set_valign(gtk::Align::Center);
    dot.set_halign(gtk::Align::Center);
    dot
}

impl Sidebar {
    pub fn build() -> Self {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("omux-sidebar");
        root.set_size_request(200, -1);

        let bar = adw::HeaderBar::new();
        bar.add_css_class("omux-chrome");
        bar.set_show_end_title_buttons(false);
        bar.set_title_widget(Some(&gtk::Box::new(gtk::Orientation::Horizontal, 0)));
        let menu = gio::Menu::new();
        let section = gio::Menu::new();
        section.append(Some("New Project"), Some("app.new-project"));
        section.append(Some("New Claude Code Session"), Some("app.new-claude"));
        section.append(Some("New Codex Session"), Some("app.new-codex"));
        section.append(Some("New Shell"), Some("app.new-shell"));
        section.append(Some("New Session in Worktree…"), Some("app.new-worktree"));
        menu.append_section(None, &section);
        let section = gio::Menu::new();
        let session = gio::Menu::new();
        for (label, action) in [
            ("Rename", "app.rename"),
            ("Edit Session…", "app.edit-session"),
            ("Start or Continue Session", "app.start"),
            ("Restart Session", "app.restart"),
            ("Interrupt (Ctrl-C)", "app.interrupt"),
            ("Kill Session", "app.kill"),
            ("Close Session", "app.close-session"),
        ] {
            session.append(Some(label), Some(action));
        }
        section.append_submenu(Some("Session"), &session);
        let view = gio::Menu::new();
        view.append(Some("Files Panel"), Some("app.toggle-panel"));
        view.append(Some("Files"), Some("app.panel-tab::files"));
        view.append(Some("Changes"), Some("app.panel-tab::changes"));
        view.append(Some("Browser"), Some("app.panel-tab::browser"));
        view.append(Some("Next Session"), Some("app.next-session"));
        view.append(Some("Previous Session"), Some("app.prev-session"));
        section.append_submenu(Some("View"), &view);
        section.append(Some("Jump to Session…"), Some("app.quick-switch"));
        section.append(Some("Settings"), Some("app.settings"));
        section.append(Some("Keyboard Shortcuts"), Some("app.shortcuts"));
        section.append(Some("Welcome to omux…"), Some("app.welcome"));
        section.append(Some("omux on GitHub"), Some("app.github"));
        section.append(Some("About omux"), Some("app.about"));
        menu.append_section(None, &section);
        let section = gio::Menu::new();
        section.append(Some("Close Window"), Some("app.close-window"));
        section.append(Some("Quit"), Some("app.quit"));
        menu.append_section(None, &section);
        let menu_button = gtk::MenuButton::builder()
            .icon_name("open-menu-symbolic")
            .menu_model(&menu)
            .tooltip_text("Main menu")
            .build();
        bar.pack_end(&menu_button);
        for (icon, action, tip) in [
            (
                "document-open-recent-symbolic",
                "app.open-recent",
                "Open recent conversation (Ctrl+Alt+O)",
            ),
            (
                "folder-new-symbolic",
                "app.open-folder",
                "Open folder as a project (Ctrl+Shift+O)",
            ),
            (
                "list-add-symbolic",
                "app.new-session",
                "New session in current project (Ctrl+Shift+T)",
            ),
        ] {
            let button = gtk::Button::from_icon_name(icon);
            button.set_action_name(Some(action));
            button.set_tooltip_text(Some(tip));
            bar.pack_end(&button);
        }
        root.append(&bar);

        let list = gtk::ListBox::new();
        list.set_selection_mode(gtk::SelectionMode::Single);
        list.set_activate_on_single_click(true);
        list.add_css_class("navigation-sidebar");
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&list)
            .build();
        root.append(&scroller);

        let hairline = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        hairline.add_css_class("omux-hairline");
        root.append(&hairline);
        let footer = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.append(&footer);

        let menu = gtk::PopoverMenu::from_model(None::<&gio::MenuModel>);
        menu.set_has_arrow(false);
        // Not parented to the list: ListBox::remove_all would treat it as a row.
        menu.set_parent(&root);

        Self {
            root,
            list,
            footer,
            rows: RefCell::new(HashMap::new()),
            menu,
            hovered: Cell::new(None),
            syncing: Cell::new(false),
        }
    }

    pub fn select_row(&self, id: Option<Uuid>) {
        self.syncing.set(true);
        match id.and_then(|id| self.rows.borrow().get(&id).map(|r| r.row.clone())) {
            Some(row) => self.list.select_row(Some(&row)),
            None => self.list.unselect_all(),
        }
        self.syncing.set(false);
    }

    pub fn update_row(&self, app: &App, id: Uuid) {
        let rows = self.rows.borrow();
        let Some(row) = rows.get(&id) else { return };
        let Some((group, tab)) = app.tab(id) else {
            return;
        };
        let rt = app.rt(id);
        set_dot(&row.dot, dot_color(&rt, &tab));
        row.name.set_text(&tab.name);
        row.status.set_text(&secondary_line(app, &group, &tab, &rt));
        row.status.set_visible(!row.status.text().is_empty());
        let hovered = self.hovered.get() == Some(id);
        if rt.exited && !hovered {
            row.row.add_css_class("omux-stopped");
        } else {
            row.row.remove_css_class("omux-stopped");
        }
        let codex_pending = crate::codex::pending_approval(app, id).is_some();
        row.permission
            .set_visible(rt.awaits_permission() || codex_pending);
        // Trailing: on hover ■ (busy) or ▶ (not connected); else bell or activity.
        if hovered && (rt.busy || !rt.agent_connected) {
            let busy = rt.busy;
            row.start_stop.set_icon_name(if busy {
                "media-playback-stop-symbolic"
            } else {
                "media-playback-start-symbolic"
            });
            row.start_stop.set_tooltip_text(Some(if busy {
                "Interrupt (Ctrl-C)"
            } else {
                "Start or continue this session"
            }));
            row.trailing.set_visible_child_name("button");
        } else if rt.needs_attention {
            row.trailing.set_visible_child_name("bell");
        } else if rt.has_activity {
            row.trailing.set_visible_child_name("activity");
        } else {
            row.trailing.set_visible_child_name("none");
        }
        crate::ui::agents::update_sidebar(app, id, &row.extras);
    }
}

/// The second line: branch for worktree sessions, status, agent count.
fn secondary_line(app: &App, _group: &TabGroup, tab: &TabItem, rt: &TabRuntime) -> String {
    let show_folder = app.settings.borrow().show_folder_path;
    let mut parts = Vec::new();
    if let Some(worktree) = &tab.worktree {
        parts.push(format!("⎇ {}", worktree.branch));
    }
    let status = rt.status_line(show_folder && tab.worktree.is_none());
    if !status.is_empty() {
        parts.push(status);
    }
    if app.selected.get() != Some(tab.id) {
        let agents = crate::ui::agents::running_count(app, tab.id);
        if agents > 0 {
            parts.push(if agents == 1 {
                "1 agent".to_string()
            } else {
                format!("{agents} agents")
            });
        }
    }
    parts.join(" · ")
}

pub fn rebuild(app: &Rc<App>) {
    let sidebar = &app.ui.sidebar;
    sidebar.syncing.set(true);
    sidebar.list.remove_all();
    sidebar.rows.borrow_mut().clear();
    let groups = app.ws.borrow().groups.clone();
    for group in &groups {
        sidebar.list.append(&group_row(app, group));
        if group.is_collapsed {
            continue;
        }
        for tab in &group.tabs {
            let row = session_row(app, tab);
            sidebar.list.append(&row.row);
            sidebar.rows.borrow_mut().insert(tab.id, row);
        }
    }
    sidebar.syncing.set(false);
    let ids: Vec<Uuid> = sidebar.rows.borrow().keys().copied().collect();
    for id in ids {
        sidebar.update_row(app, id);
    }
    sidebar.select_row(app.selected.get());
}

fn group_row(app: &Rc<App>, group: &TabGroup) -> gtk::ListBoxRow {
    let row = gtk::ListBoxRow::new();
    row.set_widget_name(&format!("group:{}", group.id));
    row.set_selectable(false);
    let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    hbox.set_margin_start(6);
    hbox.set_margin_end(4);
    hbox.set_margin_top(8);
    hbox.set_margin_bottom(2);
    let chevron = gtk::Image::from_icon_name(if group.is_collapsed {
        "pan-end-symbolic"
    } else {
        "pan-down-symbolic"
    });
    chevron.set_opacity(0.5);
    hbox.append(&chevron);

    if app.renaming_group.get() == Some(group.id) {
        let entry = rename_entry(&group.name);
        let weak = Rc::downgrade(app);
        let id = group.id;
        commit_on_finish(&entry, move |text| {
            let Some(app) = weak.upgrade() else { return };
            app.renaming_group.set(None);
            if let Some(text) = text.filter(|t| !t.trim().is_empty()) {
                app.update_group(id, |g| g.name = text.trim().to_string());
            }
            app.refresh_sidebar();
        });
        hbox.append(&entry);
        glib::idle_add_local_once(move || {
            entry.grab_focus();
        });
    } else {
        let name = gtk::Label::new(Some(&group.name));
        name.add_css_class("omux-project");
        name.set_xalign(0.0);
        name.set_hexpand(true);
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        hbox.append(&name);
    }

    let add = gtk::Button::from_icon_name("list-add-symbolic");
    add.add_css_class("flat");
    add.add_css_class("circular");
    add.set_tooltip_text(Some("New session"));
    add.set_opacity(0.0);
    add.set_action_name(Some("app.group-new-session"));
    add.set_action_target_value(Some(&group.id.to_string().to_variant()));
    hbox.append(&add);
    let motion = gtk::EventControllerMotion::new();
    let shown = add.clone();
    motion.connect_enter(move |_, _, _| shown.set_opacity(1.0));
    let hidden = add.clone();
    motion.connect_leave(move |_| hidden.set_opacity(0.0));
    row.add_controller(motion);

    row.set_child(Some(&hbox));
    drag_source(&row, format!("group:{}", group.id));
    row
}

fn session_row(app: &Rc<App>, tab: &TabItem) -> SessionRow {
    let row = gtk::ListBoxRow::new();
    row.set_widget_name(&format!("tab:{}", tab.id));
    let outer = gtk::Box::new(gtk::Orientation::Vertical, 2);
    outer.set_margin_start(16);
    outer.set_margin_end(6);
    outer.set_margin_top(5);
    outer.set_margin_bottom(5);

    let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let dot = dot();
    line.append(&dot);
    let text = gtk::Box::new(gtk::Orientation::Vertical, 1);
    text.set_hexpand(true);

    let name_stack = gtk::Stack::new();
    let name = gtk::Label::new(Some(&tab.name));
    name.add_css_class("omux-session-name");
    name.set_xalign(0.0);
    name.set_ellipsize(gtk::pango::EllipsizeMode::End);
    name_stack.add_named(&name, Some("label"));
    if app.renaming.get() == Some(tab.id) {
        let entry = rename_entry(&tab.name);
        let weak = Rc::downgrade(app);
        let id = tab.id;
        commit_on_finish(&entry, move |text| {
            let Some(app) = weak.upgrade() else { return };
            app.renaming.set(None);
            if let Some(text) = text.filter(|t| !t.trim().is_empty()) {
                app.update_tab(id, |t| t.name = text.trim().to_string());
            }
            app.refresh_sidebar();
            app.ui.header.update(&app);
        });
        name_stack.add_named(&entry, Some("entry"));
        name_stack.set_visible_child_name("entry");
        glib::idle_add_local_once(move || {
            entry.grab_focus();
        });
    }
    text.append(&name_stack);

    let status = gtk::Label::new(None);
    status.add_css_class("omux-status");
    status.set_xalign(0.0);
    status.set_ellipsize(gtk::pango::EllipsizeMode::End);
    text.append(&status);
    line.append(&text);

    let trailing = gtk::Stack::new();
    trailing.set_valign(gtk::Align::Center);
    trailing.add_named(
        &gtk::Box::new(gtk::Orientation::Horizontal, 0),
        Some("none"),
    );
    let bell = gtk::Image::from_icon_name("preferences-system-notifications-symbolic");
    bell.add_css_class("omux-bell");
    trailing.add_named(&bell, Some("bell"));
    let activity = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    activity.add_css_class("omux-activity");
    activity.set_halign(gtk::Align::Center);
    activity.set_valign(gtk::Align::Center);
    trailing.add_named(&activity, Some("activity"));
    let start_stop = gtk::Button::from_icon_name("media-playback-start-symbolic");
    start_stop.add_css_class("flat");
    start_stop.add_css_class("circular");
    let weak = Rc::downgrade(app);
    let id = tab.id;
    start_stop.connect_clicked(move |_| {
        let Some(app) = weak.upgrade() else { return };
        if app.rt(id).busy {
            app.stop(id);
        } else {
            app.start(id);
        }
    });
    trailing.add_named(&start_stop, Some("button"));
    trailing.set_hhomogeneous(false);
    line.append(&trailing);
    outer.append(&line);

    let permission = permission_buttons(app, tab.id);
    permission.set_margin_start(16);
    outer.append(&permission);

    let extras = gtk::Box::new(gtk::Orientation::Vertical, 2);
    extras.set_margin_start(16);
    outer.append(&extras);
    row.set_child(Some(&outer));

    let motion = gtk::EventControllerMotion::new();
    let weak = Rc::downgrade(app);
    motion.connect_enter(move |_, _, _| {
        if let Some(app) = weak.upgrade() {
            app.ui.sidebar.hovered.set(Some(id));
            app.refresh_busy(id);
            app.ui.sidebar.update_row(&app, id);
        }
    });
    let weak = Rc::downgrade(app);
    motion.connect_leave(move |_| {
        if let Some(app) = weak.upgrade() {
            if app.ui.sidebar.hovered.get() == Some(id) {
                app.ui.sidebar.hovered.set(None);
            }
            app.ui.sidebar.update_row(&app, id);
        }
    });
    row.add_controller(motion);
    drag_source(&row, format!("tab:{}", tab.id));

    SessionRow {
        row,
        dot,
        name,
        status,
        permission,
        trailing,
        start_stop,
        extras,
    }
}

/// Allow / Deny (plus details for Codex), shown while a session waits for
/// permission.
pub fn permission_buttons(app: &Rc<App>, id: Uuid) -> gtk::Box {
    let hbox = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    hbox.set_visible(false);
    for (label, allow) in [("Allow", true), ("Deny", false)] {
        let button = gtk::Button::with_label(label);
        button.add_css_class("omux-small");
        if allow {
            button.add_css_class("suggested-action");
        }
        let weak = Rc::downgrade(app);
        button.connect_clicked(move |_| {
            if let Some(app) = weak.upgrade() {
                app.answer_permission(id, allow);
            }
        });
        hbox.append(&button);
    }
    let info = gtk::MenuButton::builder()
        .icon_name("dialog-information-symbolic")
        .tooltip_text("What Codex asks for")
        .build();
    info.add_css_class("flat");
    info.add_css_class("omux-small");
    let weak = Rc::downgrade(app);
    info.set_create_popup_func(move |button| {
        let Some(app) = weak.upgrade() else { return };
        let detail = crate::codex::pending_approval(&app, id).unwrap_or_default();
        let label = gtk::Label::new(Some(&detail));
        label.add_css_class("omux-mono");
        label.set_selectable(true);
        label.set_wrap(true);
        label.set_max_width_chars(60);
        let scroller = gtk::ScrolledWindow::builder()
            .child(&label)
            .min_content_width(420)
            .min_content_height(120)
            .max_content_height(180)
            .build();
        let popover = gtk::Popover::new();
        popover.set_child(Some(&scroller));
        button.set_popover(Some(&popover));
    });
    hbox.append(&info);
    let weak = Rc::downgrade(app);
    hbox.connect_map(move |_| {
        if let Some(app) = weak.upgrade() {
            info.set_visible(crate::codex::pending_approval(&app, id).is_some());
        }
    });
    hbox
}

fn rename_entry(text: &str) -> gtk::Entry {
    let entry = gtk::Entry::new();
    entry.set_text(text);
    entry.set_hexpand(true);
    entry.add_css_class("omux-small");
    entry
}

/// Enter or leaving the field commits; Escape cancels (`None`).
fn commit_on_finish(entry: &gtk::Entry, done: impl Fn(Option<String>) + 'static) {
    let done = Rc::new(done);
    let finished = Rc::new(Cell::new(false));
    let (d, f) = (done.clone(), finished.clone());
    entry.connect_activate(move |entry| {
        if !f.replace(true) {
            d(Some(entry.text().to_string()));
        }
    });
    let keys = gtk::EventControllerKey::new();
    let (d, f) = (done.clone(), finished.clone());
    keys.connect_key_pressed(move |_, key, _, _| {
        if key == gdk::Key::Escape {
            if !f.replace(true) {
                d(None);
            }
            return glib::Propagation::Stop;
        }
        glib::Propagation::Proceed
    });
    entry.add_controller(keys);
    let focus = gtk::EventControllerFocus::new();
    let entry_ref = entry.downgrade();
    focus.connect_leave(move |_| {
        if let Some(entry) = entry_ref.upgrade() {
            if !finished.replace(true) {
                let text = entry.text().to_string();
                // Leaving rebuilds the sidebar; do it after GTK finishes the focus change.
                let done = done.clone();
                glib::idle_add_local_once(move || done(Some(text)));
            }
        }
    });
    entry.add_controller(focus);
}

fn drag_source(row: &gtk::ListBoxRow, payload: String) {
    let source = gtk::DragSource::new();
    source.set_actions(gdk::DragAction::MOVE);
    source
        .connect_prepare(move |_, _, _| Some(gdk::ContentProvider::for_value(&payload.to_value())));
    row.add_controller(source);
}

fn row_target(list: &gtk::ListBox, y: f64) -> Option<(String, Uuid)> {
    let row = list.row_at_y(y as i32)?;
    let name = row.widget_name();
    let (kind, id) = name.split_once(':')?;
    Some((kind.to_string(), Uuid::parse_str(id).ok()?))
}

fn group_of_row(app: &Rc<App>, kind: &str, id: Uuid) -> Option<Uuid> {
    match kind {
        "group" => Some(id),
        _ => app.tab(id).map(|(g, _)| g.id),
    }
}

pub fn connect(app: &Rc<App>) {
    let sidebar = &app.ui.sidebar;
    let weak = Rc::downgrade(app);
    sidebar.list.connect_row_activated(move |_, row| {
        let Some(app) = weak.upgrade() else { return };
        if app.ui.sidebar.syncing.get() {
            return;
        }
        let name = row.widget_name();
        let Some((kind, id)) = name.split_once(':') else {
            return;
        };
        let Ok(id) = Uuid::parse_str(id) else { return };
        if kind == "group" {
            app.update_group(id, |g| g.is_collapsed = !g.is_collapsed);
            app.refresh_sidebar();
        } else {
            app.select(id);
        }
    });

    // Arrow keys move the selection; follow it like a click.
    let weak = Rc::downgrade(app);
    sidebar.list.connect_row_selected(move |_, row| {
        let (Some(app), Some(row)) = (weak.upgrade(), row) else {
            return;
        };
        if app.ui.sidebar.syncing.get() {
            return;
        }
        let name = row.widget_name();
        if let Some(id) = name
            .strip_prefix("tab:")
            .and_then(|id| Uuid::parse_str(id).ok())
        {
            if app.selected.get() != Some(id) {
                app.select(id);
            }
        }
    });

    // Right click: session, project or empty-area menu.
    let click = gtk::GestureClick::new();
    click.set_button(3);
    let weak = Rc::downgrade(app);
    click.connect_pressed(move |gesture, _, x, y| {
        let Some(app) = weak.upgrade() else { return };
        gesture.set_state(gtk::EventSequenceState::Claimed);
        let model = match row_target(&app.ui.sidebar.list, y) {
            Some((kind, id)) if kind == "tab" => tab_menu(&app, id),
            Some((_, id)) => group_menu(&app, id),
            None => empty_menu(),
        };
        let sidebar = &app.ui.sidebar;
        let point = gtk::graphene::Point::new(x as f32, y as f32);
        let (x, y) = sidebar
            .list
            .compute_point(&sidebar.root, &point)
            .map_or((x, y), |p| (p.x() as f64, p.y() as f64));
        let menu = &sidebar.menu;
        menu.set_menu_model(Some(&model));
        menu.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        menu.popup();
    });
    sidebar.list.add_controller(click);

    // Reordering by drag.
    let target = gtk::DropTarget::new(glib::Type::STRING, gdk::DragAction::MOVE);
    let weak = Rc::downgrade(app);
    target.connect_drop(move |_, value, _, y| {
        let Some(app) = weak.upgrade() else {
            return false;
        };
        let Ok(payload) = value.get::<String>() else {
            return false;
        };
        let Some((kind, id)) = payload.split_once(':') else {
            return false;
        };
        let Ok(id) = Uuid::parse_str(id) else {
            return false;
        };
        let target = row_target(&app.ui.sidebar.list, y);
        match (kind, target) {
            ("tab", Some((target_kind, target_id))) => {
                let Some(group) = group_of_row(&app, &target_kind, target_id) else {
                    return false;
                };
                let after = (target_kind == "tab").then_some(target_id);
                app.drop_tab(id, group, after);
            }
            ("tab", None) => {
                if let Some(last) = app.ws.borrow().groups.last().map(|g| g.id) {
                    let after = app
                        .ws
                        .borrow()
                        .groups
                        .last()
                        .and_then(|g| g.tabs.last().map(|t| t.id));
                    drop_later(&app, move |app| app.drop_tab(id, last, after));
                }
            }
            ("group", Some((target_kind, target_id))) => {
                let Some(before) = group_of_row(&app, &target_kind, target_id) else {
                    return false;
                };
                app.drop_group(id, before);
            }
            ("group", None) => app.drop_group(id, Uuid::nil()),
            _ => return false,
        }
        true
    });
    sidebar.list.add_controller(target);

    // Folders dropped from the file manager open as projects.
    let files = gtk::DropTarget::new(gdk::FileList::static_type(), gdk::DragAction::COPY);
    let weak = Rc::downgrade(app);
    files.connect_drop(move |_, value, _, _| {
        let Some(app) = weak.upgrade() else {
            return false;
        };
        let Ok(list) = value.get::<gdk::FileList>() else {
            return false;
        };
        for file in list.files() {
            if let Some(path) = file.path().filter(|p| p.is_dir()) {
                app.open_folder(&path);
            }
        }
        true
    });
    sidebar.list.add_controller(files);
}

fn drop_later(app: &Rc<App>, f: impl FnOnce(&Rc<App>) + 'static) {
    let weak = Rc::downgrade(app);
    glib::idle_add_local_once(move || {
        if let Some(app) = weak.upgrade() {
            f(&app);
        }
    });
}

fn item(menu: &gio::Menu, label: &str, action: &str, target: &str) {
    let item = gio::MenuItem::new(Some(label), None);
    item.set_action_and_target_value(Some(action), Some(&target.to_variant()));
    menu.append_item(&item);
}

fn tab_menu(app: &Rc<App>, id: Uuid) -> gio::Menu {
    let menu = gio::Menu::new();
    let target = id.to_string();
    let top = gio::Menu::new();
    item(&top, "Rename", "app.tab-rename", &target);
    item(&top, "Edit Session…", "app.tab-edit", &target);
    let colors = gio::Menu::new();
    for color in TabColor::ALL {
        item(
            &colors,
            &color.label(),
            "app.tab-color",
            &format!("{id}:{}", color.raw()),
        );
    }
    top.append_submenu(Some("Color"), &colors);
    let groups = app.ws.borrow().groups.clone();
    if groups.len() > 1 {
        let move_to = gio::Menu::new();
        let own = app.tab(id).map(|(g, _)| g.id);
        for group in groups.iter().filter(|g| Some(g.id) != own) {
            item(
                &move_to,
                &group.name,
                "app.tab-move",
                &format!("{id}:{}", group.id),
            );
        }
        top.append_submenu(Some("Move to"), &move_to);
    }
    menu.append_section(None, &top);
    if let Some(section) = crate::ui::worktree_actions::menu_section(app, id) {
        menu.append_section(None, &section);
    }
    let process = gio::Menu::new();
    item(&process, "Interrupt (Ctrl-C)", "app.tab-interrupt", &target);
    item(&process, "Restart Session", "app.tab-restart", &target);
    item(&process, "Kill Session", "app.tab-kill", &target);
    item(&process, "Close Session", "app.tab-close", &target);
    menu.append_section(None, &process);
    menu
}

fn group_menu(app: &Rc<App>, group_id: Uuid) -> gio::Menu {
    let menu = gio::Menu::new();
    let target = group_id.to_string();
    let new = gio::Menu::new();
    item(&new, "New Session", "app.group-new-session", &target);
    item(
        &new,
        "New Session in Worktree…",
        "app.group-new-worktree",
        &target,
    );
    item(&new, "New Shell", "app.group-new-shell", &target);
    menu.append_section(None, &new);
    let edit = gio::Menu::new();
    item(&edit, "Rename", "app.group-rename", &target);
    item(&edit, "Edit Project…", "app.group-edit", &target);
    menu.append_section(None, &edit);
    let order = gio::Menu::new();
    let index = app.group_index(group_id).unwrap_or(0);
    let count = app.ws.borrow().groups.len();
    if index > 0 {
        item(&order, "Move Up", "app.group-up", &target);
    }
    if index + 1 < count {
        item(&order, "Move Down", "app.group-down", &target);
    }
    menu.append_section(None, &order);
    let delete = gio::Menu::new();
    item(&delete, "Delete Project", "app.group-delete", &target);
    menu.append_section(None, &delete);
    menu
}

fn empty_menu() -> gio::Menu {
    let menu = gio::Menu::new();
    let top = gio::Menu::new();
    top.append(Some("New Project"), Some("app.new-project"));
    top.append(Some("Open Folder as Project…"), Some("app.open-folder"));
    top.append(Some("Open Recent Conversation…"), Some("app.open-recent"));
    top.append(Some("New Codex Session"), Some("app.new-codex"));
    menu.append_section(None, &top);
    let bottom = gio::Menu::new();
    bottom.append(Some("New Session"), Some("app.new-session"));
    bottom.append(Some("New Shell"), Some("app.new-shell"));
    menu.append_section(None, &bottom);
    menu
}
