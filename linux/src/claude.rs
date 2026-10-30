//! Claude Code's files: conversations, subagents and their transcripts.
//!
//! Claude Code keeps each conversation as `~/.claude/projects/<project>/<id>.jsonl`
//! and each subagent of a session as
//! `<project>/<session>/subagents/agent-<id>.meta.json` with its transcript
//! next to it as `agent-<id>.jsonl`.

use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

use serde_json::Value;
use uuid::Uuid;

use crate::persistence::home_dir;

/// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
pub fn config_dir() -> PathBuf {
    match std::env::var("CLAUDE_CONFIG_DIR") {
        Ok(dir) if !dir.is_empty() => PathBuf::from(dir),
        _ => home_dir().join(".claude"),
    }
}

pub fn projects_dir() -> PathBuf {
    config_dir().join("projects")
}

fn project_dirs() -> Vec<PathBuf> {
    std::fs::read_dir(projects_dir())
        .map(|entries| entries.flatten().map(|e| e.path()).collect())
        .unwrap_or_default()
}

/// Whether Claude has a transcript for this session id, in any project
/// folder (decides `--resume` over `--session-id`).
pub fn conversation_exists(session: Uuid) -> bool {
    let name = format!("{}.jsonl", session.to_string().to_lowercase());
    project_dirs().iter().any(|dir| dir.join(&name).is_file())
}

// MARK: recent conversations

#[derive(Debug, Clone)]
pub struct RecentSession {
    pub id: Uuid,
    pub cwd: String,
    /// The first real prompt, on one line.
    pub prompt: String,
    pub date: SystemTime,
}

impl RecentSession {
    /// The first five words, at most 32 characters.
    pub fn tab_name(&self) -> String {
        let words: Vec<&str> = self
            .prompt
            .split(' ')
            .filter(|w| !w.is_empty())
            .take(5)
            .collect();
        let name = words.join(" ");
        if name.is_empty() {
            "Session".into()
        } else if name.chars().count() > 32 {
            format!("{}…", name.chars().take(32).collect::<String>())
        } else {
            name
        }
    }
}

/// The 300 most recently modified conversations that start with a real prompt.
pub fn recent_sessions() -> Vec<RecentSession> {
    let mut files: Vec<(PathBuf, SystemTime)> = project_dirs()
        .iter()
        .filter_map(|dir| std::fs::read_dir(dir).ok())
        .flat_map(|entries| entries.flatten())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "jsonl"))
        .filter_map(|p| {
            let date = p.metadata().and_then(|m| m.modified()).ok()?;
            Some((p, date))
        })
        .collect();
    files.sort_by_key(|a| std::cmp::Reverse(a.1));
    files.truncate(300);
    files
        .into_iter()
        .filter_map(|(path, date)| {
            let id = Uuid::parse_str(path.file_stem()?.to_str()?).ok()?;
            let (cwd, prompt) = first_prompt(&path)?;
            Some(RecentSession {
                id,
                cwd,
                prompt,
                date,
            })
        })
        .collect()
}

