import Foundation
import SwiftUI

enum TabColor: String, Codable, CaseIterable, Identifiable {
    case none, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    var id: String { rawValue }

    var color: Color? {
        switch self {
        case .none: return nil
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .gray: return .gray
        }
    }

    var label: String { self == .none ? "None" : rawValue.capitalized }
}

struct TabItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// nil inherits the group's directory (or the home folder).
    var directory: String?
    /// nil inherits the group's command; "" means a plain shell.
    var command: String?
    /// nil inherits the project, or infers the provider of a legacy command.
    var provider: SessionProvider?
    var color: TabColor = .none
    /// Stable Claude Code session id so the conversation resumes across relaunches.
    var claudeSessionID = UUID()
    /// Assigned by Codex, never guessed from the working directory or latest chat.
    var codexThreadID: String?
    /// Minted by `cursor-agent create-chat` the first time the session runs, so later
    /// launches resume that exact chat instead of starting a new one.
    var cursorChatID: String?
    /// Set when the session runs in its own git worktree; `directory` is the worktree.
    var worktree: Worktree?

    init(name: String, directory: String? = nil, command: String? = nil, worktree: Worktree? = nil) {
        self.name = name
        self.directory = directory
        self.command = command
        self.worktree = worktree
    }

    // Every field is optional on decode so saved workspaces survive schema changes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Session"
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        // A value from a newer version decodes as unset rather than failing the whole workspace.
        provider = try? c.decodeIfPresent(SessionProvider.self, forKey: .provider)
        color = (try? c.decodeIfPresent(TabColor.self, forKey: .color)) ?? .none
        claudeSessionID = try c.decodeIfPresent(UUID.self, forKey: .claudeSessionID) ?? UUID()
        codexThreadID = try c.decodeIfPresent(String.self, forKey: .codexThreadID)
        cursorChatID = try c.decodeIfPresent(String.self, forKey: .cursorChatID)
        worktree = try c.decodeIfPresent(Worktree.self, forKey: .worktree)
    }

    func resolvedProvider(in group: TabGroup) -> SessionProvider {
        provider ?? command.map { SessionProvider.infer(command: $0) } ?? group.provider
    }
}

struct Worktree: Codable, Hashable {
    var branch: String
    /// The branch it was made from; diffs and merges compare against it.
    var base: String
    /// The main checkout that owns the worktree.
    var repo: String
}

struct TabGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var directory: String?
    var command: String? = "claude"
    var provider: SessionProvider = .claude
    var isCollapsed = false
    /// New sessions get their own git worktree.
    var useWorktrees = false
    /// Runs in each new worktree before the session's command, e.g. to copy ignored
    /// files like `.env` or install dependencies. Empty runs nothing.
    var worktreeSetup = ""
    var tabs: [TabItem] = []

    init(name: String, directory: String? = nil, tabs: [TabItem] = []) {
        self.name = name
        self.directory = directory
        self.tabs = tabs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Project"
        directory = try c.decodeIfPresent(String.self, forKey: .directory)
        command = try c.decodeIfPresent(String.self, forKey: .command)
        provider = (try? c.decodeIfPresent(SessionProvider.self, forKey: .provider)) ?? SessionProvider.infer(command: command)
        isCollapsed = try c.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
        useWorktrees = try c.decodeIfPresent(Bool.self, forKey: .useWorktrees) ?? false
        worktreeSetup = try c.decodeIfPresent(String.self, forKey: .worktreeSetup) ?? ""
        tabs = try c.decodeIfPresent([TabItem].self, forKey: .tabs) ?? []
    }
}

struct Workspace: Codable {
    var groups: [TabGroup] = []
    var selectedTabID: UUID?
}

/// Live, non-persisted state of one terminal tab.
struct TabRuntime: Equatable {
    var provider: SessionProvider?
    var agentConnected = false
    var title = ""
    var cwd: String?
    var hasActivity = false
    var needsAttention = false
    var exited = false
    /// A program (e.g. claude) is running in the shell, as opposed to an idle prompt.
    var busy = false
    var statusState: StatusState?
    var statusDetail: String?
    /// Why a blocked program waits: permission, question or auth.
    var statusKind: String?
    /// OSC 7501 records other than the root, e.g. Claude Code's subagents.
    var statusChildren: [StatusChild] = []

    enum StatusState: String { case idle, working, done, blocked, error }

    struct StatusChild: Equatable {
        let id: String
        let state: StatusState?
        let kind: String?
        let message: String?
        let title: String?
    }

    /// Claude Code is waiting on a tool permission, which Allow/Deny can answer.
    var awaitsPermission: Bool { statusState == .blocked && statusKind == "permission" }

    func statusLine(showFolder: Bool = true) -> String? {
        if let s = statusState {
            switch s {
            case .blocked: return (statusDetail ?? statusKind).map { "Needs you · \($0)" } ?? "Needs you"
            case .working: return statusDetail.map { "Working · \($0)" } ?? "Working…"
            case .done: return "Done"
            case .error: return statusDetail.map { "Error · \($0)" } ?? "Error"
            case .idle: break
            }
        }
        if exited { return "Stopped" }
        if !title.isEmpty { return title }
        if showFolder, let cwd { return (cwd as NSString).abbreviatingWithTildeInPath }
        return nil
    }

    var statusColor: Color? {
        switch statusState {
        case .blocked: return .orange
        case .working: return .blue
        case .done: return .green
        case .error: return .red
        default: return nil
        }
    }
}

enum Persistence {
    static let directory: URL = {
        // Development smoke tests can use disposable state without opening or
        // replacing the user's real workspace.
        if let path = ProcessInfo.processInfo.environment["OMUX_WORKSPACE_DIRECTORY"], !path.isEmpty {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // A beta build (./build.sh --beta) keeps its own workspace next to the release one.
        let dir = base.appendingPathComponent(Persistence.isBeta ? "omux-beta" : "omux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static var workspaceURL: URL { directory.appendingPathComponent("workspace.json") }

    /// Built with `./build.sh --beta`: a separate app, preferences and workspace.
    static let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true

    static var backupURL: URL { directory.appendingPathComponent("workspace.json.bak") }

    /// Falls back to the previous save if the current file is missing or unreadable.
    static func loadWorkspace() -> Workspace? {
        for url in [workspaceURL, backupURL] {
            if let data = try? Data(contentsOf: url),
               let workspace = try? JSONDecoder().decode(Workspace.self, from: data),
               !workspace.groups.isEmpty {
                return workspace
            }
        }
        return nil
    }

    static func save(_ workspace: Workspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspace) else { return }
        if let current = try? Data(contentsOf: workspaceURL), current != data {
            try? current.write(to: backupURL, options: .atomic)
        }
        try? data.write(to: workspaceURL, options: .atomic)
    }
}
