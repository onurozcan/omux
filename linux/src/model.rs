//! The persisted workspace: projects (`TabGroup`) holding sessions (`TabItem`).
//!
//! Field names, defaults and decoding rules match `Models.swift` so a
//! workspace saved by either app reads the same way. Every field is optional
//! on decode so saved workspaces survive schema changes.

use serde::{Deserialize, Deserializer, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionProvider {
    Claude,
    Codex,
    Shell,
    Custom,
}

impl SessionProvider {
    pub fn label(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Shell => "Plain shell",
            Self::Custom => "Custom command",
        }
    }

    pub fn command(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Shell | Self::Custom => "",
        }
    }

    /// Existing custom commands keep their exact text. Only the standard Codex
    /// command opts into managed Codex sessions; wrappers remain ordinary commands.
    pub fn infer(command: Option<&str>) -> Self {
        let raw = command.unwrap_or("").trim();
        if raw.is_empty() {
            Self::Shell
        } else if raw == "codex" {
            Self::Codex
        } else if raw == "claude" || raw.starts_with("claude ") {
            Self::Claude
        } else {
            Self::Custom
        }
    }

    /// Pins a Claude command to the session's conversation: `--session-id` for a
    /// new one, `--resume` once its transcript exists. Commands that already
    /// choose a conversation are left alone.
    pub fn claude_command(raw: &str, session_id: Uuid, conversation_exists: bool) -> String {
        let (first, rest) = match raw.split_once(' ') {
            Some((first, rest)) => (first, rest),
            None => (raw, ""),
        };
        if first != "claude" {
            return raw.to_string();
        }
        const FLAGS: [&str; 5] = ["--resume", "-r", "--continue", "-c", "--session-id"];
        let user_managed = rest.split_whitespace().any(|word| {
            FLAGS.contains(&word)
                || word.starts_with("--resume=")
                || word.starts_with("--session-id=")
        });
        if user_managed {
            return raw.to_string();
        }
        let session = session_id.as_hyphenated().to_string().to_lowercase();
        let flag = if conversation_exists {
            format!("--resume {session}")
        } else {
            format!("--session-id {session}")
        };
        ["claude", flag.as_str(), rest]
            .into_iter()
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TabColor {
    #[default]
    None,
    Red,
    Orange,
    Yellow,
    Green,
    Mint,
    Teal,
    Cyan,
    Blue,
    Indigo,
    Purple,
    Pink,
    Brown,
    Gray,
}

impl TabColor {
    pub const ALL: [TabColor; 14] = [
        Self::None,
        Self::Red,
        Self::Orange,
        Self::Yellow,
        Self::Green,
        Self::Mint,
        Self::Teal,
        Self::Cyan,
        Self::Blue,
        Self::Indigo,
        Self::Purple,
        Self::Pink,
        Self::Brown,
        Self::Gray,
    ];

    pub fn raw(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Red => "red",
            Self::Orange => "orange",
            Self::Yellow => "yellow",
            Self::Green => "green",
            Self::Mint => "mint",
            Self::Teal => "teal",
            Self::Cyan => "cyan",
            Self::Blue => "blue",
            Self::Indigo => "indigo",
            Self::Purple => "purple",
            Self::Pink => "pink",
            Self::Brown => "brown",
            Self::Gray => "gray",
        }
    }

    pub fn label(self) -> String {
        let raw = self.raw();
        let mut chars = raw.chars();
        match chars.next() {
            Some(first) => first.to_uppercase().chain(chars).collect(),
            None => String::new(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Worktree {
    pub branch: String,
    /// The branch it was made from; diffs and merges compare against it.
    pub base: String,
    /// The main checkout that owns the worktree.
    pub repo: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabItem {
    #[serde(default = "Uuid::new_v4", with = "upper_uuid")]
    pub id: Uuid,
    #[serde(default = "default_session_name")]
    pub name: String,
    /// None inherits the group's directory (or the home folder).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    /// None inherits the group's command; "" means a plain shell.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// None inherits the project, or infers the provider of a legacy command.
    #[serde(
        default,
        skip_serializing_if = "Option::is_none",
        deserialize_with = "lenient_option"
    )]
    pub provider: Option<SessionProvider>,
    #[serde(default, deserialize_with = "lenient_or_default")]
    pub color: TabColor,
    /// Stable Claude Code session id so the conversation resumes across relaunches.
    #[serde(
        rename = "claudeSessionID",
        default = "Uuid::new_v4",
        with = "upper_uuid"
    )]
    pub claude_session_id: Uuid,
    /// Assigned by Codex, never guessed from the working directory or latest chat.
    #[serde(
        rename = "codexThreadID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub codex_thread_id: Option<String>,
    /// Set when the session runs in its own git worktree; `directory` is the worktree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub worktree: Option<Worktree>,
}

fn default_session_name() -> String {
    "Session".into()
}

impl TabItem {
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            directory: None,
            command: None,
            provider: None,
            color: TabColor::None,
            claude_session_id: Uuid::new_v4(),
            codex_thread_id: None,
            worktree: None,
        }
    }

    pub fn resolved_provider(&self, group: &TabGroup) -> SessionProvider {
        self.provider.unwrap_or_else(|| match &self.command {
            Some(command) => SessionProvider::infer(Some(command)),
            None => group.provider,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TabGroup {
    #[serde(with = "upper_uuid")]
    pub id: Uuid,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub directory: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    pub provider: SessionProvider,
    pub is_collapsed: bool,
    /// New sessions get their own git worktree.
    pub use_worktrees: bool,
    /// Runs in each new worktree before the session's command, e.g. to copy
    /// ignored files like `.env` or install dependencies. Empty runs nothing.
    pub worktree_setup: String,
    pub tabs: Vec<TabItem>,
}

impl TabGroup {
    /// A project made in the app starts Claude Code sessions. (A saved project
    /// without a command decodes differently; see `Deserialize`.)
    pub fn new(name: impl Into<String>, directory: Option<String>, tabs: Vec<TabItem>) -> Self {
        Self {
            id: Uuid::new_v4(),
            name: name.into(),
            directory,
            command: Some("claude".into()),
            provider: SessionProvider::Claude,
            is_collapsed: false,
            use_worktrees: false,
            worktree_setup: String::new(),
            tabs,
        }
    }
}

impl<'de> Deserialize<'de> for TabGroup {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Raw {
            #[serde(default = "Uuid::new_v4", with = "upper_uuid")]
            id: Uuid,
            #[serde(default)]
            name: Option<String>,
            #[serde(default)]
            directory: Option<String>,
            #[serde(default)]
            command: Option<String>,
            #[serde(default, deserialize_with = "lenient_option")]
            provider: Option<SessionProvider>,
            #[serde(default)]
            is_collapsed: bool,
            #[serde(default)]
            use_worktrees: bool,
            #[serde(default)]
            worktree_setup: String,
            #[serde(default)]
            tabs: Vec<TabItem>,
        }
        let raw = Raw::deserialize(deserializer)?;
        let provider = raw
            .provider
            .unwrap_or_else(|| SessionProvider::infer(raw.command.as_deref()));
        Ok(Self {
            id: raw.id,
            name: raw.name.unwrap_or_else(|| "Project".into()),
            directory: raw.directory,
            command: raw.command,
            provider,
            is_collapsed: raw.is_collapsed,
            use_worktrees: raw.use_worktrees,
            worktree_setup: raw.worktree_setup,
            tabs: raw.tabs,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    #[serde(default)]
    pub groups: Vec<TabGroup>,
    #[serde(
        rename = "selectedTabID",
        default,
        skip_serializing_if = "Option::is_none",
        with = "upper_uuid_option"
    )]
    pub selected_tab_id: Option<Uuid>,
}

/// An enum value written by a newer version decodes as absent instead of
/// failing the whole workspace.
fn lenient_option<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned,
{
    let value = Option::<serde_json::Value>::deserialize(deserializer)?;
    Ok(value.and_then(|v| serde_json::from_value(v).ok()))
}

fn lenient_or_default<'de, D, T>(deserializer: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: serde::de::DeserializeOwned + Default,
{
    Ok(lenient_option(deserializer)?.unwrap_or_default())
}

/// Swift encodes UUIDs as uppercase hyphenated strings and accepts either case.
mod upper_uuid {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(id: &Uuid, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&id.as_hyphenated().to_string().to_uppercase())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Uuid, D::Error> {
        let text = String::deserialize(d)?;
        Uuid::parse_str(&text).map_err(serde::de::Error::custom)
    }
}

mod upper_uuid_option {
    use serde::{Deserialize, Deserializer, Serializer};
    use uuid::Uuid;

    pub fn serialize<S: Serializer>(id: &Option<Uuid>, s: S) -> Result<S::Ok, S::Error> {
        match id {
            Some(id) => super::upper_uuid::serialize(id, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<Uuid>, D::Error> {
        let text = Option::<String>::deserialize(d)?;
        Ok(text.and_then(|t| Uuid::parse_str(&t).ok()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_workspace_preserves_claude_identity_and_command() {
        let id = Uuid::new_v4();
        let json = format!(
            r#"{{"command":"claude --model opus","tabs":[{{"claudeSessionID":"{id}","name":"Existing"}}]}}"#
        );
        let group: TabGroup = serde_json::from_str(&json).unwrap();
        assert_eq!(group.provider, SessionProvider::Claude);
        assert_eq!(group.tabs[0].claude_session_id, id);
        assert_eq!(
            group.tabs[0].resolved_provider(&group),
            SessionProvider::Claude
        );
        assert_eq!(group.command.as_deref(), Some("claude --model opus"));
    }

    #[test]
    fn shell_override_does_not_inherit_project_agent() {
        let group = TabGroup::new("Project", None, vec![]);
        let mut tab = TabItem::new("Shell");
        tab.command = Some(String::new());
        assert_eq!(tab.resolved_provider(&group), SessionProvider::Shell);
    }

    #[test]
    fn codex_identity_survives_round_trip() {
        let mut group = TabGroup::new("Project", None, vec![]);
        group.provider = SessionProvider::Codex;
        group.command = Some("codex".into());
        let mut tab = TabItem::new("Codex");
        tab.codex_thread_id = Some("thread-assigned-by-server".into());
        group.tabs = vec![tab.clone()];
        let restored: TabGroup =
            serde_json::from_str(&serde_json::to_string(&group).unwrap()).unwrap();
        assert_eq!(
            restored.tabs[0].resolved_provider(&restored),
            SessionProvider::Codex
        );
        assert_eq!(restored.tabs[0].codex_thread_id, tab.codex_thread_id);
    }

    #[test]
    fn custom_commands_remain_custom() {
        for command in [
            "env codex",
            "codex exec task",
            "npm run dev",
            "/path/to/wrapper",
        ] {
            assert_eq!(
                SessionProvider::infer(Some(command)),
                SessionProvider::Custom
            );
        }
    }

    #[test]
    fn claude_starts_a_new_pinned_conversation_instead_of_continuing_another_tab() {
        let id = Uuid::new_v4();
        let lower = id.to_string().to_lowercase();
        assert_eq!(
            SessionProvider::claude_command("claude --model opus", id, false),
            format!("claude --session-id {lower} --model opus")
        );
        assert_eq!(
            SessionProvider::claude_command("claude", id, true),
            format!("claude --resume {lower}")
        );
    }

    #[test]
    fn explicit_claude_session_flags_are_preserved() {
        for raw in [
            "claude --resume abc",
            "claude --resume=abc",
            "claude --session-id=abc",
            "claude --continue",
        ] {
            assert_eq!(
                SessionProvider::claude_command(raw, Uuid::new_v4(), false),
                raw
            );
        }
    }

    #[test]
    fn group_without_command_is_a_shell_project() {
        let group: TabGroup = serde_json::from_str(r#"{"name":"P"}"#).unwrap();
        assert_eq!(group.command, None);
        assert_eq!(group.provider, SessionProvider::Shell);
        assert_eq!(group.name, "P");
    }

    #[test]
    fn missing_fields_take_swift_defaults() {
        let tab: TabItem = serde_json::from_str("{}").unwrap();
        assert_eq!(tab.name, "Session");
        assert_eq!(tab.color, TabColor::None);
        let group: TabGroup = serde_json::from_str("{}").unwrap();
        assert_eq!(group.name, "Project");
        assert!(group.tabs.is_empty());
    }

    #[test]
    fn unknown_enum_values_do_not_fail_the_workspace() {
        let tab: TabItem =
            serde_json::from_str(r#"{"provider":"gemini","color":"magenta"}"#).unwrap();
        assert_eq!(tab.provider, None);
        assert_eq!(tab.color, TabColor::None);
    }

    #[test]
    fn uuids_accept_lowercase_and_write_uppercase() {
        let tab: TabItem =
            serde_json::from_str(r#"{"id":"0f8fad5b-d9cb-469f-a165-70867728950e"}"#).unwrap();
        let out = serde_json::to_string(&tab).unwrap();
        assert!(out.contains("0F8FAD5B-D9CB-469F-A165-70867728950E"));
    }
}
