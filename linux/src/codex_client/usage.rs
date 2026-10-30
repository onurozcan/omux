//! Codex rate-limit usage: merging sparse `account/rateLimits/updated`
//! notifications into the last full read, as `CodexManager.applyLimits` does.
//!
//! The quota is process-wide (as in the Mac app): any tab's server, or the
//! catalog server, may refresh it and every consumer sees the merged result.

use std::sync::{Mutex, OnceLock};

use serde_json::{Map, Value};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UsageLimit {
    /// "5h", "7d", "30m"
    pub label: String,
    pub percent: i64,
    /// Epoch seconds.
    pub resets_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexUsage {
    /// Display form such as "Codex Plus".
    pub plan: Option<String>,
    pub limits: Vec<UsageLimit>,
}

#[derive(Debug, Default)]
pub struct Quota {
    plan: Option<String>,
    primary: Map<String, Value>,
    secondary: Map<String, Value>,
}

/// JSON numbers may arrive as `15` or `15.0`; both count as integers.
fn as_int(value: &Value) -> Option<i64> {
    value.as_i64().or_else(|| {
        value
            .as_f64()
            .filter(|f| f.fract() == 0.0)
            .map(|f| f as i64)
    })
}

pub fn window_label(minutes: i64) -> String {
    if minutes >= 1440 {
        format!("{}d", minutes / 1440)
    } else if minutes >= 60 {
        format!("{}h", minutes / 60)
    } else {
        format!("{minutes}m")
    }
}

/// "plus" -> "Codex Plus", "pro_lite" -> "Codex Pro Lite".
pub fn plan_label(raw: &str) -> String {
    let words: Vec<String> = raw
        .replace('_', " ")
        .split_whitespace()
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(first) => {
                    first.to_uppercase().collect::<String>() + &chars.as_str().to_lowercase()
                }
                None => String::new(),
            }
        })
        .collect();
    format!("Codex {}", words.join(" "))
}

impl Quota {
    /// Forget the windows (not the plan), e.g. before a full re-read or on error.
    pub fn clear(&mut self) {
        self.primary.clear();
        self.secondary.clear();
    }

    /// `result` is a read response or notification params holding `rateLimits`.
    pub fn apply(&mut self, result: &Value, replace: bool) {
        if replace {
            self.clear();
        }
        let Some(bucket) = result.get("rateLimits").filter(|b| b.is_object()) else {
            return;
        };
        if let Some(plan) = bucket.get("planType").and_then(Value::as_str) {
            if plan != "unknown" {
                self.plan = Some(plan.to_string());
            }
        }
        for (key, target) in [
            ("primary", &mut self.primary),
            ("secondary", &mut self.secondary),
        ] {
            if let Some(update) = bucket.get(key).and_then(Value::as_object) {
                for (field, value) in update {
                    target.insert(field.clone(), value.clone());
                }
            }
        }
    }

    pub fn usage(&self) -> CodexUsage {
        let limits = [&self.primary, &self.secondary]
            .into_iter()
            .filter_map(|raw| {
                let percent = as_int(raw.get("usedPercent")?)?;
                let minutes = raw.get("windowDurationMins").and_then(as_int).unwrap_or(0);
                Some(UsageLimit {
                    label: window_label(minutes),
                    percent,
                    resets_at: raw
                        .get("resetsAt")
                        .and_then(Value::as_f64)
                        .map(|f| f as i64),
                })
            })
            .collect();
        CodexUsage {
            plan: self.plan.as_deref().map(plan_label),
            limits,
        }
    }
}

pub fn global() -> &'static Mutex<Quota> {
    static QUOTA: OnceLock<Mutex<Quota>> = OnceLock::new();
    QUOTA.get_or_init(|| Mutex::new(Quota::default()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn sparse_quota_updates_preserve_other_windows() {
        let mut quota = Quota::default();
        quota.apply(
            &json!({"rateLimits": {
                "primary": {"usedPercent": 10, "windowDurationMins": 300},
                "secondary": {"usedPercent": 30, "windowDurationMins": 10080}}}),
            false,
        );
        quota.apply(
            &json!({"rateLimits": {"primary": {"usedPercent": 15}}}),
            false,
        );
        let usage = quota.usage();
        let percents: Vec<i64> = usage.limits.iter().map(|l| l.percent).collect();
        let labels: Vec<&str> = usage.limits.iter().map(|l| l.label.as_str()).collect();
        assert_eq!(percents, [15, 30]);
        assert_eq!(labels, ["5h", "7d"]);
    }

    #[test]
    fn window_labels_use_integer_division() {
        assert_eq!(window_label(300), "5h");
        assert_eq!(window_label(10080), "7d");
        assert_eq!(window_label(1440), "1d");
        assert_eq!(window_label(90), "1h");
        assert_eq!(window_label(45), "45m");
        assert_eq!(window_label(0), "0m");
    }

    #[test]
    fn plan_is_formatted_and_unknown_is_ignored() {
        let mut quota = Quota::default();
        quota.apply(&json!({"rateLimits": {"planType": "plus"}}), false);
        assert_eq!(quota.usage().plan.as_deref(), Some("Codex Plus"));
        quota.apply(&json!({"rateLimits": {"planType": "unknown"}}), false);
        assert_eq!(quota.usage().plan.as_deref(), Some("Codex Plus"));
        quota.apply(&json!({"rateLimits": {"planType": "PRO_lite"}}), false);
        assert_eq!(quota.usage().plan.as_deref(), Some("Codex Pro Lite"));
    }

    #[test]
    fn limits_need_an_integer_used_percent() {
        let mut quota = Quota::default();
        quota.apply(
            &json!({"rateLimits": {
                "primary": {"windowDurationMins": 300},
                "secondary": {"usedPercent": 40.0, "resetsAt": 1700000000}}}),
            false,
        );
        let usage = quota.usage();
        assert_eq!(usage.limits.len(), 1);
        assert_eq!(usage.limits[0].percent, 40);
        assert_eq!(usage.limits[0].label, "0m");
        assert_eq!(usage.limits[0].resets_at, Some(1_700_000_000));
    }

    #[test]
    fn replace_drops_old_windows_but_keeps_plan() {
        let mut quota = Quota::default();
        quota.apply(
            &json!({"rateLimits": {"planType": "pro",
                "primary": {"usedPercent": 10, "windowDurationMins": 300},
                "secondary": {"usedPercent": 30, "windowDurationMins": 10080}}}),
            false,
        );
        quota.apply(
            &json!({"rateLimits": {"primary": {"usedPercent": 1, "windowDurationMins": 300}}}),
            true,
        );
        let usage = quota.usage();
        assert_eq!(usage.limits.len(), 1);
        assert_eq!(usage.plan.as_deref(), Some("Codex Pro"));
    }
}
