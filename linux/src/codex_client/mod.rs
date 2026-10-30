//! Codex app-server client: one private `codex app-server` per tab plus a
//! shared catalog server, speaking JSON-RPC over a loopback WebSocket
//! (port of `CodexConnection.swift` / `CodexManager.swift`).
//!
//! Layers: `protocol` is the pure state machine (no IO, fully unit-tested),
//! `connection` owns the child process, WebSocket and request matching, and
//! this file glues them into the `TabClient` / `Catalog` API.
//!
//! Threading: the GTK main thread must never call the blocking methods
//! (`start`, `answer`, `interrupt`, `transcript`, `detach`, `usage`,
//! `Catalog::*`); run them on worker threads. Asynchronous changes arrive as
//! `Update`s on the `async_channel::Sender` passed to `TabClient::start`; the
//! sends never block, so use an unbounded channel.
//!
//! Usage: the quota is process-wide and merged. `account/rateLimits/updated`
//! on any tab connection is merged into it and delivered as `Update::Usage`;
//! `start` also kicks off one full read in the background. `Catalog::usage` and
//! `TabClient::usage` perform a full read (`account/read` then
//! `account/rateLimits/read`) and return the merged result.

mod connection;
mod protocol;
mod usage;

use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use connection::{lock, resume_command, Conn, Handlers};
use protocol::{Effect, Protocol};

pub use protocol::{format_transcript, Approval, CodexAgent, CodexState, CodexStatus, RequestId};
#[allow(unused_imports)]
pub use usage::{CodexUsage, UsageLimit};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CodexError {
    Unavailable,
    Timeout,
    Disconnected,
    NotSignedIn,
    Server(String),
    NoConversationId,
    PreviousServerStopping,
}

impl fmt::Display for CodexError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable => f.write_str("Couldn't connect to Codex. Install Codex CLI 0.165.0 or later and check that codex is on your login shell's PATH."),
            Self::Disconnected => f.write_str("The Codex connection closed. Restart this session to reconnect to its saved conversation."),
            Self::Timeout => f.write_str("Codex didn't respond in time. Try restarting this session."),
            Self::NotSignedIn => f.write_str("Codex isn't signed in: run codex login"),
            Self::Server(message) => f.write_str(message),
            Self::NoConversationId => f.write_str("Codex didn't return a conversation ID"),
            Self::PreviousServerStopping => f.write_str("The previous Codex server is still stopping. Try restarting the session again."),
        }
    }
}

impl std::error::Error for CodexError {}

