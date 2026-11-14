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
        case inherit = "Project default", claude = "Claude Code", codex = "Codex", shell = "Plain shell", custom = "Custom"
        var id: String { rawValue }
    }

    @State private var name = ""
    @State private var directory = ""
    @State private var mode: CommandMode = .inherit
    @State private var customCommand = ""
    @State private var sessionID = UUID()
    @State private var codexThreadID: String?
    /// Only a fresh start is saved: Codex can assign or replace the thread while the sheet is open.
    @State private var freshConversation = false

    private var provider: SessionProvider {
        switch mode {
        case .inherit: return store.group(containing: tabID)?.provider ?? .shell
        case .claude: return .claude
        case .codex: return .codex
        case .shell: return .shell
        case .custom: return .custom
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
            if !provider.startsAutomatically(in: directory.isEmpty ? group?.directory ?? "~" : directory) {
                HomeFolderHint(provider: provider)
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
            if provider == .claude || provider == .codex {
                LabeledContent(provider == .codex ? "Codex conversation" : "Claude conversation") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider == .codex ? codexThreadID ?? "New conversation" : sessionID.uuidString.lowercased())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button("Start a fresh conversation on next restart") {
                            if provider == .codex { codexThreadID = nil }
                            else { sessionID = UUID() }
                            freshConversation = true
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
            case .shell: mode = .shell
            case .custom: mode = .custom; customCommand = tab.command ?? ""
            case nil:
                switch tab.command {
                case nil: mode = .inherit
                case "": mode = .shell
                case "codex": mode = .codex
                case "claude": mode = .claude
                case let cmd?: mode = .custom; customCommand = cmd
                }
            }
            sessionID = tab.claudeSessionID
            codexThreadID = tab.codexThreadID
        }
    }

    private func save() {
        store.updateTab(tabID) { tab in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed != tab.name { tab.name = trimmed; tab.autoName = false }
            tab.directory = directory.isEmpty ? nil : directory
            switch mode {
            case .inherit: tab.command = nil; tab.provider = nil
            case .claude: tab.command = "claude"; tab.provider = .claude
            case .codex: tab.command = "codex"; tab.provider = .codex
            case .shell: tab.command = ""; tab.provider = .shell
            case .custom: tab.command = customCommand; tab.provider = SessionProvider.infer(command: customCommand)
            }
            if freshConversation {
                if provider == .codex { tab.codexThreadID = nil } else { tab.claudeSessionID = sessionID }
            }
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
    @State private var sessionView = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var host = ""

    private var remote: Bool { !host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            TextField("Name", text: $name)
            MachineField(host: $host)
            Text(remote ? "Sessions run on \(host.trimmingCharacters(in: .whitespaces)) over SSH and keep running there when omux is closed. omux sets itself up on the machine the first time. The folder below is a folder there."
                        : "Leave empty for this Mac. To run this project on another machine, enter how you reach it with ssh: a name from ~/.ssh/config, or user@address.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if remote {
                RemoteFolderField(host: host.trimmingCharacters(in: .whitespaces), folder: $directory)
                HStack {
                    Button("Test") {
                        let machine = host.trimmingCharacters(in: .whitespaces)
                        Task { await RemoteMachines.shared.check(machine, folder: directory.isEmpty ? nil : directory) }
                    }
                    .disabled(!RemoteMachines.isValid(host.trimmingCharacters(in: .whitespaces)))
                    Spacer()
                }
                MachineCheck(host: host.trimmingCharacters(in: .whitespaces), folder: directory.isEmpty ? nil : directory, provider: provider)
            } else {
                HStack {
                    TextField("Folder", text: $directory, prompt: Text("~"))
                    Button("Choose…") { if let dir = chooseDirectory(current: directory) { directory = dir } }
                }
            }
            if !remote, !provider.startsAutomatically(in: directory.isEmpty ? "~" : directory) {
                HomeFolderHint(provider: provider)
            }
            Picker("New sessions", selection: $provider) {
                ForEach(SessionProvider.allCases) { Text($0.label).tag($0) }
            }
            if provider == .custom {
                TextField("Command", text: $command)
            }
            if provider == .claude || provider == .codex {
                TextField("Model", text: $model, prompt: Text(provider == .codex ? "Codex's default" : "claude-opus-5-5, or the plan's default"))
                    .font(.system(.body, design: .monospaced))
                Picker("Effort", selection: $effort) {
                    Text("Default").tag("")
                    ForEach(provider == .codex ? ["low", "medium", "high", "xhigh"] : ["auto", "low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0).tag($0) }
                }
            }
            Picker("Show sessions as", selection: $sessionView) {
                Text("Settings' choice").tag("")
                Text("Terminal").tag("terminal")
                Text("Transcript").tag("transcript")
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
            sessionView = group.sessionView ?? ""
            model = group.model ?? ""
            effort = group.effort ?? ""
            host = group.host ?? ""
        }
    }

    private func save() {
        store.updateGroup(groupID) { group in
            let machine = host.trimmingCharacters(in: .whitespaces)
            // Only what ssh takes as a destination: never something it would read as an option.
            if machine.isEmpty { group.host = nil } else if RemoteMachines.isValid(machine) { group.host = machine; RemoteMachines.shared.remember(machine) }
            group.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? group.name : name
            group.directory = directory.isEmpty ? nil : directory
            group.command = provider == .custom ? command : provider.command
            group.provider = provider == .custom ? SessionProvider.infer(command: command) : provider
            group.useWorktrees = useWorktrees
            group.worktreeSetup = worktreeSetup.trimmingCharacters(in: .whitespacesAndNewlines)
            group.sessionView = sessionView.isEmpty ? nil : sessionView
            let trimmedModel = model.trimmingCharacters(in: .whitespaces)
            group.model = trimmedModel.isEmpty ? nil : trimmedModel
            group.effort = effort.isEmpty ? nil : effort
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
            case .shell, .custom: return nil
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

/// Shown when an agent would open in the home folder, where omux doesn't start it.
private struct HomeFolderHint: View {
    let provider: SessionProvider

    var body: some View {
        Text("Choose a project folder. In your home folder \(provider.label) doesn't start on its own: it would read Downloads, Documents, Pictures and Music, and macOS would ask you about each.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
