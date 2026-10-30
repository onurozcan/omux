//! The Codex app-server protocol as a pure state machine: a port of the
//! notification handling in `CodexManager.swift`, without any IO.
//!
//! One `Protocol` belongs to one tab's private server. Feed it decoded JSON
//! messages and it returns `Effect`s (status to publish, subagents changed,
//! follow-up requests to make) for the connection layer to carry out. Keeping
//! it IO-free is what lets the approval/turn bookkeeping be tested with plain
//! JSON vectors.

use std::collections::HashMap;

use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CodexState {
    Idle,
    Working,
    Blocked,
    Done,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexStatus {
    pub state: CodexState,
    pub kind: Option<String>,
    pub detail: Option<String>,
}

impl CodexStatus {
    pub fn new(state: CodexState) -> Self {
        Self {
            state,
            kind: None,
            detail: None,
        }
    }

    fn with(state: CodexState, kind: Option<&str>, detail: Option<&str>) -> Self {
        Self {
            state,
            kind: kind.map(str::to_string),
            detail: detail.map(str::to_string),
        }
    }

    /// Decode a thread status object (`{"type": "active", "activeFlags": [...]}`).
    pub fn decode(raw: &Value) -> Option<Self> {
        match raw.get("type")?.as_str()? {
            "idle" => Some(Self::new(CodexState::Idle)),
            "active" => {
                let flags: Vec<&str> = raw
                    .get("activeFlags")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_str).collect())
                    .unwrap_or_default();
                if flags.contains(&"waitingOnApproval") {
                    Some(Self::with(
                        CodexState::Blocked,
                        Some("approval"),
                        Some("Answer the approval request in Codex"),
                    ))
                } else if flags.contains(&"waitingOnUserInput") {
                    Some(Self::with(
                        CodexState::Blocked,
                        Some("question"),
                        Some("Answer the question in Codex"),
                    ))
                } else {
                    Some(Self::new(CodexState::Working))
                }
            }
            "systemError" => Some(Self::with(
                CodexState::Error,
                None,
                Some("Codex reported an error"),
            )),
            "notLoaded" => Some(Self::with(
                CodexState::Idle,
                None,
                Some("Conversation unloaded"),
            )),
            _ => None,
        }
    }
}

/// JSON-RPC request ids may be numbers or strings; replies echo them as sent.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum RequestId {
    Number(i64),
    Text(String),
}

impl RequestId {
    pub fn from_json(value: Option<&Value>) -> Option<Self> {
        let value = value?;
        if let Some(n) = value.as_i64() {
            Some(Self::Number(n))
        } else {
            value.as_str().map(|s| Self::Text(s.to_string()))
        }
    }

    pub fn to_json(&self) -> Value {
        match self {
            Self::Number(n) => Value::from(*n),
            Self::Text(s) => Value::from(s.clone()),
        }
    }
}

/// A command or file-change approval the server asked the client to answer.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct Approval {
    pub id: RequestId,
    pub thread_id: String,
    pub turn_id: String,
    pub method: String,
    pub detail: String,
}

