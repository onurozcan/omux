//! The environment and shell a session starts with (docs/ROADMAP.md,
//! decision 2). Unlike the Mac app, which builds a clean environment with a
//! Homebrew PATH, the session inherits omux's environment: on Linux that
//! carries the display, D-Bus, SSH agent and locale programs need.

use std::ffi::OsString;

use crate::term::pty;

/// Whether a variable describes the Claude Code session omux itself was
/// started from (session ids, sockets, entry point): passed on, it would
/// make every agent in omux think it is nested. User configuration such as
/// `CLAUDE_CONFIG_DIR` and `ANTHROPIC_*` is kept; settings in the user's
/// profile return anyway, since the shell is a login shell.
fn is_nested_marker(key: &str) -> bool {
    key == "CLAUDECODE"
        || key.starts_with("CLAUDE_CODE_")
        || matches!(key, "CLAUDE_PID" | "CLAUDE_EFFORT" | "AI_AGENT")
}

pub struct Extra<'a> {
    pub codex_token: Option<&'a str>,
    pub repo: Option<&'a str>,
}

pub fn shell() -> String {
    std::env::var("SHELL")
        .ok()
        .filter(|s| !s.is_empty())
        .or_else(pty::passwd_shell)
        .unwrap_or_else(|| "/bin/bash".into())
}

pub type Env = Vec<(OsString, OsString)>;

/// `vars_os`: a variable that isn't valid UTF-8 is passed on, not a panic.
pub fn build(extra: Extra<'_>) -> Env {
    build_from(std::env::vars_os().collect(), extra)
}

fn build_from(inherited: Env, extra: Extra<'_>) -> Env {
    let mut env: Env = inherited
        .into_iter()
        .filter(|(key, _)| {
            let key = key.to_string_lossy();
            !is_nested_marker(&key) && !key.starts_with("OMUX_")
        })
        .filter(|(key, _)| {
            !matches!(
                key.to_string_lossy().as_ref(),
                "TERM" | "COLORTERM" | "TERM_PROGRAM" | "TERM_PROGRAM_VERSION" | "VTE_VERSION"
            )
        })
        .collect();
    let mut set = |key: &str, value: &str| {
        env.retain(|(k, _)| k != key);
        env.push((key.into(), value.into()));
    };
    if std::env::var("USER").is_err() {
        if let Some(name) = pty::login_name() {
            set("USER", &name);
            set("LOGNAME", &name);
        }
    }
    if std::env::var("LANG").is_err() {
        set("LANG", "C.UTF-8");
    }
    set("SHELL", &shell());
    set("TERM", "xterm-256color");
    set("COLORTERM", "truecolor");
    set("TERM_PROGRAM", "omux");
    set("TERM_PROGRAM_VERSION", env!("CARGO_PKG_VERSION"));
    if let Some(token) = extra.codex_token {
        set("OMUX_CODEX_TOKEN", token);
    }
    if let Some(repo) = extra.repo {
        set("OMUX_REPO", repo);
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get<'a>(env: &'a [(OsString, OsString)], key: &str) -> Option<&'a str> {
        env.iter()
            .find(|(k, _)| k == key)
            .and_then(|(_, v)| v.to_str())
    }

    #[test]
    fn strips_nested_claude_markers_and_sets_terminal_identity() {
        let inherited = vec![
            ("CLAUDECODE".into(), "1".into()),
            ("CLAUDE_CODE_SESSION_ID".into(), "abc".into()),
            ("CLAUDE_CONFIG_DIR".into(), "/home/u/.claude-work".into()),
            ("ANTHROPIC_BASE_URL".into(), "https://proxy".into()),
            ("TERM".into(), "dumb".into()),
            ("DISPLAY".into(), ":0".into()),
            ("OMUX_CODEX_TOKEN".into(), "stale".into()),
        ];
        let env = build_from(
            inherited,
            Extra {
                codex_token: None,
                repo: Some("/src/app"),
            },
        );
        assert_eq!(get(&env, "CLAUDECODE"), None);
        assert_eq!(get(&env, "CLAUDE_CODE_SESSION_ID"), None);
        assert_eq!(get(&env, "CLAUDE_CONFIG_DIR"), Some("/home/u/.claude-work"));
        assert_eq!(get(&env, "ANTHROPIC_BASE_URL"), Some("https://proxy"));
        assert_eq!(
            get(&env, "OMUX_CODEX_TOKEN"),
            None,
            "a token never leaks between sessions"
        );
        assert_eq!(get(&env, "DISPLAY"), Some(":0"));
        assert_eq!(get(&env, "TERM"), Some("xterm-256color"));
        assert_eq!(get(&env, "TERM_PROGRAM"), Some("omux"));
        assert_eq!(get(&env, "OMUX_REPO"), Some("/src/app"));
        assert_eq!(env.iter().filter(|(k, _)| k == "TERM").count(), 1);
    }
}
