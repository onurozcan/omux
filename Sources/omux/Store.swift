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
            if let maximized = maximizedID, maximized != id { maximizedID = nil }
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
    /// Each project's arrangement of panes, by project id; a project has at most one.
    /// Shown while the selected session is one of its panes.
    @Published var layouts: [UUID: PaneLayout] = [:]
    /// One pane of the layout shown on its own for a while; the layout stays as it was.
    @Published var maximizedID: UUID?
    /// What each pane measures on screen, reported by the view, so a new pane isn't put where it can't fit.
    var paneSizes: [UUID: CGSize] = [:]
    /// Below this, a pane isn't split further; the new pane joins the layout at the top level instead.
    static let comfortablePane = CGSize(width: 360, height: 220)
    /// The sessions in the layout, in reading order.
    var splitIDs: [UUID] { selectedGroup.flatMap { layouts[$0.id] }?.ids ?? [] }
    /// Sessions each session started with `omux new`; only those may it steer or close.
    var cliChildren: [UUID: Set<UUID>] = [:]
    /// Projects already told, this launch, that their agent waits for a folder.
    private var folderNoticed: Set<UUID> = []
    private var codexStarts: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose startup command is about to be typed; Start would type it a second time.
    private var pendingCommands: [UUID: UUID] = [:]
    /// A worktree setup command to run before a new Codex session's TUI starts.
    private var codexSetup: [UUID: String] = [:]
    /// Tabs whose Codex was started again after it updated itself and quit; cleared once its
    /// TUI is up, so a launch that keeps failing isn't retried forever.
    private var codexRelaunched: Set<UUID> = []
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
        $layouts.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
        // The saved arrangements, minus sessions that no longer exist.
        for (key, saved) in saved?.layouts ?? [:] {
            guard let gid = UUID(uuidString: key), groups.contains(where: { $0.id == gid }),
                  let live = saved.keeping({ allIDs.contains($0) }), live.ids.count > 1 else { continue }
            layouts[gid] = live
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.async {
                if let id = Store.shared.selectedTabID { Store.shared.clearAttention(id) }
            }
        }

        // Codex's TUI leaves no trace when it exits (after updating itself, say): the shell
        // takes over without a word to the terminal. Look for ourselves.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (id, rt) in self.runtime where rt.provider == .codex && rt.agentConnected && !rt.exited { self.refreshBusy(id) }
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

    /// The provider the transcript follows: the agent running now, else the one the session is
    /// set up for. A stopped Claude Code session sits in a plain shell, but it is still a Claude
    /// Code session: its history shows, and a message starts it again.
    func transcriptProvider(of tab: TabItem) -> SessionProvider {
        if let live = runtime[tab.id]?.provider, live == .claude || live == .codex { return live }
        return group(containing: tab.id).map { tab.resolvedProvider(in: $0) } ?? .shell
    }

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

    /// The live view for a running tab; nil for a dormant or exited one. Starts nothing.
    func terminal(ifRunning tabID: UUID) -> TermView? {
        guard let view = terminals[tabID], !(runtime[tabID]?.exited ?? true) else { return nil }
        return view
    }

    // MARK: Split view

    /// What the main area shows: the split while the selected session is in it, else the selected one.
    var shownIDs: [UUID] {
        guard let shown = shownLayout else { return selectedTabID.map { [$0] } ?? [] }
        return shown.ids
    }

    /// The panes of the project `id` belongs to, without sessions that no longer exist.
    func layout(near id: UUID) -> PaneLayout? {
        guard let gid = group(containing: id)?.id else { return nil }
        return layouts[gid]?.keeping({ tab($0) != nil })
    }

    private func setLayout(_ new: PaneLayout?, near id: UUID) {
        guard let gid = group(containing: id)?.id else { return }
        if let new, new.ids.count > 1 { layouts[gid] = new } else { layouts[gid] = nil; maximizedID = nil }
    }

    /// The arrangement on screen, or nil for the selected session alone.
    var shownLayout: PaneLayout? {
        guard let selected = selectedTabID, let live = layout(near: selected),
              live.ids.count > 1, live.contains(selected), maximizedID != selected else { return nil }
        return live
    }

    /// Whether the single pane on screen is a maximized member of its project's panes.
    var isMaximized: Bool {
        guard let selected = selectedTabID, maximizedID == selected, let live = layout(near: selected) else { return false }
        return live.ids.count > 1 && live.contains(selected)
    }

    /// Splits `id`'s pane and puts `other` beside (horizontal) or below it (vertical), or
    /// before it (left, above) with `before`. Both must be sessions of the same project; the
    /// project's existing panes are kept, and `id` joins them first if it wasn't among them.
    func splitPane(_ id: UUID, with other: UUID, axis: Axis, before: Bool = false) {
        guard id != other, let gid = group(containing: id)?.id, group(containing: other)?.id == gid else { return }
        var current = layout(near: id) ?? .session(id)
        if current.contains(other) { current = current.removing(other) ?? .session(id) }
        if !current.contains(id) {
            // A session shown on its own joins the project's panes as a new column.
            let share = min(max(1 / Double(current.ids.count + 1), 0.25), 0.5)
            current = .split(axis: .horizontal, fraction: 1 - share, first: current, second: .session(id))
        }
        guard current.ids.count < PaneLayout.maxPanes else {
            Self.showError("Up to \(PaneLayout.maxPanes) sessions in the window", "Close a pane first.")
            return
        }
        // Halving a pane that is already small gives two unusable ones: then the new pane
        // becomes a column or row of the whole layout, with a fair share of it.
        let size = paneSizes[id] ?? CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let room = axis == .horizontal ? size.width : size.height
        let needed = 2 * (axis == .horizontal ? Self.comfortablePane.width : Self.comfortablePane.height)
        let new: PaneLayout
        if room < needed, current.ids.count > 1 {
            let share = min(max(1 / Double(current.ids.count + 1), 0.25), 0.5)
            new = before ? .split(axis: axis, fraction: share, first: .session(other), second: current)
                         : .split(axis: axis, fraction: 1 - share, first: current, second: .session(other))
        } else {
            new = current.splitting(id, with: other, axis: axis, before: before)
        }
        setLayout(new, near: id)
        maximizedID = nil
        selectedTabID = other
    }

    /// A session dropped on `edge` of `target`'s pane: moved there if it's among the panes,
    /// otherwise added there from the sidebar. Only within one project.
    func dropSession(_ id: UUID, on target: UUID, edge: Edge) {
        guard let gid = group(containing: id)?.id, group(containing: target)?.id == gid else {
            Self.showError("Panes hold one project", "Sessions of different projects can't share the window.")
            return
        }
        if id == target {
            // Picking a session up in the sidebar selects it, so the main area shows it alone and
            // the drop lands on itself: that means "put me on the project's canvas", on that side.
            guard let canvas = layout(near: id), !canvas.contains(id) else { return }
            let axis: Axis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
            let share = min(max(1 / Double(canvas.ids.count + 1), 0.25), 0.5)
            guard canvas.ids.count < PaneLayout.maxPanes else {
                Self.showError("Up to \(PaneLayout.maxPanes) sessions in the window", "Close a pane first.")
                return
            }
            let before = edge == .leading || edge == .top
            setLayout(before ? .split(axis: axis, fraction: share, first: .session(id), second: canvas)
                             : .split(axis: axis, fraction: 1 - share, first: canvas, second: .session(id)), near: id)
            maximizedID = nil
            selectedTabID = id
            return
        }
        if layout(near: id)?.contains(id) == true { movePane(id, to: target, edge: edge); return }
        let axis: Axis = (edge == .leading || edge == .trailing) ? .horizontal : .vertical
        splitPane(target, with: id, axis: axis, before: edge == .leading || edge == .top)
    }

    func resizePane(path: [Bool], fraction: Double) {
        guard let selected = selectedTabID, let current = layout(near: selected) else { return }
        setLayout(current.resizing(path, to: fraction), near: selected)
    }

    /// A new shell in the same folder as `id`'s session, placed beside or below it.
    func splitWithShell(_ id: UUID, axis: Axis) {
        guard let tab = tab(id), let group = group(containing: id) else { return }
        var shell = TabItem(name: "Shell", directory: directory(of: tab), command: "")
        shell.provider = .shell
        addSession(shell, to: group.id, select: false)
        splitPane(id, with: shell.id, axis: axis)
    }

    /// Moves `id` to `edge` of `target`'s pane.
    func movePane(_ id: UUID, to target: UUID, edge: Edge) {
        guard let current = layout(near: id), current.contains(id), current.contains(target) else { return }
        setLayout(current.moving(id, to: target, edge: edge), near: id)
        maximizedID = nil
        selectedTabID = id
    }

    func maximize(_ id: UUID) {
        selectedTabID = id
        maximizedID = id
    }

    func restoreSplit() { maximizedID = nil }

    /// The project's sessions that aren't among its panes yet, for "add beside".
    func splitCandidates(near id: UUID) -> [TabItem] {
        let shown = layout(near: id)?.ids ?? []
        return (group(containing: id)?.tabs ?? []).filter { !shown.contains($0.id) }
    }

    func toggleSplit(_ id: UUID) {
        if layout(near: id)?.contains(id) == true { removeFromSplit(id) } else { addToSplit(id) }
    }

    /// Shows `id` beside the selected session (to its right), within the same project.
    func addToSplit(_ id: UUID) {
        guard let selected = selectedTabID, selected != id else { return }
        splitPane(selected, with: id, axis: .horizontal)
    }

    func removeFromSplit(_ id: UUID) {
        guard let current = layout(near: id) else { return }
        setLayout(current.removing(id), near: id)
        if maximizedID == id { maximizedID = nil }
    }

    /// Evens out the selected project's panes.
    func tidyPanes() {
        guard let gid = selectedGroup?.id, let current = layouts[gid] else { return }
        layouts[gid] = current.balanced
    }

    /// Clears the selected project's panes.
    func clearSplit() {
        if let gid = selectedGroup?.id { layouts[gid] = nil }
        maximizedID = nil
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
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "omux",
        ]
        if let enc = inherited["__CF_USER_TEXT_ENCODING"] { env["__CF_USER_TEXT_ENCODING"] = enc }
        env.merge(cliEnvironment(for: tab.id, path: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")) { $1 }
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
            $0.provider = provider; $0.agentConnected = false; $0.agentConnectedAt = nil; $0.tuiReady = false
            $0.exited = false; $0.cwd = dir; $0.title = ""
            $0.statusState = nil; $0.statusKind = nil; $0.statusDetail = nil; $0.statusChildren = []
        }

        // A tab without a project folder (or whose folder is gone) opens in the home folder;
        // there the agent waits until the user starts it.
        if command == nil, !provider.startsAutomatically(in: dir, home: home) {
            // Once per project, and quietly: the shell is open, only the agent waits.
            if !folderNoticed.contains(group.id) {
                folderNoticed.insert(group.id)
                Notices.shared.post("Pick a folder for \(group.name)",
                                    detail: "\(provider.label) starts only in a project folder. Right-click the project › Edit Project… to set one, or press ▶ to start it in your home folder anyway.",
                                    isError: false)
            }
            return
        }

        if provider == .codex, command == nil {
            startCodex(view, tab: tab, cwd: dir)
        } else if let command = command ?? startupCommand(tab: tab, group: group), !command.isEmpty {
            let token = UUID()
            pendingCommands[tab.id] = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                if self?.pendingCommands[tab.id] == token { self?.pendingCommands[tab.id] = nil }
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
                let choice = self?.codexChoice(tabID: tab.id) ?? (model: nil, effort: nil)
                let launch = try await CodexManager.shared.prepare(tabID: tab.id, threadID: tab.codexThreadID, cwd: cwd, name: tab.name, model: choice.model, effort: choice.effort)
                try Task.checkCancellation()
                guard let self, let view, self.terminals[tab.id] === view else { return }
                self.updateTab(tab.id) { $0.codexThreadID = launch.threadID }
                self.save()
                self.update(tab.id) { $0.agentConnected = true; $0.agentConnectedAt = Date(); $0.busy = false }
                let setup = self.codexSetup.removeValue(forKey: tab.id)
                let command = self.codexFlags(launch.command, tabID: tab.id)
                view.send(txt: (setup.map { Self.afterSetup($0, command) } ?? command) + "\n")
            } catch {
                guard !Task.isCancelled, let self, let view, self.terminals[tab.id] === view else { return }
                self.update(tab.id) { $0.busy = false; $0.statusState = .error; $0.statusDetail = Self.codexStartFailure(error) }
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
        view.keepUntilExit()
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

    /// The last scan of mentioned paths: which session, at what output, and when.
    private var mentionScan: (tab: UUID, output: UInt64, at: Date)?

    /// Rescans the selected session's scrollback for file paths and local URLs (background, cheap).
    func scanMentionedPaths() {
        guard let id = selectedTabID, let view = terminals[id] else { mentionedPaths = []; mentionedURLs = []; mentionScan = nil; return }
        // Copying the whole scrollback is the dear part, so skip it while the screen has had no
        // new output since the last scan of this session. Every 30 seconds it runs anyway, for
        // a file that appeared or went away without a word on the screen.
        let output = view.outputGeneration
        if let last = mentionScan, last.tab == id, last.output == output, Date().timeIntervalSince(last.at) < 30 { return }
        mentionScan = (id, output, Date())
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
    /// false when the session isn't running, so nothing was typed.
    @discardableResult
    func sendText(_ text: String, to id: UUID, submit: Bool) -> Bool {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return false }
        view.paste(text)
        if submit {
            // A beat later, so the program has taken the paste before Return arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { view.send(txt: "\r") }
            // An agent's TUI that was busy and read the paste and the Return together takes the
            // Return as a line break inside the paste, and the prompt sits in its input box; the
            // next prompt would then be typed onto it. If it's still there a moment later, press
            // Return again. The box is the last line starting with the agent's prompt mark.
            if runtime[id]?.provider == .claude || runtime[id]?.provider == .codex {
                let head = Self.inputHead(of: text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak view] in
                    guard let self, let view, self.terminals[id] === view, !(self.runtime[id]?.exited ?? true),
                          Self.inputHolds(head, in: view.lastLines(12)) else { return }
                    view.send(txt: "\r")
                }
            }
        }
        return true
    }

    /// The start of a prompt's first line, enough to recognise it on the screen.
    nonisolated static func inputHead(of text: String) -> String {
        String((text.split(whereSeparator: \.isNewline).first ?? "").prefix(24)).trimmingCharacters(in: .whitespaces)
    }

    /// Whether the agent's input box, the last screen line starting with Claude Code's ❯ or
    /// Codex's ›, still holds the prompt.
    nonisolated static func inputHolds(_ head: String, in lines: [String]) -> Bool {
        guard head.count >= 3, let box = lines.last(where: { $0.hasPrefix("❯") || $0.hasPrefix("›") }) else { return false }
        return box.contains(head)
    }

    /// The last lines on the session's screen, for views that need to see what the program asks.
    func screenLines(_ id: UUID, count: Int = 12) -> [String] {
        terminals[id]?.lastLines(count) ?? []
    }

    /// How much output the session has had; it changes whenever something new reached the
    /// screen. Pollers compare it with the value they last read at. nil without a terminal.
    func outputGeneration(_ id: UUID) -> UInt64? {
        terminals[id]?.outputGeneration
    }

    /// Raw keys to the program in the session, such as an arrow key or Return.
    func sendKeys(_ keys: String, to id: UUID) {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return }
        view.send(txt: keys)
    }

    /// Whether the program in the session takes a paste as one block, without acting on its newlines.
    func acceptsBracketedPaste(_ id: UUID) -> Bool {
        terminals[id]?.terminalInputStateSnapshot()?.bracketedPasteMode == true
    }

    /// Answers Claude Code's permission prompt: "1" picks its "Yes" wherever the highlight is
    /// (Return would take the highlighted row, e.g. "allow all edits during this session"),
    /// Escape is its "No, and tell Claude what to do differently".
    /// For Codex, `codexApproval` is the request the buttons showed.
    func answerPermission(_ id: UUID, allow: Bool, codexApproval: CodexApproval? = nil) {
        if runtime[id]?.provider == .codex {
            guard let codexApproval else { return }
            Task {
                do { try await CodexManager.shared.answer(codexApproval, tabID: id, allow: allow) }
                catch { Self.showError("Couldn't answer Codex", error.localizedDescription) }
            }
            return
        }
        guard let view = terminals[id], runtime[id]?.awaitsPermission == true else { return }
        view.send(txt: allow ? "1" : "\u{1b}")
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
            // Just connected: the shell hasn't spawned the TUI yet.
            if !busy, let since = runtime[id]?.agentConnectedAt, Date().timeIntervalSince(since) < 4 { return }
            if !busy {
                update(id) { $0.agentConnected = false; $0.busy = false }
                // Codex updates itself on launch when a new version is out, then quits with
                // "Please restart Codex." Do that once, so the session doesn't sit in a shell.
                if Self.asksForRestart(view.lastLines(8)), !codexRelaunched.contains(id) {
                    codexRelaunched.insert(id)
                    start(id)
                }
            }
            return
        }
        update(id) { $0.busy = busy }
    }

    /// A terminal title without the spinner the agents animate in front of it.
    nonisolated static func cleanTitle(_ title: String) -> String {
        let spinners: Set<Character> = ["✢", "✳", "✶", "✻", "✽", "·", "⏺", "◐", "◓", "◑", "◒", "⋮"]
        return String(title.drop { character in
            character == " " || spinners.contains(character)
                || character.unicodeScalars.first.map { (0x2800...0x28FF).contains($0.value) } == true
        })
    }

    /// Whether the session's shell runs a child process right now (the agent, a build, …).
    func shellHasChild(_ id: UUID) -> Bool {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return false }
        let pid = view.process.shellPid
        return pid > 0 && Self.hasChildProcess(of: pid)
    }

    /// Whether an agent runs under the session's shell: `claude` or `codex` themselves, or the
    /// node that runs them. Not the helpers a login shell spawns while it starts up.
    func shellRunsAgent(_ id: UUID) -> Bool {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return false }
        let pid = view.process.shellPid
        guard pid > 0 else { return false }
        return Self.descendantNames(of: pid).contains { Self.isAgentProcess($0) }
    }

    nonisolated static func isAgentProcess(_ name: String) -> Bool {
        ["claude", "codex", "node", "bun"].contains(name)
    }

    /// The short names (`p_comm`) of every process under `pid`.
    private static func descendantNames(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let all = Array(procs.prefix(size / MemoryLayout<kinfo_proc>.stride))
        let under = Set(descendants(of: pid))
        return all.filter { under.contains($0.kp_proc.p_pid) }.map { proc in
            withUnsafePointer(to: proc.kp_proc.p_comm) { $0.withMemoryRebound(to: CChar.self, capacity: 17) { String(cString: $0) } }
        }
    }

    /// Whether omux is still bringing the session's agent up: its command not yet typed, or
    /// Codex not yet connected.
    func isStarting(_ id: UUID) -> Bool {
        codexStarts[id] != nil || pendingCommands[id] != nil
    }

    /// Whether Claude Code has a dialog on the screen that takes Return as its answer: the
    /// model or effort switch, or the trust question. Its status doesn't say so.
    func dialogOnScreen(_ id: UUID) -> Bool {
        Self.showsDialog(screenLines(id, count: 14))
    }

    nonisolated static func showsDialog(_ lines: [String]) -> Bool {
        let text = lines.joined(separator: "\n")
        return text.contains(ClaudeScreen.switchModel) || text.contains(ClaudeScreen.changeEffort) || text.localizedCaseInsensitiveContains(ClaudeScreen.trustFolder)
    }

    /// Whether the agent's input box is drawn on the session's screen.
    func composerVisible(_ id: UUID) -> Bool {
        Self.showsComposer(screenLines(id))
    }

    /// Codex's own words for a thread another Codex holds open, made actionable.
    nonisolated static func codexStartFailure(_ error: Error) -> String {
        let text = error.localizedDescription
        guard text.contains("already has an active writer") else { return text }
        return "Another Codex has this conversation open: a terminal, another omux, or an app-server left from a crash. Close it there, or start a new session."
    }

    /// Codex's "Update ran successfully! Please restart Codex." on its way out.
    nonisolated static func asksForRestart(_ lines: [String]) -> Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("restart Codex") }
    }

    /// Claude Code's `❯` or Codex's `›` input box, at the start of a line.
    nonisolated static func showsComposer(_ lines: [String]) -> Bool {
        lines.contains { line in
            let text = line.drop { $0 == " " || $0 == "\u{a0}" }
            return text.hasPrefix("❯") || text.hasPrefix("›")
        }
    }

    private static func hasChildProcess(of pid: pid_t) -> Bool {
        !descendants(of: pid).isEmpty
    }

    /// Every process under `pid`: the shell's child, its children, and so on.
    private static func descendants(of pid: pid_t) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let parents = procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { ($0.kp_proc.p_pid, $0.kp_eproc.e_ppid) }
        var found: [pid_t] = []
        var frontier: Set<pid_t> = [pid]
        while !frontier.isEmpty {
            let children = parents.filter { frontier.contains($0.1) }.map(\.0)
            frontier = Set(children).subtracting(found)
            found.append(contentsOf: frontier)
        }
        return found
    }

    /// The transcript of the session's Claude Code conversation. The tab's own session id first;
    /// else the id of the `claude` running in the terminal, which Claude Code records per process in
    /// ~/.claude/sessions/<pid>.json. That covers a `claude` typed into a shell, or `claude --continue`.
    func claudeTranscriptURL(for id: UUID) -> URL? {
        guard let tab = tab(id) else { return nil }
        if let url = Self.claudeTranscriptURL(tab.claudeSessionID.uuidString.lowercased()) { return url }
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return nil }
        let sessions = NSHomeDirectory() + "/.claude/sessions"
        for pid in Self.descendants(of: view.process.shellPid) {
            guard let data = FileManager.default.contents(atPath: "\(sessions)/\(pid).json"),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = object["sessionId"] as? String else { continue }
            if let url = Self.claudeTranscriptURL(session.lowercased()) { return url }
        }
        return nil
    }

    /// Starts the selected provider in an idle shell or resumes its exact saved chat.
    func start(_ id: UUID) {
        guard let loc = location(of: id), pendingCommands[id] == nil else { return }
        // ▶ brings the session forward; what it starts should be what you're looking at.
        selectedTabID = id
        if let view = terminals[id] { view.window?.makeFirstResponder(view) }
        // ▶ in a plain shell turns it into an agent session, the one chosen in Settings.
        if groups[loc.group].tabs[loc.tab].resolvedProvider(in: groups[loc.group]) == .shell {
            let agent: SessionProvider = UserDefaults.standard.string(forKey: Prefs.playAgent) == "codex" ? .codex : .claude
            groups[loc.group].tabs[loc.tab].provider = agent
            groups[loc.group].tabs[loc.tab].command = agent.command
            // A folder that already has conversations goes on from its latest one, not from
            // nothing: the project's history outlives the sessions that were closed. One that
            // another session holds stays with it.
            if agent == .claude, let folder = runtime[id]?.cwd ?? directory(of: groups[loc.group].tabs[loc.tab]) {
                let taken = Set(groups.flatMap(\.tabs).filter { $0.id != id }.map(\.claudeSessionID))
                if let latest = Self.latestClaudeConversation(in: folder, taken: taken) {
                    groups[loc.group].tabs[loc.tab].claudeSessionID = latest
                }
            }
        }
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
        let exists = Self.claudeSessionExists(session)
        // No saved conversation: start fresh, or pick up the folder's latest if Settings say so.
        let continueLatest = !exists && UserDefaults.standard.string(forKey: Prefs.startWithoutHistory) == "continue"
        var command = SessionProvider.claudeCommand(raw, sessionID: tab.claudeSessionID, conversationExists: exists, continueLatest: continueLatest)
        // The session's own model and effort, else the project's, unless the command names its own.
        if let model = (tab.model ?? group.model)?.trimmingCharacters(in: .whitespaces), !model.isEmpty, model != "default", !raw.contains("--model") {
            command += " --model \(Git.quote(model))"
        }
        if let effort = tab.effort ?? group.effort, !effort.isEmpty, effort != "default", effort != "auto", !raw.contains("--effort") {
            command += " --effort \(effort)"
        }
        return command
    }

    /// Codex takes the project's model and effort as config overrides on its command line.
    /// The session's model and effort for Codex, else the project's; nil for the defaults.
    private func codexChoice(tabID: UUID) -> (model: String?, effort: String?) {
        guard let group = group(containing: tabID) else { return (nil, nil) }
        let item = tab(tabID)
        var model = (item?.model ?? group.model)?.trimmingCharacters(in: .whitespaces)
        if model?.isEmpty == true || model == "default" { model = nil }
        var effort = item?.effort ?? group.effort
        if effort?.isEmpty == true || effort == "default" || effort == "auto" { effort = nil }
        return (model, effort)
    }

    /// The same choice on the TUI's command line, for what it shows in its status line.
    private func codexFlags(_ command: String, tabID: UUID) -> String {
        let choice = codexChoice(tabID: tabID)
        var flags: [String] = []
        if let model = choice.model { flags.append("-c model=\(Git.quote(model))") }
        if let effort = choice.effort { flags.append("-c model_reasoning_effort=\(Git.quote(effort))") }
        return flags.isEmpty ? command : command + " " + flags.joined(separator: " ")
    }

    /// Claude Code's folder name for a project: its path with everything but ASCII letters
    /// and digits turned into "-".
    nonisolated static func claudeProjectFolder(for directory: String) -> String {
        let path = ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
        return String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// The folder's newest Claude conversation that has something in it, skipping the ones
    /// `taken` by other sessions. nil for a folder Claude Code has never run in.
    nonisolated static func latestClaudeConversation(in directory: String, taken: Set<UUID> = [],
                                                      projects: String = NSHomeDirectory() + "/.claude/projects") -> UUID? {
        let folder = projects + "/" + claudeProjectFolder(for: directory)
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder) else { return nil }
        var latest: (id: UUID, date: Date)?
        for name in names where name.hasSuffix(".jsonl") {
            guard let id = UUID(uuidString: String(name.dropLast(6))), !taken.contains(id),
                  let attributes = try? fm.attributesOfItem(atPath: folder + "/" + name),
                  (attributes[.size] as? Int ?? 0) > 0,
                  let date = attributes[.modificationDate] as? Date else { continue }
            if latest.map({ date > $0.date }) ?? true { latest = (id, date) }
        }
        return latest?.id
    }

    /// Claude Code writes each conversation to ~/.claude/projects/<project>/<session>.jsonl.
    private static func claudeSessionExists(_ session: String) -> Bool {
        claudeTranscriptURL(session) != nil
    }

    /// The transcript file of a Claude Code session, once it has written one.
    static func claudeTranscriptURL(_ session: String) -> URL? {
        let projects = NSHomeDirectory() + "/.claude/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return nil }
        for dir in dirs {
            let path = "\(projects)/\(dir)/\(session).jsonl"
            if FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
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
        case .title(let raw):
            // Claude Code and Codex spin a glyph in the title while they work, ten times a
            // second: not a change, and not worth a redraw of the window each time.
            let title = Self.cleanTitle(raw)
            guard runtime[id]?.title != title else { return }
            refreshBusy(id)
            // Claude Code rewrites the title as its state changes; treat that as activity.
            update(id) {
                if $0.title != title, !isWatching(id) { $0.hasActivity = true }
                if $0.title != title { $0.lastActivity = Date() }
                $0.title = title
            }
            if runtime[id]?.provider == .claude, tab(id)?.autoName == true,
               let name = TabItem.name(fromTitle: title), tab(id)?.name != name {
                updateTab(id) { $0.name = name }
            }
        case .directory(let dir):
            update(id) { $0.cwd = dir }
            // The shell is at its prompt again: whatever ran in it is gone.
            refreshBusy(id)
        case .exited:
            update(id) { $0.exited = true; $0.statusState = nil; $0.statusKind = nil; $0.statusChildren = []; $0.busy = false }
        case .openPath(let path):
            previewRequest = path
        case .status(let state, let kind, let message, let children):
            // Codex also emits terminal OSC status. Its protocol is authoritative, particularly
            // for approval IDs; mixing both can revive stale buttons. Its first idle does say
            // that the TUI has drawn its prompt and takes input.
            if runtime[id]?.provider == .codex {
                if state == .idle, runtime[id]?.tuiReady == false { update(id) { $0.tuiReady = true } }
                if state == .idle { codexRelaunched.remove(id) }
                return
            }
            applyStatus(state, kind: kind, message: message, children: children, for: id)
        case .notification(let title, let body):
            guard !isWatching(id) else { return }
            update(id) { $0.needsAttention = true }
            if UserDefaults.standard.object(forKey: Prefs.notifyPrograms) as? Bool ?? true {
                notify(id, subtitle: title, body: body)
            }
        }
    }

    /// Marks the session's project as worked in: an agent reported status. Opening a session or
    /// using its shell doesn't count. When the agent starts a turn, the project moves to the top
    /// of the sidebar: the projects sit in the order they were last put to work, the latest first.
    /// Status ticks during the turn, or a second project working alongside, don't reorder them.
    private func touchProject(of id: UUID, activated: Bool) {
        guard let group = group(containing: id), let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
        if group.forcedIdle { updateGroup(group.id) { $0.forcedIdle = false } }
        guard activated else { return }
        updateGroup(group.id) { $0.lastActive = Date() }
        if index > 0 { groups.move(fromOffsets: [index], toOffset: 0) }
    }

    /// Whether a status change is the agent starting a turn: from nothing, as it comes up, or
    /// into working from any other state, as after a prompt or an answered permission.
    nonisolated static func startsTurn(from previous: TabRuntime.StatusState?, to state: TabRuntime.StatusState?) -> Bool {
        guard let state else { return false }
        if previous == nil { return true }
        return state == .working && previous != .working
    }

    private func applyStatus(_ state: TabRuntime.StatusState?, kind: String?, message: String?, children: [TabRuntime.StatusChild], for id: UUID) {
        let previous = runtime[id]?.statusState
        if state != nil { touchProject(of: id, activated: Self.startsTurn(from: previous, to: state)) }
        update(id) {
            if $0.statusState != state || $0.statusDetail != message { $0.lastActivity = Date() }
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
        // A late result for a closed tab would leave a badge nothing can clear.
        guard tab(id) != nil else { return }
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

    /// The new session's id, or nil when nothing was created right away (worktree sheet, cancelled folder).
    @discardableResult
    func newTab(in groupID: UUID? = nil, command: String? = nil) -> UUID? {
        guard let gi = groups.firstIndex(where: { $0.id == (groupID ?? selectedGroup?.id) }) ?? groups.indices.first else {
            newGroup()
            return nil
        }
        if command != "", groups[gi].useWorktrees {
            newWorktreeProvider = command.map { SessionProvider.infer(command: $0) }
            newWorktreeGroupID = groups[gi].id
            return nil
        }
        let tab = TabItem(name: "Session \(groups[gi].tabs.count + 1)", command: command)
        // An agent needs a project folder; ask for it now rather than opening the shell and waiting.
        if [.claude, .codex].contains(tab.resolvedProvider(in: groups[gi])), !askFolderIfMissing(groupIndex: gi) { return nil }
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        makeTerminal(tab: tab, group: groups[gi])
        selectedTabID = tab.id
        return tab.id
    }

    /// Adds a ready-made session to a project and starts it. `setup` runs once before the
    /// session's command, which only starts if it succeeds.
    func addSession(_ tab: TabItem, to groupID: UUID, setup: String? = nil, select: Bool = true) {
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
        if select { selectedTabID = tab.id }
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
        // Only the closed pane goes; its neighbours fill the space and one of them takes the selection.
        let wasOnCanvas = layout(near: id)?.contains(id) == true
        removeFromSplit(id)
        let nextPane = wasOnCanvas ? layout(near: id)?.ids.first : nil
        cliChildren[id] = nil
        for key in cliChildren.keys { cliChildren[key]?.remove(id) }
        Notifier.shared.clear(tabID: id)
        browsers.removeValue(forKey: id)?.close()
        if openAgent?.tabID == id { openAgent = nil }
        if openCodexAgent?.tabID == id { openCodexAgent = nil }
        groups[loc.group].tabs.remove(at: loc.tab)
        if selectedTabID == id {
            let siblings = groups[loc.group].tabs
            selectedTabID = nextPane ?? (siblings.isEmpty ? allTabs.first?.tab.id : siblings[min(loc.tab, siblings.count - 1)].id)
        }
    }

    /// Makes the session run the other agent, with a model if one was picked: a running session
    /// restarts into it, a stopped or plain shell session starts it. Each agent keeps its own
    /// conversation on the session, so coming back to one resumes where it left off; the hand-off
    /// the compose box sends carries what happened meanwhile.
    func switchProvider(_ id: UUID, to provider: SessionProvider, model: String?) {
        guard location(of: id) != nil, provider == .claude || provider == .codex else { return }
        updateTab(id) {
            $0.provider = provider
            $0.command = provider.command
            $0.model = model
        }
        if terminals[id] != nil, !(runtime[id]?.exited ?? true) { restart(id) } else { start(id) }
    }

    /// Whether the session has a conversation with the agent to resume: Codex's thread, or a
    /// transcript file for the Claude Code session id.
    func hasConversation(_ id: UUID, with provider: SessionProvider) -> Bool {
        guard let tab = tab(id) else { return false }
        switch provider {
        case .codex: return tab.codexThreadID != nil
        case .claude: return Self.claudeSessionExists(tab.claudeSessionID.uuidString.lowercased())
        default: return false
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
            groups[loc.group].tabs[loc.tab].autoName = false
        } else if let gi = groups.firstIndex(where: { $0.id == id }) {
            groups[gi].name = trimmed
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
        // A project is a folder first; cancelling still makes one, named by hand, with no agent yet.
        let folder = Self.chooseFolder(prompt: "Choose the project's folder")
        let name = folder.map { ($0 as NSString).lastPathComponent } ?? "Project \(groups.count + 1)"
        let group = TabGroup(name: name, directory: folder, tabs: [TabItem(name: "Session 1")])
        groups.append(group)
        makeTerminal(tab: group.tabs[0], group: group)
        selectedTabID = group.tabs[0].id
        if folder == nil { renamingID = group.id }
    }

    /// Asks for the project's folder when it has none; false when the user cancelled.
    private func askFolderIfMissing(groupIndex gi: Int) -> Bool {
        guard (groups[gi].directory ?? "").isEmpty else { return true }
        guard let folder = Self.chooseFolder(prompt: "Choose the folder for \(groups[gi].name)") else { return false }
        groups[gi].directory = folder
        if groups[gi].name == "Default" || groups[gi].name.hasPrefix("Project ") { groups[gi].name = (folder as NSString).lastPathComponent }
        return true
    }

    static func chooseFolder(prompt: String) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = prompt
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url?.path : nil
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
            // Projects not in the list (stacked as idle) keep their place after the visible ones.
            let hidden = groups.enumerated().compactMap { order.contains($0.element.id) ? nil : $0.element.id }
            let full = order + hidden
            groups.sort { a, b in (full.firstIndex(of: a.id) ?? 0) < (full.firstIndex(of: b.id) ?? 0) }
        case .shells, .projects:
            return
        case .tab(let tab, let fromGroupID), .nested(let tab, let fromGroupID):
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
        Persistence.save(Workspace(groups: groups, selectedTabID: selectedTabID,
                                   layouts: Dictionary(uniqueKeysWithValues: layouts.map { ($0.key.uuidString, $0.value) })))
    }

    func applyAppearance() {
        let theme = Theme.current
        terminals.values.forEach { $0.apply(theme) }
    }

    /// Saves the layout and kills every session's process tree, running or not.
    func prepareForTermination() {
        CommandServer.shared.stop()
        save()
        codexStarts.values.forEach { $0.cancel() }
        CodexManager.shared.shutdown()
        terminals.values.forEach(killTree)
    }
}
