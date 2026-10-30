//! Watches the bytes a session writes for the OSC sequences omux acts on.
//! VTE still receives every byte; this only observes.
//!
//! - OSC 7501: program status (Claude Code's working / needs-you / done)
//! - OSC 9 and OSC 777: notifications from programs
//! - OSC 133 A: a new shell prompt, which ends working and blocked records
//!
//! Sequences end with BEL or ESC \. The 8-bit C1 terminator is not accepted:
//! byte 0x9C also occurs inside UTF-8 text (for example in "Ü").

use super::status::{self, Report};

#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    Status(Report),
    /// `OSC 7501 ; ?`; the reply must use the same terminator kind.
    StatusQuery {
        bel: bool,
    },
    Notification {
        title: Option<String>,
        body: String,
    },
    PromptStart,
}

/// Longest OSC kept; longer ones are dropped (OSC 7501 is capped lower).
const MAX_OSC: usize = 64 * 1024;

#[derive(Debug, Default)]
enum Mode {
    #[default]
    Ground,
    Escape,
    Osc,
    OscEscape,
    /// An over-long OSC, or a DCS / SOS / PM / APC string: skip to its
    /// terminator so an `ESC ]` inside it isn't taken as an OSC.
    OscSkip,
    OscSkipEscape,
}

#[derive(Debug, Default)]
pub struct Scanner {
    mode: Mode,
    buffer: Vec<u8>,
}

impl Scanner {
    pub fn feed(&mut self, bytes: &[u8], events: &mut Vec<Event>) {
        for &byte in bytes {
            self.step(byte, events);
        }
    }

    fn step(&mut self, byte: u8, events: &mut Vec<Event>) {
        const ESC: u8 = 0x1b;
        const BEL: u8 = 0x07;
        const CAN: u8 = 0x18;
        const SUB: u8 = 0x1a;
        self.mode = match std::mem::take(&mut self.mode) {
            Mode::Ground => {
                if byte == ESC {
                    Mode::Escape
                } else {
                    Mode::Ground
                }
            }
            Mode::Escape => match byte {
                b']' => {
                    self.buffer.clear();
                    Mode::Osc
                }
                b'P' | b'X' | b'^' | b'_' => Mode::OscSkip,
                ESC => Mode::Escape,
                _ => Mode::Ground,
            },
            Mode::Osc => match byte {
                BEL => {
                    self.dispatch(true, events);
                    Mode::Ground
                }
                ESC => Mode::OscEscape,
                CAN | SUB => Mode::Ground,
                // Other C0 controls are ignored inside a string, as in the
                // VT500 parser SwiftTerm follows.
                0x00..=0x1f => Mode::Osc,
                _ if self.buffer.len() >= MAX_OSC => Mode::OscSkip,
                _ => {
                    self.buffer.push(byte);
                    Mode::Osc
                }
            },
            Mode::OscEscape => match byte {
                b'\\' => {
                    self.dispatch(false, events);
                    Mode::Ground
                }
                // ESC that isn't ST aborts the OSC and starts a new sequence.
                b']' => {
                    self.buffer.clear();
                    Mode::Osc
                }
                ESC => Mode::Escape,
                _ => Mode::Ground,
            },
            Mode::OscSkip => match byte {
                BEL | CAN | SUB => Mode::Ground,
                ESC => Mode::OscSkipEscape,
                _ => Mode::OscSkip,
            },
            Mode::OscSkipEscape => match byte {
                b'\\' => Mode::Ground,
                ESC => Mode::Escape,
                _ => Mode::Ground,
            },
        };
    }

    fn dispatch(&mut self, bel: bool, events: &mut Vec<Event>) {
        let data = std::mem::take(&mut self.buffer);
        let Some(semicolon) = data.iter().position(|b| *b == b';') else {
            return;
        };
        let (code, payload) = (&data[..semicolon], &data[semicolon + 1..]);
        match code {
            b"7501" => {
                if payload == b"?" {
                    events.push(Event::StatusQuery { bel });
                } else if let Some(report) = status::parse(payload) {
                    events.push(Event::Status(report));
                }
            }
            b"9" => {
                if let Some(event) = osc9(payload) {
                    events.push(event);
                }
            }
            b"777" => {
                if let Some(event) = osc777(payload) {
                    events.push(event);
                }
            }
            b"133" if payload == b"A" || payload.starts_with(b"A;") => {
                events.push(Event::PromptStart);
            }
            _ => {}
        }
        self.buffer = data;
        self.buffer.clear();
    }
}

