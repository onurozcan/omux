//! The Browser tab: a web view per session that opens the local servers the
//! session prints, with an element picker that hands the element's HTML,
//! styles and a screenshot to the session's prompt.

use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;
use std::rc::{Rc, Weak};

use adw::prelude::*;
use gtk::{gdk, gio, glib};
use serde_json::Value;
use uuid::Uuid;
use vte::prelude::*;
use webkit6::prelude::*;

use crate::app::App;

/// The Mac's picker script (Browser.swift), unchanged.
const PICKER: &str = include_str!("picker.js");

struct Page {
    root: gtk::Box,
    web: webkit6::WebView,
    address: gtk::Entry,
    back: gtk::Button,
    forward: gtk::Button,
    reload: gtk::Button,
    pick: gtk::ToggleButton,
    banner: adw::Banner,
    notice: gtk::Revealer,
    notice_label: gtk::Label,
    empty: gtk::Box,
    content: gtk::Stack,
    loaded_once: bool,
}

struct Browser {
    app: Weak<App>,
    stack: gtk::Stack,
    pages: HashMap<Uuid, Rc<RefCell<Page>>>,
}

thread_local! {
    static BROWSER: RefCell<Option<Browser>> = const { RefCell::new(None) };
}

pub fn build(app: &Rc<App>) -> gtk::Widget {
    let stack = gtk::Stack::new();
    let none = adw::StatusPage::builder()
        .title("No session")
        .icon_name("web-browser-symbolic")
        .build();
    stack.add_named(&none, Some("none"));
    BROWSER.with(|b| {
        *b.borrow_mut() = Some(Browser {
            app: Rc::downgrade(app),
            stack: stack.clone(),
            pages: HashMap::new(),
        })
    });
    // A server the session prints after the tab opened still opens by itself.
    let weak = Rc::downgrade(app);
    glib::timeout_add_local(std::time::Duration::from_secs(4), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        selection_changed(&app);
        glib::ControlFlow::Continue
    });
    stack.upcast()
}

fn app() -> Option<Rc<App>> {
    BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.app.upgrade()))
}

pub fn selection_changed(app: &Rc<App>) {
    if !crate::ui::panel::is_showing(app, "browser") {
        return;
    }
    let Some(id) = app.selected.get() else { return };
    let page = page(id);
    BROWSER.with(|b| {
        if let Some(b) = b.borrow().as_ref() {
            b.stack.set_visible_child_name(&id.to_string());
        }
    });
    let urls = mentioned_urls(app, id);
    let mut page = page.borrow_mut();
    // First time shown with nothing loaded: open the newest local server.
    if !page.loaded_once && page.address.text().is_empty() {
        if let Some(url) = urls.last() {
            page.loaded_once = true;
            let url = url.clone();
            drop(page);
            load(id, &url);
            return;
        }
    }
    if !page.loaded_once {
        fill_empty(&page, id, &urls);
    }
}

pub fn session_closed(_app: &Rc<App>, id: Uuid) {
    BROWSER.with(|b| {
        if let Some(b) = b.borrow_mut().as_mut() {
            if let Some(page) = b.pages.remove(&id) {
                b.stack.remove(&page.borrow().root);
            }
        }
    });
}

fn mentioned_urls(app: &App, id: Uuid) -> Vec<String> {
    let Some(term) = app.terminal(id) else {
        return Vec::new();
    };
    let Some(adjustment) = term.widget.vadjustment() else {
        return Vec::new();
    };
    let (text, _) = term.widget.text_range_format(
        vte::Format::Text,
        adjustment.lower() as i64,
        0,
        adjustment.upper() as i64,
        term.widget.column_count(),
    );
    text.map(|t| crate::mentions::local_urls(&t))
        .unwrap_or_default()
}

