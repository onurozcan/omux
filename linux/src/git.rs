//! Git, worktree and diff logic: thin synchronous wrappers around the `git` CLI plus
//! the pure string rules around them (branch slugs, worktree paths, GitHub compare
//! URLs, diff parsing, dialog texts). No GTK here; the UI calls these from worker
//! threads. Mirrors `Git.swift`, `Worktrees.swift` and `Changes.swift`.

use std::cmp::Ordering;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::OnceLock;

pub struct GitResult {
    pub status: i32,
    pub out: String,
    pub err: String,
}

impl GitResult {
    pub fn ok(&self) -> bool {
        self.status == 0
    }

    /// The most useful text to show when the command failed.
    pub fn message(&self) -> String {
        let text = if self.err.is_empty() {
            &self.out
        } else {
            &self.err
        };
        text.trim().to_string()
    }
}

fn exec(program: &str, args: &[&str], dir: &Path, env: &[(&str, &str)]) -> GitResult {
    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(dir)
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    match cmd.output() {
        Ok(o) => GitResult {
            status: o.status.code().unwrap_or(-1),
            out: String::from_utf8_lossy(&o.stdout).into_owned(),
            err: String::from_utf8_lossy(&o.stderr).into_owned(),
        },
        Err(e) => GitResult {
            status: -1,
            out: String::new(),
            err: e.to_string(),
        },
    }
}

/// Runs git directly. `GIT_OPTIONAL_LOCKS=0` keeps status checks from fighting with
/// whatever git the session itself is running.
pub fn run(args: &[&str], dir: &Path) -> GitResult {
    exec(
        "git",
        args,
        dir,
        &[("GIT_OPTIONAL_LOCKS", "0"), ("GIT_TERMINAL_PROMPT", "0")],
    )
}

/// Runs a command through the user's login shell, so PATH and credential helpers
/// match their terminal (needed for push and for locating gh).
pub fn login(cmd: &str, dir: &Path) -> GitResult {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into());
    exec(&shell, &["-lc", cmd], dir, &[("GIT_TERMINAL_PROMPT", "0")])
}

pub fn quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

/// Where the login shell finds gh, looked up once so polling doesn't start a shell
/// each time.
fn gh_path() -> Option<&'static str> {
    static PATH: OnceLock<Option<String>> = OnceLock::new();
    PATH.get_or_init(|| {
        let home = std::env::var("HOME").unwrap_or_else(|_| "/".into());
        let out = login("command -v gh", Path::new(&home)).out;
        let path = out.trim();
        path.starts_with('/').then(|| path.to_string())
    })
    .as_deref()
}

/// Runs the GitHub CLI, or returns None when it isn't installed.
pub fn gh(args: &[&str], dir: &Path) -> Option<GitResult> {
    let path = gh_path()?;
    Some(exec(
        path,
        args,
        dir,
        &[("GH_PROMPT_DISABLED", "1"), ("GIT_TERMINAL_PROMPT", "0")],
    ))
}

// MARK: Repository facts

pub fn top_level(dir: &Path) -> Option<PathBuf> {
    let r = run(&["rev-parse", "--show-toplevel"], dir);
    r.ok().then(|| PathBuf::from(r.out.trim()))
}

pub fn current_branch(dir: &Path) -> Option<String> {
    let r = run(&["symbolic-ref", "--quiet", "--short", "HEAD"], dir);
    r.ok().then(|| r.out.trim().to_string())
}

pub fn local_branches(dir: &Path) -> Vec<String> {
    run(
        &["for-each-ref", "--format=%(refname:short)", "refs/heads"],
        dir,
    )
    .out
    .lines()
    .filter(|l| !l.is_empty())
    .map(String::from)
    .collect()
}

/// Number of lines in `git status --porcelain` (uncommitted files).
pub fn dirty_count(dir: &Path) -> usize {
    run(&["status", "--porcelain"], dir)
        .out
        .lines()
        .filter(|l| !l.is_empty())
        .count()
}

/// Commits on `branch` that are not in `base`.
pub fn ahead_count(repo: &Path, base: &str, branch: &str) -> usize {
    let range = format!("{base}..{branch}");
    run(&["rev-list", "--count", &range], repo)
        .out
        .trim()
        .parse()
        .unwrap_or(0)
}

pub fn remote_url(dir: &Path) -> String {
    run(&["remote", "get-url", "origin"], dir)
        .out
        .trim()
        .to_string()
}

