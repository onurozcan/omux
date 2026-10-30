//! App-wide CSS: theme chrome colors, status dots and small type.

use std::cell::RefCell;

use gtk::gdk;

use crate::settings::Settings;
use crate::theme::{css_hex, semantic, Theme};

thread_local! {
    static PROVIDER: RefCell<Option<gtk::CssProvider>> = const { RefCell::new(None) };
}

pub fn apply(settings: &Settings) {
    let theme = Theme::named(&settings.theme);
    let scheme = if theme.light {
        adw::ColorScheme::ForceLight
    } else {
        adw::ColorScheme::ForceDark
    };
    adw::StyleManager::default().set_color_scheme(scheme);

    let css = css(&theme);
    PROVIDER.with(|cell| {
        let mut cell = cell.borrow_mut();
        let provider = cell.get_or_insert_with(|| {
            let provider = gtk::CssProvider::new();
            if let Some(display) = gdk::Display::default() {
                gtk::style_context_add_provider_for_display(
                    &display,
                    &provider,
                    gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
                );
            }
            provider
        });
        provider.load_from_string(&css);
    });
}

/// The variant of a system color for this theme's brightness.
pub fn pick((dark, light): (u32, u32), theme: &Theme) -> u32 {
    if theme.light {
        light
    } else {
        dark
    }
}

fn css(theme: &Theme) -> String {
    let chrome = css_hex(theme.chrome);
    let bg = css_hex(theme.background);
    let fg = css_hex(theme.foreground);
    let c = |pair| css_hex(pick(pair, theme));
    format!(
        r#"
.omux-sidebar, .omux-sidebar list, headerbar.omux-chrome, .omux-panel-strip {{
  background-color: {chrome};
}}
headerbar.omux-chrome, .omux-chrome-bar {{ box-shadow: none; border-bottom: 1px solid alpha(currentColor, 0.08); min-height: 46px; }}
.omux-chrome-bar {{ background-color: {chrome}; }}
.omux-terminal-bg, .omux-panel {{ background-color: {bg}; color: {fg}; }}
.omux-sidebar list row {{ padding: 0; border-radius: 6px; margin: 0 6px; }}
.omux-sidebar list row:selected {{ background-color: alpha(currentColor, 0.12); color: inherit; }}
.omux-project {{ font-size: 0.85em; font-weight: 600; opacity: 0.55; }}
.omux-session-name {{ font-weight: 500; }}
.omux-status {{ font-size: 0.82em; opacity: 0.6; }}
.omux-stopped {{ opacity: 0.55; }}
.omux-header-name {{ font-weight: 600; font-size: 0.92em; }}
.omux-provider {{ font-size: 0.75em; opacity: 0.45; }}
.omux-usage {{ font-size: 0.8em; }}
.omux-hairline {{ background-color: alpha(currentColor, 0.08); min-height: 1px; min-width: 1px; }}
.omux-dot {{ min-width: 8px; min-height: 8px; border-radius: 999px; background-color: alpha(currentColor, 0.35); }}
.omux-dot.ring {{ background-color: transparent; border: 1.5px solid alpha(currentColor, 0.6); min-width: 5px; min-height: 5px; }}
.omux-dot.blue {{ background-color: {blue}; }} .omux-dot.ring.blue {{ background-color: transparent; border-color: {blue}; }}
.omux-dot.orange {{ background-color: {orange}; }} .omux-dot.ring.orange {{ background-color: transparent; border-color: {orange}; }}
.omux-dot.green {{ background-color: {green}; }} .omux-dot.ring.green {{ background-color: transparent; border-color: {green}; }}
.omux-dot.red {{ background-color: {red}; }}
.omux-dot.purple {{ background-color: {purple}; }}
.omux-dot.yellow {{ background-color: {yellow}; }}
.omux-dot.mint {{ background-color: {mint}; }}
.omux-dot.teal {{ background-color: {teal}; }}
.omux-dot.cyan {{ background-color: {cyan}; }}
.omux-dot.indigo {{ background-color: {indigo}; }}
.omux-dot.pink {{ background-color: {pink}; }}
.omux-dot.brown {{ background-color: {brown}; }}
.omux-dot.gray {{ background-color: {gray}; }}
.omux-bell {{ color: {orange}; }}
.omux-activity {{ min-width: 6px; min-height: 6px; border-radius: 999px; background-color: {blue}; }}
.omux-blue {{ color: {blue}; }} .omux-orange {{ color: {orange}; }} .omux-green {{ color: {green}; }}
.omux-red {{ color: {red}; }} .omux-purple {{ color: {purple}; }} .omux-yellow {{ color: {yellow}; }}
.omux-added {{ background-color: alpha({green}, 0.13); }}
.omux-removed {{ background-color: alpha({red}, 0.13); }}
.omux-hunk {{ background-color: alpha({blue}, 0.08); }}
button.omux-small {{ min-height: 22px; min-width: 22px; padding: 0 8px; font-size: 0.85em; }}
.omux-mono {{ font-family: monospace; }}
levelbar.omux-usage-bar trough {{ min-height: 3px; padding: 0; border-radius: 2px; background-color: alpha(currentColor, 0.12); }}
levelbar.omux-usage-bar block {{ min-height: 3px; border-radius: 2px; }}
levelbar.omux-usage-bar block.filled {{ background-color: {blue}; }}
levelbar.omux-usage-bar.orange block.filled {{ background-color: {orange}; }}
levelbar.omux-usage-bar.red block.filled {{ background-color: {red}; }}
levelbar.omux-usage-bar block.empty {{ background-color: transparent; }}
"#,
        blue = c(semantic::BLUE),
        orange = c(semantic::ORANGE),
        green = c(semantic::GREEN),
        red = c(semantic::RED),
        purple = c(semantic::PURPLE),
        yellow = c(semantic::YELLOW),
        mint = c(semantic::MINT),
        teal = c(semantic::TEAL),
        cyan = c(semantic::CYAN),
        indigo = c(semantic::INDIGO),
        pink = c(semantic::PINK),
        brown = c(semantic::BROWN),
        gray = c(semantic::GRAY),
    )
}