#[derive(Debug, Clone, PartialEq)]
pub enum Update {
    /// Effective status for the tab (root status, overridden to
    /// blocked/"permission" while an approval is pending).
    Status {
        state: Option<CodexState>,
        kind: Option<String>,
        detail: Option<String>,
    },
    /// The TUI started a new root conversation (e.g. /clear): persist this id.
    ThreadChanged(String),
    /// The subagent list changed (full list).
    Agents(Vec<CodexAgent>),
    /// The connection closed unexpectedly; `Status` (error) is sent too.
    Disconnected(String),
    /// Merged usage after an `account/rateLimits/updated` notification or the
    /// background read started by `start`.
    Usage(CodexUsage),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexConversation {
    pub id: String,
    pub cwd: String,
    pub name: String,
    /// Epoch seconds.
    pub updated_at: i64,
}

impl CodexConversation {
    pub fn from_json(raw: &Value) -> Option<Self> {
        let id = raw.get("id")?.as_str()?;
        let cwd = raw.get("cwd")?.as_str()?;
        let text = |key: &str| {
            raw.get(key)
                .and_then(Value::as_str)
                .filter(|s| !s.is_empty())
        };
        let name = text("name")
            .or_else(|| text("preview"))
            .unwrap_or("Codex conversation");
        let updated = raw.get("updatedAt").and_then(Value::as_f64).unwrap_or(0.0);
        Some(Self {
            id: id.to_string(),
            cwd: cwd.to_string(),
            name: name.to_string(),
            updated_at: updated as i64,
        })
    }
}

struct TabState {
    proto: Protocol,
    updates: Option<async_channel::Sender<Update>>,
    /// Approvals whose reply is in flight, so a double click answers once.
    answering: Vec<RequestId>,
}

struct Tab {
    conn: Arc<Conn>,
    state: Mutex<TabState>,
    /// Signalled whenever the protocol state changes (turn completion waits).
    changed: Condvar,
}

impl Tab {
    fn emit(&self, update: Update) {
        let sender = lock(&self.state).updates.clone();
        if let Some(sender) = sender {
            let _ = sender.try_send(update);
        }
    }
}

fn on_message(tab: &Arc<Tab>, message: Value) {
    let effects = lock(&tab.state).proto.receive(&message);
    tab.changed.notify_all();
    run_effects(tab, effects);
}

fn on_disconnect(tab: &Arc<Tab>) {
    let mut effects = Vec::new();
    lock(&tab.state).proto.clear_activity(&mut effects);
    tab.changed.notify_all();
    run_effects(tab, effects);
    let text = CodexError::Disconnected.to_string();
    tab.emit(Update::Status {
        state: Some(CodexState::Error),
        kind: None,
        detail: Some(text.clone()),
    });
    tab.emit(Update::Disconnected(text));
}

fn run_effects(tab: &Arc<Tab>, effects: Vec<Effect>) {
    for effect in effects {
        match effect {
            Effect::Status(s) => tab.emit(Update::Status {
                state: Some(s.state),
                kind: s.kind,
                detail: s.detail,
            }),
            Effect::ThreadChanged(id) => tab.emit(Update::ThreadChanged(id)),
            Effect::Agents(list) => tab.emit(Update::Agents(list)),
            Effect::RateLimits(params) => {
                let usage = {
                    let mut quota = lock(usage::global());
                    quota.apply(&params, false);
                    quota.usage()
                };
                if !usage.limits.is_empty() {
                    tab.emit(Update::Usage(usage));
                }
            }
            Effect::SyncAgent(id) => {
                let tab = Arc::clone(tab);
                thread::spawn(move || sync_agent(&tab, &id));
            }
            Effect::AdoptRoot { id, named } => {
                let tab = Arc::clone(tab);
                thread::spawn(move || adopt_root(&tab, &id, named));
            }
        }
    }
}

/// A child can be announced before its initial history write, so the resume
/// is retried (5 attempts, 100 ms * attempt apart).
fn sync_agent(tab: &Arc<Tab>, id: &str) {
    let Some(gen) = tab.conn.link_gen() else {
        return;
    };
    let current =
        |tab: &Arc<Tab>| lock(&tab.state).proto.is_agent(id) && tab.conn.link_gen() == Some(gen);
    for attempt in 0..5u64 {
        if !current(tab) {
            return;
        }
        let params = json!({"threadId": id, "excludeTurns": false});
        match tab.conn.request("thread/resume", params) {
            Ok(response) => {
                if !current(tab) {
                    return;
                }
                if let Some(thread) = response.get("thread") {
                    let effects = lock(&tab.state).proto.synchronize_agent(thread);
                    tab.changed.notify_all();
                    run_effects(tab, effects);
                }
                return;
            }
            Err(_) => thread::sleep(Duration::from_millis(100 * (attempt + 1))),
        }
    }
}

fn adopt_requests(conn: &Conn, id: &str, named: bool) -> Result<(), CodexError> {
    if !named {
        let params = json!({"threadId": id, "name": "Codex conversation"});
        conn.request("thread/name/set", params)?;
    }
    let params = json!({"threadId": id, "excludeTurns": true});
    conn.request("thread/resume", params).map(|_| ())
}

/// Subscribe to a root the TUI just created (e.g. after /clear).
fn adopt_root(tab: &Arc<Tab>, id: &str, named: bool) {
    let Some(gen) = tab.conn.link_gen() else {
        return;
    };
    if lock(&tab.state).proto.root() != Some(id) || tab.conn.link_gen() != Some(gen) {
        return;
    }
    let result = adopt_requests(&tab.conn, id, named);
    if let Err(error) = result {
        let status = CodexStatus {
            state: CodexState::Error,
            kind: None,
            detail: Some(error.to_string()),
        };
        let effects = lock(&tab.state).proto.publish(id, status);
        run_effects(tab, effects);
    }
}

/// Full usage read: a stale login makes the limits request fail with a 401,
/// so the account is checked first.
fn read_usage(conn: &Conn) -> Result<CodexUsage, CodexError> {
    let clear = || lock(usage::global()).clear();
    let account = conn
        .request("account/read", json!({"refreshToken": true}))
        .map_err(|_| {
            clear();
            CodexError::Server("Codex usage unavailable".into())
        })?;
    if !account.get("account").is_some_and(Value::is_object) {
        clear();
        return Err(CodexError::NotSignedIn);
    }
    let limits = conn
        .request(
            "account/rateLimits/read",
            json!({"excludeResetCreditDetails": true}),
        )
        .map_err(|_| {
            clear();
            CodexError::Server("Codex usage unavailable".into())
        })?;
    let usage = {
        let mut quota = lock(usage::global());
        quota.apply(&limits, true);
        quota.usage()
    };
    if usage.limits.is_empty() {
        return Err(CodexError::Server(
            "Codex usage unavailable for this account".into(),
        ));
    }
    Ok(usage)
}

/// One per omux session (tab): owns its private `codex app-server` and the
/// protocol client. Cheap to clone; all clones share the same state.
#[derive(Clone)]
pub struct TabClient {
    tab: Arc<Tab>,
}

impl Default for TabClient {
    fn default() -> Self {
        Self::new()
    }
}

impl TabClient {
    /// Generates the bearer token (memory only). Cheap, no IO.
    pub fn new() -> Self {
        Self::build(None)
    }

