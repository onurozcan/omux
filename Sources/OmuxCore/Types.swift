import Foundation

/// A Git worktree a session works in.
public struct Worktree: Codable, Hashable, Sendable {
    public var branch: String
    /// The branch it was made from; diffs and merges compare against it.
    public var base: String
    /// The main checkout that owns the worktree.
    public var repo: String

    public init(branch: String, base: String, repo: String) {
        self.branch = branch; self.base = base; self.repo = repo
    }
}

/// One question of Claude Code's AskUserQuestion dialog.
public struct Question: Equatable, Encodable, Sendable {
    public var text: String
    /// The short tab label Claude Code shows for the question, such as "Auth method".
    public var header: String?
    public var options: [String]
    /// One per option, "" where the option has none.
    public var descriptions: [String]
    public var multi: Bool

    public init(text: String, header: String? = nil, options: [String], descriptions: [String] = [], multi: Bool) {
        self.text = text; self.header = header; self.options = options; self.descriptions = descriptions; self.multi = multi
    }
}

public extension String {
    /// The path with the home folder written as "~", for showing. Foundation's own
    /// `abbreviatingWithTildeInPath` doesn't exist on Linux.
    var tildeAbbreviated: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        return hasPrefix(home + "/") ? "~" + dropFirst(home.count) : self
    }
}
