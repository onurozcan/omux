//! Terminal appearance and per-terminal input: theme colors, font, the
//! right-click menu, paste and drop.

use std::rc::Rc;

use gtk::prelude::*;
use gtk::{gdk, gio};
use uuid::Uuid;
use vte::prelude::*;

use crate::app::App;
use crate::settings::Settings;
use crate::term::SessionTerminal;
use crate::theme::{rgba, Theme};

pub fn configure(app: &Rc<App>, id: Uuid, terminal: &Rc<SessionTerminal>) {
    apply_appearance(&app.settings.borrow(), terminal);
    terminal.widget.add_css_class("omux-terminal-bg");

    let menu = gio::Menu::new();
    menu.append(Some("Copy"), Some("app.copy"));
    menu.append(Some("Paste"), Some("app.paste"));
    menu.append(Some("Select All"), Some("app.select-all"));
    let popover = gtk::PopoverMenu::from_model(Some(&menu));
    popover.set_has_arrow(false);
    terminal.add_popover(popover.upcast_ref());
    let click = gtk::GestureClick::new();
    click.set_button(3);
    click.connect_pressed(move |gesture, _, x, y| {
        gesture.set_state(gtk::EventSequenceState::Claimed);
        popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        popover.popup();
    });
    terminal.widget.add_controller(click);

    crate::ui::paste::install(app, id, terminal);
    crate::ui::links::install(app, id, terminal);
}

pub fn apply_appearance(settings: &Settings, terminal: &SessionTerminal) {
    let theme = Theme::named(&settings.theme);
    let palette: Vec<gdk::RGBA> = theme.palette.iter().map(|c| rgba(*c)).collect();
    let palette: Vec<&gdk::RGBA> = palette.iter().collect();
    let fg = rgba(theme.foreground);
    let bg = rgba(theme.background);
    terminal.widget.set_colors(Some(&fg), Some(&bg), &palette);
    terminal.widget.set_color_cursor(Some(&fg));
    terminal.widget.set_color_cursor_foreground(Some(&bg));
    terminal.widget.set_font(Some(&font(settings)));
}

pub fn font(settings: &Settings) -> gtk::pango::FontDescription {
    let family = if settings.font_family.is_empty() {
        "Monospace"
    } else {
        settings.font_family.as_str()
    };
    let mut font = gtk::pango::FontDescription::from_string(family);
    font.set_size((settings.terminal_font_size() * gtk::pango::SCALE as f64) as i32);
    font
}

/// Fixed-pitch font families installed on the system, for the font picker.
pub fn monospace_families(widget: &impl IsA<gtk::Widget>) -> Vec<String> {
    let mut names: Vec<String> = widget
        .pango_context()
        .list_families()
        .iter()
        .filter(|f| f.is_monospace())
        .map(|f| f.name().to_string())
        .collect();
    names.sort_by_key(|n| n.to_lowercase());
    names.dedup();
    names
}