    /// Like `new`, but the server runs with exactly this environment
    /// (tests use it for a temporary `CODEX_HOME`).
    #[cfg(test)]
    pub fn with_env(env: HashMap<String, String>) -> Self {
        Self::build(Some(env))
    }

    fn build(env: Option<HashMap<String, String>>) -> Self {
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let tab = Arc::new_cyclic(|weak: &Weak<Tab>| {
            let (messages, disconnects) = (weak.clone(), weak.clone());
            let handlers = Handlers {
                on_message: Box::new(move |m| {
                    if let Some(tab) = messages.upgrade() {
                        on_message(&tab, m);
                    }
                }),
                on_disconnect: Box::new(move || {
                    if let Some(tab) = disconnects.upgrade() {
                        on_disconnect(&tab);
                    }
                }),
            };
            Tab {
                conn: Conn::new(token, env, handlers),
                state: Mutex::new(TabState {
                    proto: Protocol::new(),
                    updates: None,
                    answering: Vec::new(),
                }),
                changed: Condvar::new(),
            }
        });
        Self { tab }
    }

    /// The value for the `OMUX_CODEX_TOKEN` env var of the tab's shell.
    pub fn token(&self) -> String {
        self.tab.conn.token.clone()
    }

    /// Blocking. Launches the server, waits for readiness, connects,
    /// initializes, then `thread/resume` (saved id) or `thread/start` +
    /// `thread/name/set`. Returns the conversation id and the shell line that
    /// attaches the TUI to this server.
    pub fn start(
        &self,
        cwd: &Path,
        saved_thread: Option<String>,
        name: &str,
        client_version: &str,
        updates: async_channel::Sender<Update>,
    ) -> Result<(String, String), CodexError> {
        let tab = &self.tab;
        lock(&tab.state).updates = Some(updates);
        tab.conn.set_client_version(client_version);
        tab.conn.connect()?;
        let response = match &saved_thread {
            Some(id) => tab.conn.request(
                "thread/resume",
                json!({"threadId": id, "excludeTurns": true}),
            )?,
            None => tab
                .conn
                .request("thread/start", json!({"cwd": cwd.to_string_lossy()}))?,
        };
        let thread = response.get("thread");
        let id = thread
            .and_then(|t| t.get("id"))
            .and_then(Value::as_str)
            .ok_or(CodexError::NoConversationId)?
            .to_string();
        let endpoint = tab.conn.endpoint().ok_or(CodexError::NoConversationId)?;
        // Naming materializes a new conversation before a second client (the
        // TUI) resumes it, including conversations with no user turn yet.
        if saved_thread.is_none() {
            tab.conn
                .request("thread/name/set", json!({"threadId": id, "name": name}))?;
        }
        let effects = {
            let mut state = lock(&tab.state);
            state.proto.register(&id);
            match thread
                .and_then(|t| t.get("status"))
                .and_then(CodexStatus::decode)
            {
                Some(status) => state.proto.publish(&id, status),
                None => Vec::new(),
            }
        };
        run_effects(tab, effects);
        let background = Arc::clone(tab);
        thread::spawn(move || {
            if let Ok(usage) = read_usage(&background.conn) {
                background.emit(Update::Usage(usage));
            }
        });
        Ok((id.clone(), resume_command(&endpoint, &id)))
    }

