//! File previews for the Files tab. There is no Quick Look on Linux, so each
//! kind gets its own view (docs/ROADMAP.md, decision 7): Markdown rendered,
//! text in monospace, images, audio and video, PDF and SVG through WebKit,
//! and anything else offers the default app.

use std::path::Path;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};
use webkit6::prelude::*;

use crate::app::App;

const IMAGES: [&str; 8] = ["png", "jpg", "jpeg", "heic", "bmp", "tiff", "tif", "webp"];
const MEDIA: [&str; 9] = [
    "mp4", "mov", "m4v", "mp3", "m4a", "wav", "aac", "aiff", "ogg",
];
const WEB: [&str; 3] = ["pdf", "svg", "html"];
const TEXT: [&str; 35] = [
    "txt",
    "json",
    "swift",
    "py",
    "js",
    "ts",
    "tsx",
    "jsx",
    "html",
    "css",
    "yaml",
    "yml",
    "toml",
    "sh",
    "zsh",
    "log",
    "csv",
    "xml",
    "rs",
    "go",
    "c",
    "h",
    "cpp",
    "java",
    "kt",
    "rb",
    "sql",
    "env",
    "gitignore",
    "lock",
    "bash",
    "fish",
    "conf",
    "ini",
    "nix",
];
const MAX_TEXT: u64 = 1_000_000;

enum Kind {
    Markdown,
    Image,
    Media,
    Web,
    Text,
    Other,
}

fn kind(path: &Path) -> Kind {
    let ext = path
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    match ext.as_str() {
        "md" | "markdown" => Kind::Markdown,
        e if IMAGES.contains(&e) => Kind::Image,
        e if MEDIA.contains(&e) => Kind::Media,
        "pdf" | "svg" => Kind::Web,
        e if TEXT.contains(&e) || name.starts_with('.') || ext.is_empty() => Kind::Text,
        e if WEB.contains(&e) => Kind::Web,
        _ => Kind::Other,
    }
}

/// Reads a file as text if it's small, UTF-8 and has no NUL bytes.
fn read_text(path: &Path) -> Option<String> {
    let meta = path.metadata().ok()?;
    if meta.len() >= MAX_TEXT {
        return None;
    }
    let bytes = std::fs::read(path).ok()?;
    if bytes.iter().take(8000).any(|b| *b == 0) {
        return None;
    }
    String::from_utf8(bytes).ok()
}

pub fn view(app: &Rc<App>, path: &Path, wrap: bool) -> gtk::Widget {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 0);
    let kind = kind(path);
    // Markdown is rendered at any size, as on the Mac; text only under 1 MB.
    let text = match kind {
        Kind::Text => read_text(path),
        Kind::Markdown => std::fs::read(path)
            .ok()
            .and_then(|b| String::from_utf8(b).ok()),
        _ => None,
    };
    let textual = text.is_some();
    vbox.append(&header(app, path, textual));
    let body: gtk::Widget = match (kind, text) {
        (Kind::Markdown, Some(text)) => scroll(&crate::ui::markdown::render(&text, wrap), wrap),
        (Kind::Text, Some(text)) => scroll(&code_view(&text, wrap), wrap),
        (Kind::Image, _) => {
            let picture = gtk::Picture::for_filename(path);
            picture.set_content_fit(gtk::ContentFit::ScaleDown);
            picture.set_margin_start(12);
            picture.set_margin_end(12);
            picture.set_margin_top(12);
            picture.set_margin_bottom(12);
            picture.set_vexpand(true);
            picture.upcast()
        }
        (Kind::Media, _) => {
            let video = gtk::Video::for_filename(Some(path));
            video.set_vexpand(true);
            video.upcast()
        }
        (Kind::Web, _) => {
            let web = webkit6::WebView::new();
            web.set_vexpand(true);
            web.load_uri(&gio::File::for_path(path).uri());
            web.upcast()
        }
        _ => other(path),
    };
    body.set_vexpand(true);
    vbox.append(&body);
    vbox.upcast()
}