/// A branch name from free text: "Fix the login bug" -> "fix-the-login-bug".
pub fn slug(name: &str) -> String {
    let lower = name.to_lowercase();
    let words: Vec<&str> = lower
        .split(|c: char| !(c.is_alphanumeric() || "-_/.".contains(c)))
        .filter(|w| !w.is_empty())
        .collect();
    // Git rejects "..", "//" and components starting with ".": keep only
    // the first of such a run.
    let mut collapsed = String::new();
    for c in words.join("-").chars() {
        let run = matches!(c, '.' | '/') && collapsed.ends_with(['.', '/']);
        if !run {
            collapsed.push(c);
        }
    }
    let joined: String = collapsed.chars().take(48).collect();
    joined.trim_matches(['-', '.', '/']).to_string()
}

// MARK: Worktrees

/// Where a branch's worktree lives: next to the repo, in `<repo>.worktrees/<branch>`.
pub fn worktree_path(repo: &Path, branch: &str) -> PathBuf {
    let name = repo
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let parent = repo.parent().unwrap_or_else(|| Path::new("/"));
    parent
        .join(format!("{name}.worktrees"))
        .join(branch.replace('/', "-"))
}

fn check(r: GitResult) -> Result<(), String> {
    if r.ok() {
        Ok(())
    } else {
        Err(r.message())
    }
}

/// Creates the worktree at `path`, reusing the branch when it already exists.
pub fn add_worktree(repo: &Path, path: &Path, branch: &str, base: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let p = path.to_string_lossy();
    if local_branches(repo).iter().any(|b| b == branch) {
        check(run(&["worktree", "add", &p, branch], repo))
    } else {
        check(run(&["worktree", "add", "-b", branch, &p, base], repo))
    }
}

pub fn remove_worktree(repo: &Path, path: &Path, branch: &str) -> Result<(), String> {
    let p = path.to_string_lossy();
    check(run(&["worktree", "remove", "--force", &p], repo))?;
    check(run(&["branch", "-D", branch], repo))
}

pub fn commit_all(dir: &Path, message: &str) -> Result<(), String> {
    check(run(&["add", "-A"], dir))?;
    check(run(&["commit", "-m", message], dir))
}

/// Merges `branch` into `base` in the main checkout; returns git's output.
pub fn merge(repo: &Path, base: &str, branch: &str) -> Result<String, String> {
    let shown = repo.display();
    let Some(current) = current_branch(repo) else {
        return Err(format!("Couldn't read the branch checked out in {shown}."));
    };
    if current != base {
        return Err(format!(
            "{shown} has \u{201c}{current}\u{201d} checked out. Check out \u{201c}{base}\u{201d} there first."
        ));
    }
    let r = run(&["merge", "--no-edit", branch], repo);
    if r.ok() {
        let out = r.out.trim();
        Ok(if out.is_empty() {
            r.message()
        } else {
            out.into()
        })
    } else {
        Err(r.message())
    }
}

/// Pushes through the login shell so the user's credential helpers apply.
pub fn push(dir: &Path, branch: &str) -> Result<(), String> {
    check(login(&format!("git push -u origin {}", quote(branch)), dir))
}

/// The page for opening a pull request; GitHub remotes only.
pub fn compare_url(remote: &str, base: &str, branch: &str) -> Option<String> {
    let mut slug = remote;
    for prefix in [
        "git@github.com:",
        "ssh://git@github.com/",
        "https://github.com/",
        "http://github.com/",
    ] {
        if let Some(rest) = slug.strip_prefix(prefix) {
            slug = rest;
        }
    }
    if slug == remote {
        return None;
    }
    let slug = slug.strip_suffix(".git").unwrap_or(slug);
    Some(format!(
        "https://github.com/{slug}/compare/{}...{}?expand=1",
        encode_path(base),
        encode_path(branch)
    ))
}

