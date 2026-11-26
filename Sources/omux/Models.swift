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

    /// Whether this session's Claude Code is started without permission prompts: the project
    /// says so and the session's own command doesn't choose a permission mode itself.
    func skipsPermissions(in group: TabGroup) -> Bool {
        guard group.skipPermissions, resolvedProvider(in: group) == .claude else { return false }
        let raw = command ?? group.command ?? ""
        return !raw.contains("--dangerously-skip-permissions") && !raw.contains("--permission-mode")
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
    /// Claude Code starts with --dangerously-skip-permissions: it never asks before a command or an edit.
    var skipPermissions = false
    /// When something last happened in the project; projects quiet for days fold into the idle stack.
    var lastActive: Date?
    /// Put in the idle stack by hand; cleared when an agent works in the project again.
    var forcedIdle = false
    /// Kept at the top of the sidebar, above the projects at work, and never folded into the idle stack.
    var pinned = false
    /// File name of the project's picture in `ProjectIcons.directory`, shown on the rail in place of its initials.
    var icon: String?
    /// An SSH destination, as `ssh` takes it ("devbox", "me@10.0.0.5"), when the project lives
    /// on another machine: its sessions run there and keep running with omux closed. `directory`
    /// is then a folder on that machine. nil for a project on this Mac.
    var host: String?
    var isRemote: Bool { !(host ?? "").isEmpty }
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
        skipPermissions = try c.decodeIfPresent(Bool.self, forKey: .skipPermissions) ?? false
        lastActive = try c.decodeIfPresent(Date.self, forKey: .lastActive)
        forcedIdle = try c.decodeIfPresent(Bool.self, forKey: .forcedIdle) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        host = try c.decodeIfPresent(String.self, forKey: .host)
        tabs = try c.decodeIfPresent(LenientList<TabItem>.self, forKey: .tabs)?.elements ?? []
    }
}

/// Counts what a decode left out, handed to the decoder in `userInfo[.skippedElements]`.
final class SkippedElements {
    var count = 0
}

extension CodingUserInfoKey {
    static let skippedElements = CodingUserInfoKey(rawValue: "omux.skippedElements")!
}

/// Decodes a list one element at a time: an element that can't be read is left out instead of
/// failing the list and everything that holds it, so one bad session doesn't take every project
/// with it. Left-out elements are counted in the decoder's `SkippedElements`, so the file can be
/// kept before a save replaces it.
struct LenientList<Element: Decodable>: Decodable {
    var elements: [Element] = []

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let element = try? c.decode(Element.self) {
                elements.append(element)
                continue
            }
            (decoder.userInfo[.skippedElements] as? SkippedElements)?.count += 1
            // A failed decode doesn't move the container on; this does. Stop if even that fails.
            guard (try? c.decode(Skipped.self)) != nil else { break }
        }
    }

    private struct Skipped: Decodable {
        init(from decoder: Decoder) {}
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
        groups = try c.decodeIfPresent(LenientList<TabGroup>.self, forKey: .groups)?.elements ?? []
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

extension TabRuntime {
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

    /// Built with `./build.sh --beta`: a separate app, preferences and workspace.
    static let isBeta = Bundle.main.bundleIdentifier?.hasSuffix(".beta") == true

    static func workspaceURL(in dir: URL) -> URL { dir.appendingPathComponent("workspace.json") }
    static func backupURL(in dir: URL) -> URL { dir.appendingPathComponent("workspace.json.bak") }

    /// What `loadWorkspace` found.
    struct LoadedWorkspace {
        /// The workspace to open; nil when no file held one.
        var workspace: Workspace?
        /// Copies of files that couldn't be read, or only in part, kept as they were.
        var kept: [URL] = []
    }

    /// Falls back to the previous save if the current file is missing or unreadable. A file that
    /// can't be read in full is copied aside first: the saves that follow replace the workspace
    /// and then its backup, and the projects omux couldn't read would be gone for good.
    static func loadWorkspace(in dir: URL = directory) -> LoadedWorkspace {
        var loaded = LoadedWorkspace()
        for (url, name) in [(workspaceURL(in: dir), "workspace"), (backupURL(in: dir), "workspace-backup")] {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            let skipped = SkippedElements()
            let decoder = JSONDecoder()
            decoder.userInfo[.skippedElements] = skipped
            let workspace = try? decoder.decode(Workspace.self, from: data)
            if workspace == nil || skipped.count > 0, let copy = keep(data, as: name, in: dir) {
                loaded.kept.append(copy)
            }
            if let workspace, !workspace.groups.isEmpty {
                loaded.workspace = workspace
                return loaded
            }
        }
        return loaded
    }

    static func save(_ workspace: Workspace, in dir: URL = directory) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspace) else { return }
        if let current = try? Data(contentsOf: workspaceURL(in: dir)), current != data {
            try? current.write(to: backupURL(in: dir), options: .atomic)
        }
        try? data.write(to: workspaceURL(in: dir), options: .atomic)
    }

    /// Writes `data` beside the workspace under a name with the time in it, never over another
    /// file. A file opened again before anything was saved over it is kept once, not once per
    /// launch. nil when it couldn't be written.
    private static func keep(_ data: Data, as name: String, in dir: URL) -> URL? {
        let prefix = "\(name)-unreadable-"
        for file in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where file.hasPrefix(prefix) {
            let url = dir.appendingPathComponent(file)
            if FileManager.default.contents(atPath: url.path) == data { return url }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        for attempt in 1...20 {
            let url = dir.appendingPathComponent("\(prefix)\(stamp)\(attempt == 1 ? "" : "-\(attempt)").json")
            if (try? data.write(to: url, options: .withoutOverwriting)) != nil { return url }
        }
        return nil
    }
}