/// The first user message with a cwd and text that isn't a slash command or
/// system message (those start with `<`), from the first 128 KiB.
fn first_prompt(path: &Path) -> Option<(String, String)> {
    let mut head = Vec::new();
    File::open(path)
        .ok()?
        .take(128 * 1024)
        .read_to_end(&mut head)
        .ok()?;
    // The 128 KiB cut can split a multi-byte character (Turkish, CJK):
    // keep the valid part instead of dropping the conversation.
    let text = match std::str::from_utf8(&head) {
        Ok(text) => text,
        Err(err) => std::str::from_utf8(&head[..err.valid_up_to()]).ok()?,
    };
    text.split('\n').find_map(|line| {
        let object: Value = serde_json::from_str(line).ok()?;
        if object.get("type")?.as_str()? != "user" {
            return None;
        }
        let cwd = object.get("cwd")?.as_str()?.to_string();
        let content = object.get("message")?.get("content")?;
        let prompt = match content {
            Value::String(s) => s.clone(),
            Value::Array(items) => items
                .iter()
                .filter_map(|i| i.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join(" "),
            _ => return None,
        };
        let prompt = prompt.trim();
        if prompt.is_empty() || prompt.starts_with('<') {
            return None;
        }
        Some((cwd, prompt.replace('\n', " ")))
    })
}

// MARK: transcripts

/// Reads only what was appended to a JSONL file since the last call. A
/// partial last line waits for the next read.
#[derive(Debug, Default)]
pub struct JsonlReader {
    offset: u64,
    remainder: Vec<u8>,
}

impl JsonlReader {
    pub fn read(&mut self, path: &Path) -> Vec<Value> {
        let Ok(mut file) = File::open(path) else {
            return Vec::new();
        };
        let Ok(size) = file.seek(SeekFrom::End(0)) else {
            return Vec::new();
        };
        if size <= self.offset || file.seek(SeekFrom::Start(self.offset)).is_err() {
            return Vec::new();
        }
        let mut chunk = Vec::new();
        let _ = (&mut file)
            .take((size - self.offset).min(64 << 20))
            .read_to_end(&mut chunk);
        self.offset += chunk.len() as u64;
        let mut data = std::mem::take(&mut self.remainder);
        data.extend(chunk);
        let Some(end) = data.iter().rposition(|b| *b == b'\n') else {
            self.remainder = data;
            return Vec::new();
        };
        self.remainder = data[end + 1..].to_vec();
        data[..end]
            .split(|b| *b == b'\n')
            .filter_map(|line| serde_json::from_slice(line).ok())
            .collect()
    }
}

/// `Grep "useTheme"`, `Read app.tsx`, `Bash npm test`.
pub fn tool_summary(name: &str, input: &Value) -> String {
    let get = |key: &str| input.get(key).and_then(Value::as_str);
    let mut detail = if let Some(command) = get("command") {
        command.to_string()
    } else if let Some(path) = get("file_path").or_else(|| get("notebook_path")) {
        Path::new(path)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.to_string())
    } else if let Some(pattern) = get("pattern") {
        format!("\"{pattern}\"")
    } else {
        ["url", "query", "description", "prompt", "path"]
            .iter()
            .find_map(|k| get(k))
            .unwrap_or("")
            .to_string()
    };
    detail = detail.replace('\n', " ");
    if detail.chars().count() > 90 {
        detail = format!("{}…", detail.chars().take(90).collect::<String>());
    }
    if detail.is_empty() {
        name.to_string()
    } else {
        format!("{name} {detail}")
    }
}

