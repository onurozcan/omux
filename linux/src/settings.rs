//! User preferences, stored as `settings.json` next to the workspace. Key
//! names and defaults are the Mac app's `UserDefaults` keys (`Prefs`).

use std::fs;

use serde::{Deserialize, Serialize};

use crate::persistence::{config_dir, write_atomic};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub confirm_quit: bool,
    pub show_folder_path: bool,
    /// Seconds between Claude usage checks: 60, 300, 1800 or 3600.
    pub usage_interval: f64,
    pub theme: String,
    pub auto_resume: bool,
    pub show_files: bool,
    pub files_by_date: bool,
    pub files_browser_collapsed: bool,
    pub preview_wrap_lines: bool,
    /// `files`, `changes` or `browser`.
    pub panel_tab: String,
    /// Empty means the system monospace font.
    pub font_family: String,
    pub font_size: f64,
    pub notify_needs_you: bool,
    pub notify_done: bool,
    pub notify_programs: bool,
    /// `banner` or `sound` (sound only).
    pub notify_style: String,
    pub notify_sound: String,
    pub welcomed: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            confirm_quit: true,
            show_folder_path: true,
            usage_interval: 300.0,
            theme: "dark".into(),
            auto_resume: false,
            show_files: false,
            files_by_date: false,
            files_browser_collapsed: false,
            preview_wrap_lines: true,
            panel_tab: "files".into(),
            font_family: String::new(),
            font_size: 13.0,
            notify_needs_you: true,
            notify_done: false,
            notify_programs: true,
            notify_style: "banner".into(),
            notify_sound: "Default".into(),
            welcomed: false,
        }
    }
}

impl Settings {
    /// Reads each key on its own, like UserDefaults: one value of the wrong
    /// type falls back to its default instead of resetting every setting.
    pub fn load() -> Self {
        fs::read(config_dir().join("settings.json"))
            .ok()
            .and_then(|data| serde_json::from_slice::<serde_json::Value>(&data).ok())
            .map(|value| Self::from_value(&value))
            .unwrap_or_default()
    }

    fn from_value(value: &serde_json::Value) -> Self {
        let Ok(serde_json::Value::Object(mut merged)) = serde_json::to_value(Self::default())
        else {
            return Self::default();
        };
        if let serde_json::Value::Object(stored) = value {
            for (key, item) in stored {
                let same_kind = merged.get(key).is_some_and(|default| {
                    std::mem::discriminant(default) == std::mem::discriminant(item)
                });
                if same_kind {
                    merged.insert(key.clone(), item.clone());
                }
            }
        }
        serde_json::from_value(serde_json::Value::Object(merged)).unwrap_or_default()
    }

    pub fn save(&self) {
        if let Ok(text) = serde_json::to_string_pretty(self) {
            let _ = write_atomic(&config_dir().join("settings.json"), text.as_bytes());
        }
    }

    /// A stored size of zero or less means the default, as on the Mac.
    pub fn terminal_font_size(&self) -> f64 {
        if self.font_size > 0.0 {
            self.font_size
        } else {
            13.0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_keys_take_mac_defaults() {
        let s: Settings = serde_json::from_str(r#"{"theme":"nord"}"#).unwrap();
        assert_eq!(s.theme, "nord");
        assert!(s.confirm_quit);
        assert!(s.notify_needs_you);
        assert!(!s.notify_done);
        assert_eq!(s.usage_interval, 300.0);
    }

    #[test]
    fn one_bad_value_keeps_the_others() {
        let s = Settings::from_value(
            &serde_json::json!({"theme": "nord", "fontSize": "big", "confirmQuit": false}),
        );
        assert_eq!(s.theme, "nord");
        assert_eq!(s.font_size, 13.0);
        assert!(!s.confirm_quit);
    }

    #[test]
    fn keys_use_mac_names() {
        let text = serde_json::to_string(&Settings::default()).unwrap();
        for key in [
            "confirmQuit",
            "showFolderPath",
            "usageInterval",
            "notifyNeedsYou",
            "previewWrapLines",
        ] {
            assert!(text.contains(key), "{key}");
        }
    }
}
