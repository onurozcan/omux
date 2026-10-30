import AppKit
import SwiftUI

struct QuickSwitcher: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private struct Match: Identifiable {
        let tab: TabItem
        let group: TabGroup
        var id: UUID { tab.id }
    }

    private var matches: [Match] {
        store.allTabs
            .map { Match(tab: $0.tab, group: $0.group) }
            .filter { m in
                query.isEmpty ||
                    "\(m.tab.name) \(m.group.name) \(store.runtime[m.tab.id]?.title ?? "")"
                    .localizedCaseInsensitiveContains(query)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Jump to session…", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($focused)
                .onSubmit { if let first = matches.first { pick(first.id) } }
            Divider()
            List(matches.prefix(15)) { match in
                Button { pick(match.id) } label: {
                    HStack {
                        Circle()
                            .fill(store.runtime[match.id]?.statusColor ?? match.tab.color.color ?? Color.secondary.opacity(0.35))
                            .frame(width: 8, height: 8)
                        Text(match.tab.name)
                        Text(match.group.name).foregroundStyle(.secondary)
                        Spacer()
                        if let line = store.runtime[match.id]?.statusLine() {
                            Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 460, height: 380)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func pick(_ id: UUID) {
        store.selectedTabID = id
        dismiss()
    }
}

private func chooseDirectory(current: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if !current.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
    }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct TabEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let tabID: UUID

    private enum CommandMode: String, CaseIterable, Identifiable {
        case inherit = "Project default", claude = "Claude Code", codex = "Codex",
             cursor = "Cursor CLI", shell = "Plain shell", custom = "Custom"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var directory = ""
    @State private var mode: CommandMode = .inherit
    @State private var customCommand = ""
    @State private var sessionID = UUID()
    @State private var codexThreadID: String?
    @State private var cursorChatID: String?

    private var provider: SessionProvider {
        switch mode {
        case .inherit: return store.group(containing: tabID)?.provider ?? .shell
        case .claude: return .claude
        case .codex: return .codex
        case .cursor: return .cursor
        case .shell: return .shell
        case .custom: return .custom
        }
    }

    /// What the session resumes next time, as the agent that owns it names it.
    private var conversationID: String {
        switch provider {
        case .codex: return codexThreadID ?? "New conversation"
        case .cursor: return cursorChatID ?? "New chat"
        default: return sessionID.uuidString.lowercased()
        }
    }

    var body: some View {
        let group = store.group(containing: tabID)
        Form {
            TextField("Name", text: $name)
            HStack {
                TextField("Folder", text: $directory, prompt: Text(group?.directory ?? "~"))
                Button("Choose…") { if let dir = chooseDirectory(current: directory) { directory = dir } }
            }
            Picker("Command", selection: $mode) {
                ForEach(CommandMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if mode == .custom {
                TextField("Command", text: $customCommand, prompt: Text("claude"))
            } else if mode == .inherit {
                Text(group?.command?.isEmpty == false ? group!.command! : "plain shell")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if provider == .claude || provider == .codex || provider == .cursor {
                LabeledContent("\(provider.agentName) conversation") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(conversationID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button("Start a fresh conversation on next restart") {
                            switch provider {
                            case .codex: codexThreadID = nil
                            case .cursor: cursorChatID = nil
                            default: sessionID = UUID()
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let tab = store.tab(tabID) else { return }
            name = tab.name
            directory = tab.directory ?? ""
            switch tab.provider {
            case .claude:
                if let command = tab.command, command != "claude" { mode = .custom; customCommand = command }
                else { mode = .claude }
            case .codex: mode = .codex
            case .cursor:
                if let command = tab.command, command != "cursor-agent" { mode = .custom; customCommand = command }
                else { mode = .cursor }
            case .shell: mode = .shell
            case .custom: mode = .custom; customCommand = tab.command ?? ""
            case nil:
                switch tab.command {
                case nil: mode = .inherit
                case "": mode = .shell
                case "codex": mode = .codex
                case "claude": mode = .claude
                case "cursor-agent": mode = .cursor
                case let cmd?: mode = .custom; customCommand = cmd
                }
            }
            sessionID = tab.claudeSessionID
            codexThreadID = tab.codexThreadID
            cursorChatID = tab.cursorChatID
        }
    }

    private func save() {
        store.updateTab(tabID) { tab in
            tab.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? tab.name : name
            tab.directory = directory.isEmpty ? nil : directory
            switch mode {
            case .inherit: tab.command = nil; tab.provider = nil
            case .claude: tab.command = "claude"; tab.provider = .claude
            case .codex: tab.command = "codex"; tab.provider = .codex
            case .cursor: tab.command = "cursor-agent"; tab.provider = .cursor
            case .shell: tab.command = ""; tab.provider = .shell
            case .custom: tab.command = customCommand; tab.provider = SessionProvider.infer(command: customCommand)
            }
            tab.claudeSessionID = sessionID
            tab.codexThreadID = codexThreadID
            tab.cursorChatID = cursorChatID
        }
        dismiss()
    }
}

struct GroupEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID

    @State private var name = ""
    @State private var directory = ""
    @State private var command = ""
    @State private var provider = SessionProvider.claude
    @State private var useWorktrees = false
    @State private var worktreeSetup = ""

    var body: some View {
        Form {
            TextField("Name", text: $name)
            HStack {
                TextField("Folder", text: $directory, prompt: Text("~"))
                Button("Choose…") { if let dir = chooseDirectory(current: directory) { directory = dir } }
            }
            Picker("New sessions", selection: $provider) {
                ForEach(SessionProvider.allCases) { Text($0.label).tag($0) }
            }
            if provider == .custom {
                TextField("Command", text: $command)
            }
            Text("Applies when a session starts. Existing sessions keep running.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Give new sessions their own Git worktree", isOn: $useWorktrees)
            TextField("Worktree setup", text: $worktreeSetup, prompt: Text("cp \"$OMUX_REPO/.env\" . && npm install"))
                .font(.system(.body, design: .monospaced))
            Text(WorktreeSetupHint.text)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let group = store.groups.first(where: { $0.id == groupID }) else { return }
            name = group.name
            directory = group.directory ?? ""
            command = group.command ?? ""
            provider = command == group.provider.command ? group.provider : .custom
            useWorktrees = group.useWorktrees
            worktreeSetup = group.worktreeSetup
        }
    }

    private func save() {
        store.updateGroup(groupID) { group in
            group.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? group.name : name
            group.directory = directory.isEmpty ? nil : directory
            group.command = provider == .custom ? command : provider.command
            group.provider = provider == .custom ? SessionProvider.infer(command: command) : provider
            group.useWorktrees = useWorktrees
            group.worktreeSetup = worktreeSetup.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        dismiss()
    }
}

struct RecentSessionsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [RecentConversation] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var byFolder = false
    @State private var provider = SessionProvider.claude
    @State private var error: String?
    @FocusState private var focused: Bool

    private var matches: [RecentConversation] {
        sessions.filter { query.isEmpty || "\($0.prompt) \($0.folder)".localizedCaseInsensitiveContains(query) }
    }

    /// Folders ordered by their most recent session; sessions stay newest-first within each.
    private var folders: [(folder: String, sessions: [RecentConversation])] {
        var order: [String] = []
        var grouped: [String: [RecentConversation]] = [:]
        for session in matches {
            if grouped[session.folder] == nil { order.append(session.folder) }
            grouped[session.folder, default: []].append(session)
        }
        return order.map { ($0, grouped[$0]!) }
    }

    private var openIDs: Set<String> {
        Set(store.allTabs.compactMap { entry in
            switch store.provider(of: entry.tab) {
            case .claude: return "claude:" + entry.tab.claudeSessionID.uuidString.lowercased()
            case .codex: return entry.tab.codexThreadID.map { "codex:" + $0 }
            // Cursor chats aren't in this list; it reads Claude's and Codex's own stores.
            case .cursor, .shell, .custom: return nil
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search recent conversations…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if let first = matches.first { pick(first) } }
                Picker("", selection: $byFolder) {
                    Text("Recent").tag(false)
                    Text("By folder").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)
            Picker("Agent", selection: $provider) {
                Text("Claude Code").tag(SessionProvider.claude)
                Text("Codex").tag(SessionProvider.codex)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                Text(error ?? (sessions.isEmpty ? "No \(provider.label) conversations found" : "No matches"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if byFolder {
                        ForEach(folders, id: \.folder) { entry in
                            Section(entry.folder) {
                                ForEach(entry.sessions) { row($0, showFolder: false) }
                            }
                        }
                    } else {
                        ForEach(matches) { row($0, showFolder: true) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 560, height: 440)
        .onAppear { provider = store.selectedProvider == .codex ? .codex : .claude }
        .onExitCommand { dismiss() }
        .task(id: provider) {
            focused = true
            loaded = false; error = nil; sessions = []
            do {
                let result: [RecentConversation]
                if provider == .codex {
                    result = try await CodexManager.shared.recent().map(RecentConversation.codex)
                } else {
                    result = await Task.detached { RecentSession.load().map(RecentConversation.claude) }.value
                }
                guard !Task.isCancelled else { return }
                sessions = result; loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; loaded = true
            }
        }
    }

    private func row(_ session: RecentConversation, showFolder: Bool) -> some View {
        Button { pick(session) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.prompt).lineLimit(1)
                    Spacer()
                    if openIDs.contains(session.id) {
                        Text("open").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if showFolder { Text(session.folder) }
                    Spacer()
                    Text(session.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ session: RecentConversation) {
        switch session {
        case .claude(let recent): store.openClaudeSession(recent)
        case .codex(let recent): store.openCodexSession(recent)
        }
        dismiss()
    }
}
