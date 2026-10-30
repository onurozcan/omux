//! OSC 7501 "program status" records: a port of SwiftTerm 1.99.1
//! `ProgramStatus.swift`, which is what the Mac app reads Claude Code's
//! working / needs-you / done state from.
//!
//! Each report replaces one record. A report without `id` replaces the root
//! record; other ids are paths such as `build/test`. `state=clear` removes a
//! record and its descendants (all records without an id).

use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Idle,
    Working,
    Done,
    Blocked,
    Error,
}

impl State {
    fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "idle" => Self::Idle,
            "working" => Self::Working,
            "done" => Self::Done,
            "blocked" => Self::Blocked,
            "error" => Self::Error,
            _ => return None,
        })
    }
}

/// Why a blocked program waits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Permission,
    Question,
    Auth,
}

impl Kind {
    fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "permission" => Self::Permission,
            "question" => Self::Question,
            "auth" => Self::Auth,
            _ => return None,
        })
    }

    pub fn raw(self) -> &'static str {
        match self {
            Self::Permission => "permission",
            Self::Question => "question",
            Self::Auth => "auth",
        }
    }
}

/// One record. Text is plain UTF-8 without control characters, but it comes
/// from the program, so treat it as untrusted when showing it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    /// The record path. Empty for the root record.
    pub id: String,
    pub state: State,
    pub kind: Option<Kind>,
    pub progress: Option<u8>,
    /// The program name in this record's last report.
    pub app: Option<String>,
    /// The program name from this record or its nearest ancestor with a name.
    pub effective_app: Option<String>,
    pub title: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Report {
    Clear(String),
    Replace(Record),
}

const MAX_RECORDS: usize = 256;
/// The parser bounds the OSC code and framing bytes; this is the payload cap.
pub const MAX_PAYLOAD: usize = 4087;

#[derive(Debug, Default)]
pub struct Store {
    records: HashMap<String, Record>,
    /// Oldest update first. Reads do not change this order.
    order: Vec<String>,
}

impl Store {
    /// Current records, oldest update first, with `effective_app` filled in.
    pub fn snapshots(&self) -> Vec<Record> {
        self.order
            .iter()
            .filter_map(|id| self.snapshot(id))
            .collect()
    }

    pub fn snapshot(&self, id: &str) -> Option<Record> {
        let mut record = self.records.get(id)?.clone();
        let mut ancestor = id.to_string();
        loop {
            if let Some(app) = self.records.get(&ancestor).and_then(|r| r.app.clone()) {
                record.effective_app = Some(app);
                break;
            }
            if ancestor.is_empty() {
                break;
            }
            match ancestor.rfind('/') {
                Some(slash) => ancestor.truncate(slash),
                None => ancestor.clear(),
            }
        }
        Some(record)
    }

    /// Applies a report; returns whether the records changed.
    pub fn apply(&mut self, report: Report) -> bool {
        match report {
            Report::Clear(id) => self.clear(&id),
            Report::Replace(record) => {
                self.order.retain(|id| *id != record.id);
                if !self.records.contains_key(&record.id) && self.records.len() == MAX_RECORDS {
                    let oldest = self.order.remove(0);
                    self.records.remove(&oldest);
                }
                self.order.push(record.id.clone());
                self.records.insert(record.id.clone(), record);
                true
            }
        }
    }

    /// Removes a record and its descendants. An empty id removes all records.
    pub fn clear(&mut self, id: &str) -> bool {
        let prefix = format!("{id}/");
        self.remove(|r| id.is_empty() || r.id == id || r.id.starts_with(&prefix))
    }

    /// After the process exits, or a new shell prompt starts (OSC 133 A):
    /// working and blocked records go, others remain.
    pub fn remove_active(&mut self) -> bool {
        self.remove(|r| matches!(r.state, State::Working | State::Blocked))
    }

    fn remove(&mut self, predicate: impl Fn(&Record) -> bool) -> bool {
        let ids: Vec<String> = self
            .order
            .iter()
            .filter(|id| self.records.get(*id).is_some_and(&predicate))
            .cloned()
            .collect();
        if ids.is_empty() {
            return false;
        }
        for id in &ids {
            self.records.remove(id);
        }
        self.order.retain(|id| self.records.contains_key(id));
        true
    }
}