    pub fn is_ready(&self) -> bool {
        self.tab.conn.is_ready()
    }

    #[cfg(test)]
    pub fn thread_id(&self) -> Option<String> {
        lock(&self.tab.state).proto.root().map(str::to_string)
    }

    /// First pending approval of the root, else of any subagent.
    pub fn pending_approval(&self) -> Option<Approval> {
        lock(&self.tab.state).proto.approval().cloned()
    }

    /// Blocking. Replies `{"decision": "accept"|"decline"}`, then removes the
    /// approval locally and republishes without waiting for the server's
    /// resolved notification.
    pub fn answer(&self, allow: bool) -> Result<(), CodexError> {
        let tab = &self.tab;
        let approval = {
            let mut state = lock(&tab.state);
            let Some(approval) = state.proto.approval().cloned() else {
                return Ok(());
            };
            if state.answering.contains(&approval.id) {
                return Ok(());
            }
            state.answering.push(approval.id.clone());
            approval
        };
        let decision = if allow { "accept" } else { "decline" };
        let result = tab
            .conn
            .respond(&approval.id, json!({"decision": decision}));
        let effects = {
            let mut state = lock(&tab.state);
            state.answering.retain(|id| id != &approval.id);
            if result.is_ok() {
                state.proto.answered(&approval)
            } else {
                Vec::new()
            }
        };
        tab.changed.notify_all();
        run_effects(tab, effects);
        result
    }

    /// Blocking. Interrupts subagents then the root; for each thread with a
    /// running turn, waits up to 10 s for its `turn/completed`.
    pub fn interrupt(&self) -> Result<(), CodexError> {
        let tab = &self.tab;
        let threads = {
            let state = lock(&tab.state);
            if state.proto.root().is_none() {
                return Ok(());
            }
            state.proto.interrupt_threads()
        };
        for thread in threads {
            let Some(turn) = lock(&tab.state).proto.turn(&thread).map(str::to_string) else {
                continue;
            };
            tab.conn.request(
                "turn/interrupt",
                json!({"threadId": thread, "turnId": turn}),
            )?;
            // The response acknowledges cancellation; turn/completed confirms it.
            let deadline = Instant::now() + Duration::from_secs(10);
            let mut state = lock(&tab.state);
            while state.proto.turn(&thread) == Some(turn.as_str()) {
                let now = Instant::now();
                if now >= deadline {
                    return Err(CodexError::Timeout);
                }
                state = tab
                    .changed
                    .wait_timeout(state, deadline - now)
                    .unwrap_or_else(|e| e.into_inner())
                    .0;
            }
        }
        Ok(())
    }

    /// Blocking. Markdown preview of the thread's latest 100 items.
    pub fn transcript(&self, thread_id: &str) -> Result<String, CodexError> {
        let tab = &self.tab;
        let known = {
            let state = lock(&tab.state);
            state.proto.root() == Some(thread_id) || state.proto.is_agent(thread_id)
        };
        if !known || tab.conn.link_gen().is_none() {
            return Err(CodexError::Disconnected);
        }
        let result = tab.conn.request(
            "thread/items/list",
            json!({"threadId": thread_id, "limit": 100, "sortDirection": "desc"}),
        )?;
        Ok(format_transcript(&result))
    }

    /// Non-blocking. Stops the server (SIGTERM), fails pending requests and
    /// forgets the conversation. No `Update`s are sent for a deliberate close.
    pub fn close(&self) {
        self.tab.conn.close(false);
        lock(&self.tab.state).proto.reset();
        self.tab.changed.notify_all();
    }