fn fill_empty(page: &Page, id: Uuid, urls: &[String]) {
    while let Some(child) = page.empty.first_child() {
        page.empty.remove(&child);
    }
    if urls.is_empty() {
        let hint = gtk::Label::new(Some(
            "Type an address above. Local servers this session prints, like localhost:3000, open here by themselves.",
        ));
        hint.set_wrap(true);
        hint.set_justify(gtk::Justification::Center);
        hint.add_css_class("dim-label");
        page.empty.append(&hint);
        return;
    }
    for url in urls.iter().rev().take(5) {
        let link = gtk::LinkButton::with_label(url, url);
        let url = url.clone();
        link.connect_activate_link(move |_| {
            load(id, &url);
            glib::Propagation::Stop
        });
        page.empty.append(&link);
    }
}

fn page(id: Uuid) -> Rc<RefCell<Page>> {
    if let Some(page) =
        BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
    {
        return page;
    }
    let page = Rc::new(RefCell::new(build_page(id)));
    BROWSER.with(|b| {
        if let Some(b) = b.borrow_mut().as_mut() {
            b.stack
                .add_named(&page.borrow().root, Some(&id.to_string()));
            b.pages.insert(id, page.clone());
        }
    });
    page
}

fn icon_button(icon: &str, tip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("omux-small");
    button.set_tooltip_text(Some(tip));
    button
}

fn build_page(id: Uuid) -> Page {
    let manager = webkit6::UserContentManager::new();
    manager.register_script_message_handler("omuxPick", None);
    let web = webkit6::WebView::builder()
        .user_content_manager(&manager)
        .build();
    if let Some(settings) = webkit6::prelude::WebViewExt::settings(&web) {
        settings.set_enable_developer_extras(true);
    }
    web.set_vexpand(true);

    let toolbar = gtk::Box::new(gtk::Orientation::Horizontal, 2);
    toolbar.set_margin_start(4);
    toolbar.set_margin_end(4);
    toolbar.set_margin_top(3);
    toolbar.set_margin_bottom(3);
    let back = icon_button("go-previous-symbolic", "Back");
    let forward = icon_button("go-next-symbolic", "Forward");
    let reload = icon_button("view-refresh-symbolic", "Reload");
    let address = gtk::Entry::new();
    address.set_placeholder_text(Some("localhost:3000"));
    address.set_hexpand(true);
    let pick = gtk::ToggleButton::new();
    pick.set_icon_name("find-location-symbolic");
    pick.add_css_class("flat");
    pick.add_css_class("omux-small");
    pick.set_tooltip_text(Some("Pick an element for the session's prompt"));
    pick.set_sensitive(false);
    let external = icon_button("web-browser-symbolic", "Open in default browser");
    for w in [
        back.upcast_ref::<gtk::Widget>(),
        forward.upcast_ref(),
        reload.upcast_ref(),
        address.upcast_ref(),
        pick.upcast_ref(),
        external.upcast_ref(),
    ] {
        toolbar.append(w);
    }

    let banner = adw::Banner::new("");
    let notice_label = gtk::Label::new(None);
    notice_label.add_css_class("omux-status");
    notice_label.set_margin_top(4);
    notice_label.set_margin_bottom(4);
    let notice = gtk::Revealer::new();
    notice.set_child(Some(&notice_label));

    let empty = gtk::Box::new(gtk::Orientation::Vertical, 6);
    empty.set_valign(gtk::Align::Center);
    empty.set_halign(gtk::Align::Center);
    empty.set_margin_start(24);
    empty.set_margin_end(24);
    let content = gtk::Stack::new();
    content.add_named(&empty, Some("empty"));
    content.add_named(&web, Some("web"));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.append(&toolbar);
    root.append(&banner);
    root.append(&notice);
    root.append(&content);

    address.connect_activate(move |entry| load(id, &entry.text()));
    let w = web.clone();
    back.connect_clicked(move |_| w.go_back());
    let w = web.clone();
    forward.connect_clicked(move |_| w.go_forward());
    let w = web.clone();
    reload.connect_clicked(move |_| {
        if w.is_loading() {
            w.stop_loading();
        } else {
            w.reload();
        }
    });
    let w = web.clone();
    external.connect_clicked(move |_| {
        if let (Some(uri), Some(app)) = (w.uri(), app()) {
            app.open_uri(&uri);
        }
    });
    let w = web.clone();
    pick.connect_toggled(move |button| {
        if button.is_active() {
            w.evaluate_javascript(PICKER, None, None, gio::Cancellable::NONE, |_| {});
            show_notice(
                id,
                "Click an element to add it to the session prompt. Esc cancels.",
            );
        } else {
            hide_notice(id);
            w.evaluate_javascript(
                "window.__omuxPick && window.__omuxPick.stop()",
                None,
                None,
                gio::Cancellable::NONE,
                |_| {},
            );
        }
    });
    // Single-page apps change the address without a load (pushState).
    web.connect_uri_notify(move |web| {
        let Some(page) =
            BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
        else {
            return;
        };
        let page = page.borrow();
        if let Some(uri) = web.uri() {
            if !page.address.has_focus() {
                page.address.set_text(&uri);
            }
        }
        page.back.set_sensitive(web.can_go_back());
        page.forward.set_sensitive(web.can_go_forward());
    });
    let notice_click = gtk::GestureClick::new();
    notice_click.connect_released(move |_, _, _, _| hide_notice(id));
    notice.add_controller(notice_click);
    web.connect_load_changed(move |web, event| {
        let Some(page) =
            BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
        else {
            return;
        };
        let page = page.borrow();
        if event == webkit6::LoadEvent::Started {
            page.banner.set_revealed(false);
            page.pick.set_active(false);
        }
        if let Some(uri) = web.uri() {
            if !page.address.has_focus() {
                page.address.set_text(&uri);
            }
        }
        page.back.set_sensitive(web.can_go_back());
        page.forward.set_sensitive(web.can_go_forward());
        page.reload.set_icon_name(if web.is_loading() {
            "process-stop-symbolic"
        } else {
            "view-refresh-symbolic"
        });
        page.pick
            .set_sensitive(event == webkit6::LoadEvent::Finished || web.uri().is_some());
    });
    web.connect_load_failed(move |_, _, _, error| {
        if error.matches(webkit6::NetworkError::Cancelled) {
            return false;
        }
        if let Some(page) =
            BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
        {
            let page = page.borrow();
            page.banner
                .set_title(&format!("Couldn't load the page: {}", error.message()));
            page.banner.set_button_label(Some("Try Again"));
            page.banner.set_revealed(true);
        }
        false
    });
    let w = web.clone();
    banner.connect_button_clicked(move |b| {
        b.set_revealed(false);
        w.reload();
    });
    manager.connect_script_message_received(Some("omuxPick"), move |_, value| {
        let json = value.to_json(0).map(|s| s.to_string()).unwrap_or_default();
        received(id, &json);
    });

    Page {
        root,
        web,
        address,
        back,
        forward,
        reload,
        pick,
        banner,
        notice,
        notice_label,
        empty,
        content,
        loaded_once: false,
    }
}

