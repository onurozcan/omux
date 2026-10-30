//! Where omux keeps its files, and how the workspace is loaded and saved.
//!
//! Save writes the previous distinct version to `workspace.json.bak` first, so
//! the backup is always one real change behind. Load falls back to the backup
//! when the main file is missing, unreadable or has no projects.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use crate::model::Workspace;
use crate::swift_json;

const WORKSPACE: &str = "workspace.json";
const BACKUP: &str = "workspace.json.bak";

/// `$OMUX_WORKSPACE_DIRECTORY` (for tests), else `$XDG_CONFIG_HOME/omux`.
pub fn config_dir() -> PathBuf {
    let dir = match std::env::var("OMUX_WORKSPACE_DIRECTORY") {
        Ok(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => xdg_config_home().join("omux"),
    };
    let _ = fs::create_dir_all(&dir);
    dir
}

fn xdg_config_home() -> PathBuf {
    match std::env::var("XDG_CONFIG_HOME") {
        Ok(dir) if Path::new(&dir).is_absolute() => PathBuf::from(dir),
        _ => home_dir().join(".config"),
    }
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn load_workspace() -> Option<Workspace> {
    load_workspace_from(&config_dir())
}

pub fn load_workspace_from(dir: &Path) -> Option<Workspace> {
    [WORKSPACE, BACKUP].iter().find_map(|name| {
        let data = fs::read(dir.join(name)).ok()?;
        let workspace: Workspace = serde_json::from_slice(&data).ok()?;
        (!workspace.groups.is_empty()).then_some(workspace)
    })
}

pub fn save_workspace(workspace: &Workspace) {
    save_workspace_to(&config_dir(), workspace);
}

/// Errors are ignored, as on the Mac: a failed save is retried with the next change.
pub fn save_workspace_to(dir: &Path, workspace: &Workspace) {
    let Ok(text) = swift_json::to_string(workspace) else {
        return;
    };
    let path = dir.join(WORKSPACE);
    if let Ok(old) = fs::read(&path) {
        if old == text.as_bytes() {
            return;
        }
        let _ = write_atomic(&dir.join(BACKUP), &old);
    }
    let _ = write_atomic(&path, text.as_bytes());
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    {
        let mut file = fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&tmp, path)
}

/// A per-user scratch folder (`$XDG_RUNTIME_DIR/omux`, else
/// `<tmp>/omux-<uid>`), mode 0700, for pasted images and browser picks:
/// a shared `/tmp/omux-paste` could be pre-created by another user.
pub fn private_temp_dir(name: &str) -> Option<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    let base = match std::env::var_os("XDG_RUNTIME_DIR") {
        Some(dir) if Path::new(&dir).is_dir() => PathBuf::from(dir).join("omux"),
        _ => std::env::temp_dir().join(format!("omux-{}", unsafe { libc::getuid() })),
    };
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&base)
        .ok()?;
    let meta = fs::symlink_metadata(&base).ok()?;
    let mine = std::os::unix::fs::MetadataExt::uid(&meta) == unsafe { libc::getuid() };
    if !meta.is_dir() || !mine {
        return None;
    }
    let _ = fs::set_permissions(&base, fs::Permissions::from_mode(0o700));
    let dir = base.join(name);
    fs::create_dir_all(&dir).ok()?;
    Some(dir)
}

/// Replaces a leading `~` with the home folder.
pub fn expand_tilde(path: &str) -> PathBuf {
    if path == "~" {
        home_dir()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home_dir().join(rest)
    } else {
        PathBuf::from(path)
    }
}

/// Shows the home folder as `~`.
pub fn abbreviate_home(path: &Path) -> String {
    let home = home_dir();
    match path.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{TabGroup, TabItem};

    fn temp_dir(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("omux-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn workspace(name: &str) -> Workspace {
        Workspace {
            groups: vec![TabGroup::new(name, None, vec![TabItem::new("Session 1")])],
            selected_tab_id: None,
        }
    }

    #[test]
    fn save_keeps_previous_distinct_version_as_backup() {
        let dir = temp_dir("bak");
        save_workspace_to(&dir, &workspace("One"));
        assert!(!dir.join(BACKUP).exists());
        let first = fs::read(dir.join(WORKSPACE)).unwrap();
        save_workspace_to(&dir, &workspace("Two"));
        assert_eq!(fs::read(dir.join(BACKUP)).unwrap(), first);
        let backup = fs::read(dir.join(BACKUP)).unwrap();
        // Saving identical content touches nothing.
        let current = load_workspace_from(&dir).unwrap();
        save_workspace_to(&dir, &current);
        assert_eq!(fs::read(dir.join(BACKUP)).unwrap(), backup);
    }

    #[test]
    fn load_falls_back_to_backup_when_main_has_no_projects() {
        let dir = temp_dir("fallback");
        save_workspace_to(&dir, &workspace("Kept"));
        save_workspace_to(&dir, &Workspace::default());
        let loaded = load_workspace_from(&dir).unwrap();
        assert_eq!(loaded.groups[0].name, "Kept");
    }

    #[test]
    fn load_survives_garbage() {
        let dir = temp_dir("garbage");
        fs::write(dir.join(WORKSPACE), b"{not json").unwrap();
        assert!(load_workspace_from(&dir).is_none());
    }

    #[test]
    fn round_trip_is_stable() {
        let dir = temp_dir("stable");
        let mut ws = workspace("P");
        ws.selected_tab_id = Some(ws.groups[0].tabs[0].id);
        save_workspace_to(&dir, &ws);
        let loaded = load_workspace_from(&dir).unwrap();
        assert_eq!(loaded, ws);
    }
}
