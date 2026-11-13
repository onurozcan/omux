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
    /// Set when the session runs in its own git worktree; `directory` is the worktree.
    var worktree: Worktree?
    /// The name follows the title Claude Code gives the conversation until the session is renamed.
    var autoName: Bool
    /// Model and effort chosen for this session from the compose box; applied when it starts.
    var model: String?
    var effort: String?

    init(name: String, directory: String? = nil, command: String? = nil, worktree: Worktree? = nil) {
        self.name = name
        self.autoName = Self.isDefaultName(name)
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
        worktree = try c.decodeIfPresent(Worktree.self, forKey: .worktree)
        autoName = try c.decodeIfPresent(Bool.self, forKey: .autoName) ?? Self.isDefaultName(name)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
    }

    /// A name omux made up, such as "Session 3", as opposed to one the user chose.
    static func isDefaultName(_ name: String) -> Bool {
        guard name.hasPrefix("Session") else { return false }
        let number = name.dropFirst("Session".count)
        return number.isEmpty || (number.first == " " && number.count > 1
            && number.dropFirst().allSatisfy { $0.isASCII && $0.isNumber })
    }

    /// The conversation's topic from a terminal title Claude Code sets, without its status
    /// glyph ("✳ Fix login bug" → "Fix login bug"). nil for titles that aren't a topic.
    static func name(fromTitle title: String) -> String? {
        let topic = String(title.drop { !$0.isLetter && !$0.isNumber })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty, topic.count <= 80, topic.caseInsensitiveCompare("Claude Code") != .orderedSame,
              topic.caseInsensitiveCompare("claude") != .orderedSame else { return nil }
        return topic
    }

    func resolvedProvider(in group: TabGroup) -> SessionProvider {
        provider ?? command.map { SessionProvider.infer(command: $0) } ?? group.provider
    }
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
    /// "terminal" or "transcript" for this project; nil follows Settings.
    var sessionView: String?
    /// Model and effort new sessions start with; nil leaves the agent's default.
    var model: String?
    var effort: String?
    /// When something last happened in the project; projects quiet for days fold into the idle stack.
    var lastActive: Date?
    /// Put in the idle stack by hand; cleared when an agent works in the project again.
    var forcedIdle = false
    /// Kept at the top of the sidebar, above the projects at work, and never folded into the idle stack.
    var pinned = false
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
        sessionView = try c.decodeIfPresent(String.self, forKey: .sessionView)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        lastActive = try c.decodeIfPresent(Date.self, forKey: .lastActive)
        forcedIdle = try c.decodeIfPresent(Bool.self, forKey: .forcedIdle) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        tabs = try c.decodeIfPresent([TabItem].self, forKey: .tabs) ?? []
    }
}

struct Workspace: Codable {
    var groups: [TabGroup] = []
    var selectedTabID: UUID?
    /// Each project's panes, by project id, when it showed more than one session.
    var layouts: [String: PaneLayout] = [:]

    init(groups: [TabGroup] = [], selectedTabID: UUID? = nil, layouts: [String: PaneLayout] = [:]) {
        self.groups = groups; self.selectedTabID = selectedTabID; self.layouts = layouts
    }

    private enum CodingKeys: String, CodingKey { case groups, selectedTabID, layouts, layout }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.decodeIfPresent([TabGroup].self, forKey: .groups) ?? []
        selectedTabID = try? c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        // Layouts a newer version wrote that can't be read are dropped, not the whole workspace.
        layouts = (try? c.decodeIfPresent([String: PaneLayout].self, forKey: .layouts)) ?? [:]
        // Before layouts were per project there was one; it belongs to its first session's project.
        if layouts.isEmpty, let single = try? c.decodeIfPresent(PaneLayout.self, forKey: .layout), let first = single.ids.first,
           let group = groups.first(where: { $0.tabs.contains { $0.id == first } }) {
            layouts[group.id.uuidString] = single
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(groups, forKey: .groups)
        try c.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        try c.encode(layouts, forKey: .layouts)
    }
}

/// Live, non-persisted state of one terminal tab.
struct TabRuntime: Equatable {
    var provider: SessionProvider?
    var agentConnected = false
    /// When Codex's app-server took the session and its TUI command was typed.
    var agentConnectedAt: Date?
    /// Codex's TUI has drawn its prompt (its first idle status line), so it takes input.
    var tuiReady = false
    var title = ""
    var cwd: String?
    var hasActivity = false
    /// When the session last did something: output, a status change, a bell.
    var lastActivity: Date?
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

    /// The state without what changes many times a turn: the status wording, the subagent
    /// records, the window title and the time of the last sign of life. Two states equal in this
    /// look the same to everything but the session's own views.
    var coarse: TabRuntime {
        var copy = self
        copy.statusDetail = nil; copy.statusChildren = []; copy.title = ""; copy.lastActivity = nil
        return copy
    }

    struct StatusChild: Equatable {
        let id: String
        let state: StatusState?
        let kind: String?
        let message: String?
        let title: String?
    }

    /// Claude Code is waiting on a tool permission, which Allow/Deny can answer. It reports plan
    /// approval and peer messages as "permission" too, but their first option isn't a plain
    /// yes; a tool prompt's message reads "approve <Tool>: …", or just "permission prompt" when
    /// it has no description for the call, as with some long Bash commands.
    var awaitsPermission: Bool {
        guard statusState == .blocked, statusKind == "permission" else { return false }
        guard provider != .codex, let message = statusDetail else { return true }
        return message == "permission prompt" || message.range(of: #"^approve [\w-]+: "#, options: .regularExpression) != nil
    }

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
        case .blocked: return Palette.needs
        case .working: return Palette.working
        case .done: return Palette.done
        case .error: return Palette.error
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