/// Loads an address; `http://` is assumed when no scheme is given.
pub fn load(id: Uuid, text: &str) {
    let page = page(id);
    let page = page.borrow_mut();
    let text = text.trim();
    if text.is_empty() {
        return;
    }
    let uri = if text.contains("://") {
        text.to_string()
    } else {
        format!("http://{text}")
    };
    if glib::Uri::parse(&uri, glib::UriFlags::NONE).is_err() {
        page.banner.set_title("That isn't a valid address.");
        page.banner.set_button_label(None);
        page.banner.set_revealed(true);
        return;
    }
    page.address.set_text(&uri);
    page.content.set_visible_child_name("web");
    page.web.load_uri(&uri);
}

fn hide_notice(id: Uuid) {
    if let Some(page) =
        BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
    {
        page.borrow().notice.set_reveal_child(false);
    }
}

fn show_notice(id: Uuid, text: &str) {
    if let Some(page) =
        BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
    {
        let page = page.borrow();
        // Stays until clicked away or replaced, as on the Mac.
        page.notice_label.set_text(text);
        page.notice.set_reveal_child(true);
    }
}

/// A pick from the page: writes `element.html` (and `element.png`) to a new
/// folder and pastes a sentence pointing at them into the prompt.
fn received(id: Uuid, json: &str) {
    let Some(page) = BROWSER.with(|b| b.borrow().as_ref().and_then(|b| b.pages.get(&id).cloned()))
    else {
        return;
    };
    page.borrow().pick.set_active(false);
    let Ok(pick) = serde_json::from_str::<Value>(json) else {
        return;
    };
    if pick.get("cancel").and_then(Value::as_bool) == Some(true) {
        return;
    }
    let get = |k: &str| {
        pick.get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string()
    };
    let num = |k: &str| pick.get(k).and_then(Value::as_f64).unwrap_or(0.0);
    let (selector, html, css, url) = (get("selector"), get("html"), get("css"), get("url"));
    let millis = glib::real_time() / 1000;
    let Some(picks) = crate::persistence::private_temp_dir("omux-picks") else {
        return;
    };
    let dir: PathBuf = picks.join(millis.to_string());
    if std::fs::create_dir_all(&dir).is_err() {
        return;
    }
    let file = dir.join("element.html");
    let contents = format!(
        "<!-- Picked in omux from {url} -->\n<!-- Selector: {selector} -->\n<!-- Computed styles:\n{css}\n-->\n{html}\n"
    );
    if std::fs::write(&file, contents).is_err() {
        return;
    }
    let rect = (num("x"), num("y"), num("width"), num("height"));
    let web = page.borrow().web.clone();
    let shot = dir.join("element.png");
    let send = move |screenshot: Option<PathBuf>| {
        let Some(app) = app() else { return };
        let mut text = format!(
            "The {selector} element on {url}: HTML and computed styles in {}",
            file.display()
        );
        if let Some(shot) = screenshot {
            text.push_str(&format!(", screenshot at {}", shot.display()));
        }
        text.push_str(". ");
        app.send_text(id, &text, false);
        show_notice(id, &format!("Added {selector} to the prompt"));
    };
    if rect.2 < 1.0 || rect.3 < 1.0 {
        send(None);
        return;
    }
    let widget_width = web.width().max(1) as f64;
    web.snapshot(
        webkit6::SnapshotRegion::Visible,
        webkit6::SnapshotOptions::NONE,
        gio::Cancellable::NONE,
        move |result| {
            let saved = result
                .ok()
                .and_then(|texture| crop(&texture, rect, widget_width, &shot));
            send(saved);
        },
    );
}