impl Approval {
    /// Only command and file-change approvals are handled; anything else
    /// (e.g. `item/permissions/requestApproval`) stays in the TUI.
    pub fn from_message(message: &Value) -> Option<Self> {
        let method = message.get("method")?.as_str()?;
        if !matches!(
            method,
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval"
        ) {
            return None;
        }
        let id = RequestId::from_json(message.get("id"))?;
        let params = message.get("params")?;
        let thread = params.get("threadId")?.as_str()?;
        let turn = params.get("turnId")?.as_str()?;
        let detail = params
            .get("command")
            .and_then(Value::as_str)
            .or_else(|| params.get("reason").and_then(Value::as_str))
            .unwrap_or("Approve file changes in Codex");
        Some(Self {
            id,
            thread_id: thread.to_string(),
            turn_id: turn.to_string(),
            method: method.to_string(),
            detail: detail.to_string(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexAgent {
    pub thread_id: String,
    pub name: String,
    /// running | completed | errored | shutdown | interrupted | notFound
    pub state: String,
    pub finished: bool,
}

impl CodexAgent {
    fn new(thread_id: &str, name: &str, state: &str) -> Self {
        Self {
            thread_id: thread_id.to_string(),
            name: name.chars().take(160).collect(),
            state: state.to_string(),
            finished: is_finished(state),
        }
    }

    fn set_state(&mut self, state: &str) {
        self.state = state.to_string();
        self.finished = is_finished(state);
    }
}

fn is_finished(state: &str) -> bool {
    matches!(
        state,
        "completed" | "errored" | "shutdown" | "interrupted" | "notFound"
    )
}

/// What the connection layer must do after a message was applied.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Effective tab status (root status, or blocked/"permission" on an approval).
    Status(CodexStatus),
    ThreadChanged(String),
    Agents(Vec<CodexAgent>),
    /// Resume this subagent thread with turns to learn its current turn.
    SyncAgent(String),
    /// The TUI started a new root: name it if it has no name, then resume it.
    AdoptRoot {
        id: String,
        named: bool,
    },
    /// Sparse `account/rateLimits/updated` params to merge into usage.
    RateLimits(Value),
}

#[derive(Debug, Default)]
pub struct Protocol {
    root: Option<String>,
    agents: Vec<CodexAgent>,
    turns: HashMap<String, String>,
    status: HashMap<String, CodexStatus>,
    completed: HashMap<String, String>,
    approvals: HashMap<String, Vec<Approval>>,
}

fn str_field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

impl Protocol {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn register(&mut self, thread: &str) {
        self.root = Some(thread.to_string());
    }

    pub fn root(&self) -> Option<&str> {
        self.root.as_deref()
    }

    #[cfg(test)]
    pub fn agents(&self) -> &[CodexAgent] {
        &self.agents
    }

    pub fn turn(&self, thread: &str) -> Option<&str> {
        self.turns.get(thread).map(String::as_str)
    }

    pub fn is_agent(&self, thread: &str) -> bool {
        self.agents.iter().any(|a| a.thread_id == thread)
    }

    fn owns(&self, thread: &str) -> bool {
        self.root.as_deref() == Some(thread) || self.is_agent(thread)
    }

    /// Threads to interrupt, subagents first, root last.
    pub fn interrupt_threads(&self) -> Vec<String> {
        let mut ids: Vec<String> = self.agents.iter().map(|a| a.thread_id.clone()).collect();
        ids.extend(self.root.clone());
        ids
    }

    /// First pending approval of the root, else of any subagent.
    pub fn approval(&self) -> Option<&Approval> {
        self.root
            .as_ref()
            .and_then(|r| self.approvals.get(r))
            .and_then(|list| list.first())
            .or_else(|| {
                self.agents
                    .iter()
                    .find_map(|a| self.approvals.get(&a.thread_id).and_then(|l| l.first()))
            })
    }

    /// Forget all activity, keeping the root id (used on disconnect).
    pub fn clear_activity(&mut self, fx: &mut Vec<Effect>) {
        let ids: Vec<String> = self
            .root
            .iter()
            .cloned()
            .chain(self.agents.iter().map(|a| a.thread_id.clone()))
            .collect();
        for id in ids {
            self.approvals.remove(&id);
            self.turns.remove(&id);
            self.status.remove(&id);
            self.completed.remove(&id);
        }
        if !self.agents.is_empty() {
            self.agents.clear();
            fx.push(Effect::Agents(Vec::new()));
        }
    }

    /// Forget the conversation entirely (used when the tab's server is closed).
    pub fn reset(&mut self) {
        let mut ignored = Vec::new();
        self.clear_activity(&mut ignored);
        if let Some(root) = self.root.take() {
            self.approvals.remove(&root);
            self.turns.remove(&root);
            self.status.remove(&root);
            self.completed.remove(&root);
        }
    }

    pub fn publish(&mut self, thread: &str, value: CodexStatus) -> Vec<Effect> {
        let mut fx = Vec::new();
        self.publish_into(thread, value, &mut fx);
        fx
    }

    fn publish_into(&mut self, thread: &str, value: CodexStatus, fx: &mut Vec<Effect>) {
        self.status.insert(thread.to_string(), value);
        if !self.owns(thread) {
            return;
        }
        let Some(root) = self.root.as_ref() else {
            return;
        };
        let mut effective = self
            .status
            .get(root)
            .cloned()
            .unwrap_or_else(|| CodexStatus::new(CodexState::Idle));
        if let Some(approval) = self.approval() {
            effective = CodexStatus::with(
                CodexState::Blocked,
                Some("permission"),
                Some(&approval.detail),
            );
        }
        fx.push(Effect::Status(effective));
    }

    /// Either client may resolve a request; once answered here, drop it
    /// instead of waiting for the server's resolved notification.
    pub fn answered(&mut self, approval: &Approval) -> Vec<Effect> {
        self.remove_approval(&approval.id);
        let state = if self.turns.contains_key(&approval.thread_id) {
            CodexState::Working
        } else {
            CodexState::Idle
        };
        self.publish(&approval.thread_id, CodexStatus::new(state))
    }

    fn remove_approval(&mut self, id: &RequestId) {
        for list in self.approvals.values_mut() {
            list.retain(|a| &a.id != id);
        }
        self.approvals.retain(|_, list| !list.is_empty());
    }

    pub fn receive(&mut self, message: &Value) -> Vec<Effect> {
        let mut fx = Vec::new();
        let Some(method) = str_field(message, "method") else {
            return fx;
        };
        let Some(params) = message.get("params").filter(|p| p.is_object()) else {
            return fx;
        };
        let thread = str_field(params, "threadId");
        if thread.is_some_and(|t| !self.owns(t)) {
            return fx;
        }

        // An approval is recorded only for the thread's live turn (or, before
        // any turn is known, while the thread is working/blocked) and never
        // for a turn that already completed.
        if let Some(approval) = Approval::from_message(message) {
            let id = &approval.thread_id;
            let current = self.turns.get(id);
            let live = current == Some(&approval.turn_id)
                || (current.is_none()
                    && matches!(
                        self.status.get(id).map(|s| s.state),
                        Some(CodexState::Working | CodexState::Blocked)
                    ));
            if self.completed.get(id) != Some(&approval.turn_id) && live {
                let id = approval.thread_id.clone();
                self.turns.insert(id.clone(), approval.turn_id.clone());
                let list = self.approvals.entry(id.clone()).or_default();
                if !list.iter().any(|a| a.id == approval.id) {
                    list.push(approval);
                }
                self.publish_into(&id, CodexStatus::new(CodexState::Blocked), &mut fx);
                return fx;
            }
        }

        match method {
            "thread/started" => self.thread_started(params, &mut fx),
            "item/started" | "item/completed" => {
                let Some(item) = params.get("item") else {
                    return fx;
                };
                if str_field(item, "type") != Some("collabAgentToolCall") {
                    return fx;
                }
                let states = item.get("agentsStates");
                let ids = item.get("receiverThreadIds").and_then(Value::as_array);
                for id in ids.into_iter().flatten().filter_map(Value::as_str) {
                    let state = states
                        .and_then(|s| s.get(id))
                        .and_then(|s| str_field(s, "status"));
                    self.update_agent(id, str_field(item, "prompt"), state, &mut fx);
                }
            }
            "thread/status/changed" => {
                let Some(thread) = thread else {
                    return fx;
                };
                let Some(value) = params.get("status").and_then(CodexStatus::decode) else {
                    return fx;
                };
                let last = self.status.get(thread).map(|s| s.state);
                if value.state == CodexState::Idle
                    && matches!(last, Some(CodexState::Done | CodexState::Error))
                {
                    return fx;
                }
                let state = value.state;
                self.publish_into(thread, value, &mut fx);
                if self.is_agent(thread) {
                    let mapped = match state {
                        CodexState::Working => Some("running"),
                        CodexState::Error => Some("errored"),
                        _ => None,
                    };
                    self.update_agent(thread, None, mapped, &mut fx);
                }
            }
            "turn/started" => {
                let Some(thread) = thread else {
                    return fx;
                };
                let Some(id) = params.get("turn").and_then(|t| str_field(t, "id")) else {
                    return fx;
                };
                self.turns.insert(thread.to_string(), id.to_string());
                self.approvals.remove(thread);
                self.publish_into(thread, CodexStatus::new(CodexState::Working), &mut fx);
            }
            "turn/completed" => {
                let Some(thread) = thread else {
                    return fx;
                };
                let Some(turn) = params.get("turn").filter(|t| t.is_object()) else {
                    return fx;
                };
                let id = str_field(turn, "id");
                if id != self.turns.get(thread).map(String::as_str) {
                    return fx;
                }
                self.turns.remove(thread);
                self.approvals.remove(thread);
                match id {
                    Some(id) => self.completed.insert(thread.to_string(), id.to_string()),
                    None => self.completed.remove(thread),
                };
                let failed = str_field(turn, "status") == Some("failed");
                let detail = turn.get("error").and_then(|e| str_field(e, "message"));
                let state = if failed {
                    CodexState::Error
                } else {
                    CodexState::Done
                };
                self.publish_into(thread, CodexStatus::with(state, None, detail), &mut fx);
                if self.is_agent(thread) {
                    let name = if failed { "errored" } else { "completed" };
                    self.update_agent(thread, None, Some(name), &mut fx);
                }
            }
            "serverRequest/resolved" => {
                let Some(id) = RequestId::from_json(params.get("requestId")) else {
                    return fx;
                };
                self.remove_approval(&id);
                if let Some(thread) = thread {
                    let state = if self.turns.contains_key(thread) {
                        CodexState::Working
                    } else {
                        CodexState::Idle
                    };
                    self.publish_into(thread, CodexStatus::new(state), &mut fx);
                }
            }
            "account/rateLimits/updated" => fx.push(Effect::RateLimits(params.clone())),
            _ => {}
        }
        fx
    }

    fn thread_started(&mut self, params: &Value, fx: &mut Vec<Effect>) {
        let Some(raw) = params.get("thread").filter(|t| t.is_object()) else {
            return;
        };
        let Some(id) = str_field(raw, "id") else {
            return;
        };
        let parent = str_field(raw, "parentThreadId");
        if parent.is_some_and(|p| self.owns(p)) {
            let name = str_field(raw, "agentNickname").or_else(|| str_field(raw, "agentRole"));
            self.update_agent(id, name, None, fx);
            return;
        }
        // A TUI /clear creates a new root conversation. The server is private
        // to this tab, so it can never belong to another one.
        let is_subagent = raw.get("source").and_then(|s| s.get("subAgent")).is_some();
        if parent.is_some() || is_subagent {
            return;
        }
        let Some(current) = self.root.as_deref() else {
            return;
        };
        if current == id {
            return;
        }
        self.clear_activity(fx);
        self.root = Some(id.to_string());
        fx.push(Effect::ThreadChanged(id.to_string()));
        fx.push(Effect::AdoptRoot {
            id: id.to_string(),
            named: str_field(raw, "name").is_some(),
        });
    }

    fn update_agent(
        &mut self,
        id: &str,
        name: Option<&str>,
        state: Option<&str>,
        fx: &mut Vec<Effect>,
    ) {
        if self.root.as_deref() == Some(id) {
            return;
        }
        let before = self.agents.clone();
        if let Some(agent) = self.agents.iter_mut().find(|a| a.thread_id == id) {
            if let Some(name) = name.filter(|n| !n.is_empty()) {
                agent.name = name.chars().take(160).collect();
            }
            if let Some(state) = state {
                agent.set_state(state);
            }
        } else {
            self.agents.push(CodexAgent::new(
                id,
                name.unwrap_or("Codex agent"),
                state.unwrap_or("running"),
            ));
            self.status
                .insert(id.to_string(), CodexStatus::new(CodexState::Working));
            fx.push(Effect::SyncAgent(id.to_string()));
        }
        if self.agents != before {
            fx.push(Effect::Agents(self.agents.clone()));
        }
    }

    /// A resume response includes a turn that may have started before we
    /// subscribed. Live events received while the request was pending win.
    pub fn synchronize_agent(&mut self, thread: &Value) -> Vec<Effect> {
        let mut fx = Vec::new();
        let Some(id) = str_field(thread, "id") else {
            return fx;
        };
        if !self.is_agent(id) {
            return fx;
        }
        let history = thread.get("turns").and_then(Value::as_array);
        let active = history.and_then(|turns| {
            turns
                .iter()
                .rev()
                .find(|t| str_field(t, "status") == Some("inProgress"))
        });
        if let Some(active) = active {
            let Some(turn_id) = str_field(active, "id") else {
                return fx;
            };
            if self.completed.get(id).map(String::as_str) == Some(turn_id)
                || self.turns.contains_key(id)
            {
                return fx;
            }
            self.turns.insert(id.to_string(), turn_id.to_string());
        } else if self.turns.contains_key(id) || self.completed.contains_key(id) {
            return fx;
        }
        if let Some(value) = thread.get("status").and_then(CodexStatus::decode) {
            self.publish_into(id, value, &mut fx);
        }
        fx
    }
}

/// Markdown preview of a `thread/items/list` result (newest first on the wire).
pub fn format_transcript(result: &Value) -> String {
    let entries = result.get("data").and_then(Value::as_array);
    let items: Vec<&Value> = entries
        .into_iter()
        .flatten()
        .filter_map(|e| e.get("item").filter(|i| i.is_object()))
        .collect();
    items
        .iter()
        .rev()
        .filter_map(|item| match str_field(item, "type")? {
            "agentMessage" => str_field(item, "text").map(str::to_string),
            "userMessage" => {
                let content = item.get("content").and_then(Value::as_array);
                let texts: Vec<&str> = content
                    .into_iter()
                    .flatten()
                    .filter_map(|c| str_field(c, "text"))
                    .collect();
                Some(texts.join("\n"))
            }
            "commandExecution" => {
                let output: String = str_field(item, "aggregatedOutput")
                    .unwrap_or("")
                    .chars()
                    .take(6000)
                    .collect();
                Some(format!(
                    "```sh\n{}\n```\n{}",
                    str_field(item, "command").unwrap_or("Command"),
                    output
                ))
            }
            "fileChange" => Some(format!(
                "File changes · {}",
                str_field(item, "status").unwrap_or("")
            )),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tab(root: &str) -> Protocol {
        let mut p = Protocol::new();
        p.register(root);
        p
    }

    fn last_status(fx: &[Effect]) -> Option<&CodexStatus> {
        fx.iter().rev().find_map(|e| match e {
            Effect::Status(s) => Some(s),
            _ => None,
        })
    }

    #[test]
    fn waiting_for_input_is_not_a_tool_approval() {
        let state =
            CodexStatus::decode(&json!({"type": "active", "activeFlags": ["waitingOnUserInput"]}));
        let state = state.unwrap();
        assert_eq!(state.state, CodexState::Blocked);
        assert_eq!(state.kind.as_deref(), Some("question"));
        assert_eq!(
            state.detail.as_deref(),
            Some("Answer the question in Codex")
        );
    }

    #[test]
    fn status_decoding_covers_every_type() {
        let d = |v: Value| CodexStatus::decode(&v);
        assert_eq!(d(json!({"type": "idle"})).unwrap().state, CodexState::Idle);
        assert_eq!(
            d(json!({"type": "active"})).unwrap().state,
            CodexState::Working
        );
        let approval = d(
            json!({"type": "active", "activeFlags": ["waitingOnApproval", "waitingOnUserInput"]}),
        )
        .unwrap();
        assert_eq!(approval.kind.as_deref(), Some("approval"));
        assert_eq!(
            approval.detail.as_deref(),
            Some("Answer the approval request in Codex")
        );
        let error = d(json!({"type": "systemError"})).unwrap();
        assert_eq!(error.state, CodexState::Error);
        assert_eq!(error.detail.as_deref(), Some("Codex reported an error"));
        let unloaded = d(json!({"type": "notLoaded"})).unwrap();
        assert_eq!(unloaded.state, CodexState::Idle);
        assert_eq!(unloaded.detail.as_deref(), Some("Conversation unloaded"));
        assert_eq!(d(json!({"type": "mystery"})), None);
        assert_eq!(d(json!({})), None);
    }

    #[test]
    fn unsupported_permission_requests_stay_in_the_terminal() {
        let message = json!({"method": "item/permissions/requestApproval", "id": 1,
            "params": {"threadId": "a", "turnId": "t"}});
        assert_eq!(Approval::from_message(&message), None);
    }

    #[test]
    fn approval_detail_prefers_command_then_reason() {
        let with = |params: Value| {
            Approval::from_message(
                &json!({"method": "item/fileChange/requestApproval", "id": "r",
                "params": params}),
            )
            .unwrap()
        };
        assert_eq!(
            with(json!({"threadId": "a", "turnId": "t", "command": "ls", "reason": "x"})).detail,
            "ls"
        );
        assert_eq!(
            with(json!({"threadId": "a", "turnId": "t", "reason": "why"})).detail,
            "why"
        );
        assert_eq!(
            with(json!({"threadId": "a", "turnId": "t"})).detail,
            "Approve file changes in Codex"
        );
    }

    #[test]
    fn approvals_are_bound_to_their_thread_and_active_turn() {
        let mut tab_a = tab("a");
        let mut other = tab("b");
        tab_a.receive(&json!({"method": "turn/started", "params": {"threadId": "a", "turn": {"id": "turn-1"}}}));
        let approval = json!({"id": "request-1", "method": "item/commandExecution/requestApproval",
            "params": {"threadId": "a", "turnId": "turn-1", "command": "git status"}});
        other.receive(&approval);
        assert!(tab_a.approval().is_none());
        tab_a.receive(&approval);
        assert_eq!(
            tab_a.approval().unwrap().id,
            RequestId::Text("request-1".into())
        );
        assert!(other.approval().is_none());
        tab_a.receive(&json!({"method": "turn/completed", "params": {"threadId": "a", "turn": {"id": "old-turn", "status": "completed"}}}));
        assert!(tab_a.approval().is_some());
        tab_a.receive(&json!({"method": "serverRequest/resolved", "params": {"threadId": "a", "requestId": "request-1"}}));
        assert!(tab_a.approval().is_none());
        tab_a.receive(&json!({"method": "turn/completed", "params": {"threadId": "a", "turn": {"id": "turn-1", "status": "completed"}}}));
        tab_a.receive(&approval);
        assert!(
            tab_a.approval().is_none(),
            "A late request from a completed turn must not become clickable"
        );
    }

    #[test]
    fn conversation_ids_and_timestamps_decode_without_uuid_assumptions() {
        let row = crate::codex_client::CodexConversation::from_json(
            &json!({"id": "opaque-thread", "cwd": "/tmp/project", "name": "Fix login", "updatedAt": 1000}),
        )
        .unwrap();
        assert_eq!(row.id, "opaque-thread");
        assert_eq!(row.updated_at, 1000);
        assert_eq!(row.name, "Fix login");
        assert!(
            crate::codex_client::CodexConversation::from_json(&json!({"cwd": "/tmp"})).is_none()
        );
    }

    #[test]
    fn identical_request_ids_from_two_servers_resolve_independently() {
        let mut a = Protocol::new();
        let mut b = Protocol::new();
        for (p, thread) in [(&mut a, "a"), (&mut b, "b")] {
            p.register(thread);
            p.receive(&json!({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": "turn"}}}));
            p.receive(
                &json!({"id": 1, "method": "item/commandExecution/requestApproval",
                "params": {"threadId": thread, "turnId": "turn", "command": "git status"}}),
            );
        }
        a.receive(&json!({"method": "serverRequest/resolved", "params": {"threadId": "a", "requestId": 1}}));
        assert!(a.approval().is_none());
        assert!(b.approval().is_some());
    }

    #[test]
    fn new_turn_clears_previous_approval_and_ignores_its_late_completion() {
        let mut p = tab("root");
        p.receive(&json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "old"}}}));
        p.receive(
            &json!({"id": 7, "method": "item/fileChange/requestApproval",
            "params": {"threadId": "root", "turnId": "old"}}),
        );
        assert!(p.approval().is_some());
        p.receive(&json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "new"}}}));
        assert!(p.approval().is_none());
        let fx = p.receive(&json!({"method": "turn/completed", "params": {"threadId": "root", "turn": {"id": "old", "status": "completed"}}}));
        assert!(last_status(&fx).is_none());
    }

    #[test]
    fn child_approvals_appear_under_the_parent_and_clear_on_new_conversation() {
        let mut p = tab("root");
        let other = tab("other");
        p.receive(&json!({"method": "item/started", "params": {"threadId": "root", "item": {
            "type": "collabAgentToolCall", "receiverThreadIds": ["child"], "prompt": "Inspect tests"}}}));
        assert_eq!(p.agents()[0].thread_id, "child");
        assert_eq!(p.agents()[0].name, "Inspect tests");
        p.receive(&json!({"method": "turn/started", "params": {"threadId": "child", "turn": {"id": "child-turn"}}}));
        p.receive(
            &json!({"id": 2, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": "child", "turnId": "child-turn", "command": "git status"}}),
        );
        assert_eq!(p.approval().unwrap().thread_id, "child");
        assert!(other.approval().is_none());
        let fx = p.receive(&json!({"method": "thread/started", "params": {"thread": {"id": "new-root", "source": "cli"}}}));
        assert!(fx.contains(&Effect::ThreadChanged("new-root".into())));
        assert!(fx.contains(&Effect::AdoptRoot {
            id: "new-root".into(),
            named: false
        }));
        assert!(p.approval().is_none());
        assert!(p.agents().is_empty());
        assert_eq!(p.root(), Some("new-root"));
        assert_eq!(other.root(), Some("other"));
    }

    #[test]
    fn late_child_subscription_tracks_completion_without_started_event() {
        let mut p = tab("root");
        let fx = p.receive(
            &json!({"method": "item/started", "params": {"threadId": "root", "item": {
            "type": "collabAgentToolCall", "receiverThreadIds": ["child"]}}}),
        );
        assert!(fx.contains(&Effect::SyncAgent("child".into())));
        assert_eq!(p.agents()[0].name, "Codex agent");
        let snapshot = json!({"id": "child", "status": {"type": "active"},
            "turns": [{"id": "active-turn", "status": "inProgress"}]});
        p.synchronize_agent(&snapshot);
        p.receive(
            &json!({"method": "turn/completed", "params": {"threadId": "child", "turn": {
            "id": "active-turn", "status": "completed"}}}),
        );
        assert_eq!(p.agents()[0].state, "completed");
        assert!(p.agents()[0].finished);
        // A late resume response must not revive a completed turn.
        p.synchronize_agent(&snapshot);
        p.receive(
            &json!({"id": 7, "method": "item/commandExecution/requestApproval", "params": {
            "threadId": "child", "turnId": "active-turn", "command": "git status"}}),
        );
        assert!(p.approval().is_none());
    }

    #[test]
    fn approval_without_known_turn_needs_a_working_thread() {
        let mut p = tab("root");
        let request = json!({"id": 3, "method": "item/commandExecution/requestApproval",
            "params": {"threadId": "root", "turnId": "t", "command": "ls"}});
        p.receive(&request);
        assert!(p.approval().is_none());
        p.publish("root", CodexStatus::new(CodexState::Working));
        let fx = p.receive(&request);
        assert!(p.approval().is_some());
        let status = last_status(&fx).unwrap();
        assert_eq!(status.state, CodexState::Blocked);
        assert_eq!(status.kind.as_deref(), Some("permission"));
        assert_eq!(status.detail.as_deref(), Some("ls"));
        // Duplicate delivery does not duplicate the approval.
        p.receive(&request);
        let approval = p.approval().unwrap().clone();
        let fx = p.answered(&approval);
        assert!(p.approval().is_none());
        assert_eq!(last_status(&fx).unwrap().state, CodexState::Working);
    }

    #[test]
    fn answering_without_a_turn_publishes_idle() {
        let mut p = tab("root");
        p.publish("root", CodexStatus::new(CodexState::Working));
        p.receive(
            &json!({"id": 3, "method": "item/fileChange/requestApproval",
            "params": {"threadId": "root", "turnId": "t"}}),
        );
        p.turns.remove("root");
        let approval = p.approval().unwrap().clone();
        let fx = p.answered(&approval);
        assert_eq!(last_status(&fx).unwrap().state, CodexState::Idle);
    }

    #[test]
    fn turn_completion_publishes_done_or_error_with_message() {
        let mut p = tab("root");
        p.receive(&json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "t1"}}}));
        let fx = p.receive(&json!({"method": "turn/completed", "params": {"threadId": "root", "turn": {"id": "t1", "status": "interrupted"}}}));
        assert_eq!(last_status(&fx).unwrap().state, CodexState::Done);
        p.receive(&json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "t2"}}}));
        let fx = p.receive(
            &json!({"method": "turn/completed", "params": {"threadId": "root", "turn": {
            "id": "t2", "status": "failed", "error": {"message": "boom"}}}}),
        );
        let status = last_status(&fx).unwrap();
        assert_eq!(status.state, CodexState::Error);
        assert_eq!(status.detail.as_deref(), Some("boom"));
    }

    #[test]
    fn idle_after_done_or_error_is_ignored() {
        let mut p = tab("root");
        p.receive(
            &json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "t"}}}),
        );
        p.receive(&json!({"method": "turn/completed", "params": {"threadId": "root", "turn": {"id": "t", "status": "completed"}}}));
        let fx = p.receive(&json!({"method": "thread/status/changed", "params": {"threadId": "root", "status": {"type": "idle"}}}));
        assert!(fx.is_empty());
        let fx = p.receive(&json!({"method": "thread/status/changed", "params": {"threadId": "root", "status": {"type": "active"}}}));
        assert_eq!(last_status(&fx).unwrap().state, CodexState::Working);
    }

    #[test]
    fn subagents_come_from_thread_started_and_follow_status() {
        let mut p = tab("root");
        p.receive(&json!({"method": "thread/started", "params": {"thread": {
            "id": "kid", "parentThreadId": "root", "agentNickname": "Scout", "agentRole": "explorer"}}}));
        assert_eq!(p.agents()[0].name, "Scout");
        p.receive(&json!({"method": "thread/status/changed", "params": {"threadId": "kid", "status": {"type": "systemError"}}}));
        assert_eq!(p.agents()[0].state, "errored");
        assert!(p.agents()[0].finished);
        // A thread whose parent is somebody else's is neither agent nor root.
        let fx = p.receive(&json!({"method": "thread/started", "params": {"thread": {
            "id": "stranger", "parentThreadId": "elsewhere"}}}));
        assert!(fx.is_empty());
        let fx = p.receive(&json!({"method": "thread/started", "params": {"thread": {
            "id": "sub", "source": {"subAgent": {}}}}}));
        assert!(fx.is_empty());
        assert_eq!(p.root(), Some("root"));
    }

    #[test]
    fn agent_names_are_truncated_and_default() {
        let mut p = tab("root");
        let long = "x".repeat(300);
        p.receive(
            &json!({"method": "item/started", "params": {"threadId": "root", "item": {
            "type": "collabAgentToolCall", "receiverThreadIds": ["a", "b"], "prompt": long,
            "agentsStates": {"a": {"status": "completed"}}}}}),
        );
        assert_eq!(p.agents()[0].name.chars().count(), 160);
        assert_eq!(p.agents()[0].state, "completed");
        assert_eq!(p.agents()[1].state, "running");
        assert!(!p.agents()[1].finished);
    }

    #[test]
    fn same_conversation_thread_started_is_not_a_replacement() {
        let mut p = tab("root");
        let fx =
            p.receive(&json!({"method": "thread/started", "params": {"thread": {"id": "root"}}}));
        assert!(fx.is_empty());
        let fx = p.receive(&json!({"method": "thread/started", "params": {"thread": {"id": "n", "name": "Named"}}}));
        assert!(fx.contains(&Effect::AdoptRoot {
            id: "n".into(),
            named: true
        }));
    }

    #[test]
    fn notifications_for_foreign_threads_are_dropped() {
        let mut p = tab("root");
        let fx = p.receive(&json!({"method": "turn/started", "params": {"threadId": "other", "turn": {"id": "t"}}}));
        assert!(fx.is_empty());
        assert!(p.turn("other").is_none());
    }

    #[test]
    fn rate_limit_updates_are_forwarded() {
        let mut p = tab("root");
        let params = json!({"rateLimits": {"primary": {"usedPercent": 15}}});
        let fx =
            p.receive(&json!({"method": "account/rateLimits/updated", "params": params.clone()}));
        assert_eq!(fx, vec![Effect::RateLimits(params)]);
    }

    #[test]
    fn disconnect_clears_activity_but_keeps_the_root() {
        let mut p = tab("root");
        p.receive(
            &json!({"method": "turn/started", "params": {"threadId": "root", "turn": {"id": "t"}}}),
        );
        p.receive(
            &json!({"method": "item/started", "params": {"threadId": "root", "item": {
            "type": "collabAgentToolCall", "receiverThreadIds": ["kid"]}}}),
        );
        let mut fx = Vec::new();
        p.clear_activity(&mut fx);
        assert_eq!(fx, vec![Effect::Agents(vec![])]);
        assert!(p.turn("root").is_none());
        assert_eq!(p.root(), Some("root"));
        p.reset();
        assert_eq!(p.root(), None);
    }

    #[test]
    fn interrupt_order_is_agents_then_root() {
        let mut p = tab("root");
        p.receive(
            &json!({"method": "item/started", "params": {"threadId": "root", "item": {
            "type": "collabAgentToolCall", "receiverThreadIds": ["a", "b"]}}}),
        );
        assert_eq!(p.interrupt_threads(), vec!["a", "b", "root"]);
    }

    #[test]
    fn transcript_formats_items_chronologically() {
        let result = json!({"data": [
            {"item": {"type": "fileChange", "status": "completed"}},
            {"item": {"type": "commandExecution", "command": "ls", "aggregatedOutput": "a\nb"}},
            {"item": {"type": "commandExecution"}},
            {"item": {"type": "reasoning", "text": "skip"}},
            {"item": {"type": "agentMessage", "text": "Done."}},
            {"item": {"type": "userMessage", "content": [{"type": "text", "text": "one"}, {"type": "image"}, {"text": "two"}]}},
            {"notAnItem": true},
        ]});
        assert_eq!(
            format_transcript(&result),
            "one\ntwo\n\nDone.\n\n```sh\nCommand\n```\n\n\n```sh\nls\n```\na\nb\n\nFile changes · completed"
        );
        assert_eq!(format_transcript(&json!({})), "");
    }

    #[test]
    fn transcript_output_is_capped_at_6000_characters() {
        let output = "é".repeat(7000);
        let result = json!({"data": [{"item": {"type": "commandExecution", "command": "c", "aggregatedOutput": output}}]});
        let text = format_transcript(&result);
        assert_eq!(text.chars().filter(|c| *c == 'é').count(), 6000);
    }
}
