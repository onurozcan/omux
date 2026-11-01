import Foundation

/// Thin, synchronous wrappers around the git CLI. Call them off the main thread.
enum Git {
    struct Result {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
        /// The most useful text to show when the command failed.
        var message: String {
            let text = err.isEmpty ? out : err
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Runs git directly. `GIT_OPTIONAL_LOCKS=0` keeps status checks from fighting
    /// with whatever git the session itself is running.
    @discardableResult
    static func run(_ args: [String], in dir: String) -> Result {
        exec("/usr/bin/git", args, in: dir, env: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "PATH": loginPath])
    }

    /// The login shell's PATH, looked up once. Opened from Finder, omux only has
    /// /usr/bin:/bin, where hooks, signing and LFS filters can't find npx, gpg or git-lfs.
    static let loginPath: String = {
        let out = login(#"printf '\n%s' "$PATH""#, in: NSHomeDirectory()).out
        let path = out.components(separatedBy: "\n").last ?? ""
        return path.contains("/") ? path : "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }()

    /// Runs a command through the user's login shell, so PATH and credential helpers
    /// match their terminal (needed for push and anything that may call gh).
    @discardableResult
    static func login(_ command: String, in dir: String) -> Result {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return exec(shell, ["-lc", command], in: dir, env: ["GIT_TERMINAL_PROMPT": "0"])
    }

    private static func exec(_ path: String, _ args: [String], in dir: String, env extra: [String: String]) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        extra.forEach { env[$0.key] = $0.value }
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Result(status: -1, out: "", err: error.localizedDescription) }
        // Read both pipes before waiting, stderr on its own thread: a full pipe would
        // otherwise block the child forever (a chatty commit hook fills 64 KB fast).
        var errData = Data()
        let errRead = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: errRead) {
            errData = err.fileHandleForReading.readDataToEndOfFile()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errRead.wait()
        process.waitUntilExit()
        return Result(status: process.terminationStatus,
                      out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self))
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Where the login shell finds gh, looked up once so polling doesn't start a shell
    /// each time. nil when gh isn't installed.
    static let ghPath: String? = {
        let path = login("command -v gh", in: NSHomeDirectory()).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
    }()

    /// Runs the GitHub CLI, or returns nil when it isn't installed.
    static func gh(_ args: [String], in dir: String) -> Result? {
        guard let ghPath else { return nil }
        return exec(ghPath, args, in: dir, env: ["GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0"])
    }

    // MARK: Repository facts

