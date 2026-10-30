//! Desktop notifications, sounds, and the attention count on the dock icon.

use std::collections::HashMap;
use std::process::{Command, Stdio};

use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use uuid::Uuid;

use crate::settings::Settings;

/// Sound choices: label and freedesktop sound-theme event id.
pub const SOUNDS: [(&str, &str); 7] = [
    ("Default", "message-new-instant"),
    ("Bell", "bell"),
    ("Complete", "complete"),
    ("Message", "message"),
    ("Warning", "dialog-warning"),
    ("Login", "service-login"),
    ("Camera", "camera-shutter"),
];

/// Posts or replaces the session's notification (one per session). Clicking
/// it reveals the session. "Sound only" plays the sound without a banner.
pub fn post(
    app: &adw::Application,
    settings: &Settings,
    id: Uuid,
    title: &str,
    subtitle: &str,
    body: &str,
) {
    let sound_only = settings.notify_style == "sound";
    let custom_sound = !settings.notify_sound.is_empty() && settings.notify_sound != "Default";
    if sound_only || custom_sound {
        play_sound(&settings.notify_sound);
    }
    if sound_only {
        return;
    }
    let notification = gio::Notification::new(title);
    let text = if body.is_empty() {
        subtitle.to_string()
    } else {
        format!("{subtitle} · {body}")
    };
    notification.set_body(Some(&text));
    notification
        .set_default_action_and_target_value("app.reveal", Some(&id.to_string().to_variant()));
    notification.set_priority(gio::NotificationPriority::High);
    app.send_notification(Some(&id.to_string()), &notification);
}

/// Plays a sound by label, through libcanberra when available, else straight
/// from the freedesktop sound theme with PipeWire or PulseAudio.
pub fn play_sound(label: &str) {
    let event = SOUNDS
        .iter()
        .find(|(name, _)| *name == label)
        .map_or(SOUNDS[0].1, |(_, event)| *event);
    let file = format!("/usr/share/sounds/freedesktop/stereo/{event}.oga");
    let attempts: [(&str, Vec<&str>); 3] = [
        ("canberra-gtk-play", vec!["-i", event]),
        ("pw-play", vec![file.as_str()]),
        ("paplay", vec![file.as_str()]),
    ];
    for (program, args) in attempts {
        let spawned = Command::new(program)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        if let Ok(mut child) = spawned {
            std::thread::spawn(move || child.wait());
            return;
        }
    }
}

/// Shows the number of sessions needing attention on the dock icon
/// (Ubuntu Dock, Dash to Dock and KDE read `com.canonical.Unity.LauncherEntry`).
pub fn launcher_count(app: &adw::Application, count: usize) {
    let Some(connection) = app.dbus_connection() else {
        return;
    };
    let mut props: HashMap<String, glib::Variant> = HashMap::new();
    props.insert("count".into(), (count as i64).to_variant());
    props.insert("count-visible".into(), (count > 0).to_variant());
    let params = (format!("application://{}.desktop", crate::APP_ID), props).to_variant();
    let _ = connection.emit_signal(
        None,
        "/net/pf1/omux/launcher",
        "com.canonical.Unity.LauncherEntry",
        "Update",
        Some(&params),
    );
}
