//! The main window: sidebar | (session header, terminal | right panel).

use std::rc::Rc;

use adw::prelude::*;
use gtk::glib;
use uuid::Uuid;

use super::header::Header;
use super::sidebar::Sidebar;
use crate::app::App;
use crate::term::SessionTerminal;

pub struct Ui {
    pub window: adw::ApplicationWindow,
    pub sidebar: Sidebar,
    pub header: Header,
    pub stack: gtk::Stack,
    pub content_paned: gtk::Paned,
    pub panel: gtk::Box,
}

impl Ui {
    pub fn build(gtk_app: &adw::Application) -> Self {
        let sidebar = Sidebar::build();
        let header = Header::build();

        let stack = gtk::Stack::new();
        stack.set_hexpand(true);
        stack.set_vexpand(true);
        let empty = adw::StatusPage::builder()
            .title("No session")
            .description("Press Ctrl+Shift+T to start one.")
            .icon_name("utilities-terminal-symbolic")
            .build();
        empty.add_css_class("omux-terminal-bg");
        stack.add_named(&empty, Some("empty"));

        let panel = gtk::Box::new(gtk::Orientation::Vertical, 0);
        panel.set_size_request(260, -1);
        panel.add_css_class("omux-panel");

        let content_paned = gtk::Paned::new(gtk::Orientation::Horizontal);
        content_paned.set_start_child(Some(&stack));
        content_paned.set_end_child(Some(&panel));
        content_paned.set_resize_start_child(true);
        content_paned.set_resize_end_child(false);
        content_paned.set_shrink_start_child(false);
        content_paned.set_shrink_end_child(false);
        content_paned.set_wide_handle(false);

        let content = adw::ToolbarView::new();
        content.add_top_bar(&header.bar);
        content.set_content(Some(&content_paned));

        let split = gtk::Paned::new(gtk::Orientation::Horizontal);
        split.set_start_child(Some(&sidebar.root));
        split.set_end_child(Some(&content));
        split.set_resize_start_child(false);
        split.set_shrink_start_child(false);
        split.set_shrink_end_child(false);
        split.set_position(250);

        let window = adw::ApplicationWindow::builder()
            .application(gtk_app)
            .title("omux")
            .default_width(1240)
            .default_height(780)
            .width_request(720)
            .height_request(420)
            .content(&split)
            .build();

        Self {
            window,
            sidebar,
            header,
            stack,
            content_paned,
            panel,
        }
    }

    pub fn add_terminal(&self, id: Uuid, terminal: &Rc<SessionTerminal>) {
        let name = id.to_string();
        if let Some(old) = self.stack.child_by_name(&name) {
            self.stack.remove(&old);
        }
        self.stack.add_named(&terminal.widget, Some(&name));
    }

    pub fn remove_terminal(&self, terminal: &Rc<SessionTerminal>) {
        if terminal.widget.parent().is_some() {
            self.stack.remove(&terminal.widget);
        }
    }

    pub fn show_terminal(&self, app: &Rc<App>, id: Uuid) {
        let name = id.to_string();
        if self.stack.child_by_name(&name).is_some() {
            self.stack.set_visible_child_name(&name);
            if let Some(term) = app.terminal(id) {
                term.widget.grab_focus();
            }
        }
    }

    pub fn show_empty(&self) {
        self.stack.set_visible_child_name("empty");
    }

    pub fn set_panel_visible(&self, visible: bool) {
        self.panel.set_visible(visible);
        if !visible {
            return;
        }
        // Open at the Mac's ideal width (380), keeping 360 for the terminal.
        let paned = self.content_paned.clone();
        gtk::glib::idle_add_local_once(move || {
            let width = paned.width();
            if width > 0 && width - paned.position() < 300 {
                paned.set_position((width - 380).max(360));
            }
        });
    }
}

/// Signals that need the app: window activation, closing, panel state.
pub fn connect(app: &Rc<App>) {
    let weak = Rc::downgrade(app);
    app.ui.window.connect_is_active_notify(move |window| {
        let Some(app) = weak.upgrade() else { return };
        if window.is_active() {
            if let Some(id) = app.selected.get() {
                app.clear_attention(id);
            }
            crate::ui::panel::app_activated(&app);
        }
    });

    let weak = Rc::downgrade(app);
    app.ui.window.connect_close_request(move |window| {
        let Some(app) = weak.upgrade() else {
            return glib::Propagation::Proceed;
        };
        if confirm_quit(&app, window) {
            glib::Propagation::Stop
        } else {
            app.prepare_for_quit();
            glib::Propagation::Proceed
        }
    });

    crate::ui::sidebar::connect(app);
    crate::ui::header::connect(app);
    crate::ui::panel::build(app);
    let show = app.settings.borrow().show_files;
    app.ui.set_panel_visible(show);
    app.ui.window.present();
}

/// Asks before quitting while sessions run. Returns true if it asked (the
/// dialog then closes the window itself).
pub fn confirm_quit(app: &Rc<App>, window: &adw::ApplicationWindow) -> bool {
    let running = app.running_count();
    if !app.settings.borrow().confirm_quit || running == 0 {
        return false;
    }
    let text = if running == 1 {
        "1 session is running.".to_string()
    } else {
        format!("{running} sessions are running.")
    };
    let dialog = adw::AlertDialog::new(
        Some("Quit omux?"),
        Some(&format!(
            "{text} Agent conversation IDs are saved so you can continue them next launch."
        )),
    );
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("quit", "Quit");
    dialog.set_response_appearance("quit", adw::ResponseAppearance::Destructive);
    dialog.set_default_response(Some("quit"));
    dialog.set_close_response("cancel");
    let weak = Rc::downgrade(app);
    dialog.connect_response(None, move |_, response| {
        if response != "quit" {
            return;
        }
        if let Some(app) = weak.upgrade() {
            app.prepare_for_quit();
            app.gtk_app.quit();
        }
    });
    dialog.present(Some(window));
    true
}
