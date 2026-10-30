//! Markdown rendered into a read-only text view, styled like the Mac's
//! preview: sized bold headings, code blocks in a tinted monospace box,
//! bullets and numbers indented per level, quotes with a muted bar.

use gtk::prelude::*;
use pulldown_cmark::{CodeBlockKind, Event, HeadingLevel, Options, Parser, Tag, TagEnd};

const HEADING_SIZES: [f64; 6] = [22.0, 18.0, 15.0, 13.0, 12.0, 12.0];

pub fn render(source: &str, wrap: bool) -> gtk::TextView {
    let view = gtk::TextView::new();
    view.set_editable(false);
    view.set_cursor_visible(false);
    view.set_wrap_mode(gtk::WrapMode::WordChar);
    view.set_left_margin(16);
    view.set_right_margin(16);
    view.set_top_margin(16);
    view.set_bottom_margin(16);
    view.set_pixels_below_lines(2);
    let buffer = view.buffer();
    let tags = buffer.tag_table();
    let tag = |name: &str, setup: &dyn Fn(&gtk::TextTag)| {
        let tag = gtk::TextTag::new(Some(name));
        setup(&tag);
        tags.add(&tag);
    };
    for (i, size) in HEADING_SIZES.iter().enumerate() {
        tag(&format!("h{}", i + 1), &|t| {
            t.set_weight(700);
            t.set_size_points(*size);
            t.set_pixels_above_lines(if i < 2 { 10 } else { 4 });
            t.set_pixels_below_lines(4);
        });
    }
    tag("strong", &|t| t.set_weight(700));
    tag("em", &|t| t.set_style(gtk::pango::Style::Italic));
    tag("strike", &|t| t.set_strikethrough(true));
    tag("code", &|t| {
        t.set_family(Some("monospace"));
        t.set_background_rgba(Some(&gtk::gdk::RGBA::new(0.5, 0.5, 0.5, 0.15)));
    });
    tag("codeblock", &|t| {
        t.set_family(Some("monospace"));
        t.set_size_points(10.0);
        t.set_paragraph_background_rgba(Some(&gtk::gdk::RGBA::new(0.5, 0.5, 0.5, 0.08)));
        t.set_left_margin(24);
        t.set_right_margin(8);
        t.set_wrap_mode(if wrap {
            gtk::WrapMode::WordChar
        } else {
            gtk::WrapMode::None
        });
    });
    tag("quote", &|t| {
        t.set_left_margin(28);
        t.set_foreground_rgba(Some(&gtk::gdk::RGBA::new(0.55, 0.55, 0.55, 1.0)));
    });
    tag("link", &|t| {
        t.set_underline(gtk::pango::Underline::Single);
        t.set_foreground_rgba(Some(&gtk::gdk::RGBA::new(0.04, 0.52, 1.0, 1.0)));
    });
    for level in 1..=6 {
        tag(&format!("list{level}"), &|t| {
            t.set_left_margin(16 + 16 * level)
        });
    }

    let mut active: Vec<String> = Vec::new();
    // Ordered lists keep their next number; bullets keep None.
    let mut lists: Vec<Option<u64>> = Vec::new();
    let mut quote = 0;
    let mut end = buffer.end_iter();
    let insert =
        |buffer: &gtk::TextBuffer, end: &mut gtk::TextIter, text: &str, tags: &[String]| {
            let names: Vec<&str> = tags.iter().map(String::as_str).collect();
            let start = end.offset();
            buffer.insert(end, text);
            let start_iter = buffer.iter_at_offset(start);
            for name in names {
                buffer.apply_tag_by_name(name, &start_iter, end);
            }
        };
    let block_end = |buffer: &gtk::TextBuffer, end: &mut gtk::TextIter| {
        if end.offset() > 0 {
            buffer.insert(end, "\n");
        }
    };

    let options =
        Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TABLES | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(source, options) {
        let mut tags_now = active.clone();
        if quote > 0 {
            tags_now.push("quote".into());
        }
        if let Some(level) = (!lists.is_empty()).then(|| lists.len().min(6)) {
            tags_now.push(format!("list{level}"));
        }
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                let n = match level {
                    HeadingLevel::H1 => 1,
                    HeadingLevel::H2 => 2,
                    HeadingLevel::H3 => 3,
                    HeadingLevel::H4 => 4,
                    HeadingLevel::H5 => 5,
                    HeadingLevel::H6 => 6,
                };
                active.push(format!("h{n}"));
            }
            Event::End(TagEnd::Heading(_)) => {
                active.retain(|t| !t.starts_with('h'));
                block_end(&buffer, &mut end);
            }
            Event::Start(Tag::Strong) => active.push("strong".into()),
            Event::End(TagEnd::Strong) => active.retain(|t| t != "strong"),
            Event::Start(Tag::Emphasis) => active.push("em".into()),
            Event::End(TagEnd::Emphasis) => active.retain(|t| t != "em"),
            Event::Start(Tag::Strikethrough) => active.push("strike".into()),
            Event::End(TagEnd::Strikethrough) => active.retain(|t| t != "strike"),
            Event::Start(Tag::Link { .. }) => active.push("link".into()),
            Event::End(TagEnd::Link) => active.retain(|t| t != "link"),
            Event::Start(Tag::BlockQuote(_)) => quote += 1,
            Event::End(TagEnd::BlockQuote(_)) => quote -= 1,
            Event::Start(Tag::CodeBlock(kind)) => {
                let _ = matches!(kind, CodeBlockKind::Fenced(_));
                active.push("codeblock".into());
            }
            Event::End(TagEnd::CodeBlock) => {
                active.retain(|t| t != "codeblock");
                block_end(&buffer, &mut end);
            }
            Event::Start(Tag::List(start)) => {
                // A nested list starts on its own line.
                if !end.starts_line() {
                    buffer.insert(&mut end, "\n");
                }
                lists.push(start);
            }
            Event::End(TagEnd::List(_)) => {
                lists.pop();
                if lists.is_empty() {
                    block_end(&buffer, &mut end);
                }
            }
            Event::Start(Tag::Item) => {
                let marker = match lists.last_mut() {
                    Some(Some(n)) => {
                        let text = format!("{n}. ");
                        *n += 1;
                        text
                    }
                    _ => "• ".to_string(),
                };
                if !end.starts_line() {
                    buffer.insert(&mut end, "\n");
                }
                insert(&buffer, &mut end, &marker, &tags_now);
            }
            Event::End(TagEnd::Item) => {
                if !end.starts_line() {
                    buffer.insert(&mut end, "\n");
                }
            }
            Event::End(TagEnd::Paragraph) => {
                if lists.is_empty() {
                    buffer.insert(&mut end, "\n");
                    block_end(&buffer, &mut end);
                } else if !end.starts_line() {
                    // Paragraphs of a loose list item stay separate lines.
                    buffer.insert(&mut end, "\n");
                }
            }
            Event::Text(text) => insert(&buffer, &mut end, &text, &tags_now),
            Event::Code(text) => {
                let mut with_code = tags_now.clone();
                with_code.push("code".into());
                insert(&buffer, &mut end, &text, &with_code);
            }
            Event::SoftBreak => buffer.insert(&mut end, " "),
            Event::HardBreak => buffer.insert(&mut end, "\n"),
            Event::Rule => {
                insert(&buffer, &mut end, "──────────\n", &["quote".to_string()]);
            }
            Event::TaskListMarker(done) => {
                insert(&buffer, &mut end, if done { "☑ " } else { "☐ " }, &tags_now);
            }
            Event::End(TagEnd::TableRow | TagEnd::TableHead) => buffer.insert(&mut end, "\n"),
            Event::End(TagEnd::TableCell) => buffer.insert(&mut end, "\t"),
            _ => {}
        }
    }
    view
}