/// A string, or the text items of a content array joined by newlines.
pub fn content_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(items) => items
            .iter()
            .filter(|i| i.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|i| i.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => String::new(),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptEvent {
    /// The prompt the agent was started with.
    Task(String),
    Text(String),
    Tool {
        id: String,
        title: String,
    },
    Result {
        id: String,
        text: String,
        error: bool,
    },
}

/// Turns transcript lines into display events. `first_load` is true while the
/// view has no entries yet, so the first user string is the task.
pub fn transcript_events(objects: &[Value], mut has_task: bool) -> Vec<TranscriptEvent> {
    let mut events = Vec::new();
    for object in objects {
        let kind = object.get("type").and_then(Value::as_str);
        let Some(content) = object.get("message").and_then(|m| m.get("content")) else {
            continue;
        };
        match (kind, content) {
            (Some("user"), Value::Array(items)) => {
                for item in items {
                    if item.get("type").and_then(Value::as_str) != Some("tool_result") {
                        continue;
                    }
                    events.push(TranscriptEvent::Result {
                        id: item
                            .get("tool_use_id")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .into(),
                        text: item.get("content").map(content_text).unwrap_or_default(),
                        error: item
                            .get("is_error")
                            .and_then(Value::as_bool)
                            .unwrap_or(false),
                    });
                }
            }
            (Some("user"), Value::String(text)) if !text.is_empty() => {
                if has_task {
                    events.push(TranscriptEvent::Text(text.clone()));
                } else {
                    has_task = true;
                    events.push(TranscriptEvent::Task(text.clone()));
                }
            }
            (Some("assistant"), Value::Array(items)) => {
                for item in items {
                    match item.get("type").and_then(Value::as_str) {
                        Some("text") => {
                            let text = item
                                .get("text")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .trim();
                            if !text.is_empty() {
                                events.push(TranscriptEvent::Text(text.to_string()));
                            }
                        }
                        Some("tool_use") => events.push(TranscriptEvent::Tool {
                            id: item
                                .get("id")
                                .and_then(Value::as_str)
                                .map(str::to_string)
                                .unwrap_or_else(|| Uuid::new_v4().to_string()),
                            title: tool_summary(
                                item.get("name").and_then(Value::as_str).unwrap_or("Tool"),
                                item.get("input").unwrap_or(&Value::Null),
                            ),
                        }),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
    }
    events
}

// MARK: subagents

#[derive(Debug, Clone, PartialEq)]
pub struct SubAgent {
    pub id: String,
    pub kind: String,
    pub description: String,
    pub background: bool,
    pub depth: usize,
    pub finished: bool,
    pub started: SystemTime,
    pub ended: Option<SystemTime>,
    pub transcript: PathBuf,
    pub activity: Option<String>,
    pub tool_count: usize,
    /// Set when one of the session's OSC 7501 child records is blocked and
    /// describes this agent.
    pub blocked: bool,
}

impl SubAgent {
    pub fn elapsed_text(&self) -> String {
        let end = self.ended.unwrap_or_else(SystemTime::now);
        let seconds = end
            .duration_since(self.started)
            .unwrap_or_default()
            .as_secs();
        if seconds >= 3600 {
            format!("{}h {}m", seconds / 3600, seconds % 3600 / 60)
        } else {
            format!("{}:{:02}", seconds / 60, seconds % 60)
        }
    }

    /// `orange`, `green` or `blue`.
    pub fn color(&self) -> &'static str {
        if self.blocked {
            "orange"
        } else if self.finished {
            "green"
        } else {
            "blue"
        }
    }

    /// The tool it's using, for tight spaces: "Grep".
    pub fn short_activity(&self) -> String {
        if self.blocked {
            "needs you".into()
        } else if self.finished {
            "done".into()
        } else {
            self.activity
                .as_deref()
                .and_then(|a| a.split(' ').next())
                .unwrap_or("starting")
                .to_string()
        }
    }

    /// Whether an OSC 7501 child record describes this agent: by id, or by
    /// the description it was launched with.
    pub fn matches(&self, id: &str, title: Option<&str>, message: Option<&str>) -> bool {
        let short = self.id.replace("agent-", "");
        if id.contains(&short) {
            return true;
        }
        let description = self.description.to_lowercase();
        [title, message]
            .into_iter()
            .flatten()
            .any(|t| t.to_lowercase().contains(&description))
    }
}

#[derive(Default)]
struct Progress {
    reader: JsonlReader,
    tools: usize,
    activity: Option<String>,
}

/// How long a finished agent stays listed.
const LINGER_FOREGROUND: Duration = Duration::from_secs(20);
const LINGER_BACKGROUND: Duration = Duration::from_secs(120);

/// The file work behind the subagent list. Keeps per-transcript progress so
/// each scan reads only what was appended.
#[derive(Default)]
pub struct AgentScanner {
    folders: HashMap<Uuid, PathBuf>,
    misses: HashMap<Uuid, Instant>,
    progress: HashMap<PathBuf, Progress>,
}

impl AgentScanner {
    /// Agents worth showing for a session: running ones (only while the
    /// session is active), and finished ones for a short while.
    pub fn scan(&mut self, session: Uuid, active: bool) -> Vec<SubAgent> {
        let Some(folder) = self.folder(session) else {
            return Vec::new();
        };
        let now = SystemTime::now();
        let age = |t: SystemTime| now.duration_since(t).unwrap_or_default();
        let mut agents = Vec::new();
        let Ok(entries) = std::fs::read_dir(&folder) else {
            return agents;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let Some(id) = name.strip_suffix(".meta.json") else {
                continue;
            };
            let meta_path = entry.path();
            let transcript = folder.join(format!("{id}.jsonl"));
            let meta_date = modified(&meta_path).unwrap_or(SystemTime::UNIX_EPOCH);
            let transcript_date = modified(&transcript).unwrap_or(meta_date);
            // Old agents are skipped by date alone, without opening their files.
            let recently_written = age(transcript_date) < Duration::from_secs(1800);
            if !(age(meta_date) < LINGER_BACKGROUND || (active && recently_written)) {
                continue;
            }
            let Some(meta) = std::fs::read(&meta_path)
                .ok()
                .and_then(|d| serde_json::from_slice::<Value>(&d).ok())
            else {
                continue;
            };
            let field = |k: &str| meta.get(k);
            let finished = field("finished").and_then(Value::as_bool).unwrap_or(false);
            let background = field("requestShape").and_then(Value::as_str) == Some("background");
            if finished {
                let linger = if background {
                    LINGER_BACKGROUND
                } else {
                    LINGER_FOREGROUND
                };
                if age(meta_date) >= linger {
                    continue;
                }
            } else if !(active && recently_written) {
                continue;
            }
            let progress = self.progress.entry(transcript.clone()).or_default();
            for object in progress.reader.read(&transcript) {
                if object.get("type").and_then(Value::as_str) != Some("assistant") {
                    continue;
                }
                let Some(items) = object
                    .get("message")
                    .and_then(|m| m.get("content"))
                    .and_then(Value::as_array)
                else {
                    continue;
                };
                for item in items {
                    if item.get("type").and_then(Value::as_str) == Some("tool_use") {
                        progress.tools += 1;
                        progress.activity = Some(tool_summary(
                            item.get("name").and_then(Value::as_str).unwrap_or("Tool"),
                            item.get("input").unwrap_or(&Value::Null),
                        ));
                    }
                }
            }
            // Birth time where the filesystem records it, else the meta date.
            let started = transcript
                .metadata()
                .and_then(|m| m.created())
                .unwrap_or(meta_date);
            agents.push(SubAgent {
                id: id.to_string(),
                kind: field("agentType")
                    .and_then(Value::as_str)
                    .unwrap_or("agent")
                    .to_string(),
                description: field("description")
                    .and_then(Value::as_str)
                    .unwrap_or(id)
                    .to_string(),
                background,
                depth: field("spawnDepth")
                    .and_then(Value::as_u64)
                    .unwrap_or(1)
                    .max(1) as usize,
                finished,
                started,
                ended: finished.then_some(meta_date),
                transcript,
                activity: progress.activity.clone(),
                tool_count: progress.tools,
                blocked: false,
            });
        }
        agents.sort_by_key(|a| a.started);
        agents
    }

    /// The session's subagents folder; it appears with the first subagent.
    fn folder(&mut self, session: Uuid) -> Option<PathBuf> {
        if let Some(folder) = self.folders.get(&session) {
            return Some(folder.clone());
        }
        if self
            .misses
            .get(&session)
            .is_some_and(|miss| miss.elapsed() < Duration::from_secs(3))
        {
            return None;
        }
        let name = session.to_string().to_lowercase();
        let found = project_dirs()
            .into_iter()
            .map(|dir| dir.join(&name).join("subagents"))
            .find(|dir| dir.is_dir());
        match found {
            Some(folder) => {
                self.folders.insert(session, folder.clone());
                Some(folder)
            }
            None => {
                self.misses.insert(session, Instant::now());
                None
            }
        }
    }
}

fn modified(path: &Path) -> Option<SystemTime> {
    path.metadata().and_then(|m| m.modified()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("omux-claude-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn summaries() {
        assert_eq!(
            tool_summary("Grep", &json!({"pattern": "useTheme"})),
            "Grep \"useTheme\""
        );
        assert_eq!(
            tool_summary("Read", &json!({"file_path": "/src/app.tsx"})),
            "Read app.tsx"
        );
        assert_eq!(
            tool_summary("Bash", &json!({"command": "npm\ntest"})),
            "Bash npm test"
        );
        assert_eq!(tool_summary("Task", &json!({})), "Task");
        let long = "x".repeat(100);
        assert_eq!(
            tool_summary("Bash", &json!({ "command": long })),
            format!("Bash {}…", "x".repeat(90))
        );
    }

    #[test]
    fn jsonl_reader_keeps_partial_lines() {
        let dir = temp("jsonl");
        let path = dir.join("t.jsonl");
        let mut file = File::create(&path).unwrap();
        write!(file, "{{\"a\":1}}\n{{\"b\":").unwrap();
        let mut reader = JsonlReader::default();
        assert_eq!(reader.read(&path), vec![json!({"a": 1})]);
        writeln!(file, "2}}").unwrap();
        assert_eq!(reader.read(&path), vec![json!({"b": 2})]);
        assert!(reader.read(&path).is_empty());
    }

    #[test]
    fn transcript_events_follow_the_mac() {
        let objects = vec![
            json!({"type": "user", "message": {"content": "Find the bug"}}),
            json!({"type": "assistant", "message": {"content": [
                {"type": "text", "text": " Looking. "},
                {"type": "tool_use", "id": "t1", "name": "Grep", "input": {"pattern": "bug"}}
            ]}}),
            json!({"type": "user", "message": {"content": [
                {"type": "tool_result", "tool_use_id": "t1", "content": [{"type": "text", "text": "a.rs:1"}], "is_error": false}
            ]}}),
            json!({"type": "user", "message": {"content": "More"}}),
        ];
        assert_eq!(
            transcript_events(&objects, false),
            vec![
                TranscriptEvent::Task("Find the bug".into()),
                TranscriptEvent::Text("Looking.".into()),
                TranscriptEvent::Tool {
                    id: "t1".into(),
                    title: "Grep \"bug\"".into()
                },
                TranscriptEvent::Result {
                    id: "t1".into(),
                    text: "a.rs:1".into(),
                    error: false
                },
                TranscriptEvent::Text("More".into()),
            ]
        );
    }

    #[test]
    fn recent_tab_names() {
        let session = |prompt: &str| RecentSession {
            id: Uuid::nil(),
            cwd: "/".into(),
            prompt: prompt.into(),
            date: SystemTime::now(),
        };
        assert_eq!(
            session("fix the login bug please now thanks").tab_name(),
            "fix the login bug please"
        );
        assert_eq!(session("").tab_name(), "Session");
        assert_eq!(
            session("abcdefghijklmnopqrstuvwxyz0123456789").tab_name(),
            "abcdefghijklmnopqrstuvwxyz012345…"
        );
    }

    #[test]
    fn first_prompt_skips_commands_and_needs_cwd() {
        let dir = temp("prompt");
        let path = dir.join("c.jsonl");
        std::fs::write(
            &path,
            [
                json!({"type": "user", "message": {"content": "no cwd"}}).to_string(),
                json!({"type": "user", "cwd": "/w", "message": {"content": "<command-name>/clear"}}).to_string(),
                json!({"type": "user", "cwd": "/w", "message": {"content": [{"type": "text", "text": "Fix\nit"}]}}).to_string(),
            ]
            .join("\n"),
        )
        .unwrap();
        assert_eq!(first_prompt(&path), Some(("/w".into(), "Fix it".into())));
    }

    #[test]
    fn scanner_lists_running_and_recently_finished_agents() {
        let root = temp("agents");
        std::env::set_var("CLAUDE_CONFIG_DIR", &root);
        let session = Uuid::new_v4();
        let folder = root
            .join("projects/-w")
            .join(session.to_string().to_lowercase())
            .join("subagents");
        std::fs::create_dir_all(&folder).unwrap();
        std::fs::write(
            folder.join("agent-a1.meta.json"),
            json!({"agentType": "Explore", "description": "find tests", "spawnDepth": 2})
                .to_string(),
        )
        .unwrap();
        std::fs::write(
            folder.join("agent-a1.jsonl"),
            format!(
                "{}\n",
                json!({"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "name": "Read", "input": {"file_path": "/w/x.rs"}}
                ]}})
            ),
        )
        .unwrap();
        std::fs::write(
            folder.join("agent-b2.meta.json"),
            json!({"finished": true}).to_string(),
        )
        .unwrap();
        let mut scanner = AgentScanner::default();
        let agents = scanner.scan(session, true);
        assert_eq!(agents.len(), 2);
        let running = agents.iter().find(|a| a.id == "agent-a1").unwrap();
        assert_eq!(running.kind, "Explore");
        assert_eq!(running.depth, 2);
        assert_eq!(running.tool_count, 1);
        assert_eq!(running.short_activity(), "Read");
        assert!(running.matches("agent/a1", None, None));
        assert!(running.matches("x", Some("Find Tests now"), None));
        // Inactive sessions only show agents that recently finished.
        let inactive = scanner.scan(session, false);
        assert!(inactive.iter().all(|a| a.finished));
        std::env::remove_var("CLAUDE_CONFIG_DIR");
    }
}
