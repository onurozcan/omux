//! The selected session's header: status dot, name, agent, status line,
//! permission buttons, then folder or branch, start/stop and the panel toggle.

use std::rc::Rc;

use adw::prelude::*;

use super::sidebar::{dot, dot_color, set_dot};
use crate::app::App;
use crate::model::SessionProvider;
use crate::persistence::abbreviate_home;

pub struct Header {
    /// A custom bar (not AdwHeaderBar, which centers its title) so the
    /// session's name and status sit at the left, as on the Mac.
    pub bar: gtk::WindowHandle,
    dot: gtk::Box,
    name: gtk::Label,
    provider: gtk::Label,
    status: gtk::Label,
    permission: gtk::Box,
    info: gtk::MenuButton,
    /// Agents pill, PR chip and branch chip; filled by later layers.
    pub extras: gtk::Box,
    cwd: gtk::Label,
    start_stop: gtk::Button,
    pub panel_toggle: gtk::ToggleButton,
}

impl Header {
    pub fn build() -> Self {
        let bar = gtk::WindowHandle::new();
        bar.add_css_class("omux-chrome-bar");
        let outer = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        outer.set_margin_start(12);
        outer.set_margin_end(6);
        bar.set_child(Some(&outer));

        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.set_hexpand(true);
        let dot = dot();
        row.append(&dot);
        let name = gtk::Label::new(None);
        name.add_css_class("omux-header-name");
        name.set_ellipsize(gtk::pango::EllipsizeMode::End);
        row.append(&name);
        let provider = gtk::Label::new(None);
        provider.add_css_class("omux-provider");
        row.append(&provider);
        let status = gtk::Label::new(None);
        status.add_css_class("omux-status");
        status.set_ellipsize(gtk::pango::EllipsizeMode::End);
        status.set_xalign(0.0);
        row.append(&status);

        let permission = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        for (label, action) in [("Allow", "app.allow"), ("Deny", "app.deny")] {
            let button = gtk::Button::with_label(label);
            button.add_css_class("omux-small");
            if action == "app.allow" {
                button.add_css_class("suggested-action");
            }
            button.set_action_name(Some(action));
            permission.append(&button);
        }
        let info = gtk::MenuButton::builder()
            .icon_name("dialog-information-symbolic")
            .tooltip_text("What Codex asks for")
            .build();
        info.add_css_class("flat");
        permission.append(&info);
        row.append(&permission);

        let spacer = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        spacer.set_hexpand(true);
        row.append(&spacer);

        let extras = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        row.append(&extras);
        let cwd = gtk::Label::new(None);
        cwd.add_css_class("omux-status");
        cwd.set_ellipsize(gtk::pango::EllipsizeMode::Start);
        cwd.set_max_width_chars(40);
        row.append(&cwd);

        outer.append(&row);

        let panel_toggle = gtk::ToggleButton::builder()
            .icon_name("sidebar-show-right-symbolic")
            .tooltip_text("Files panel (F9)")
            .action_name("app.toggle-panel")
            .build();
        panel_toggle.add_css_class("flat");
        let start_stop = gtk::Button::from_icon_name("media-playback-start-symbolic");
        start_stop.set_action_name(Some("app.start-or-stop"));
        start_stop.add_css_class("flat");
        for widget in [
            start_stop.upcast_ref::<gtk::Widget>(),
            panel_toggle.upcast_ref(),
        ] {
            widget.set_valign(gtk::Align::Center);
            outer.append(widget);
        }
        let controls = gtk::WindowControls::new(gtk::PackType::End);
        outer.append(&controls);

        Self {
            bar,
            dot,
            name,
            provider,
            status,
            permission,
            info,
            extras,
            cwd,
            start_stop,
            panel_toggle,
        }
    }

    pub fn update(&self, app: &Rc<App>) {
        let Some(id) = app.selected.get().filter(|id| app.find(*id).is_some()) else {
            self.name.set_text("");
            self.provider.set_text("");
            self.status.set_text("");
            self.cwd.set_text("");
            self.dot.set_visible(false);
            self.permission.set_visible(false);
            self.start_stop.set_visible(false);
            return;
        };
        let (group, tab) = app.tab(id).expect("selected session exists");
        self.dot.set_visible(true);
        self.name.set_text(&tab.name);
        self.provider.set_text(match tab.resolved_provider(&group) {
            SessionProvider::Claude => "Claude Code",
            SessionProvider::Codex => "Codex",
            _ => "",
        });
        self.update_status(app);
    }

    pub fn update_status(&self, app: &App) {
        let Some(id) = app.selected.get() else { return };
        let Some((group, tab)) = app.tab(id) else {
            return;
        };
        let rt = app.rt(id);
        set_dot(&self.dot, dot_color(&rt, &tab));
        let line = rt.status_line(false);
        self.status.set_text(&line);
        self.status.set_tooltip_text(Some(&line));
        let codex_detail = crate::codex::pending_approval(app, id);
        self.permission
            .set_visible(rt.awaits_permission() || codex_detail.is_some());
        self.info.set_visible(codex_detail.is_some());
        if let Some(detail) = codex_detail {
            let label = gtk::Label::new(Some(&detail));
            label.add_css_class("omux-mono");
            label.set_selectable(true);
            label.set_wrap(true);
            let scroller = gtk::ScrolledWindow::builder()
                .child(&label)
                .min_content_width(420)
                .min_content_height(120)
                .build();
            let popover = gtk::Popover::new();
            popover.set_child(Some(&scroller));
            self.info.set_popover(Some(&popover));
        }
        if tab.worktree.is_none() {
            let dir = rt
                .cwd
                .clone()
                .unwrap_or_else(|| app.directory(&group, &tab).display().to_string());
            self.cwd
                .set_text(&abbreviate_home(std::path::Path::new(&dir)));
            self.cwd.set_visible(true);
        } else {
            self.cwd.set_visible(false);
        }
        self.start_stop.set_visible(rt.busy || !rt.agent_connected);
        if rt.busy {
            self.start_stop
                .set_icon_name("media-playback-stop-symbolic");
            self.start_stop.set_tooltip_text(Some("Interrupt (Ctrl-C)"));
        } else {
            self.start_stop
                .set_icon_name("media-playback-start-symbolic");
            self.start_stop
                .set_tooltip_text(Some("Start or continue this session (Ctrl+Shift+Enter)"));
        }
        crate::ui::agents::update_header(app, id, &self.extras);
    }
}

pub fn connect(app: &Rc<App>) {
    let active = app.settings.borrow().show_files;
    app.ui.header.panel_toggle.set_active(active);
}