    /// Blocking. Stop running turns before removing the subscriber or
    /// deleting the session's worktree: interrupt, close, wait for exit.
    pub fn detach(&self) -> Result<(), CodexError> {
        if lock(&self.tab.state).proto.root().is_none() {
            return Ok(());
        }
        self.interrupt()?;
        self.tab.conn.close(false);
        self.tab.conn.wait_for_shutdown()?;
        lock(&self.tab.state).proto.reset();
        self.tab.changed.notify_all();
        Ok(())
    }
}

/// Shared catalog server for Recent conversations and usage; started on first
/// use and kept until `shutdown`.
pub struct Catalog {
    conn: Arc<Conn>,
}

impl Default for Catalog {
    fn default() -> Self {
        Self::new()
    }
}

impl Catalog {
    pub fn new() -> Self {
        let token = format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        );
        let handlers = Handlers {
            on_message: Box::new(|_| {}),
            on_disconnect: Box::new(|| {}),
        };
        Self {
            conn: Conn::new(token, None, handlers),
        }
    }

    /// Blocking. Newest first, paginated 100 at a time.
    pub fn recent(&self, limit: usize) -> Result<Vec<CodexConversation>, CodexError> {
        self.conn.connect()?;
        let mut result: Vec<CodexConversation> = Vec::new();
        let mut cursor: Option<String> = None;
        loop {
            let mut params = json!({
                "limit": 100usize.min(limit.saturating_sub(result.len())),
                "sortKey": "updated_at",
            });
            if let Some(cursor) = &cursor {
                params["cursor"] = json!(cursor);
            }
            let page = self.conn.request("thread/list", params)?;
            let rows = page.get("data").and_then(Value::as_array);
            let rows = rows.map(Vec::as_slice).unwrap_or_default();
            result.extend(rows.iter().filter_map(CodexConversation::from_json));
            let next = page
                .get("nextCursor")
                .and_then(Value::as_str)
                .map(str::to_string);
            if next == cursor || rows.is_empty() {
                break;
            }
            cursor = next;
            if cursor.is_none() || result.len() >= limit {
                break;
            }
        }
        result.truncate(limit);
        Ok(result)
    }

    /// Blocking: `account/read` then `account/rateLimits/read`.
    pub fn usage(&self) -> Result<CodexUsage, CodexError> {
        self.conn.connect()?;
        read_usage(&self.conn)
    }