/// iTerm2's `OSC 9 ; text`. ConEmu commands such as `9;4;…` (progress) are not
/// notifications.
fn osc9(payload: &[u8]) -> Option<Event> {
    let text = std::str::from_utf8(payload).ok()?;
    if text.is_empty() {
        return None;
    }
    let digits = text.bytes().take_while(u8::is_ascii_digit).count();
    if digits > 0 && matches!(text.as_bytes().get(digits), None | Some(b';')) {
        return None;
    }
    Some(Event::Notification {
        title: None,
        body: text.to_string(),
    })
}

/// rxvt/Ghostty `OSC 777 ; notify ; title ; body`. The body may contain `;`.
fn osc777(payload: &[u8]) -> Option<Event> {
    let text = std::str::from_utf8(payload).ok()?;
    let mut parts = text.splitn(3, ';');
    let (kind, title, body) = (parts.next()?, parts.next()?, parts.next()?);
    if kind != "notify" || body.is_empty() {
        return None;
    }
    Some(Event::Notification {
        title: (!title.is_empty()).then(|| title.to_string()),
        body: body.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(chunks: &[&[u8]]) -> Vec<Event> {
        let mut scanner = Scanner::default();
        let mut events = Vec::new();
        for chunk in chunks {
            scanner.feed(chunk, &mut events);
        }
        events
    }

    #[test]
    fn finds_status_split_across_reads() {
        let events = scan(&[b"hello \x1b]75", b"01;state=work", b"ing\x1b", b"\\ world"]);
        assert_eq!(events.len(), 1);
        assert!(
            matches!(&events[0], Event::Status(Report::Replace(r)) if r.state == status::State::Working)
        );
    }

    #[test]
    fn answers_queries_with_matching_terminator() {
        assert_eq!(
            scan(&[b"\x1b]7501;?\x07"]),
            vec![Event::StatusQuery { bel: true }]
        );
        assert_eq!(
            scan(&[b"\x1b]7501;?\x1b\\"]),
            vec![Event::StatusQuery { bel: false }]
        );
    }

    #[test]
    fn notifications() {
        assert_eq!(
            scan(&[b"\x1b]9;Build finished\x07"]),
            vec![Event::Notification {
                title: None,
                body: "Build finished".into()
            }]
        );
        assert!(
            scan(&[b"\x1b]9;4;1;50\x07"]).is_empty(),
            "progress is not a notification"
        );
        assert!(scan(&[b"\x1b]9;12\x07"]).is_empty());
        assert_eq!(
            scan(&[b"\x1b]777;notify;Claude;Needs you; now\x1b\\"]),
            vec![Event::Notification {
                title: Some("Claude".into()),
                body: "Needs you; now".into()
            }]
        );
        assert_eq!(
            scan(&["\x1b]777;notify;;Üzgünüm\x07".as_bytes()]),
            vec![Event::Notification {
                title: None,
                body: "Üzgünüm".into()
            }],
            "0x9C inside UTF-8 is not a terminator"
        );
        assert!(scan(&[b"\x1b]777;other;a;b\x07"]).is_empty());
    }

    #[test]
    fn prompt_start() {
        assert_eq!(scan(&[b"\x1b]133;A\x07"]), vec![Event::PromptStart]);
        assert_eq!(scan(&[b"\x1b]133;A;cl=m\x07"]), vec![Event::PromptStart]);
        assert!(scan(&[b"\x1b]133;B\x07"]).is_empty());
    }

    #[test]
    fn other_sequences_and_aborts_are_ignored() {
        assert!(scan(&[b"\x1b]0;title\x07\x1b[31mred\x1b]7501;state=working\x18"]).is_empty());
        // An OSC interrupted by a new one: only the second counts.
        let events = scan(&[b"\x1b]9;lost\x1b]9;kept\x07"]);
        assert_eq!(
            events,
            vec![Event::Notification {
                title: None,
                body: "kept".into()
            }]
        );
    }

    #[test]
    fn c0_controls_inside_an_osc_are_ignored() {
        let events = scan(&[b"\x1b]9;one\ntwo\x07"]);
        assert_eq!(
            events,
            vec![Event::Notification {
                title: None,
                body: "onetwo".into()
            }]
        );
    }

    #[test]
    fn osc_inside_a_dcs_string_is_not_parsed() {
        assert!(scan(&[b"\x1bPq\x1b]9;hidden\x07\x1b\\"]).is_empty());
        assert_eq!(scan(&[b"\x1b_x\x1b\\\x1b]9;shown\x07"]).len(), 1);
    }

    #[test]
    fn over_long_sequences_are_skipped() {
        let mut long = b"\x1b]9;".to_vec();
        long.extend(std::iter::repeat_n(b'x', MAX_OSC + 10));
        long.extend(b"\x07\x1b]9;after\x07");
        let events = scan(&[&long]);
        assert_eq!(
            events,
            vec![Event::Notification {
                title: None,
                body: "after".into()
            }]
        );
    }
}
