//! Paths and local URLs a session mentions in its output: files for the
//! "Mentioned in session" list, local servers for the Browser tab.

use std::path::PathBuf;
use std::sync::OnceLock;

use regex::Regex;

use crate::ui::links::file_path_from;

fn path_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    // The Mac's `(?<![\w])(?:~|/)[\w.+@%~/-]+`; the lookbehind is checked by hand.
    RE.get_or_init(|| Regex::new(r"(?:~|/)[\w.+@%~/-]+").expect("path regex"))
}

fn url_regex() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| {
        Regex::new(
            r#"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\])(?::\d+)?(?:/[^\s'"<>)\]]*)?"#,
        )
        .expect("url regex")
    })
}

/// Pushes `item` to the end, removing an earlier copy: a re-mention counts
/// as the newest.
fn push_unique<T: PartialEq>(list: &mut Vec<T>, item: T) {
    list.retain(|existing| *existing != item);
    list.push(item);
}

/// Existing regular files mentioned in `text`, oldest mention first.
pub fn paths(text: &str) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(m) = path_regex().find_at(text, at) {
        let preceded_by_word = text[..m.start()]
            .chars()
            .next_back()
            .is_some_and(|c| c.is_alphanumeric() || c == '_');
        if preceded_by_word {
            // Like a lookbehind: try again just after the rejected start, so
            // `word~/a/b` still finds `/a/b`.
            let step = text[m.start()..].chars().next().map_or(1, char::len_utf8);
            at = m.start() + step;
            continue;
        }
        if let Some(path) = file_path_from(m.as_str()) {
            push_unique(&mut found, path);
        }
        at = m.end();
    }
    found
}

/// Local server URLs, oldest mention first.
pub fn local_urls(text: &str) -> Vec<String> {
    let mut found = Vec::new();
    for m in url_regex().find_iter(text) {
        let url = m
            .as_str()
            .trim_end_matches(['.', ',', ':', ';'])
            .to_string();
        push_unique(&mut found, url);
    }
    found
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_local_urls_newest_last() {
        let text = "Local: http://localhost:3000/, then http://127.0.0.1:8080/api. Again http://localhost:3000/ and https://example.com";
        assert_eq!(
            local_urls(text),
            vec!["http://127.0.0.1:8080/api", "http://localhost:3000/"]
        );
    }

    #[test]
    fn finds_existing_files_only() {
        let dir = std::env::temp_dir().join(format!("omux-mentions-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("notes.md");
        std::fs::write(&file, "x").unwrap();
        let text = format!(
            "Wrote {}. Also /nope/missing.txt and a{} and ({})",
            file.display(),
            file.display(),
            file.display()
        );
        assert_eq!(paths(&text), vec![file.clone()]);
        assert!(
            paths(&dir.display().to_string()).is_empty(),
            "folders are skipped"
        );
    }
}