/// Parses an OSC 7501 payload (the bytes after `7501;`). Invalid base64 or a
/// field over its size limit discards the whole report; malformed pairs and
/// unknown keys are ignored.
pub fn parse(data: &[u8]) -> Option<Report> {
    if data.len() > MAX_PAYLOAD {
        return None;
    }
    let mut fields: HashMap<&'static str, String> = HashMap::new();
    for pair in data.split(|b| *b == b':') {
        let Some(equal) = pair.iter().position(|b| *b == b'=') else {
            continue;
        };
        let key = trim(&pair[..equal]);
        let value = trim(&pair[equal + 1..]);
        if key.len() > 16 {
            return None;
        }
        if key.is_empty() || !key.iter().all(|b| b.is_ascii_lowercase()) {
            continue;
        }
        let name: &'static str = match key {
            b"msg" => "msg",
            b"title" => "title",
            b"app" => "app",
            b"id" => "id",
            b"state" => "state",
            b"kind" => "kind",
            b"progress" => "progress",
            _ => {
                continue;
            }
        };
        let limit = match name {
            "msg" => Some(2732),
            "title" => Some(256),
            "app" => Some(32),
            "id" => Some(128),
            _ => None,
        };
        if limit.is_some_and(|limit| value.len() > limit) {
            return None;
        }
        // A malformed id must never select the root record.
        if name == "id" && !valid_id(value) {
            return None;
        }
        if !value.iter().all(|b| is_value_byte(*b)) {
            continue;
        }
        let text = match name {
            "msg" | "title" => {
                let decoded_limit = if name == "msg" { 2048 } else { 192 };
                decode_text(value, decoded_limit)?
            }
            _ => String::from_utf8_lossy(value).into_owned(),
        };
        fields.insert(name, text);
    }
    let id = fields.get("id").cloned().unwrap_or_default();
    let state_text = fields.get("state")?;
    if state_text == "clear" {
        return Some(Report::Clear(id));
    }
    let state = State::parse(state_text)?;
    let kind = if state == State::Blocked {
        fields.get("kind").and_then(|k| Kind::parse(k))
    } else {
        None
    };
    let progress = match state {
        State::Working | State::Blocked => fields
            .get("progress")
            .filter(|t| !t.is_empty() && t.bytes().all(|b| b.is_ascii_digit()))
            .and_then(|t| t.parse::<u32>().ok())
            .filter(|n| *n <= 100)
            .map(|n| n as u8),
        _ => None,
    };
    let app = fields
        .get("app")
        .filter(|a| valid_segment(a.as_bytes()))
        .cloned();
    Some(Report::Replace(Record {
        id,
        state,
        kind,
        progress,
        effective_app: app.clone(),
        app,
        title: fields.get("title").cloned(),
        message: fields.get("msg").cloned(),
    }))
}

fn trim(bytes: &[u8]) -> &[u8] {
    let ws = |b: &u8| *b == b' ' || (9..=13).contains(b);
    let start = bytes.iter().position(|b| !ws(b)).unwrap_or(bytes.len());
    let end = bytes.iter().rposition(|b| !ws(b)).map_or(start, |i| i + 1);
    &bytes[start..end.max(start)]
}

fn is_value_byte(b: u8) -> bool {
    b.is_ascii_alphanumeric() || b"_.,+/=-".contains(&b)
}

fn valid_segment(bytes: &[u8]) -> bool {
    (1..=32).contains(&bytes.len())
        && bytes
            .iter()
            .all(|b| b.is_ascii_alphanumeric() || b"_.+-".contains(b))
}

fn valid_id(bytes: &[u8]) -> bool {
    if bytes.is_empty() || bytes.len() > 128 {
        return false;
    }
    let segments: Vec<&[u8]> = bytes.split(|b| *b == b'/').collect();
    segments.len() <= 8 && segments.iter().all(|s| valid_segment(s))
}

