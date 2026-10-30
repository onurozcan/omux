//! The pull request for a worktree session's branch, as `gh pr view` reports it:
//! decoding, check mapping, the one-line summary and the attention triggers.
//! Mirrors `PullRequests.swift`; polling and UI live elsewhere.

use crate::git;
use serde::Deserialize;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PrState {
    Open,
    Closed,
    Merged,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CheckResult {
    Passed,
    Failed,
    Pending,
    Skipped,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Check {
    pub name: String,
    pub result: CheckResult,
    pub url: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PullRequest {
    pub number: u64,
    pub title: String,
    pub url: String,
    pub state: PrState,
    pub is_draft: bool,
    /// One of APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED; anything else is None.
    pub review_decision: Option<String>,
    pub checks: Vec<Check>,
}

pub enum Fetch {
    Found(PullRequest),
    /// No pull request (or gh isn't installed).
    None,
    /// Offline, rate limited or unreadable: keep what was known.
    Unknown,
}

const FIELDS: &str = "number,title,url,state,isDraft,reviewDecision,statusCheckRollup";

/// Asks about the branch checked out in `dir` rather than naming it, so gh can follow
/// the branch's upstream to a pull request opened from a fork.
pub fn fetch(dir: &Path) -> Fetch {
    let Some(r) = git::gh(&["pr", "view", "--json", FIELDS], dir) else {
        return Fetch::None;
    };
    if !r.ok() {
        return if r.err.contains("no pull requests found") {
            Fetch::None
        } else {
            Fetch::Unknown
        };
    }
    decode(&r.out).map_or(Fetch::Unknown, Fetch::Found)
}

/// Only web links: these open on click, and check links come from whoever reports the check.
fn web_url(s: &str) -> Option<String> {
    let lower = s.to_ascii_lowercase();
    (lower.starts_with("http://") || lower.starts_with("https://")).then(|| s.to_string())
}

/// Checks come as CheckRuns (status and conclusion) or as commit StatusContexts (state).
#[derive(Deserialize)]
struct RawCheck {
    name: Option<String>,
    context: Option<String>,
    status: Option<String>,
    conclusion: Option<String>,
    state: Option<String>,
    #[serde(rename = "detailsUrl")]
    details_url: Option<String>,
    #[serde(rename = "targetUrl")]
    target_url: Option<String>,
}

impl RawCheck {
    fn result(&self) -> CheckResult {
        if let Some(state) = &self.state {
            return match state.as_str() {
                "SUCCESS" => CheckResult::Passed,
                "PENDING" | "EXPECTED" => CheckResult::Pending,
                _ => CheckResult::Failed,
            };
        }
        if self.status.as_deref() != Some("COMPLETED") {
            return CheckResult::Pending;
        }
        match self.conclusion.as_deref() {
            Some("SUCCESS") => CheckResult::Passed,
            Some("SKIPPED" | "NEUTRAL" | "STALE") => CheckResult::Skipped,
            _ => CheckResult::Failed,
        }
    }
}

#[derive(Deserialize)]
struct Raw {
    number: u64,
    title: String,
    url: String,
    state: String,
    #[serde(rename = "isDraft")]
    is_draft: bool,
    #[serde(rename = "reviewDecision")]
    review_decision: Option<String>,
    #[serde(rename = "statusCheckRollup")]
    status_check_rollup: Option<Vec<RawCheck>>,
}

/// Decodes `gh pr view --json` output; None when malformed, the URL isn't http(s)
/// or the state is unknown.
pub fn decode(json: &str) -> Option<PullRequest> {
    let raw: Raw = serde_json::from_str(json).ok()?;
    let url = web_url(&raw.url)?;
    let state = match raw.state.as_str() {
        "OPEN" => PrState::Open,
        "CLOSED" => PrState::Closed,
        "MERGED" => PrState::Merged,
        _ => return None,
    };
    let checks = raw
        .status_check_rollup
        .unwrap_or_default()
        .iter()
        .map(|c| Check {
            name: c
                .name
                .clone()
                .or_else(|| c.context.clone())
                .unwrap_or_else(|| "Check".into()),
            result: c.result(),
            url: c
                .details_url
                .as_deref()
                .or(c.target_url.as_deref())
                .and_then(web_url),
        })
        .collect();
    let review_decision = raw.review_decision.filter(|r| {
        matches!(
            r.as_str(),
            "APPROVED" | "CHANGES_REQUESTED" | "REVIEW_REQUIRED"
        )
    });
    Some(PullRequest {
        number: raw.number,
        title: raw.title,
        url,
        state,
        is_draft: raw.is_draft,
        review_decision,
        checks,
    })
}

impl PullRequest {
    /// The checks taken together: any failure wins, then anything still running.
    pub fn checks_result(&self) -> Option<CheckResult> {
        [
            CheckResult::Failed,
            CheckResult::Pending,
            CheckResult::Passed,
        ]
        .into_iter()
        .find(|r| self.checks.iter().any(|c| c.result == *r))
    }

    fn review(&self) -> Option<&str> {
        self.review_decision.as_deref()
    }

    /// The most pressing fact about it, for tight spaces.
    pub fn summary(&self) -> &'static str {
        match self.state {
            PrState::Merged => return "Merged",
            PrState::Closed => return "Closed",
            PrState::Open => {}
        }
        let checks = self.checks_result();
        if checks == Some(CheckResult::Failed) {
            "Checks failing"
        } else if self.review() == Some("CHANGES_REQUESTED") {
            "Changes requested"
        } else if checks == Some(CheckResult::Pending) {
            "Checks running"
        } else if self.is_draft {
            "Draft"
        } else if self.review() == Some("APPROVED") {
            "Approved"
        } else if checks == Some(CheckResult::Passed) {
            "Checks passed"
        } else {
            "Open"
        }
    }

    /// "purple", "secondary", "red", "orange", "blue" or "green".
    pub fn color(&self) -> &'static str {
        match self.state {
            PrState::Merged => return "purple",
            PrState::Closed => return "secondary",
            PrState::Open => {}
        }
        let checks = self.checks_result();
        if checks == Some(CheckResult::Failed) {
            "red"
        } else if self.review() == Some("CHANGES_REQUESTED") {
            "orange"
        } else if checks == Some(CheckResult::Pending) {
            "blue"
        } else if self.is_draft {
            "secondary"
        } else {
            "green"
        }
    }

    /// "#42 · Draft|Open|Merged|Closed · Approved|Changes requested|Review required".
    pub fn facts(&self) -> String {
        let state = match (self.state, self.is_draft) {
            (PrState::Open, true) => "Draft",
            (PrState::Open, false) => "Open",
            (PrState::Closed, _) => "Closed",
            (PrState::Merged, _) => "Merged",
        };
        let mut facts = vec![format!("#{}", self.number), state.to_string()];
        match self.review() {
            Some("APPROVED") => facts.push("Approved".into()),
            Some("CHANGES_REQUESTED") => facts.push("Changes requested".into()),
            Some("REVIEW_REQUIRED") => facts.push("Review required".into()),
            _ => {}
        }
        facts.join(" \u{b7} ")
    }
}

/// Changes worth pulling the user back to the session for. Nothing is flagged the
/// first time a pull request is seen.
pub fn needs_attention(old: Option<&PullRequest>, new: &PullRequest) -> bool {
    let Some(old) = old else { return false };
    (new.checks_result() == Some(CheckResult::Failed)
        && old.checks_result() != Some(CheckResult::Failed))
        || (new.review_decision != old.review_decision
            && matches!(new.review(), Some("CHANGES_REQUESTED" | "APPROVED")))
        || (new.state == PrState::Merged && old.state != PrState::Merged)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pr(
        state: PrState,
        draft: bool,
        review: Option<&str>,
        checks: &[CheckResult],
    ) -> PullRequest {
        PullRequest {
            number: 7,
            title: "t".into(),
            url: "https://github.com/o/r/pull/7".into(),
            state,
            is_draft: draft,
            review_decision: review.map(String::from),
            checks: checks
                .iter()
                .map(|r| Check {
                    name: "c".into(),
                    result: *r,
                    url: None,
                })
                .collect(),
        }
    }

    #[test]
    fn decodes_both_check_shapes() {
        let json = r#"{"number":42,"title":"Add x","url":"https://github.com/o/r/pull/42",
          "state":"OPEN","isDraft":false,"reviewDecision":"","statusCheckRollup":[
          {"__typename":"CheckRun","name":"build","status":"COMPLETED","conclusion":"SUCCESS","detailsUrl":"https://ci/1"},
          {"__typename":"CheckRun","name":"lint","status":"IN_PROGRESS","conclusion":"","detailsUrl":"javascript:x"},
          {"__typename":"StatusContext","context":"ci/old","state":"FAILURE","targetUrl":"http://ci/2"},
          {"status":"COMPLETED","conclusion":"NEUTRAL"}]}"#;
        let p = decode(json).unwrap();
        assert_eq!(
            (p.number, p.state, p.review_decision.clone()),
            (42, PrState::Open, None)
        );
        let got: Vec<_> = p
            .checks
            .iter()
            .map(|c| (c.name.as_str(), c.result, c.url.as_deref()))
            .collect();
        assert_eq!(
            got,
            [
                ("build", CheckResult::Passed, Some("https://ci/1")),
                ("lint", CheckResult::Pending, None),
                ("ci/old", CheckResult::Failed, Some("http://ci/2")),
                ("Check", CheckResult::Skipped, None),
            ]
        );
    }

    #[test]
    fn decode_rejects_bad_input() {
        assert!(decode("nope").is_none());
        let base = |url: &str, state: &str| {
            format!(
                r#"{{"number":1,"title":"t","url":"{url}","state":"{state}","isDraft":false,"reviewDecision":null}}"#
            )
        };
        assert!(decode(&base("https://x/1", "OPEN")).is_some());
        assert!(decode(&base("file:///x", "OPEN")).is_none());
        assert!(decode(&base("https://x/1", "WEIRD")).is_none());
    }

    #[test]
    fn check_mapping_table() {
        let c = |state: Option<&str>, status: Option<&str>, conclusion: Option<&str>| RawCheck {
            name: None,
            context: None,
            status: status.map(String::from),
            conclusion: conclusion.map(String::from),
            state: state.map(String::from),
            details_url: None,
            target_url: None,
        };
        use CheckResult::*;
        assert_eq!(c(Some("SUCCESS"), None, None).result(), Passed);
        assert_eq!(c(Some("PENDING"), None, None).result(), Pending);
        assert_eq!(c(Some("EXPECTED"), None, None).result(), Pending);
        assert_eq!(c(Some("ERROR"), None, None).result(), Failed);
        assert_eq!(c(None, Some("QUEUED"), None).result(), Pending);
        assert_eq!(c(None, None, Some("SUCCESS")).result(), Pending);
        for k in ["SKIPPED", "NEUTRAL", "STALE"] {
            assert_eq!(c(None, Some("COMPLETED"), Some(k)).result(), Skipped);
        }
        assert_eq!(c(None, Some("COMPLETED"), Some("SUCCESS")).result(), Passed);
        assert_eq!(
            c(None, Some("COMPLETED"), Some("CANCELLED")).result(),
            Failed
        );
        assert_eq!(c(None, Some("COMPLETED"), None).result(), Failed);
    }

    #[test]
    fn summary_priority_and_color() {
        use CheckResult::*;
        use PrState::*;
        let s = |p: PullRequest| (p.summary(), p.color());
        assert_eq!(s(pr(Merged, false, None, &[Failed])), ("Merged", "purple"));
        assert_eq!(s(pr(Closed, false, None, &[])), ("Closed", "secondary"));
        assert_eq!(
            s(pr(
                Open,
                true,
                Some("CHANGES_REQUESTED"),
                &[Failed, Pending]
            )),
            ("Checks failing", "red")
        );
        assert_eq!(
            s(pr(Open, true, Some("CHANGES_REQUESTED"), &[Pending])),
            ("Changes requested", "orange")
        );
        assert_eq!(
            s(pr(Open, true, Some("APPROVED"), &[Pending])),
            ("Checks running", "blue")
        );
        assert_eq!(
            s(pr(Open, true, Some("APPROVED"), &[Passed])),
            ("Draft", "secondary")
        );
        assert_eq!(
            s(pr(Open, false, Some("APPROVED"), &[Passed])),
            ("Approved", "green")
        );
        assert_eq!(
            s(pr(Open, false, None, &[Passed, Skipped])),
            ("Checks passed", "green")
        );
        assert_eq!(s(pr(Open, false, None, &[Skipped])), ("Open", "green"));
        assert_eq!(pr(Open, false, None, &[]).checks_result(), None);
    }

    #[test]
    fn facts_line() {
        let p = pr(PrState::Open, true, Some("REVIEW_REQUIRED"), &[]);
        assert_eq!(p.facts(), "#7 \u{b7} Draft \u{b7} Review required");
        assert_eq!(
            pr(PrState::Merged, true, None, &[]).facts(),
            "#7 \u{b7} Merged"
        );
    }

    #[test]
    fn attention_triggers() {
        use CheckResult::*;
        use PrState::*;
        let base = pr(Open, false, None, &[Passed]);
        assert!(!needs_attention(None, &pr(Merged, false, None, &[])));
        assert!(!needs_attention(Some(&base), &base));
        assert!(needs_attention(
            Some(&base),
            &pr(Open, false, None, &[Failed])
        ));
        let failed = pr(Open, false, None, &[Failed]);
        assert!(!needs_attention(Some(&failed), &failed));
        assert!(needs_attention(
            Some(&base),
            &pr(Open, false, Some("APPROVED"), &[Passed])
        ));
        assert!(needs_attention(
            Some(&base),
            &pr(Open, false, Some("CHANGES_REQUESTED"), &[Passed])
        ));
        assert!(!needs_attention(
            Some(&base),
            &pr(Open, false, Some("REVIEW_REQUIRED"), &[Passed])
        ));
        assert!(needs_attention(
            Some(&base),
            &pr(Merged, false, None, &[Passed])
        ));
        assert!(!needs_attention(
            Some(&pr(Merged, false, None, &[])),
            &pr(Merged, false, None, &[])
        ));
    }
}
