//! Plan usage limits for the sidebar strip (PARITY.md section 6).
//!
//! Claude: the Claude Code login token (in `~/.claude/.credentials.json` on
//! Linux, the Keychain on the Mac) is sent to the endpoint Claude Code's own
//! `/usage` uses. The token is never written or logged. Codex limits come
//! from the Codex app-server.

use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gtk::glib;
use gtk::prelude::*;
use serde_json::Value;

use crate::app::App;

#[derive(Debug, Clone, PartialEq)]
pub struct Limit {
    pub label: String,
    pub percent: i64,
    /// Seconds since the epoch.
    pub resets_at: Option<i64>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Usage {
    Limits(Vec<Limit>),
    /// Short text for the strip, longer text for its tooltip.
    Problem(String, String),
}

const ENDPOINT: &str = "https://api.anthropic.com/api/oauth/usage";

enum Token {
    Found(String),
    NoLogin,
    ApiKey,
}

fn read_token() -> Token {
    let path = crate::claude::config_dir().join(".credentials.json");
    let Ok(data) = std::fs::read(path) else {
        return Token::NoLogin;
    };
    let Ok(json) = serde_json::from_slice::<Value>(&data) else {
        return Token::NoLogin;
    };
    match json
        .get("claudeAiOauth")
        .and_then(|o| o.get("accessToken"))
        .and_then(Value::as_str)
    {
        Some(token) if !token.is_empty() => Token::Found(token.to_string()),
        _ => Token::ApiKey,
    }
}

/// Blocking: reads the token and asks Anthropic. Runs on a worker thread.
pub fn fetch_claude() -> Usage {
    let token = match read_token() {
        Token::Found(token) => token,
        Token::NoLogin => {
            return Usage::Problem(
                "No Claude login".into(),
                "No Claude Code login found. Run claude, then /login with a Claude.ai plan. Click to check again.".into(),
            )
        }
        Token::ApiKey => {
            return Usage::Problem(
                "Needs a Claude.ai plan".into(),
                "Claude Code is signed in with an API key. Usage limits exist only for Claude.ai plans (/login in claude). Click to check again.".into(),
            )
        }
    };
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .http_status_as_error(false)
        .build()
        .into();
    let response = agent
        .get(ENDPOINT)
        .header("Authorization", &format!("Bearer {token}"))
        .header("anthropic-beta", "oauth-2025-04-20")
        .call();
    let mut response = match response {
        Ok(response) => response,
        Err(err) => {
            return Usage::Problem(
                "Usage unavailable".into(),
                format!("Couldn't reach Anthropic's usage endpoint: {err}. Click to try again."),
            )
        }
    };
    match response.status().as_u16() {
        200 => {}
        401 | 403 => {
            return Usage::Problem(
                "Claude login expired".into(),
                "Claude Code's login no longer works. Run claude to sign in again, then click to check again.".into(),
            )
        }
        code => {
            return Usage::Problem(
                "Usage unavailable".into(),
                format!("Anthropic's usage endpoint answered {code}. Click to try again."),
            )
        }
    }
    let body = response.body_mut().read_to_string().unwrap_or_default();
    match parse_claude(&body) {
        Some(limits) => Usage::Limits(limits),
        None => Usage::Problem(
            "Usage unavailable".into(),
            "Anthropic's usage endpoint answered in an unexpected format. Click to try again."
                .into(),
        ),
    }
}

/// `{"limits":[{"kind","percent","resets_at","scope":{"model":{"display_name"}}}]}`
pub fn parse_claude(body: &str) -> Option<Vec<Limit>> {
    let json: Value = serde_json::from_str(body).ok()?;
    let limits = json.get("limits")?.as_array()?;
    Some(
        limits
            .iter()
            .filter_map(|item| {
                let kind = item.get("kind")?.as_str()?;
                let percent = item.get("percent")?.as_i64()?;
                let model = item
                    .get("scope")
                    .and_then(|s| s.get("model"))
                    .and_then(|m| m.get("display_name"))
                    .and_then(Value::as_str);
                let label = match kind {
                    "session" => "5h".to_string(),
                    "weekly_all" => "Week".to_string(),
                    _ => model.unwrap_or(kind).to_string(),
                };
                let resets_at = item
                    .get("resets_at")
                    .and_then(Value::as_str)
                    .and_then(|t| glib::DateTime::from_iso8601(t, None).ok())
                    .map(|d| d.to_unix());
                Some(Limit {
                    label,
                    percent,
                    resets_at,
                })
            })
            .collect(),
    )
}

/// `"5h 1%  Week 32%"`.
pub fn summary(limits: &[Limit]) -> String {
    limits
        .iter()
        .map(|l| format!("{} {}%", l.label, l.percent))
        .collect::<Vec<_>>()
        .join("  ")
}

/// "resets in 2d 3h", "4h 10m" or "12m".
pub fn resets_in(resets_at: i64) -> String {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    let seconds = (resets_at - now).max(0);
    if seconds >= 86_400 {
        format!("{}d {}h", seconds / 86_400, seconds / 3600 % 24)
    } else if seconds >= 3600 {
        format!("{}h {}m", seconds / 3600, seconds % 3600 / 60)
    } else {
        format!("{}m", seconds / 60)
    }
}

/// Bar tint: red from 90%, orange from 70%.
pub fn tint(percent: i64) -> &'static str {
    if percent >= 90 {
        "red"
    } else if percent >= 70 {
        "orange"
    } else {
        "blue"
    }
}

// MARK: the sidebar strip

thread_local! {
    static STATE: RefCell<Strip> = RefCell::new(Strip::default());
}

