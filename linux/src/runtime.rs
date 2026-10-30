//! A session's live state (`TabRuntime` on the Mac). Never saved.

use std::path::Path;

use crate::model::SessionProvider;
use crate::persistence::abbreviate_home;
use crate::term::status::{Record, State};

#[derive(Debug, Clone, Default)]
pub struct TabRuntime {
    /// OSC 0/2 title; Claude Code rewrites it as its state changes.
    pub title: String,
    pub cwd: Option<String>,
    /// Something other than the shell runs in the foreground.
    pub busy: bool,
    pub exited: bool,
    /// The provider the running terminal was started with.
    pub provider: Option<SessionProvider>,
    /// A managed agent (Codex) is attached to this terminal.
    pub agent_connected: bool,
    pub status_state: Option<State>,
    /// Why a blocked program waits: `permission`, `question`, `auth`, or
    /// Codex's `approval`.
    pub status_kind: Option<String>,
    pub status_detail: Option<String>,
    /// OSC 7501 records other than the root, e.g. Claude Code's subagents.
    pub status_children: Vec<Record>,
    /// Blocked, finished, rang the bell or got a notification while unwatched.
    pub needs_attention: bool,
    /// The title changed while unwatched.
    pub has_activity: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StatusColor {
    Orange,
    Blue,
    Green,
    Red,
}

impl TabRuntime {
    pub fn stopped() -> Self {
        Self {
            exited: true,
            ..Self::default()
        }
    }

    /// Shows Allow/Deny for a non-Codex session.
    pub fn awaits_permission(&self) -> bool {
        self.status_state == Some(State::Blocked)
            && self.status_kind.as_deref() == Some("permission")
    }

    pub fn status_line(&self, show_folder: bool) -> String {
        let detail = self.status_detail.as_deref().filter(|d| !d.is_empty());
        match self.status_state {
            Some(State::Blocked) => {
                return match detail.or(self.status_kind.as_deref()) {
                    Some(why) => format!("Needs you · {why}"),
                    None => "Needs you".into(),
                }
            }
            Some(State::Working) => {
                return match detail {
                    Some(d) => format!("Working · {d}"),
                    None => "Working…".into(),
                }
            }
            Some(State::Done) => return "Done".into(),
            Some(State::Error) => {
                return match detail {
                    Some(d) => format!("Error · {d}"),
                    None => "Error".into(),
                }
            }
            Some(State::Idle) | None => {}
        }
        if self.exited {
            return "Stopped".into();
        }
        if !self.title.is_empty() {
            return self.title.clone();
        }
        match (&self.cwd, show_folder) {
            (Some(cwd), true) => abbreviate_home(Path::new(cwd)),
            _ => String::new(),
        }
    }

    pub fn status_color(&self) -> Option<StatusColor> {
        match self.status_state? {
            State::Blocked => Some(StatusColor::Orange),
            State::Working => Some(StatusColor::Blue),
            State::Done => Some(StatusColor::Green),
            State::Error => Some(StatusColor::Red),
            State::Idle => None,
        }
    }

    /// Applies OSC 7501 records: the root (empty id) is the session itself,
    /// the rest are children. Without a root the newest record stands in.
    pub fn apply_records(&mut self, records: &[Record]) {
        let root = records
            .iter()
            .find(|r| r.id.is_empty())
            .or_else(|| records.last());
        self.status_state = root.map(|r| r.state);
        self.status_kind = root.and_then(|r| r.kind).map(|k| k.raw().to_string());
        self.status_detail = root.and_then(|r| r.message.clone());
        self.status_children = records
            .iter()
            .filter(|r| !r.id.is_empty())
            .cloned()
            .collect();
    }

    pub fn clear_status(&mut self) {
        self.status_state = None;
        self.status_kind = None;
        self.status_detail = None;
        self.status_children.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::term::status::Kind;

    fn record(id: &str, state: State, kind: Option<Kind>, message: Option<&str>) -> Record {
        Record {
            id: id.into(),
            state,
            kind,
            progress: None,
            app: None,
            effective_app: None,
            title: None,
            message: message.map(Into::into),
        }
    }

    #[test]
    fn status_line_priorities() {
        let mut rt = TabRuntime {
            title: "✳ Claude".into(),
            ..TabRuntime::default()
        };
        assert_eq!(rt.status_line(true), "✳ Claude");
        rt.apply_records(&[record("", State::Blocked, Some(Kind::Permission), None)]);
        assert_eq!(rt.status_line(true), "Needs you · permission");
        assert!(rt.awaits_permission());
        rt.apply_records(&[record(
            "",
            State::Blocked,
            Some(Kind::Permission),
            Some("Bash"),
        )]);
        assert_eq!(rt.status_line(true), "Needs you · Bash");
        rt.apply_records(&[record("", State::Working, None, None)]);
        assert_eq!(rt.status_line(true), "Working…");
        assert!(!rt.awaits_permission());
        rt.apply_records(&[]);
        rt.exited = true;
        assert_eq!(rt.status_line(true), "Stopped");
    }

    #[test]
    fn children_are_split_from_the_root() {
        let mut rt = TabRuntime::default();
        rt.apply_records(&[
            record("agent-1", State::Blocked, None, None),
            record("", State::Working, None, None),
        ]);
        assert_eq!(rt.status_state, Some(State::Working));
        assert_eq!(rt.status_children.len(), 1);
        // Without a root, the newest record is used.
        rt.apply_records(&[record("a", State::Done, None, None)]);
        assert_eq!(rt.status_state, Some(State::Done));
    }
}
