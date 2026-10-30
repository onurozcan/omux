//! Ctrl+click on a path or URL in the terminal: a file that exists opens in
//! the Files panel, anything else goes to the default app.

use std::path::PathBuf;
use std::rc::Rc;

use gtk::gdk;
use gtk::prelude::*;
use uuid::Uuid;
use vte::prelude::*;

use crate::app::App;
use crate::persistence::expand_tilde;
use crate::term::SessionTerminal;

// PCRE2 compile flags VTE needs: UTF, Unicode properties (so `\w` matches
// letters such as "ü", like NSRegularExpression), multiline.
const PCRE2_UTF: u32 = 0x0008_0000;
const PCRE2_UCP: u32 = 0x0002_0000;
const PCRE2_MULTILINE: u32 = 0x0000_0400;

pub const URL_PATTERN: &str = r#"(?:https?|file)://[^\s'"<>()\[\]]+"#;
/// The Mac's path pattern (TermView.swift:213).
pub const PATH_PATTERN: &str = r"(?<![\w])(?:~|/)[\w.+@%~/-]+";

pub fn install(app: &Rc<App>, _id: Uuid, terminal: &Rc<SessionTerminal>) {
    for pattern in [URL_PATTERN, PATH_PATTERN] {
        if let Ok(regex) = vte::Regex::for_match(pattern, PCRE2_UTF | PCRE2_UCP | PCRE2_MULTILINE) {
            let tag = terminal.widget.match_add_regex(&regex, 0);
            terminal.widget.match_set_cursor_name(tag, "pointer");
        }
    }
    let click = gtk::GestureClick::new();
    click.set_button(1);
    let weak_app = Rc::downgrade(app);
    let weak_term = Rc::downgrade(terminal);
    click.connect_pressed(move |gesture, _, x, y| {
        let ctrl = gesture
            .current_event_state()
            .contains(gdk::ModifierType::CONTROL_MASK);
        if !ctrl {
            return;
        }
        let (Some(app), Some(term)) = (weak_app.upgrade(), weak_term.upgrade()) else {
            return;
        };
        let link = term
            .widget
            .check_hyperlink_at(x, y)
            .map(|s| s.to_string())
            .or_else(|| term.widget.check_match_at(x, y).0.map(|s| s.to_string()));
        let Some(link) = link else { return };
        gesture.set_state(gtk::EventSequenceState::Claimed);
        match file_path_from(&link) {
            Some(path) => crate::ui::panel::preview_file(&app, &path),
            // Trailing sentence punctuation isn't part of a URL, as on the Mac.
            None if link.contains(':') => app.open_uri(link.trim_end_matches(['.', ',', ':', ';'])),
            None => {}
        }
    });
    terminal.widget.add_controller(click);
}

/// A mention that names an existing regular file, cleaned of trailing
/// punctuation (`filePath(from:)` on the Mac).
pub fn file_path_from(text: &str) -> Option<PathBuf> {
    let mut text = text.trim().to_string();
    if let Some(rest) = text.strip_prefix("file://") {
        text = gtk::glib::Uri::unescape_string(rest, None::<&str>)
            .map(|s| s.to_string())
            .unwrap_or_else(|| rest.to_string());
        // file://host/path: drop the host part.
        if !text.starts_with('/') {
            text = text.find('/').map(|i| text[i..].to_string())?;
        }
    }
    if !text.starts_with('/') && !text.starts_with('~') {
        return None;
    }
    while let Some(last) = text.chars().last() {
        if ".,:;)]}'\"".contains(last) {
            text.pop();
        } else {
            break;
        }
    }
    let path = expand_tilde(&text);
    path.is_file().then_some(path)
}