#[derive(Default)]
struct Strip {
    claude: Option<Usage>,
    timer: Option<glib::SourceId>,
    widget: Option<gtk::Box>,
    loading: bool,
}

/// Builds the strip in the sidebar footer and starts polling.
pub fn install(app: &Rc<App>) {
    let strip = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    strip.add_css_class("omux-usage");
    strip.set_margin_start(12);
    strip.set_margin_end(12);
    strip.set_margin_top(8);
    strip.set_margin_bottom(8);
    let click = gtk::GestureClick::new();
    let weak = Rc::downgrade(app);
    click.connect_released(move |_, _, _, _| {
        if let Some(app) = weak.upgrade() {
            refresh(&app);
        }
    });
    strip.add_controller(click);
    app.ui.sidebar.footer.append(&strip);
    STATE.with(|s| s.borrow_mut().widget = Some(strip));
    refresh(app);
    rearm(app);
}

/// Restarts the timer after the interval setting changed.
pub fn rearm(app: &Rc<App>) {
    let seconds = app.settings.borrow().usage_interval.max(60.0) as u64;
    STATE.with(|s| {
        if let Some(timer) = s.borrow_mut().timer.take() {
            timer.remove();
        }
    });
    let weak = Rc::downgrade(app);
    let timer = glib::timeout_add_local(Duration::from_secs(seconds), move || {
        let Some(app) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        refresh(&app);
        glib::ControlFlow::Continue
    });
    STATE.with(|s| s.borrow_mut().timer = Some(timer));
}

/// Fetches Claude usage on a worker thread, then redraws.
pub fn refresh(app: &Rc<App>) {
    crate::codex::refresh_usage();
    let busy = STATE.with(|s| std::mem::replace(&mut s.borrow_mut().loading, true));
    if busy {
        return;
    }
    let (tx, rx) = async_channel::bounded(1);
    std::thread::spawn(move || {
        let _ = tx.send_blocking(fetch_claude());
    });
    let weak = Rc::downgrade(app);
    glib::spawn_future_local(async move {
        let result = rx.recv().await.ok();
        STATE.with(|s| {
            let mut s = s.borrow_mut();
            s.loading = false;
            if result.is_some() {
                s.claude = result;
            }
        });
        if let Some(app) = weak.upgrade() {
            redraw(&app);
            crate::ui::welcome::usage_changed(&app);
        }
    });
}

pub fn claude() -> Option<Usage> {
    STATE.with(|s| s.borrow().claude.clone())
}

/// Shows Codex limits while a Codex session is selected, Claude's otherwise.
pub fn redraw(app: &Rc<App>) {
    let Some(strip) = STATE.with(|s| s.borrow().widget.clone()) else {
        return;
    };
    while let Some(child) = strip.first_child() {
        strip.remove(&child);
    }
    let codex_selected = app
        .selected
        .get()
        .and_then(|id| app.tab(id))
        .is_some_and(|(g, t)| t.resolved_provider(&g) == crate::model::SessionProvider::Codex);
    let (usage, plan, placeholder) = if codex_selected {
        let (usage, plan) = crate::codex::usage(app);
        (usage, plan, "Codex usage…")
    } else {
        (claude(), None, "Claude usage…")
    };
    if let Some(plan) = plan {
        let label = gtk::Label::new(Some(&plan));
        label.add_css_class("omux-status");
        strip.append(&label);
    }
    match usage {
        Some(Usage::Limits(limits)) if !limits.is_empty() => {
            for limit in limits {
                strip.append(&limit_view(&limit));
            }
        }
        Some(Usage::Problem(short, long)) => {
            let label = gtk::Label::new(Some(&short));
            label.add_css_class("omux-status");
            label.set_tooltip_text(Some(&long));
            strip.append(&label);
        }
        _ => {
            let label = gtk::Label::new(Some(placeholder));
            label.add_css_class("omux-status");
            strip.append(&label);
        }
    }
}

fn limit_view(limit: &Limit) -> gtk::Box {
    let vbox = gtk::Box::new(gtk::Orientation::Vertical, 3);
    let label = gtk::Label::new(Some(&format!("{} {}%", limit.label, limit.percent)));
    label.set_xalign(0.0);
    label.add_css_class("omux-status");
    vbox.append(&label);
    let bar = gtk::LevelBar::for_interval(0.0, 100.0);
    bar.set_value(limit.percent.clamp(0, 100) as f64);
    bar.add_css_class("omux-usage-bar");
    bar.add_css_class(tint(limit.percent));
    bar.set_size_request(48, 3);
    vbox.append(&bar);
    if let Some(at) = limit.resets_at {
        vbox.set_tooltip_text(Some(&format!(
            "{} resets in {}",
            limit.label,
            resets_in(at)
        )));
    }
    vbox
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_claude_limits() {
        let body = r#"{"limits":[
            {"kind":"session","percent":1,"resets_at":"2026-10-30T15:00:00.123Z"},
            {"kind":"weekly_all","percent":32},
            {"kind":"weekly_model","percent":35,"scope":{"model":{"display_name":"Fable"}}},
            {"kind":"broken","percent":"x"}
        ]}"#;
        let limits = parse_claude(body).unwrap();
        assert_eq!(summary(&limits), "5h 1%  Week 32%  Fable 35%");
        assert!(limits[0].resets_at.is_some());
        assert_eq!(limits[1].resets_at, None);
    }

    #[test]
    fn tints() {
        assert_eq!(tint(95), "red");
        assert_eq!(tint(70), "orange");
        assert_eq!(tint(10), "blue");
    }
}
