import AppKit
import Combine
import SwiftUI

extension UUID: Identifiable {
    public var id: UUID { self }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var groups: [TabGroup]
    @Published var selectedTabID: UUID? {
        didSet {
            // Deferred: this fires inside the List's selection update.
            guard let id = selectedTabID else { return }
            DispatchQueue.main.async { [weak self] in
                self?.clearAttention(id)
                self?.refreshBusy(id)
            }
        }
    }
    @Published private(set) var runtime: [UUID: TabRuntime] = [:] {
        didSet {
            let count = runtime.values.filter(\.needsAttention).count
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
    }
    @Published var renamingID: UUID?
    @Published var editingTabID: UUID?
    @Published var editingGroupID: UUID?
    @Published var showQuickSwitcher = false
    @Published var showRecentSessions = false
    @Published var showWelcome = false
    /// A file the user ⌘-clicked in a terminal; the files panel shows it.
    @Published var previewRequest: String?
    /// File paths mentioned in the selected session's output, newest last.
    @Published private(set) var mentionedPaths: [String] = []
    /// Local server URLs (localhost, …) in the selected session's output, newest last.
    @Published private(set) var mentionedURLs: [String] = []
    /// The project a "New Session in Worktree" sheet is open for.
    @Published var newWorktreeGroupID: UUID?
    var newWorktreeProvider: SessionProvider?
    /// The subagent whose transcript the files panel shows.
    @Published var openAgent: AgentRef?
    @Published var openCodexAgent: CodexAgentRef?
    /// A git action in progress per session ("Pushing…"), shown in the Changes tab.
    @Published var gitActivity: [UUID: String] = [:]
    /// One web view per session, kept while the session lives.
    private var browsers: [UUID: BrowserSession] = [:]

    private var terminals: [UUID: TermView] = [:]
    private var codexStarts: [UUID: Task<Void, Never>] = [:]
    /// A worktree setup command to run before a new Codex session's TUI starts.
    private var codexSetup: [UUID: String] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let saved = Persistence.loadWorkspace()
        var groups = saved?.groups ?? []
        if groups.isEmpty {
            groups = [TabGroup(name: "Default", tabs: [TabItem(name: "Session 1")])]
        }
        self.groups = groups
        let allIDs = Set(groups.flatMap { $0.tabs.map(\.id) })
        if let sel = saved?.selectedTabID, allIDs.contains(sel) {
            selectedTabID = sel
        } else {
            selectedTabID = groups.first(where: { !$0.tabs.isEmpty })?.tabs.first?.id
        }

        $groups.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
        $selectedTabID.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                if let id = Store.shared.selectedTabID { Store.shared.clearAttention(id) }
            }
        }

        CodexManager.shared.onStatus = { [weak self] id, status in
            guard let self, self.runtime[id]?.provider == .codex, self.terminals[id] != nil else { return }
            self.applyStatus(status.state, kind: status.kind, message: status.detail, children: [], for: id)
            self.update(id) {
                $0.busy = status.state == .working || status.state == .blocked
                if !CodexManager.shared.isConnected(id) { $0.agentConnected = false }
            }
        }
        CodexManager.shared.onThreadChange = { [weak self] id, thread in
            self?.updateTab(id) { $0.codexThreadID = thread }
            self?.save()
        }
        if saved == nil { save() }
        // Fresh installs (no workspace yet) get the welcome sheet; updates don't. It stays under
        // Help › Welcome to omux. A beat later, so the window is there to present it on.
        if !UserDefaults.standard.bool(forKey: Prefs.welcomed) {
            UserDefaults.standard.set(true, forKey: Prefs.welcomed)
            if saved == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcome = true }
            }
        }
        if UserDefaults.standard.bool(forKey: Prefs.autoResume) {
            startAllSessions()
        } else {
            // Restored tabs stay dormant until selected (shell) or played (claude).
            for entry in allTabs { runtime[entry.tab.id] = TabRuntime(exited: true) }
        }
    }

    // MARK: Lookup

    func location(of tabID: UUID) -> (group: Int, tab: Int)? {
        for (g, group) in groups.enumerated() {
            if let t = group.tabs.firstIndex(where: { $0.id == tabID }) { return (g, t) }
        }
        return nil
    }

    func tab(_ id: UUID) -> TabItem? {
        location(of: id).map { groups[$0.group].tabs[$0.tab] }
    }

    func group(containing tabID: UUID) -> TabGroup? {
        location(of: tabID).map { groups[$0.group] }
    }

    var selectedTab: TabItem? { selectedTabID.flatMap(tab) }

    func provider(of tab: TabItem) -> SessionProvider {
        runtime[tab.id]?.provider ?? group(containing: tab.id).map { tab.resolvedProvider(in: $0) } ?? .shell
    }

    var selectedProvider: SessionProvider { selectedTab.map(provider(of:)) ?? .shell }

    var selectedGroup: TabGroup? {
        selectedTabID.flatMap(group(containing:)) ?? groups.first
    }

    var allTabs: [(tab: TabItem, group: TabGroup)] {
        groups.flatMap { g in g.tabs.map { ($0, g) } }
    }

    var runningSessionCount: Int {
        terminals.keys.filter { !(runtime[$0]?.exited ?? false) }.count
    }

    // MARK: Terminal lifecycle

    /// The live view for a tab; a dormant tab gets a plain shell (no claude) on first show.
    func terminal(for tabID: UUID) -> TermView? {
        if let view = terminals[tabID] { return view }
        guard let loc = location(of: tabID) else { return nil }
        return makeTerminal(tab: groups[loc.group].tabs[loc.tab], group: groups[loc.group],
                            command: UserDefaults.standard.bool(forKey: Prefs.autoResume) ? nil : "")
    }

    private func startAllSessions() {
        let all = allTabs
        let ordered = all.filter { $0.tab.id == selectedTabID } + all.filter { $0.tab.id != selectedTabID }
        var delay: TimeInterval = 0
        for entry in ordered {
            let id = entry.tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.terminals[id] == nil, let loc = self.location(of: id) else { return }
                _ = self.makeTerminal(tab: self.groups[loc.group].tabs[loc.tab], group: self.groups[loc.group])
            }
            delay += 0.25
        }
    }

    @discardableResult
    private func makeTerminal(tab: TabItem, group: TabGroup, command: String? = nil) -> TermView {
        let view = TermView(tabID: tab.id)
        terminals[tab.id] = view
        // A replaced view (restart) still reports its exit; only the current one may update the tab.
        view.onEvent = { [weak self, weak view] event in
            guard let self, let view, self.terminals[tab.id] === view else { return }
            self.handle(event, for: tab.id)
        }
        launch(view, tab: tab, group: group, command: command)
        return view
    }

    private func launch(_ view: TermView, tab: TabItem, group: TabGroup, command: String?) {
        let home = NSHomeDirectory()
        var dir = ((tab.directory ?? group.directory) as NSString?)?.expandingTildeInPath ?? home
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) || !isDir.boolValue { dir = home }

        let inherited = ProcessInfo.processInfo.environment
        let shell = inherited["SHELL"] ?? "/bin/zsh"
        // A clean login environment, like Terminal.app: nothing leaks in from whoever
        // launched omux (e.g. a Claude session's CLAUDE_CODE_* markers).
        var env: [String: String] = [
            "HOME": home,
            "USER": inherited["USER"] ?? NSUserName(),
            "LOGNAME": inherited["LOGNAME"] ?? NSUserName(),
            "SHELL": shell,
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "omux",
        ]
        if let enc = inherited["__CF_USER_TEXT_ENCODING"] { env["__CF_USER_TEXT_ENCODING"] = enc }
        if let codexHome = inherited["CODEX_HOME"] { env["CODEX_HOME"] = codexHome }
        let provider = tab.resolvedProvider(in: group)
        if provider == .codex {
            env["OMUX_CODEX_TOKEN"] = CodexManager.shared.connection(for: tab.id).token
        }
        // Lets a worktree's setup reach the main checkout, e.g. `cp "$OMUX_REPO/.env" .`.
        if let worktree = tab.worktree { env["OMUX_REPO"] = worktree.repo }

        view.startProcess(
            executable: shell,
            args: ["-l"],
            environment: env.map { "\($0.key)=\($0.value)" },
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: dir
        )
        update(tab.id) {
            $0.provider = provider; $0.agentConnected = false
            $0.exited = false; $0.cwd = dir; $0.title = ""
            $0.statusState = nil; $0.statusKind = nil; $0.statusDetail = nil; $0.statusChildren = []
        }

        if provider == .codex, command == nil {
            startCodex(view, tab: tab, cwd: dir)
        } else if let command = command ?? startupCommand(tab: tab, group: group), !command.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                view.send(txt: command + "\n")
            }
        }
    }

    private func startCodex(_ view: TermView, tab: TabItem, cwd: String) {
        guard codexStarts[tab.id] == nil else { return }
        update(tab.id) { $0.busy = true; $0.statusState = .working; $0.statusDetail = "Connecting to Codex…" }
        codexStarts[tab.id] = Task { [weak self, weak view] in
            defer {
                if let self, let view, self.terminals[tab.id] === view { self.codexStarts[tab.id] = nil }
            }
            do {
                let launch = try await CodexManager.shared.prepare(tabID: tab.id, threadID: tab.codexThreadID, cwd: cwd, name: tab.name)
                try Task.checkCancellation()
                guard let self, let view, self.terminals[tab.id] === view else { return }
                self.updateTab(tab.id) { $0.codexThreadID = launch.threadID }
                self.save()
                self.update(tab.id) { $0.agentConnected = true; $0.busy = false }
                let setup = self.codexSetup.removeValue(forKey: tab.id)
                view.send(txt: (setup.map { Self.afterSetup($0, launch.command) } ?? launch.command) + "\n")
            } catch {
                guard !Task.isCancelled, let self, let view, self.terminals[tab.id] === view else { return }
                self.update(tab.id) { $0.busy = false; $0.statusState = .error; $0.statusDetail = error.localizedDescription }
            }
        }
    }

    private func closeCodex(_ id: UUID) {
        codexStarts.removeValue(forKey: id)?.cancel()
        CodexManager.shared.close(id)
    }

    /// Kills the shell and everything it spawned (claude, node, …), not just the shell.
    private func killTree(_ view: TermView) {
        let pid = view.process.shellPid
        if pid > 0 { Darwin.kill(-pid, SIGHUP) }
        view.terminate()
    }

    /// Stops a session: its whole process tree is killed and the tab shows as stopped.
    /// Interrupts whatever runs in the shell, like Ctrl-C. Sent twice because Claude Code
    /// asks for a second Ctrl-C to exit. The shell itself stays at its prompt.
    func stop(_ id: UUID) {
        if runtime[id]?.provider == .codex {
            if codexStarts[id] != nil { kill(id); return }
            Task {
                do { try await CodexManager.shared.interrupt(id) }
                catch { Self.showError("Couldn't interrupt Codex", error.localizedDescription) }
            }
            return
        }
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return }
        view.send(txt: "\u{03}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { view.send(txt: "\u{03}") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshBusy(id) }
    }

    /// Force-kills the session's whole process tree; the tab shows as exited.
    func kill(_ id: UUID) {
        closeCodex(id)
        guard let view = terminals[id] else { return }
        killTree(view)
        update(id) { $0.exited = true; $0.statusState = nil; $0.busy = false; $0.agentConnected = false }
    }

    /// Rescans the selected session's scrollback for file paths and local URLs (background, cheap).
    func scanMentionedPaths() {
        guard let id = selectedTabID, let view = terminals[id] else { mentionedPaths = []; mentionedURLs = []; return }
        // Read the buffer on the main actor; match and check files off it.
        let text = view.scrollbackText()
        Task { [weak self] in
            let (paths, urls) = await Task.detached {
                (TermView.mentionedPaths(in: text), TermView.mentionedLocalURLs(in: text))
            }.value
            guard let self, self.selectedTabID == id else { return }
            if self.mentionedPaths != paths { self.mentionedPaths = paths }
            if self.mentionedURLs != urls { self.mentionedURLs = urls }
        }
    }

    /// Types text into a session's prompt as a paste; `submit` presses Return after it.
    func sendText(_ text: String, to id: UUID, submit: Bool) {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return }
        view.paste(text)
        if submit {
            // A beat later, so the program has taken the paste before Return arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { view.send(txt: "\r") }
        }
    }

    /// Whether the program in the session takes a paste as one block, without acting on its newlines.
    func acceptsBracketedPaste(_ id: UUID) -> Bool {
        terminals[id]?.terminalInputStateSnapshot()?.bracketedPasteMode == true
    }

    /// Answers Claude Code's permission prompt: Return picks its default "Yes",
    /// Escape is its "No, and tell Claude what to do differently".
    func answerPermission(_ id: UUID, allow: Bool) {
        if runtime[id]?.provider == .codex {
            Task {
                do { try await CodexManager.shared.answer(tabID: id, allow: allow) }
                catch { Self.showError("Couldn't answer Codex", error.localizedDescription) }
            }
            return
        }
        guard let view = terminals[id], runtime[id]?.awaitsPermission == true else { return }
        view.send(txt: allow ? "\r" : "\u{1b}")
    }

    /// Shows the right panel on the given tab.
    func showPanel(_ tab: PanelTab) {
        UserDefaults.standard.set(true, forKey: Prefs.showFiles)
        UserDefaults.standard.set(tab.rawValue, forKey: Prefs.panelTab)
    }

    func openAgentTranscript(_ agent: SubAgent, in tabID: UUID) {
        openCodexAgent = nil
        openAgent = AgentRef(tabID: tabID, agent: agent)
        showPanel(.files)
    }

    func browser(for id: UUID) -> BrowserSession {
        if let browser = browsers[id] { return browser }
        let browser = BrowserSession(tabID: id)
        browsers[id] = browser
        return browser
    }

    /// Re-checks whether the shell has a child process (claude, a build, …).
    func refreshBusy(_ id: UUID) {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return }
        let pid = view.process.shellPid
        let busy = pid > 0 && Self.hasChildProcess(of: pid)
        if runtime[id]?.provider == .codex {
            guard codexStarts[id] == nil else { return }
            if !busy { update(id) { $0.agentConnected = false; $0.busy = false } }
            return
        }
        update(id) { $0.busy = busy }
    }

    private static func hasChildProcess(of pid: pid_t) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return false }
        return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { $0.kp_eproc.e_ppid == pid }
    }

    /// Starts the selected provider in an idle shell or resumes its exact saved chat.
    func start(_ id: UUID) {
        guard let loc = location(of: id) else { return }
        let tab = groups[loc.group].tabs[loc.tab]
        if let view = terminals[id], !(runtime[id]?.exited ?? true) {
            if runtime[id]?.provider == .codex, runtime[id]?.statusState == .error,
               !CodexManager.shared.isConnected(id) {
                restart(id)
                return
            }
            guard !Self.hasChildProcess(of: view.process.shellPid), codexStarts[id] == nil else { return }
            if runtime[id]?.provider != tab.resolvedProvider(in: groups[loc.group]) { restart(id); return }
        }
        if tab.resolvedProvider(in: groups[loc.group]) != .claude {
            if let view = terminals[id], !(runtime[id]?.exited ?? true) {
                // A live Codex TUI is not an idle shell, even when its agent is idle.
                if provider(of: tab) == .codex {
                    startCodex(view, tab: tab, cwd: runtime[id]?.cwd ?? directory(of: tab) ?? NSHomeDirectory())
                } else if let command = startupCommand(tab: tab, group: groups[loc.group]), !command.isEmpty {
                    view.send(txt: command + "\n")
                }
            } else {
                restart(id)
            }
            return
        }
        let session = tab.claudeSessionID.uuidString.lowercased()
        let command = startupCommand(tab: tab, group: groups[loc.group]) ?? "claude --session-id \(session)"
        if let view = terminals[id], !(runtime[id]?.exited ?? true) {
            guard !(runtime[id]?.busy ?? false) else { return }
            view.send(txt: command + "\n")
        } else {
            terminals.removeValue(forKey: id)?.removeFromSuperview()
            makeTerminal(tab: tab, group: groups[loc.group], command: command)
            objectWillChange.send()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshBusy(id) }
    }

    /// Resolves the tab's command and, for `claude`, pins it to the tab's session id so the
    /// conversation resumes on relaunch.
    func startupCommand(tab: TabItem, group: TabGroup) -> String? {
        let raw = (tab.command ?? group.command ?? "").trimmingCharacters(in: .whitespaces)
        if tab.resolvedProvider(in: group) == .shell { return nil }
        guard !raw.isEmpty else { return nil }
        guard tab.resolvedProvider(in: group) == .claude else { return raw }
        let session = tab.claudeSessionID.uuidString.lowercased()
        return SessionProvider.claudeCommand(raw, sessionID: tab.claudeSessionID, conversationExists: Self.claudeSessionExists(session))
    }

    /// Claude Code writes each conversation to ~/.claude/projects/<project>/<session>.jsonl.
    private static func claudeSessionExists(_ session: String) -> Bool {
        let projects = NSHomeDirectory() + "/.claude/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return false }
        return dirs.contains { FileManager.default.fileExists(atPath: "\(projects)/\($0)/\(session).jsonl") }
    }

    /// A project's folder may be typed as "~/app" or "/Users/me/app/"; Finder and agents
    /// report "/Users/me/app".
    private static func samePath(_ directory: String?, _ path: String) -> Bool {
        func normalized(_ p: String) -> String { ((p as NSString).expandingTildeInPath as NSString).standardizingPath }
        return directory.map(normalized) == normalized(path)
    }

    /// Opens a folder as a new group with one Claude session inside it.
    func openFolder(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        if let existing = groups.first(where: { Self.samePath($0.directory, path) }) {
            newTab(in: existing.id)
            return
        }
        let group = TabGroup(name: (path as NSString).lastPathComponent, directory: path, tabs: [TabItem(name: "Session 1")])
        groups.append(group)
        makeTerminal(tab: group.tabs[0], group: group)
        selectedTabID = group.tabs[0].id
    }

    /// Opens an existing Claude conversation as a session in the project for its folder.
    func openClaudeSession(_ recent: RecentSession) {
        if let existing = allTabs.first(where: { $0.tab.claudeSessionID == recent.id && provider(of: $0.tab) == .claude }) {
            selectedTabID = existing.tab.id
            return
        }
        let gi: Int
        if let index = groups.firstIndex(where: { Self.samePath($0.directory, recent.cwd) }) {
            gi = index
        } else {
            groups.append(TabGroup(name: (recent.cwd as NSString).lastPathComponent, directory: recent.cwd))
            gi = groups.count - 1
        }
        var tab = TabItem(name: recent.tabName.isEmpty ? "Session" : recent.tabName)
        if UserDefaults.standard.bool(forKey: Prefs.inheritClaudeSessionName),
           let title = ClaudeTitle.load(session: recent.id.uuidString.lowercased()).best {
            tab.name = title
            tab.claudeTitle = title
        }
        tab.provider = .claude
        tab.command = "claude"
        tab.claudeSessionID = recent.id
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        makeTerminal(tab: tab, group: groups[gi])
        selectedTabID = tab.id
    }

    func openCodexSession(_ recent: CodexConversation) {
        if let existing = allTabs.first(where: { $0.tab.codexThreadID == recent.id && provider(of: $0.tab) == .codex }) {
            selectedTabID = existing.tab.id
            return
        }
        let groupID: UUID
        if let group = groups.first(where: { Self.samePath($0.directory, recent.cwd) }) {
            groupID = group.id
        } else {
            var group = TabGroup(name: (recent.cwd as NSString).lastPathComponent, directory: recent.cwd)
            group.provider = .codex; group.command = "codex"
            groups.append(group); groupID = group.id
        }
        var tab = TabItem(name: String(recent.name.prefix(60)), command: "codex")
        tab.provider = .codex; tab.codexThreadID = recent.id
        addSession(tab, to: groupID)
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { openFolder($0.path) }
    }

    private func handle(_ event: TermEvent, for id: UUID) {
        switch event {
        case .bell:
            if !isWatching(id) { update(id) { $0.needsAttention = true } }
        case .title(let title):
            refreshBusy(id)
            // Claude Code rewrites the title as its state changes; treat that as activity.
            update(id) {
                if $0.title != title, !isWatching(id) { $0.hasActivity = true }
                $0.title = title
            }
        case .directory(let dir):
            update(id) { $0.cwd = dir }
        case .exited:
            update(id) { $0.exited = true; $0.statusState = nil; $0.statusKind = nil; $0.statusChildren = []; $0.busy = false }
        case .openPath(let path):
            previewRequest = path
        case .status(let state, let kind, let message, let children):
            // Codex also emits terminal OSC status. Its protocol is authoritative,
            // particularly for approval IDs; mixing both can revive stale buttons.
            guard runtime[id]?.provider != .codex else { return }
            applyStatus(state, kind: kind, message: message, children: children, for: id)
        case .notification(let title, let body):
            guard !isWatching(id) else { return }
            update(id) { $0.needsAttention = true }
            if UserDefaults.standard.object(forKey: Prefs.notifyPrograms) as? Bool ?? true {
                notify(id, subtitle: title, body: body)
            }
        }
    }

    private func applyStatus(_ state: TabRuntime.StatusState?, kind: String?, message: String?, children: [TabRuntime.StatusChild], for id: UUID) {
        let previous = runtime[id]?.statusState
        update(id) {
            $0.statusState = state; $0.statusKind = kind; $0.statusDetail = message; $0.statusChildren = children
            if state == .blocked || state == .done, !isWatching(id) { $0.needsAttention = true }
        }
        if state != previous { notifyStatusChange(id) }
    }

    /// Notifies when a session you aren't looking at starts waiting on you, or finishes.
    /// Only on a change of state, so a session that stays blocked notifies once.
    private func notifyStatusChange(_ id: UUID) {
        guard !isWatching(id), let rt = runtime[id], let state = rt.statusState else { return }
        let enabled: Bool
        switch state {
        case .blocked: enabled = UserDefaults.standard.object(forKey: Prefs.notifyNeedsYou) as? Bool ?? true
        case .done, .error: enabled = UserDefaults.standard.bool(forKey: Prefs.notifyDone)
        case .idle, .working: enabled = false
        }
        guard enabled, let line = rt.statusLine(showFolder: false) else { return }
        notify(id, body: line)
    }

    /// The session's name as the title, its project (or the program's own title) under it.
    private func notify(_ id: UUID, subtitle: String? = nil, body: String) {
        guard let tab = tab(id) else { return }
        Notifier.shared.post(tabID: id, title: tab.name, subtitle: subtitle ?? group(containing: id)?.name, body: body)
    }

    /// Brings omux forward on a session, e.g. from a click on its notification.
    func reveal(_ id: UUID) {
        guard tab(id) != nil else { return }
        AppDelegate.openWindow?(id: "main")
        NSApp.activate()
        selectedTabID = id
    }

    private func isWatching(_ id: UUID) -> Bool {
        selectedTabID == id && NSApp.isActive && NSApp.keyWindow != nil
    }

    /// Flags a session for something that happened outside its terminal, like its pull
    /// request's checks failing.
    func requestAttention(_ id: UUID) {
        if !isWatching(id) { update(id) { $0.needsAttention = true } }
    }

    private func clearAttention(_ id: UUID) {
        update(id) { $0.hasActivity = false; $0.needsAttention = false }
        Notifier.shared.clear(tabID: id)
    }

    private func update(_ id: UUID, _ mutate: (inout TabRuntime) -> Void) {
        var value = runtime[id] ?? TabRuntime()
        let before = value
        mutate(&value)
        if value != before { runtime[id] = value }
    }

    // MARK: Tabs

    func newTab(in groupID: UUID? = nil, command: String? = nil) {
        guard let gi = groups.firstIndex(where: { $0.id == (groupID ?? selectedGroup?.id) }) ?? groups.indices.first else {
            newGroup()
            return
        }
        if command != "", groups[gi].useWorktrees {
            newWorktreeProvider = command.map { SessionProvider.infer(command: $0) }
            newWorktreeGroupID = groups[gi].id
            return
        }
        let tab = TabItem(name: "Session \(groups[gi].tabs.count + 1)", command: command)
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        makeTerminal(tab: tab, group: groups[gi])
        selectedTabID = tab.id
    }

    /// Adds a ready-made session to a project and starts it. `setup` runs once before the
    /// session's command, which only starts if it succeeds.
    func addSession(_ tab: TabItem, to groupID: UUID, setup: String? = nil) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        var command: String?
        if let setup = setup?.trimmingCharacters(in: .whitespacesAndNewlines), !setup.isEmpty {
            if tab.resolvedProvider(in: groups[gi]) == .codex {
                // Codex starts after its app-server connects; the setup runs in front of it then.
                codexSetup[tab.id] = setup
            } else {
                command = Self.afterSetup(setup, startupCommand(tab: tab, group: groups[gi]))
            }
        }
        makeTerminal(tab: tab, group: groups[gi], command: command)
        selectedTabID = tab.id
    }

    /// `command` after `setup`, only if it succeeds. A trailing ";" or "&" can't stand in
    /// front of "&&", and "&" already ends the setup by putting it in the background.
    nonisolated static func afterSetup(_ setup: String, _ command: String?) -> String {
        var setup = setup.trimmingCharacters(in: .whitespacesAndNewlines)
        // An escaped "\;" (find -exec) is an argument, not a separator.
        while setup.hasSuffix(";"), !setup.hasSuffix("\\;") { setup = String(setup.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard let command else { return setup }
        let background = setup.hasSuffix("&") && !setup.hasSuffix("&&") && !setup.hasSuffix("\\&")
        return setup + (background ? " " : " && ") + command
    }

    func closeTab(_ id: UUID) {
        closeCodex(id)
        guard let loc = location(of: id) else { return }
        if let view = terminals.removeValue(forKey: id) {
            killTree(view)
            view.removeFromSuperview()
        }
        runtime[id] = nil
        Notifier.shared.clear(tabID: id)
        browsers.removeValue(forKey: id)?.close()
        if openAgent?.tabID == id { openAgent = nil }
        if openCodexAgent?.tabID == id { openCodexAgent = nil }
        groups[loc.group].tabs.remove(at: loc.tab)
        if selectedTabID == id {
            let siblings = groups[loc.group].tabs
            selectedTabID = siblings.isEmpty ? allTabs.first?.tab.id : siblings[min(loc.tab, siblings.count - 1)].id
        }
    }

    func restart(_ id: UUID) {
        closeCodex(id)
        guard let loc = location(of: id) else { return }
        if let view = terminals.removeValue(forKey: id) {
            killTree(view)
            view.removeFromSuperview()
        }
        makeTerminal(tab: groups[loc.group].tabs[loc.tab], group: groups[loc.group])
        objectWillChange.send()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let loc = location(of: id) {
            groups[loc.group].tabs[loc.tab].name = trimmed
        } else if let gi = groups.firstIndex(where: { $0.id == id }) {
            groups[gi].name = trimmed
        }
    }

    /// Copies a Claude Code session title into the tab's name.
    func applyClaudeTitle(_ id: UUID, _ title: String) {
        updateTab(id) { tab in
            tab.name = title
            tab.claudeTitle = title
        }
    }

    func updateTab(_ id: UUID, _ mutate: (inout TabItem) -> Void) {
        guard let loc = location(of: id) else { return }
        mutate(&groups[loc.group].tabs[loc.tab])
    }

    func updateGroup(_ id: UUID, _ mutate: (inout TabGroup) -> Void) {
        guard let gi = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[gi])
    }

    func moveTabs(in groupID: UUID, from source: IndexSet, to destination: Int) {
        updateGroup(groupID) { $0.tabs.move(fromOffsets: source, toOffset: destination) }
    }

    func moveTab(_ id: UUID, toGroup groupID: UUID) {
        guard let loc = location(of: id), let gi = groups.firstIndex(where: { $0.id == groupID }), groups[loc.group].id != groupID else { return }
        let tab = groups[loc.group].tabs.remove(at: loc.tab)
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
    }

    // MARK: Groups

    func newGroup() {
        let group = TabGroup(name: "Project \(groups.count + 1)", tabs: [TabItem(name: "Session 1")])
        groups.append(group)
        makeTerminal(tab: group.tabs[0], group: group)
        selectedTabID = group.tabs[0].id
        renamingID = group.id
    }

    func deleteGroup(_ id: UUID) {
        guard let gi = groups.firstIndex(where: { $0.id == id }) else { return }
        let running = groups[gi].tabs.filter { !(runtime[$0.id]?.exited ?? true) }.count
        if running > 0 {
            let alert = NSAlert()
            alert.messageText = "Delete “\(groups[gi].name)”?"
            alert.informativeText = "\(running) running session\(running == 1 ? "" : "s") will be closed."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for tab in groups[gi].tabs { closeTab(tab.id) }
        groups.remove(at: gi)
        if groups.isEmpty { newGroup() }
    }

    /// Drops `groupID` at the position of `targetID`.
    func moveGroup(_ groupID: UUID, onto targetID: UUID) {
        guard groupID != targetID,
              let from = groups.firstIndex(where: { $0.id == groupID }),
              let to = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: to)
    }

    /// Applies a drag in the flat sidebar list. Moving a project row reorders projects;
    /// moving a session row places it under whichever project row ends up above it.
    func moveRows(_ rows: [SidebarRow], from source: IndexSet, to destination: Int) {
        guard let first = source.first else { return }
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        switch rows[first] {
        case .group:
            let order = moved.compactMap { row -> UUID? in
                if case .group(let g) = row { return g.id } else { return nil }
            }
            groups.sort { a, b in (order.firstIndex(of: a.id) ?? 0) < (order.firstIndex(of: b.id) ?? 0) }
        case .tab(let tab, let fromGroupID):
            guard let newIndex = moved.firstIndex(where: { $0.id == tab.id }) else { return }
            var targetID = groups.first?.id
            var position = 0
            for row in moved[..<newIndex].reversed() {
                if case .group(let g) = row { targetID = g.id; break }
                position += 1
            }
            guard let targetID, let gi = groups.firstIndex(where: { $0.id == targetID }),
                  let loc = location(of: tab.id) else { return }
            if fromGroupID == targetID {
                groups[gi].tabs.remove(at: loc.tab)
                groups[gi].tabs.insert(tab, at: min(position, groups[gi].tabs.count))
            } else {
                groups[loc.group].tabs.remove(at: loc.tab)
                groups[gi].tabs.insert(tab, at: min(position, groups[gi].tabs.count))
                groups[gi].isCollapsed = false
            }
        }
    }

    func moveGroup(_ groupID: UUID, by offset: Int) {
        guard let from = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let to = from + offset
        guard groups.indices.contains(to) else { return }
        groups.swapAt(from, to)
    }

    func expandedBinding(_ groupID: UUID) -> Binding<Bool> {
        Binding(
            get: { !(self.groups.first(where: { $0.id == groupID })?.isCollapsed ?? false) },
            set: { expanded in self.updateGroup(groupID) { $0.isCollapsed = !expanded } }
        )
    }

    // MARK: Navigation

    func selectIndex(_ index: Int) {
        guard let group = selectedGroup, group.tabs.indices.contains(index) else { return }
        selectedTabID = group.tabs[index].id
    }

    func selectRelative(_ offset: Int) {
        let tabs = allTabs.map(\.tab.id)
        guard !tabs.isEmpty else { return }
        let current = selectedTabID.flatMap(tabs.firstIndex(of:)) ?? 0
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count]
    }

    // MARK: Persistence

    private func save() {
        Persistence.save(Workspace(groups: groups, selectedTabID: selectedTabID))
    }

    func applyAppearance() {
        let theme = Theme.current
        terminals.values.forEach { $0.apply(theme) }
    }

    /// Saves the layout and kills every session's process tree, running or not.
    func prepareForTermination() {
        save()
        codexStarts.values.forEach { $0.cancel() }
        CodexManager.shared.shutdown()
        terminals.values.forEach(killTree)
    }
}