    static func topLevel(_ dir: String) -> String? {
        let r = run(["rev-parse", "--show-toplevel"], in: dir)
        return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// The folder with this checkout's HEAD and index. A linked worktree's is under the
    /// main repository's .git, and a subfolder's is above it, so neither is inside `dir`.
    static func gitDirectory(_ dir: String) -> String? {
        let r = run(["rev-parse", "--absolute-git-dir"], in: dir)
        return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func currentBranch(_ dir: String) -> String? {
        let r = run(["symbolic-ref", "--quiet", "--short", "HEAD"], in: dir)
        return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    static func branches(_ dir: String) -> [String] {
        run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: dir).out
            .split(separator: "\n").map(String.init)
    }

    static func hasUncommittedChanges(_ dir: String) -> Bool {
        uncommittedFileCount(dir) > 0
    }

    /// Changed and new files, a new folder counting once. New files are listed even when
    /// the user's status.showUntrackedFiles=no hides them from `git status`.
    static func uncommittedFileCount(_ dir: String) -> Int {
        run(["status", "--porcelain", "--untracked-files=normal"], in: dir).out.split(separator: "\n").count
    }

    /// Commits on `branch` that aren't in `commit`, or nil when git doesn't have that commit.
    /// `commit` comes from GitHub, so only an object id is taken.
    static func commitCount(after commit: String, on branch: String, in repo: String) -> Int? {
        guard commit.range(of: #"^[0-9a-f]{40,64}\z"#, options: .regularExpression) != nil else { return nil }
        return Int(run(["rev-list", "--count", "\(commit)..refs/heads/\(branch)"], in: repo).out
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A branch name from free text: "Fix the login bug" → "fix-the-login-bug".
    static func slug(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_/."))
        let words = text.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        // Git rejects "..", "//" and components starting with ".": keep only the first of such a run.
        let joined = words.joined(separator: "-").replacingOccurrences(of: #"([./])[./]+"#, with: "$1", options: .regularExpression)
        return String(joined.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-./"))
    }

    // MARK: Worktrees

    /// Where a branch's worktree lives: next to the repo, in `<repo>.worktrees/<branch>`.
    static func worktreePath(repo: String, branch: String) -> String {
        let url = URL(fileURLWithPath: repo)
        return url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".worktrees")
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-")).path
    }

    /// Creates the worktree, reusing the branch when it already exists.
    static func addWorktree(repo: String, branch: String, base: String) -> Result {
        // git builds `git branch <branch> <base>` from these, so "-D" would delete the base.
        guard !branch.hasPrefix("-"), run(["check-ref-format", "--branch", branch], in: repo).ok else {
            return Result(status: 1, out: "", err: "“\(branch)” isn't a valid branch name.")
        }
        let path = worktreePath(repo: repo, branch: branch)
        // "a/b" and "a-b" share a folder; git would create the branch before refusing it.
        if let items = try? FileManager.default.contentsOfDirectory(atPath: path), !items.isEmpty {
            return Result(status: 1, out: "", err: "\(path) is already in use. Pick another branch name.")
        }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if branches(repo).contains(branch) {
            return run(["worktree", "add", path, branch], in: repo)
        }
        return run(["worktree", "add", "-b", branch, path, base], in: repo)
    }

    static func removeWorktree(_ worktree: Worktree, path: String) -> Result {
        let removed = run(["worktree", "remove", "--force", path], in: worktree.repo)
        guard removed.ok else { return removed }
        return run(["branch", "-D", worktree.branch], in: worktree.repo)
    }

    static func commitAll(in dir: String, message: String) -> Result {
        let added = run(["add", "-A"], in: dir)
        guard added.ok else { return added }
        return run(["commit", "-m", message], in: dir)
    }

    /// Merges the worktree's branch into its base in the main checkout.
    static func merge(_ worktree: Worktree) -> Result {
        guard let current = currentBranch(worktree.repo) else {
            return Result(status: 1, out: "", err: "Couldn't read the branch checked out in \(worktree.repo).")
        }
        guard current == worktree.base else {
            return Result(status: 1, out: "", err: "\(worktree.repo) has “\(current)” checked out. Check out “\(worktree.base)” there first.")
        }
        return run(["merge", "--no-edit", worktree.branch], in: worktree.repo)
    }

    /// Pushes the branch and returns the page for opening a pull request, when the
    /// remote is on GitHub.
    static func pushForPullRequest(_ worktree: Worktree, path: String) -> (Result, URL?) {
        let pushed = login("git push -u origin \(quote(worktree.branch))", in: path)
        guard pushed.ok else { return (pushed, nil) }
        let remote = run(["remote", "get-url", "origin"], in: path).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return (pushed, compareURL(remote: remote, base: worktree.base, branch: worktree.branch))
    }

    static func compareURL(remote: String, base: String, branch: String) -> URL? {
        var slug = remote
        for prefix in ["git@github.com:", "ssh://git@github.com/", "https://github.com/", "http://github.com/"] where slug.hasPrefix(prefix) {
            slug = String(slug.dropFirst(prefix.count))
        }
        guard slug != remote else { return nil }
        if slug.hasSuffix(".git") { slug = String(slug.dropLast(4)) }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#"))
        let b = base.addingPercentEncoding(withAllowedCharacters: allowed) ?? base
        let h = branch.addingPercentEncoding(withAllowedCharacters: allowed) ?? branch
        return URL(string: "https://github.com/\(slug)/compare/\(b)...\(h)?expand=1")
    }

    // MARK: Diffs

    /// What a session's changes are measured against: the merge base with the worktree's
    /// base branch, or HEAD for an ordinary checkout. nil when there is no commit yet.
    static func diffBase(dir: String, worktree: Worktree?) -> String? {
        if let worktree {
            let r = run(["merge-base", "HEAD", worktree.base], in: dir)
            if r.ok { return r.out.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return run(["rev-parse", "--verify", "--quiet", "HEAD"], in: dir).ok ? "HEAD" : nil
    }

    /// Changed and untracked files, compared with `base` (working tree included).
    static func changedFiles(dir: String, base: String?) -> [ChangedFile] {
        var files: [ChangedFile] = []
        // Before the first commit, staged files are measured against the empty tree.
        if let base = base ?? emptyTree(dir) {
            // --relative: paths from `dir`, as ls-files and the diff below take them.
            let numstat = run(["diff", "--numstat", "-z", "--no-renames", "--relative", base], in: dir).out
            let status = run(["diff", "--name-status", "-z", "--no-renames", "--relative", base], in: dir).out
            var kinds: [String: ChangedFile.Status] = [:]
            let parts = status.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            var i = 0
            while i + 1 < parts.count {
                kinds[parts[i + 1]] = parts[i].hasPrefix("A") ? .added : parts[i].hasPrefix("D") ? .deleted : .modified
                i += 2
            }
            for record in numstat.split(separator: "\0") {
                let fields = record.split(separator: "\t", maxSplits: 2).map(String.init)
                guard fields.count == 3 else { continue }
                files.append(ChangedFile(path: fields[2], added: Int(fields[0]), removed: Int(fields[1]),
                                         status: kinds[fields[2]] ?? .modified))
            }
        }
        let untracked = run(["ls-files", "--others", "--exclude-standard", "-z"], in: dir).out
        for path in untracked.split(separator: "\0").map(String.init).prefix(300) {
            let full = (dir as NSString).appendingPathComponent(path)
            let lines = textLines(atPath: full)?.count
            files.append(ChangedFile(path: path, added: lines, removed: lines == nil ? nil : 0, status: .untracked))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func emptyTree(_ dir: String) -> String? {
        let r = run(["hash-object", "-t", "tree", "/dev/null"], in: dir)
        return r.ok ? r.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    /// The lines of a small text file, or nil for binaries and big files.
    static func textLines(atPath path: String) -> [String]? {
        // Sized through symlinks, since contents(atPath:) follows them.
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: (path as NSString).resolvingSymlinksInPath),
              (attrs[.size] as? Int ?? .max) < 1_000_000,
              let data = FileManager.default.contents(atPath: path),
              !data.prefix(8000).contains(0),
              let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func diff(dir: String, base: String?, file: ChangedFile) -> [DiffLine] {
        if file.status == .untracked || base == nil {
            guard let lines = textLines(atPath: (dir as NSString).appendingPathComponent(file.path)) else {
                return [DiffLine(index: 0, kind: .info, oldNumber: nil, newNumber: nil, text: "Binary or large file")]
            }
            return [DiffLine(index: 0, kind: .hunk, oldNumber: nil, newNumber: nil, text: "New file")] +
                lines.prefix(3000).enumerated().map { DiffLine(index: $0.offset + 1, kind: .added, oldNumber: nil, newNumber: $0.offset + 1, text: $0.element) }
        }
        // Literal, so a name like "a*" or ":x" isn't read as a pattern.
        let out = run(["--literal-pathspecs", "diff", "--no-color", "--no-ext-diff", "--no-renames", base!, "--", file.path], in: dir).out
        return parseDiff(out)
    }

    static func parseDiff(_ text: String) -> [DiffLine] {
        var lines: [DiffLine] = []
        var old = 0, new = 0, inHunk = false
        let header = try! NSRegularExpression(pattern: #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$"#)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(6000) {
            let line = String(raw)
            if line.hasPrefix("@@"), let m = header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let o = Range(m.range(at: 1), in: line), let n = Range(m.range(at: 2), in: line) {
                old = Int(line[o]) ?? 0
                new = Int(line[n]) ?? 0
                inHunk = true
                lines.append(DiffLine(index: lines.count, kind: .hunk, oldNumber: nil, newNumber: nil, text: line))
            } else if line.hasPrefix("diff ") {
                // A type change (symlink ↔ file) diffs as two files; skip the second's header.
                inHunk = false
            } else if line.hasPrefix("Binary files") {
                lines.append(DiffLine(index: lines.count, kind: .info, oldNumber: nil, newNumber: nil, text: "Binary file changed"))
            } else if !inHunk {
                continue
            } else if line.hasPrefix("+") {
                lines.append(DiffLine(index: lines.count, kind: .added, oldNumber: nil, newNumber: new, text: String(line.dropFirst())))
                new += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(index: lines.count, kind: .removed, oldNumber: old, newNumber: nil, text: String(line.dropFirst())))
                old += 1
            } else if line.hasPrefix(" ") {
                lines.append(DiffLine(index: lines.count, kind: .context, oldNumber: old, newNumber: new, text: String(line.dropFirst())))
                old += 1
                new += 1
            }
        }
        return lines
    }
}

struct ChangedFile: Identifiable, Hashable {
    enum Status { case modified, added, deleted, untracked }
    let path: String
    /// nil for binary files.
    let added: Int?
    let removed: Int?
    let status: Status
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

extension Array where Element == ChangedFile {
    /// Lines added and removed; binary files count for neither.
    var totals: DiffStat {
        DiffStat(added: reduce(0) { $0 + ($1.added ?? 0) }, removed: reduce(0) { $0 + ($1.removed ?? 0) })
    }
}

struct DiffStat: Equatable {
    let added: Int
    let removed: Int
    var isEmpty: Bool { added == 0 && removed == 0 }
}

struct DiffLine: Identifiable, Hashable {
    enum Kind { case hunk, context, added, removed, info }
    let index: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
    var id: Int { index }
    /// The line number a review note refers to.
    var number: Int? { newNumber ?? oldNumber }
}