/// Standard base64 with optional padding; the result must be valid UTF-8
/// without control characters.
fn decode_text(bytes: &[u8], limit: usize) -> Option<String> {
    let content_len = bytes.iter().position(|b| *b == b'=').unwrap_or(bytes.len());
    let content = &bytes[..content_len];
    let padding = bytes.len() - content_len;
    let remainder = content.len() % 4;
    if remainder == 1 || padding > 2 || !bytes[content_len..].iter().all(|b| *b == b'=') {
        return None;
    }
    if padding != 0 && !(bytes.len() % 4 == 0 && padding == 4 - remainder) {
        return None;
    }
    let mut decoded = Vec::new();
    let mut bits: u32 = 0;
    let mut count = 0;
    for &byte in content {
        let value = match byte {
            b'A'..=b'Z' => byte - b'A',
            b'a'..=b'z' => byte - b'a' + 26,
            b'0'..=b'9' => byte - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32;
        bits = (bits << 6) | value;
        count += 6;
        if count >= 8 {
            count -= 8;
            decoded.push(((bits >> count) & 255) as u8);
            if decoded.len() > limit {
                return None;
            }
            bits &= (1 << count) - 1;
        }
    }
    if bits != 0 {
        return None;
    }
    let text = String::from_utf8(decoded).ok()?;
    if text
        .chars()
        .any(|c| (c as u32) <= 31 || (127..=159).contains(&(c as u32)))
    {
        return None;
    }
    Some(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(data: &str) -> Record {
        match parse(data.as_bytes()) {
            Some(Report::Replace(r)) => r,
            other => panic!("expected a record, got {other:?}"),
        }
    }

    #[test]
    fn parses_root_blocked_permission_with_message() {
        // "Allow Bash?" in base64
        let r = record("state=blocked:kind=permission:app=claude:msg=QWxsb3cgQmFzaD8=");
        assert_eq!(r.id, "");
        assert_eq!(r.state, State::Blocked);
        assert_eq!(r.kind, Some(Kind::Permission));
        assert_eq!(r.app.as_deref(), Some("claude"));
        assert_eq!(r.message.as_deref(), Some("Allow Bash?"));
    }

    #[test]
    fn kind_only_counts_when_blocked_and_progress_only_when_active() {
        let r = record("state=done:kind=permission:progress=50");
        assert_eq!(r.kind, None);
        assert_eq!(r.progress, None);
        let r = record("state=working:progress=42");
        assert_eq!(r.progress, Some(42));
        assert_eq!(record("state=working:progress=101").progress, None);
    }

    #[test]
    fn invalid_reports_are_discarded() {
        assert!(parse(b"state=bogus").is_none());
        assert!(parse(b"kind=permission").is_none());
        // Bytes outside the value alphabet make the pair malformed, so it's skipped.
        assert_eq!(record("state=working:msg=!!!").message, None);
        assert!(parse(b"state=working:msg=QQ=").is_none(), "wrong padding");
        assert!(
            parse(b"state=working:id=a//b").is_none(),
            "empty id segment"
        );
        assert!(
            parse(b"state=working:id=a/b/c/d/e/f/g/h/i").is_none(),
            "too deep"
        );
        // A control character inside the decoded text discards the report.
        assert!(parse(b"state=working:msg=AQ==").is_none());
    }

    #[test]
    fn whitespace_and_unknown_keys_are_tolerated() {
        let r = record(" state = working : extra=1 : id=agent-1/sub ");
        assert_eq!(r.state, State::Working);
        assert_eq!(r.id, "agent-1/sub");
    }

    #[test]
    fn clear_removes_record_and_descendants() {
        let mut store = Store::default();
        for data in [
            "state=working",
            "state=working:id=a",
            "state=blocked:id=a/b",
            "state=done:id=ab",
        ] {
            store.apply(parse(data.as_bytes()).unwrap());
        }
        store.apply(parse(b"state=clear:id=a").unwrap());
        let ids: Vec<String> = store.snapshots().into_iter().map(|r| r.id).collect();
        assert_eq!(ids, vec!["".to_string(), "ab".to_string()]);
        store.apply(parse(b"state=clear").unwrap());
        assert!(store.snapshots().is_empty());
    }

    #[test]
    fn effective_app_comes_from_nearest_named_ancestor() {
        let mut store = Store::default();
        store.apply(parse(b"state=working:app=claude").unwrap());
        store.apply(parse(b"state=working:id=agent-x/tool").unwrap());
        let child = store.snapshot("agent-x/tool").unwrap();
        assert_eq!(child.app, None);
        assert_eq!(child.effective_app.as_deref(), Some("claude"));
    }

    #[test]
    fn replacing_moves_record_to_newest() {
        let mut store = Store::default();
        store.apply(parse(b"state=working:id=a").unwrap());
        store.apply(parse(b"state=working:id=b").unwrap());
        store.apply(parse(b"state=done:id=a").unwrap());
        let ids: Vec<String> = store.snapshots().into_iter().map(|r| r.id).collect();
        assert_eq!(ids, vec!["b", "a"]);
    }

    #[test]
    fn store_keeps_at_most_256_records() {
        let mut store = Store::default();
        for i in 0..300 {
            store.apply(parse(format!("state=working:id=r{i}").as_bytes()).unwrap());
        }
        let snaps = store.snapshots();
        assert_eq!(snaps.len(), 256);
        assert_eq!(snaps[0].id, "r44");
    }

    #[test]
    fn remove_active_keeps_done_and_error() {
        let mut store = Store::default();
        for data in [
            "state=working",
            "state=blocked:id=a",
            "state=done:id=b",
            "state=error:id=c",
        ] {
            store.apply(parse(data.as_bytes()).unwrap());
        }
        assert!(store.remove_active());
        let ids: Vec<String> = store.snapshots().into_iter().map(|r| r.id).collect();
        assert_eq!(ids, vec!["b", "c"]);
    }
}