/// Percent-encoding with the URL path set minus `?` and `#`.
fn encode_path(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~!$&'()*+,/:;=@".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

// MARK: Dialog texts

fn plural(n: usize, word: &str) -> String {
    format!("{n} {word}{}", if n == 1 { "" } else { "s" })
}

pub fn close_title(name: &str) -> String {
    format!("Close \u{201c}{name}\u{201d}?")
}

/// Body of the Close Session dialog. `merged_pr` is the number of a merged pull request.
pub fn close_text(
    branch: &str,
    base: &str,
    dirty: usize,
    ahead: usize,
    merged_pr: Option<u64>,
) -> String {
    if let Some(n) = merged_pr {
        let mut text = format!("Its pull request #{n} was merged.");
        if dirty > 0 {
            text += &format!(" The worktree has {}.", plural(dirty, "uncommitted file"));
        }
        return text;
    }
    let mut facts = Vec::new();
    if dirty > 0 {
        facts.push(plural(dirty, "uncommitted file"));
    }
    if ahead > 0 {
        facts.push(format!("{} not in {base}", plural(ahead, "commit")));
    }
    if facts.is_empty() {
        format!(
            "Its worktree on \u{201c}{branch}\u{201d} has nothing that isn't already in {base}."
        )
    } else {
        format!(
            "Its worktree on \u{201c}{branch}\u{201d} has {}.",
            facts.join(" and ")
        )
    }
}

pub fn cleanup_title(name: &str) -> String {
    format!("Delete the worktree for \u{201c}{name}\u{201d}?")
}

pub fn cleanup_text(branch: &str, merged_pr: Option<u64>, dirty: usize) -> String {
    let number = merged_pr.map(|n| format!(" in #{n}")).unwrap_or_default();
    let mut text = format!(
        "\u{201c}{branch}\u{201d} was merged{number}. This closes the session and deletes its worktree and local branch."
    );
    if dirty > 0 {
        text += &format!(" {} will be lost.", plural(dirty, "uncommitted file"));
    }
    text
}

pub fn commit_title(dirty: usize) -> String {
    format!("Commit {} first?", plural(dirty, "changed file"))
}

pub fn commit_text(branch: &str) -> String {
    format!("They'll be committed to \u{201c}{branch}\u{201d}. Uncommitted changes aren't part of a merge or pull request.")
}

// MARK: Diffs

/// What a session's changes are measured against: the merge base with the worktree's
/// base branch, or HEAD for an ordinary checkout. None when there is no commit yet.
pub fn diff_base(dir: &Path, worktree_base: Option<&str>) -> Option<String> {
    if let Some(base) = worktree_base {
        let r = run(&["merge-base", "HEAD", base], dir);
        if r.ok() {
            return Some(r.out.trim().to_string());
        }
    }
    run(&["rev-parse", "--verify", "--quiet", "HEAD"], dir)
        .ok()
        .then(|| "HEAD".to_string())
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChangedFile {
    pub path: String,
    /// 'A' added, 'D' deleted, 'M' modified, 'U' untracked.
    pub status: char,
    /// None for binary files.
    pub added: Option<usize>,
    pub removed: Option<usize>,
}

/// The lines of a small text file, or None for binaries and big files.
pub fn text_lines(path: &Path) -> Option<Vec<String>> {
    if fs::metadata(path).ok()?.len() >= 1_000_000 {
        return None;
    }
    let mut data = Vec::new();
    fs::File::open(path).ok()?.read_to_end(&mut data).ok()?;
    if data.iter().take(8000).any(|&b| b == 0) {
        return None;
    }
    let text = String::from_utf8(data).ok()?;
    let mut lines: Vec<String> = text.split('\n').map(String::from).collect();
    if lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    Some(lines)
}

/// Changed and untracked files, compared with `base` (working tree included).
pub fn changed_files(dir: &Path, base: Option<&str>) -> Vec<ChangedFile> {
    let mut files = Vec::new();
    if let Some(base) = base {
        let numstat = run(&["diff", "--numstat", "-z", "--no-renames", base], dir).out;
        let status = run(&["diff", "--name-status", "-z", "--no-renames", base], dir).out;
        let parts: Vec<&str> = status.split('\0').collect();
        let mut kinds = std::collections::HashMap::new();
        let mut i = 0;
        while i + 1 < parts.len() {
            let kind = match parts[i].chars().next() {
                Some('A') => 'A',
                Some('D') => 'D',
                _ => 'M',
            };
            kinds.insert(parts[i + 1], kind);
            i += 2;
        }
        for record in numstat.split('\0').filter(|r| !r.is_empty()) {
            let mut fields = record.splitn(3, '\t');
            let (Some(a), Some(r), Some(path)) = (fields.next(), fields.next(), fields.next())
            else {
                continue;
            };
            files.push(ChangedFile {
                path: path.to_string(),
                status: kinds.get(path).copied().unwrap_or('M'),
                added: a.parse().ok(),
                removed: r.parse().ok(),
            });
        }
    }
    let untracked = run(&["ls-files", "--others", "--exclude-standard", "-z"], dir).out;
    for path in untracked.split('\0').filter(|p| !p.is_empty()).take(300) {
        let lines = text_lines(&dir.join(path)).map(|l| l.len());
        files.push(ChangedFile {
            path: path.to_string(),
            status: 'U',
            added: lines,
            removed: lines.map(|_| 0),
        });
    }
    files.sort_by(|a, b| natural_cmp(&a.path, &b.path));
    files
}

fn digit_run(it: &mut std::iter::Peekable<std::str::Chars<'_>>) -> String {
    let mut n = String::new();
    while let Some(&c) = it.peek() {
        if !c.is_ascii_digit() {
            break;
        }
        n.push(c);
        it.next();
    }
    n.trim_start_matches('0').to_string()
}

/// Case-insensitive comparison with digit runs compared numerically, like Finder.
fn natural_cmp(a: &str, b: &str) -> Ordering {
    let (mut a, mut b) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (a.peek().copied(), b.peek().copied()) {
            (None, None) => return Ordering::Equal,
            (None, _) => return Ordering::Less,
            (_, None) => return Ordering::Greater,
            (Some(x), Some(y)) if x.is_ascii_digit() && y.is_ascii_digit() => {
                let (na, nb) = (digit_run(&mut a), digit_run(&mut b));
                let ord = na.len().cmp(&nb.len()).then_with(|| na.cmp(&nb));
                if ord != Ordering::Equal {
                    return ord;
                }
            }
            (Some(x), Some(y)) => {
                let ord = x.to_lowercase().cmp(y.to_lowercase());
                if ord != Ordering::Equal {
                    return ord;
                }
                a.next();
                b.next();
            }
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiffKind {
    Added,
    Removed,
    Context,
    Hunk,
    Info,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiffLine {
    pub kind: DiffKind,
    pub text: String,
    pub old_number: Option<usize>,
    pub new_number: Option<usize>,
}

impl DiffLine {
    /// The line number a review note refers to.
    pub fn number(&self) -> Option<usize> {
        self.new_number.or(self.old_number)
    }
}

fn line(kind: DiffKind, text: &str, old: Option<usize>, new: Option<usize>) -> DiffLine {
    DiffLine {
        kind,
        text: text.to_string(),
        old_number: old,
        new_number: new,
    }
}

pub fn diff(dir: &Path, base: Option<&str>, file: &ChangedFile) -> Vec<DiffLine> {
    let base = match base {
        Some(b) if file.status != 'U' => b,
        _ => {
            let Some(lines) = text_lines(&dir.join(&file.path)) else {
                return vec![line(DiffKind::Info, "Binary or large file", None, None)];
            };
            let mut out = vec![line(DiffKind::Hunk, "New file", None, None)];
            out.extend(
                lines
                    .iter()
                    .take(3000)
                    .enumerate()
                    .map(|(i, l)| line(DiffKind::Added, l, None, Some(i + 1))),
            );
            return out;
        }
    };
    let out = run(
        &[
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--no-renames",
            base,
            "--",
            &file.path,
        ],
        dir,
    )
    .out;
    parse_diff(&out)
}

/// Parses `@@ -a[,b] +c[,d] @@ rest`, returning the two start numbers.
fn parse_hunk_header(l: &str) -> Option<(usize, usize)> {
    fn number(s: &str) -> Option<(usize, &str)> {
        let end = s.find(|c: char| !c.is_ascii_digit()).unwrap_or(s.len());
        let n = s[..end].parse().ok()?;
        let mut rest = &s[end..];
        if let Some(r) = rest.strip_prefix(',') {
            let e = r.find(|c: char| !c.is_ascii_digit()).unwrap_or(r.len());
            if e == 0 {
                return None;
            }
            rest = &r[e..];
        }
        Some((n, rest))
    }
    let (old, rest) = number(l.strip_prefix("@@ -")?)?;
    let (new, rest) = number(rest.strip_prefix(" +")?)?;
    rest.starts_with(" @@").then_some((old, new))
}

pub fn parse_diff(text: &str) -> Vec<DiffLine> {
    let mut lines = Vec::new();
    let (mut old, mut new, mut in_hunk) = (0, 0, false);
    for l in text.split('\n').take(6000) {
        if let Some((o, n)) = parse_hunk_header(l) {
            (old, new, in_hunk) = (o, n, true);
            lines.push(line(DiffKind::Hunk, l, None, None));
        } else if l.starts_with("diff ") {
            // A type change (symlink ↔ file) diffs as two files; skip the second's header.
            in_hunk = false;
        } else if l.starts_with("Binary files") {
            lines.push(line(DiffKind::Info, "Binary file changed", None, None));
        } else if !in_hunk {
            continue;
        } else if let Some(t) = l.strip_prefix('+') {
            lines.push(line(DiffKind::Added, t, None, Some(new)));
            new += 1;
        } else if let Some(t) = l.strip_prefix('-') {
            lines.push(line(DiffKind::Removed, t, Some(old), None));
            old += 1;
        } else if let Some(t) = l.strip_prefix(' ') {
            lines.push(line(DiffKind::Context, t, Some(old), Some(new)));
            old += 1;
            new += 1;
        }
    }
    lines
}

/// The message typed into the session for review notes: (path, line number, text).
pub fn review_message(notes: &[(String, Option<usize>, String)]) -> String {
    let body: Vec<String> = notes
        .iter()
        .map(|(path, n, text)| match n {
            Some(n) => format!("- {path}:{n}: {text}"),
            None => format!("- {path}: {text}"),
        })
        .collect();
    format!("Review notes on your changes:\n{}", body.join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Once;

    fn setup_env() {
        static ONCE: Once = Once::new();
        ONCE.call_once(|| {
            for (k, v) in [
                ("GIT_AUTHOR_NAME", "t"),
                ("GIT_AUTHOR_EMAIL", "t@example.com"),
                ("GIT_COMMITTER_NAME", "t"),
                ("GIT_COMMITTER_EMAIL", "t@example.com"),
                ("GIT_CONFIG_GLOBAL", "/dev/null"),
                ("GIT_CONFIG_SYSTEM", "/dev/null"),
            ] {
                std::env::set_var(k, v);
            }
        });
    }

    /// A fresh repo on `main` with one commit, in its own temp dir.
    fn temp_repo() -> PathBuf {
        setup_env();
        let root = std::env::temp_dir().join(format!("omux-git-{}", uuid::Uuid::new_v4()));
        let repo = root.join("repo");
        fs::create_dir_all(&repo).unwrap();
        let repo = repo.canonicalize().unwrap();
        assert!(run(&["init", "-q", "-b", "main"], &repo).ok());
        fs::write(repo.join("a.txt"), "one\ntwo\n").unwrap();
        commit_all(&repo, "init").unwrap();
        repo
    }

    fn cleanup(repo: &Path) {
        let _ = fs::remove_dir_all(repo.parent().unwrap());
    }

    #[test]
    fn slug_rules() {
        assert_eq!(slug("Fix the login bug"), "fix-the-login-bug");
        assert_eq!(slug("  --Feature/Add_API v2.0!! "), "feature/add_api-v2.0");
        assert_eq!(slug("???"), "");
        assert_eq!(slug(&"a".repeat(60)).len(), 48);
        assert_eq!(slug(&format!("{}-b", "a".repeat(47))), "a".repeat(47));
    }

    #[test]
    fn worktree_path_layout() {
        assert_eq!(
            worktree_path(Path::new("/home/u/proj"), "feat/x"),
            PathBuf::from("/home/u/proj.worktrees/feat-x")
        );
    }

    #[test]
    fn quoting() {
        assert_eq!(quote("main"), "'main'");
        assert_eq!(quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn compare_urls() {
        let want = "https://github.com/o/r/compare/main...feat/x?expand=1";
        for remote in [
            "git@github.com:o/r.git",
            "ssh://git@github.com/o/r.git",
            "https://github.com/o/r",
            "http://github.com/o/r.git",
        ] {
            assert_eq!(compare_url(remote, "main", "feat/x").as_deref(), Some(want));
        }
        assert_eq!(compare_url("git@gitlab.com:o/r.git", "main", "x"), None);
        assert_eq!(
            compare_url("https://github.com/o/r", "main", "a b#c?d").as_deref(),
            Some("https://github.com/o/r/compare/main...a%20b%23c%3Fd?expand=1")
        );
    }

    #[test]
    fn dialog_texts() {
        assert_eq!(close_title("S"), "Close \u{201c}S\u{201d}?");
        assert_eq!(
            close_text("b", "main", 2, 1, None),
            "Its worktree on \u{201c}b\u{201d} has 2 uncommitted files and 1 commit not in main."
        );
        assert_eq!(
            close_text("b", "main", 0, 0, None),
            "Its worktree on \u{201c}b\u{201d} has nothing that isn't already in main."
        );
        assert_eq!(
            close_text("b", "main", 1, 0, Some(7)),
            "Its pull request #7 was merged. The worktree has 1 uncommitted file."
        );
        assert_eq!(
            cleanup_text("b", Some(7), 3),
            "\u{201c}b\u{201d} was merged in #7. This closes the session and deletes its worktree and local branch. 3 uncommitted files will be lost."
        );
        assert_eq!(commit_title(1), "Commit 1 changed file first?");
    }

    #[test]
    fn parses_diffs() {
        let text = "diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -3,3 +3,4 @@ fn main\n ctx\n-gone\n+new1\n+new2\n\\ No newline at end of file\n more\n";
        let d = parse_diff(text);
        let kinds: Vec<_> = d.iter().map(|l| l.kind).collect();
        assert_eq!(
            kinds,
            [
                DiffKind::Hunk,
                DiffKind::Context,
                DiffKind::Removed,
                DiffKind::Added,
                DiffKind::Added,
                DiffKind::Context
            ]
        );
        assert_eq!(d[0].text, "@@ -3,3 +3,4 @@ fn main");
        assert_eq!((d[1].old_number, d[1].new_number), (Some(3), Some(3)));
        assert_eq!((d[2].old_number, d[2].new_number), (Some(4), None));
        assert_eq!((d[3].old_number, d[3].new_number), (None, Some(4)));
        assert_eq!(d[4].new_number, Some(5));
        assert_eq!((d[5].old_number, d[5].new_number), (Some(5), Some(6)));
        assert_eq!(d[2].number(), Some(4));
        assert_eq!(d[3].text, "new1");

        let b = parse_diff("diff --git a/x b/x\nBinary files a/x and b/x differ\n");
        assert_eq!(b.len(), 1);
        assert_eq!(
            (b[0].kind, b[0].text.as_str()),
            (DiffKind::Info, "Binary file changed")
        );
        assert!(parse_diff("--- a\n+++ b\n+stray\n").is_empty());
        assert_eq!(parse_diff("@@ -1 +1 @@\n+x").len(), 2);
    }

    #[test]
    fn review_message_format() {
        let notes = vec![
            ("src/a.rs".to_string(), Some(12), "rename this".to_string()),
            ("b.txt".to_string(), None, "why?".to_string()),
        ];
        assert_eq!(
            review_message(&notes),
            "Review notes on your changes:\n- src/a.rs:12: rename this\n- b.txt: why?"
        );
    }

    #[test]
    fn natural_order() {
        let mut v = vec!["b10", "B2", "a", "b1"];
        v.sort_by(|a, b| natural_cmp(a, b));
        assert_eq!(v, ["a", "b1", "B2", "b10"]);
    }

    #[test]
    fn repo_queries_and_changes() {
        let repo = temp_repo();
        assert_eq!(top_level(&repo.join(".")), Some(repo.clone()));
        assert_eq!(current_branch(&repo).as_deref(), Some("main"));
        assert_eq!(local_branches(&repo), ["main"]);
        assert_eq!(dirty_count(&repo), 0);
        assert_eq!(diff_base(&repo, None).as_deref(), Some("HEAD"));

        fs::write(repo.join("a.txt"), "one\nTWO\nthree\n").unwrap();
        fs::write(repo.join("new.txt"), "x\ny\n").unwrap();
        fs::write(repo.join("bin.dat"), [0u8, 1, 2]).unwrap();
        assert_eq!(dirty_count(&repo), 3);

        let files = changed_files(&repo, Some("HEAD"));
        let got: Vec<_> = files
            .iter()
            .map(|f| (f.path.as_str(), f.status, f.added, f.removed))
            .collect();
        assert_eq!(
            got,
            [
                ("a.txt", 'M', Some(2), Some(1)),
                ("bin.dat", 'U', None, None),
                ("new.txt", 'U', Some(2), Some(0)),
            ]
        );

        let d = diff(&repo, Some("HEAD"), &files[0]);
        assert_eq!(d[0].kind, DiffKind::Hunk);
        assert!(d
            .iter()
            .any(|l| l.kind == DiffKind::Removed && l.text == "two"));
        assert!(d
            .iter()
            .any(|l| l.kind == DiffKind::Added && l.text == "three"));

        let n = diff(&repo, Some("HEAD"), &files[2]);
        assert_eq!(n.len(), 3);
        assert_eq!(n[0].text, "New file");
        assert_eq!(n[2].new_number, Some(2));
        assert_eq!(
            diff(&repo, Some("HEAD"), &files[1])[0].text,
            "Binary or large file"
        );

        // A committed binary change reports no counts.
        commit_all(&repo, "bin").unwrap();
        fs::write(repo.join("bin.dat"), [0u8, 9, 9, 9]).unwrap();
        let files = changed_files(&repo, Some("HEAD"));
        assert_eq!((files[0].path.as_str(), files[0].added), ("bin.dat", None));
        cleanup(&repo);
    }

    #[test]
    fn worktree_lifecycle_and_merge() {
        let repo = temp_repo();
        let path = worktree_path(&repo, "feat/x");
        add_worktree(&repo, &path, "feat/x", "main").unwrap();
        assert!(path.join("a.txt").exists());
        assert_eq!(current_branch(&path).as_deref(), Some("feat/x"));
        assert_eq!(
            top_level(&path).map(|p| p.canonicalize().unwrap()),
            Some(path.canonicalize().unwrap())
        );

        fs::write(path.join("w.txt"), "w\n").unwrap();
        assert_eq!(dirty_count(&path), 1);
        let base = diff_base(&path, Some("main")).unwrap();
        assert_eq!(changed_files(&path, Some(&base))[0].path, "w.txt");
        commit_all(&path, "work").unwrap();
        assert_eq!(ahead_count(&repo, "main", "feat/x"), 1);

        assert!(merge(&repo, "other", "feat/x")
            .unwrap_err()
            .contains("Check out"));
        merge(&repo, "main", "feat/x").unwrap();
        assert!(repo.join("w.txt").exists());

        remove_worktree(&repo, &path, "feat/x").unwrap();
        assert!(!path.exists());
        assert_eq!(local_branches(&repo), ["main"]);

        // An existing branch is reused.
        run(&["branch", "again"], &repo);
        add_worktree(&repo, &worktree_path(&repo, "again"), "again", "main").unwrap();
        cleanup(&repo);
    }

    #[test]
    fn no_commit_lists_only_untracked() {
        setup_env();
        let root = std::env::temp_dir().join(format!("omux-git-{}", uuid::Uuid::new_v4()));
        let repo = root.join("repo");
        fs::create_dir_all(&repo).unwrap();
        run(&["init", "-q"], &repo);
        fs::write(repo.join("u.txt"), "u\n").unwrap();
        assert_eq!(diff_base(&repo, None), None);
        let files = changed_files(&repo, None);
        assert_eq!(files.len(), 1);
        assert_eq!(files[0].status, 'U');
        cleanup(&repo);
    }

    #[test]
    fn slug_collapses_runs_git_rejects() {
        assert_eq!(slug("Fix the login bug"), "fix-the-login-bug");
        assert_eq!(slug("Refactor... auth"), "refactor.-auth");
        assert_eq!(slug("docs //notes"), "docs-/notes");
        assert_eq!(slug("foo /.hidden"), "foo-/hidden");
    }

    #[test]
    fn type_change_diff_skips_the_second_file_header() {
        let diff = "diff --git a/link b/link\ndeleted file mode 120000\n--- a/link\n+++ /dev/null\n@@ -1 +0,0 @@\n-target\n\\ No newline at end of file\ndiff --git a/link b/link\nnew file mode 100644\n--- /dev/null\n+++ b/link\n@@ -0,0 +1,2 @@\n+one\n+two\n";
        let lines: Vec<DiffLine> = parse_diff(diff)
            .into_iter()
            .filter(|l| l.kind != DiffKind::Hunk)
            .collect();
        assert_eq!(
            lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>(),
            ["target", "one", "two"]
        );
        assert_eq!(
            lines.iter().map(|l| l.new_number).collect::<Vec<_>>(),
            [None, Some(1), Some(2)]
        );
    }
}
