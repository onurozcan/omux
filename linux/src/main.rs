mod actions;
mod app;
mod claude;
mod codex;
mod codex_client;
mod git;
mod mentions;
mod model;
mod notify;
mod persistence;
mod pulls;
mod runtime;
mod session_env;
mod settings;
mod swift_json;
mod term;
mod theme;
mod ui;
mod usage;

use std::cell::RefCell;
use std::rc::Rc;

use adw::prelude::*;
use gtk::{gio, glib};

pub const APP_ID: &str = "net.pf1.omux";

fn main() -> glib::ExitCode {
    let gtk_app = adw::Application::builder()
        .application_id(APP_ID)
        .flags(gio::ApplicationFlags::HANDLES_OPEN)
        .build();
    // One instance: launching again (or `omux <folder>`) reaches this one.
    let state: Rc<RefCell<Option<Rc<app::App>>>> = Rc::new(RefCell::new(None));

    let s = state.clone();
    gtk_app.connect_activate(move |gtk_app| {
        let app = s
            .borrow_mut()
            .get_or_insert_with(|| app::App::new(gtk_app))
            .clone();
        app.ui.window.present();
    });
    let s = state.clone();
    gtk_app.connect_open(move |gtk_app, files, _| {
        let app = s
            .borrow_mut()
            .get_or_insert_with(|| app::App::new(gtk_app))
            .clone();
        app.ui.window.present();
        for file in files {
            if let Some(path) = file.path().filter(|p| p.is_dir()) {
                app.open_folder(&path);
            }
        }
    });
    gtk_app.run()
}