    pub fn shutdown(&self) {
        self.conn.close(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_messages_match_the_mac_app() {
        assert_eq!(
            CodexError::Unavailable.to_string(),
            "Couldn't connect to Codex. Install Codex CLI 0.165.0 or later and check that codex is on your login shell's PATH."
        );
        assert_eq!(
            CodexError::Disconnected.to_string(),
            "The Codex connection closed. Restart this session to reconnect to its saved conversation."
        );
        assert_eq!(
            CodexError::Timeout.to_string(),
            "Codex didn't respond in time. Try restarting this session."
        );
        assert_eq!(
            CodexError::NotSignedIn.to_string(),
            "Codex isn't signed in: run codex login"
        );
        assert_eq!(
            CodexError::NoConversationId.to_string(),
            "Codex didn't return a conversation ID"
        );
        assert_eq!(
            CodexError::PreviousServerStopping.to_string(),
            "The previous Codex server is still stopping. Try restarting the session again."
        );
        assert_eq!(CodexError::Server("x".into()).to_string(), "x");
    }

    #[test]
    fn conversation_name_falls_back_to_preview_then_default() {
        let name = |v: Value| CodexConversation::from_json(&v).unwrap().name;
        assert_eq!(
            name(json!({"id": "a", "cwd": "/", "name": "N", "preview": "P"})),
            "N"
        );
        assert_eq!(
            name(json!({"id": "a", "cwd": "/", "name": "", "preview": "P"})),
            "P"
        );
        assert_eq!(
            name(json!({"id": "a", "cwd": "/", "preview": ""})),
            "Codex conversation"
        );
    }

    #[test]
    fn tokens_are_long_unique_and_printable() {
        let (a, b) = (TabClient::new(), TabClient::new());
        assert_eq!(a.token().len(), 64);
        assert_ne!(a.token(), b.token());
        assert!(a.token().chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn idle_client_has_no_state_and_blocking_calls_fail_fast() {
        let client = TabClient::new();
        assert!(!client.is_ready());
        assert!(client.pending_approval().is_none());
        assert_eq!(client.thread_id(), None);
        assert_eq!(client.interrupt(), Ok(()));
        assert_eq!(client.answer(true), Ok(()));
        assert_eq!(client.detach(), Ok(()));
        assert_eq!(client.transcript("t"), Err(CodexError::Disconnected));
        client.close();
    }

    #[test]
    fn effects_flow_to_updates_through_message_handling() {
        let client = TabClient::new();
        let (tx, rx) = async_channel::unbounded();
        lock(&client.tab.state).updates = Some(tx);
        lock(&client.tab.state).proto.register("root");
        on_message(
            &client.tab,
            json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "t"}}}),
        );
        on_message(
            &client.tab,
            json!({"id": 1, "method": "item/commandExecution/requestApproval",
                "params": {"threadId": "root", "turnId": "t", "command": "ls"}}),
        );
        assert_eq!(client.pending_approval().unwrap().detail, "ls");
        assert!(matches!(
            rx.try_recv(),
            Ok(Update::Status {
                state: Some(CodexState::Working),
                ..
            })
        ));
        match rx.try_recv() {
            Ok(Update::Status {
                state,
                kind,
                detail,
            }) => {
                assert_eq!(state, Some(CodexState::Blocked));
                assert_eq!(kind.as_deref(), Some("permission"));
                assert_eq!(detail.as_deref(), Some("ls"));
            }
            other => panic!("unexpected {other:?}"),
        }
        on_disconnect(&client.tab);
        assert!(client.pending_approval().is_none());
        assert!(matches!(
            rx.try_recv(),
            Ok(Update::Status {
                state: Some(CodexState::Error),
                ..
            })
        ));
        assert!(matches!(rx.try_recv(), Ok(Update::Disconnected(_))));
    }

    /// Opt-in like the Mac `CodexConnectionTests`: needs the real codex CLI.
    /// Uses a temporary CODEX_HOME with a dead model provider; no turn is sent.
    #[test]
    #[ignore = "needs the codex CLI; set OMUX_CODEX_INTEGRATION=1 and run with --ignored"]
    fn real_server_persists_and_resumes_exact_thread() {
        if std::env::var("OMUX_CODEX_INTEGRATION").as_deref() != Ok("1") {
            return;
        }
        let folder = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join("config.toml"),
            "model_provider = \"omux_test\"\nmodel = \"gpt-6.1-sol\"\n[model_providers.omux_test]\nname = \"Local test\"\nbase_url = \"http://127.0.0.1:1/v1\"\nwire_api = \"responses\"\nrequires_openai_auth = false\nsupports_websockets = false\n",
        )
        .unwrap();
        let mut env: HashMap<String, String> = std::env::vars().collect();
        env.insert("CODEX_HOME".into(), folder.to_string_lossy().into_owned());
        env.remove("OPENAI_API_KEY");
        env.remove("CODEX_API_KEY");
        let (tx, _rx) = async_channel::unbounded();
        let first_client = TabClient::with_env(env.clone());
        let (first, command) = first_client
            .start(&folder, None, "Omux integration test", "0", tx.clone())
            .unwrap();
        assert!(command.starts_with("codex resume --remote 'ws://127.0.0.1:"));
        first_client.close();
        let (resumed, _) = first_client
            .start(&folder, Some(first.clone()), "x", "0", tx.clone())
            .unwrap();
        assert_eq!(resumed, first);
        let independent = TabClient::with_env(env);
        let (third, _) = independent
            .start(&folder, None, "Independent Omux test", "0", tx)
            .unwrap();
        first_client.close();
        assert_eq!(independent.thread_id(), Some(third));
        assert!(
            independent.is_ready(),
            "Closing one server must not stop another"
        );
        independent.close();
        let _ = std::fs::remove_dir_all(&folder);
    }
}