fn scroll(child: &impl IsA<gtk::Widget>, wrap: bool) -> gtk::Widget {
    gtk::ScrolledWindow::builder()
        .child(child)
        .hscrollbar_policy(if wrap {
            gtk::PolicyType::Never
        } else {
            gtk::PolicyType::Automatic
        })
        .vexpand(true)
        .build()
        .upcast()
}

fn code_view(text: &str, wrap: bool) -> gtk::TextView {
    let view = gtk::TextView::new();
    view.set_editable(false);
    view.set_monospace(true);
    view.set_wrap_mode(if wrap {
        gtk::WrapMode::WordChar
    } else {
        gtk::WrapMode::None
    });
    view.set_left_margin(12);
    view.set_right_margin(12);
    view.set_top_margin(10);
    view.set_bottom_margin(10);
    view.buffer().set_text(text);
    view.add_css_class("omux-preview-text");
    view
}

fn other(path: &Path) -> gtk::Widget {
    let page = adw::StatusPage::builder()
        .title("No preview")
        .description("Open it with the default app.")
        .icon_name("document-open-symbolic")
        .build();
    page.add_css_class("compact");
    let button = gtk::Button::with_label("Open");
    button.set_halign(gtk::Align::Center);
    button.add_css_class("pill");
    let uri = gio::File::for_path(path).uri();
    button.connect_clicked(move |_| {
        let _ = gio::AppInfo::launch_default_for_uri(&uri, gio::AppLaunchContext::NONE);
    });
    page.set_child(Some(&button));
    page.upcast()
}

fn header(app: &Rc<App>, path: &Path, textual: bool) -> gtk::Box {
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    header.set_margin_start(10);
    header.set_margin_end(6);
    header.set_margin_top(4);
    header.set_margin_bottom(4);
    let name = gtk::Label::new(Some(
        &path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default(),
    ));
    name.add_css_class("omux-header-name");
    name.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    name.set_xalign(0.0);
    name.set_hexpand(true);
    name.set_tooltip_text(Some(&path.display().to_string()));
    header.append(&name);
    if let Ok(meta) = path.metadata() {
        let size = gtk::Label::new(Some(&glib::format_size(meta.len())));
        size.add_css_class("omux-status");
        header.append(&size);
    }
    if textual {
        let wrap = app.settings.borrow().preview_wrap_lines;
        let toggle = gtk::ToggleButton::new();
        toggle.set_icon_name("format-justify-left-symbolic");
        toggle.set_active(wrap);
        toggle.add_css_class("flat");
        toggle.add_css_class("omux-small");
        toggle.set_tooltip_text(Some(if wrap {
            "Don't wrap lines"
        } else {
            "Wrap lines"
        }));
        let weak = Rc::downgrade(app);
        let path = path.to_path_buf();
        toggle.connect_toggled(move |t| {
            if let Some(app) = weak.upgrade() {
                let on = t.is_active();
                app.update_settings(|s| s.preview_wrap_lines = on);
                crate::ui::files::preview(&app, &path);
            }
        });
        header.append(&toggle);
    }
    let open = gtk::Button::from_icon_name("document-open-symbolic");
    open.set_tooltip_text(Some("Open with default app"));
    let uri = gio::File::for_path(path).uri();
    open.connect_clicked(move |_| {
        let _ = gio::AppInfo::launch_default_for_uri(&uri, gio::AppLaunchContext::NONE);
    });
    let reveal = gtk::Button::from_icon_name("folder-open-symbolic");
    reveal.set_tooltip_text(Some("Show in Files"));
    let target = path.to_path_buf();
    reveal.connect_clicked(move |_| crate::ui::files::show_in_files(&target));
    for b in [&open, &reveal] {
        b.add_css_class("flat");
        b.add_css_class("omux-small");
        header.append(b);
    }
    header
}