/// Crops the element out of the view snapshot (in device pixels).
fn crop(
    texture: &gdk::Texture,
    (x, y, w, h): (f64, f64, f64, f64),
    widget_width: f64,
    out: &std::path::Path,
) -> Option<PathBuf> {
    let scale = texture.width() as f64 / widget_width;
    let (tw, th) = (texture.width() as f64, texture.height() as f64);
    let left = (x * scale).clamp(0.0, tw);
    let top = (y * scale).clamp(0.0, th);
    let right = ((x + w) * scale).clamp(0.0, tw);
    let bottom = ((y + h) * scale).clamp(0.0, th);
    let (cw, ch) = ((right - left) as usize, (bottom - top) as usize);
    if cw < 1 || ch < 1 {
        return None;
    }
    let stride = texture.width() as usize * 4;
    let mut pixels = vec![0u8; stride * texture.height() as usize];
    texture.download(&mut pixels, stride);
    let mut cropped = Vec::with_capacity(cw * ch * 4);
    for row in top as usize..top as usize + ch {
        let start = row * stride + left as usize * 4;
        cropped.extend_from_slice(&pixels[start..start + cw * 4]);
    }
    let bytes = glib::Bytes::from_owned(cropped);
    let image = gdk::MemoryTexture::new(
        cw as i32,
        ch as i32,
        gdk::MemoryFormat::B8g8r8a8Premultiplied,
        &bytes,
        cw * 4,
    );
    image.save_to_png(out).ok()?;
    Some(out.to_path_buf())
}
