import AppKit
import SwiftUI

// The transcript view (beta): a session's conversation as chat, with a compose box that types
// into the terminal. The page is WebKit (TranscriptWebView); the cards that answer the agent
// (TranscriptCards.swift) and the compose box (TranscriptCompose.swift) are native.

struct TranscriptPanel: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var codex = CodexManager.shared
    @ObservedObject private var agents = AgentMonitor.shared
    @StateObject private var model: SessionTranscript
    let tabID: UUID
    let name: String
    private let initialProvider: SessionProvider
    let theme: Theme
    /// In the main panel the session header above already names the session; only the metrics show.
    let compact: Bool
    /// The page this panel draws into; a page outlives the sessions it shows, so switching is a redraw, not a reload.
    let slot: String
    /// Sessions dragged onto the page's edges split the pane, as on a terminal.
    var hooks: DropHooks? = nil

    /// The session's provider: the agent running, else what the session is set up for. A shell
    /// becomes an agent session when the agent starts; a stopped agent session stays one.
    private var provider: SessionProvider {
        store.tab(tabID).map(store.transcriptProvider(of:)) ?? initialProvider
    }
    @State private var workingSince: Date?
    @State private var sendNotice: String?
    /// The reply as it appears on the terminal, ahead of the transcript file.
    @State private var liveText: String?
    /// The page has drawn the conversation; until then a native stand-in shows the tail.
    @State private var pageReady = false
    /// Prompts held back while Claude Code shows a permission dialog, since Return there would answer it.
    @State private var held: [String] = []
    /// Prompts waiting for the agent to come up, sent in order once it has: the hand-off
    /// written on a switch, then what the user typed meanwhile.
    @State private var starting: [String] = []
    @AppStorage(Prefs.accent) private var accentChoice = "system"
    @AppStorage(Prefs.transcriptFont) private var transcriptFont = ""
    @AppStorage(Prefs.transcriptSize) private var transcriptSize = 13.0
    @AppStorage(Prefs.transcriptWidth) private var transcriptWidth = "full"
    @AppStorage(Prefs.transcriptDensity) private var transcriptDensity = "comfortable"
    @AppStorage(Prefs.transcriptBubbles) private var transcriptBubbles = "tinted"
    @AppStorage(Prefs.transcriptTimestamps) private var transcriptTimestamps = true
    private var style: TranscriptStyle {
        TranscriptStyle(accent: accentChoice, font: transcriptFont, size: transcriptSize, width: transcriptWidth,
                        density: transcriptDensity, bubbles: transcriptBubbles, timestamps: transcriptTimestamps)
    }
    /// Whether the project is a git repository, checked once per folder rather than on every redraw.
    @State private var hasGit = false

    init(tab: TabItem, provider: SessionProvider, theme: Theme, compact: Bool = false, slot: String? = nil, hooks: DropHooks? = nil,
         claudeFile: @escaping () -> URL?, codexThread: @escaping () -> String?) {
        tabID = tab.id
        name = tab.name
        initialProvider = provider
        self.theme = theme
        self.compact = compact
        self.slot = slot ?? "panel-\(tab.id.uuidString)"
        self.hooks = hooks
        // A page that already loaded for this slot redraws in place: no stand-in needed.
        _pageReady = State(initialValue: TranscriptPages.shared.isLoaded(self.slot))
        _model = StateObject(wrappedValue: TranscriptModels.shared.model(for: tab, provider: provider, claudeFile: claudeFile, codexThread: codexThread))
    }

    private var isAgent: Bool { provider == .claude || provider == .codex }

    var body: some View {
        let runtime = store.runtime[tabID] ?? TabRuntime()
        VStack(spacing: 0) {
            header(runtime)
            ZStack {
                TranscriptWebView(slot: slot, tabID: tabID, model: model, blocksVersion: model.version, envelope: envelope(runtime), theme: theme, style: style,
                                  onClick: select, onDragEdge: hooks?.edgeChanged, onDropSession: hooks?.dropped, onMessage: handle)
                    .opacity(pageReady ? 1 : 0)
                if !pageReady {
                    TranscriptStandIn(blocks: model.blocks, notice: model.notice, loading: !model.loaded)
                        .transition(.opacity)
                        .task(id: model.loaded) {
                            // A page that never reports in shouldn't hide the conversation for good.
                            guard model.loaded else { return }
                            try? await Task.sleep(for: .seconds(4))
                            pageReady = true
                        }
                }
            }
            .animation(.easeOut(duration: 0.15), value: pageReady)
                .onAppear { if runtime.statusState == .working { workingSince = Date() } }
                .onChange(of: runtime.agentConnected) { _, connected in
                    // Codex went away with a prompt still on its way: again once it's back
                    // from its self-update, else back into the box.
                    guard !connected, provider == .codex, let text = model.takeUnsent() else { return }
                    if store.isStarting(tabID) {
                        sendNotice = "Codex updated itself; sending again once it's back…"
                        startAndSend(text, agentName: "Codex")
                        return
                    }
                    ComposeDrafts.text[tabID] = text
                    ComposeDrafts.version += 1
                    sendNotice = "Codex quit before taking the prompt. It's back in the box."
                }
                .onChange(of: runtime.statusState) { _, state in
                    workingSince = state == .working ? (workingSince ?? Date()) : nil
                    if state != .working { liveText = nil }
                    // The dialog is gone: what was held goes now, in order.
                    if state != .blocked { releaseHeld() }
                }
                .task(id: runtime.statusState == .working) {
                    // While the agent writes, follow the reply on the screen.
                    guard runtime.statusState == .working else { return }
                    while !Task.isCancelled {
                        readLive()
                        try? await Task.sleep(for: .milliseconds(700))
                    }
                }
            cards(runtime)
            ComposeBox(tabID: tabID, name: name, provider: provider, theme: theme, model: model, notice: $sendNotice, send: send, onFocus: select)
                .onTapGesture(perform: select)
        }
        .background(Color(nsColor: theme.background))
        .onAppear {
            model.resume()
            let ids = Set(store.allTabs.map { $0.tab.id })
            TranscriptModels.shared.prune(keeping: ids)
            TranscriptPages.shared.prune(keeping: Set(ids.map(\.uuidString)).union(["single"]))
        }
        .onDisappear { model.pause() }
        .task(id: baseDirectory) { hasGit = FileManager.default.fileExists(atPath: (baseDirectory as NSString).appendingPathComponent(".git")) }
        .onChange(of: provider) { _, now in model.switchTo(now) }
        // The conversation moved on, so whatever dialog the terminal showed is over.
        .onChange(of: model.version) { _, _ in TerminalPeek.shared.hideAutomatic(tabID) }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ runtime: TabRuntime) -> some View {
        if compact {
            HStack(spacing: 10) {
                Spacer()
                if let model = model.lastModel { Text(Self.shortModel(model)) }
                if let context = model.lastContext { Text("ctx \(Self.tokens(context))").monospacedDigit() }
                if model.totalOut > 0 { Text("out \(Self.tokens(model.totalOut))").monospacedDigit() }
                Button { TerminalPeek.shared.show(tabID, store: store) } label: {
                    HStack(spacing: 4) { Image(systemName: "terminal").imageScale(.small); Text("Terminal") }
                }
                .buttonStyle(.plain)
                .help("Show the terminal underneath (⌥⌘P): for dialogs like /config, or to see the raw screen")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 20)
        } else {
            HStack(spacing: 8) {
                if let color = runtime.statusColor { Circle().fill(color).frame(width: 7, height: 7) }
                Text(name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(provider.label).foregroundStyle(.secondary)
                Spacer()
                if let model = model.lastModel { Text(Self.shortModel(model)).foregroundStyle(.secondary) }
                if let context = model.lastContext {
                    Text("ctx \(Self.tokens(context))").foregroundStyle(.secondary).monospacedDigit()
                        .help("Tokens the latest reply was produced from: input plus cache")
                }
                if model.totalOut > 0 {
                    Text("out \(Self.tokens(model.totalOut))").foregroundStyle(.secondary).monospacedDigit()
                        .help("Tokens written over the session")
                }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 12)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        }
    }

    /// "claude-opus-5-5" → "Opus 5.5".
    static func shortModel(_ id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return id }
        let name = parts.dropFirst().first { !$0.allSatisfy(\.isNumber) } ?? parts[1]
        let version = parts.drop { !$0.allSatisfy(\.isNumber) }.prefix(2).joined(separator: ".")
        return (name.prefix(1).uppercased() + name.dropFirst()) + (version.isEmpty ? "" : " " + version)
    }

    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    // MARK: Cards

    @ViewBuilder
    private func cards(_ runtime: TabRuntime) -> some View {
        let pending = model.pendingTool
        if provider == .claude, runtime.statusState == .blocked, let pending, pending.name == "ExitPlanMode", let plan = pending.new {
            PlanCard(tabID: tabID, plan: plan)
        } else if provider == .claude, runtime.statusState == .blocked, let pending, pending.name == "AskUserQuestion", let question = pending.questions.first {
            QuestionCard(tabID: tabID, question: question)
        } else if runtime.awaitsPermission || codex.approval(for: tabID) != nil {
            PermissionCard(tabID: tabID, provider: provider, pending: pending)
        } else if provider == .claude, !runtime.exited, runtime.busy {
            ScreenPromptCard(tabID: tabID, starting: runtime.statusState == nil)
        }
    }

    // MARK: What the page gets

    /// Everything but the blocks, which travel separately so a status tick doesn't resend them.
    private struct Envelope: Encodable {
        struct Status: Encodable { var state: String; var detail: String?; var since: Int?; var workedFor: String?; var live: String?; var queueEditable = false }
        struct Agent: Encodable { var id: String; var description: String; var activity: String; var elapsed: String; var finished: Bool; var blocked: Bool }
        struct Summary: Encodable { var started: Int?; var turns: Int; var files: Int; var branch: String?; var tokensOut: Int }
        var name: String
        var summary: Summary?
        var status: Status?
        var notice: String?
        var truncated: Bool
        var agents: [Agent]
        /// The session's folder is a Git checkout, so the Changes tab has something to show.
        var git: Bool
    }

    private func envelope(_ runtime: TabRuntime) -> String {
        var status: Envelope.Status?
        if isAgent {
            switch runtime.statusState {
            case .working:
                status = .init(state: "working", detail: runtime.statusDetail, since: workingSince.map { Int($0.timeIntervalSince1970 * 1000) }, live: liveText, queueEditable: provider == .claude)
            case .done:
                var worked: String?
                if let start = model.lastPrompt, let end = model.lastWrite, end.timeIntervalSince(start) >= 2 {
                    worked = SessionTranscript.duration(end.timeIntervalSince(start))
                }
                status = .init(state: "done", workedFor: worked)
            case .blocked where !runtime.awaitsPermission && model.pendingTool.map({ !["ExitPlanMode", "AskUserQuestion"].contains($0.name) }) ?? true:
                status = .init(state: "blocked", detail: runtime.statusDetail ?? runtime.statusKind)
            case .error:
                status = .init(state: "error", detail: runtime.statusDetail)
            default:
                if runtime.exited, !model.blocks.isEmpty { status = .init(state: "stopped") }
            }
        }
        let live = (agents.agents[tabID] ?? []).map {
            Envelope.Agent(id: $0.id, description: $0.description, activity: $0.shortActivity, elapsed: $0.elapsedText, finished: $0.finished, blocked: $0.blocked)
        }
        var summary: Envelope.Summary?
        if model.promptCount >= 1 {
            summary = .init(started: model.firstPrompt.map { Int($0.timeIntervalSince1970 * 1000) }, turns: model.promptCount,
                            files: model.filesTouched.count, branch: store.tab(tabID)?.worktree?.branch, tokensOut: model.totalOut)
        }
        let envelope = Envelope(name: name, summary: summary, status: status, notice: model.blocks.isEmpty ? model.notice : nil,
                                truncated: model.truncated, agents: live,
                                git: hasGit)
        let data = (try? JSONEncoder().encode(envelope)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// A click or focus in this pane makes it the selected session, so its border lights up.
    private func select() {
        if store.selectedTabID != tabID { store.selectedTabID = tabID }
    }

    // MARK: Streaming from the screen

    /// While the agent works, the reply it's writing is on the terminal before it's in the
    /// transcript: the text after the last reply marker, up to the prompt box.
    private func readLive() {
        guard provider == .claude, store.runtime[tabID]?.statusState == .working else { if liveText != nil { liveText = nil }; return }
        let lines = store.screenLines(tabID, count: 60)
        guard let start = lines.lastIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            // A reply, not a tool call such as "● Bash(npm test)".
            return t.hasPrefix(ClaudeScreen.reply) && t.range(of: #"^● [A-Z][A-Za-z]+\("#, options: .regularExpression) == nil
        }) else { if liveText != nil { liveText = nil }; return }
        var collected: [String] = [String(lines[start].trimmingCharacters(in: .whitespaces).dropFirst(ClaudeScreen.reply.count))]
        for line in lines[(start + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if ClaudeScreen.replyEnds.contains(where: { t.hasPrefix($0) }) { break }
            collected.append(line.trimmingCharacters(in: .whitespaces))
        }
        var text = collected.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 1500 { text = "…" + text.suffix(1500) }
        // Already in the transcript: the file caught up.
        if let last = model.blocks.last(where: { $0.kind == .assistant }), !text.isEmpty,
           last.text.replacingOccurrences(of: "\n", with: " ").hasPrefix(text.prefix(80).replacingOccurrences(of: "\n", with: " ")) { text = "" }
        let value = text.isEmpty ? nil : text
        if value != liveText { liveText = value }
    }

    // MARK: Messages from the page

    private func handle(_ message: [String: Any]) {
        switch message["type"] as? String {
        case "changes":
            store.showPanel(.changes)
        case "path":
            guard let raw = message["path"] as? String else { return }
            let path = raw.hasPrefix("/") || raw.hasPrefix("~") ? (raw as NSString).expandingTildeInPath
                : (baseDirectory as NSString).appendingPathComponent(raw)
            if FileManager.default.fileExists(atPath: path) { store.previewRequest = path }
        case "agent":
            if let id = message["id"] as? String, let agent = agents.agents[tabID]?.first(where: { $0.id == id }) {
                store.openAgentTranscript(agent, in: tabID)
            }
        case "send":
            if let text = message["text"] as? String { send(text) }
        case "manage":
            // The real command, which opens the agent's dialog on the terminal.
            if let command = message["command"] as? String, command.hasPrefix("/"), !command.contains(" "),
               store.sendText(command, to: tabID, submit: true) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { TerminalPeek.shared.show(tabID, store: store, automatic: true) }
            }
        case "config":
            configure(message)
        case "rendered":
            pageReady = true
        case "queue":
            if let action = message["action"] as? String, let id = message["id"] as? Int { requeue(action: action, id: id) }
        case "interrupt":
            // Escape with the conversation focused: stop the agent, as the stop button does.
            if isAgent, store.runtime[tabID]?.statusState == .working { store.sendKeys("\u{1b}", to: tabID) }
        case "quote":
            if let text = message["text"] as? String {
                let quoted = text.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
                ComposeDrafts.text[tabID] = (ComposeDrafts.text[tabID] ?? "") + quoted + "\n\n"
                ComposeDrafts.version += 1
            }
        default:
            break
        }
    }

    /// An action from an overview: add or remove an MCP server, sign in to one, enable, disable or
    /// uninstall a plugin, add or remove a permission rule. Through the agent's own command line
    /// or its settings files, then the overview is redrawn.
    private func configure(_ message: [String: Any]) {
        guard let action = message["action"] as? String, let blockID = message["block"] as? Int else { return }
        let fields = message["fields"] as? [String: String] ?? [:]
        let name = (fields["name"] ?? message["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let arg = message["arg"] as? String ?? ""
        let project = projectDirectory
        let scopes: Set<String> = ["user", "local", "project"]
        let tool = provider == .codex ? "codex" : "claude"
        var kind = "mcp"
        var work: (() async -> (Bool, String))?
        switch action {
        case "mcp-add":
            let transport = fields["transport"] ?? "stdio"
            let target = (fields["target"] ?? "").trimmingCharacters(in: .whitespaces)
            let scope = scopes.contains(fields["scope"] ?? "") ? fields["scope"]! : "user"
            guard AgentConfig.validName(name), !target.isEmpty, ["stdio", "http", "sse"].contains(transport) else {
                model.note("Add server: a name of letters, digits, dots and dashes, and a command or URL, are needed"); return
            }
            let words = target.split(separator: " ").map(String.init)
            if tool == "codex" {
                work = { await AgentConfig.run(transport == "stdio" ? ["mcp", "add", name, "--"] + words : ["mcp", "add", name, "--url", target], tool: "codex") }
            } else if transport == "stdio" {
                work = { await AgentConfig.run(["mcp", "add", "-s", scope, "-t", "stdio", name, "--"] + words) }
            } else {
                work = { await AgentConfig.run(["mcp", "add", "-s", scope, "-t", transport, name, target]) }
            }
        case "mcp-remove":
            guard AgentConfig.validName(name), scopes.contains(arg) else { return }
            work = { await AgentConfig.run(tool == "codex" ? ["mcp", "remove", name] : ["mcp", "remove", "-s", arg, name], tool: tool) }
        case "mcp-login", "mcp-reconnect":
            guard Self.validServerName(name) else { return }
            let option = action == "mcp-login" ? "Authenticate" : "Reconnect"
            // In the session's own /mcp dialog, so the running session gets the connection.
            if tool == "claude", let rt = store.runtime[tabID], !rt.exited, rt.statusState != nil, rt.statusState != .working {
                Task { @MainActor in
                    let result = await mcpDialog(server: name, option: option)
                    model.note(result)
                    refresh("mcp", block: blockID, project: project)
                }
                return
            }
            guard action == "mcp-login", AgentConfig.validName(name) else {
                model.note(action == "mcp-login" ? "Start the session to sign in to \(name)." : "Start the session to reconnect \(name)."); return
            }
            // No running session: the CLI signs in, in a terminal of its own, and sessions started afterwards connect.
            model.note("Signing in to \(name): finish in the browser. Sessions started afterwards will be connected.")
            work = { await AgentConfig.run(["mcp", "login", name], tool: tool, pty: true) }
        case "mcp-logout":
            guard AgentConfig.validName(name) else { return }
            work = { await AgentConfig.run(["mcp", "logout", name], tool: tool) }
        case "mcp-import":
            // Claude Code's user servers added to Codex one by one: stdio ones with their command,
            // env and args; HTTP ones by URL. Headers can't be carried over, so those are named.
            guard tool == "codex" else { return }
            let servers = AgentConfig.claudeUserServers()
            model.note("Adding \(servers.count) server\(servers.count == 1 ? "" : "s") to Codex…")
            work = {
                var added: [String] = [], skipped: [String] = [], failed: [String] = []
                for (name, server) in servers where AgentConfig.validName(name) {
                    var arguments = ["mcp", "add", name]
                    if let url = server["url"] as? String {
                        if let headers = server["headers"] as? [String: Any], !headers.isEmpty { skipped.append(name); continue }
                        arguments += ["--url", url]
                    } else if let command = server["command"] as? String {
                        for (key, value) in server["env"] as? [String: String] ?? [:] { arguments += ["--env", "\(key)=\(value)"] }
                        arguments += ["--"] + [command] + (server["args"] as? [String] ?? [])
                    } else { skipped.append(name); continue }
                    let (ok, _) = await AgentConfig.run(arguments, tool: "codex", timeout: 30)
                    if ok { added.append(name) } else { failed.append(name) }
                }
                var parts = ["Added \(added.count) to Codex"]
                if !skipped.isEmpty { parts.append("skipped \(skipped.joined(separator: ", ")) (custom headers; add by hand)") }
                if !failed.isEmpty { parts.append("failed: \(failed.joined(separator: ", "))") }
                return (failed.isEmpty, parts.joined(separator: " · ") + ". Codex sessions started afterwards get them.")
            }
        case "plugin-enable", "plugin-disable", "plugin-uninstall":
            kind = "plugins"
            let parts = arg.split(separator: "|", maxSplits: 1).map(String.init)
            let id = parts.first ?? ""
            let scope = parts.count > 1 && scopes.contains(parts[1]) ? parts[1] : "user"
            guard id.range(of: #"^[\w.-]+@[\w.-]+$"#, options: .regularExpression) != nil else { return }
            let verb = String(action.dropFirst("plugin-".count))
            work = { await AgentConfig.run(["plugin", verb, "-s", scope, id]) }
        case "perm-add":
            kind = "permissions"
            let rule = (fields["rule"] ?? "").trimmingCharacters(in: .whitespaces)
            let ruleKind = fields["kind"] ?? "allow"
            let file = AgentConfig.settingsFile(scope: fields["scope"] ?? "user", project: project)
            if let error = AgentConfig.editPermission(kind: ruleKind, rule: rule, file: file, add: true) { model.note("Couldn't add the rule: " + error) }
            else { model.note("Added \(ruleKind) rule \(rule). Applies to sessions started afterwards.") }
            refresh(kind, block: blockID, project: project)
            return
        case "perm-remove":
            kind = "permissions"
            let rule = message["rule"] as? String ?? ""
            let ruleKind = message["kind"] as? String ?? "allow"
            // Only the settings files the overview reads; nothing else gets rewritten.
            guard AgentConfig.isSettingsFile(arg, project: project) else { return }
            if let error = AgentConfig.editPermission(kind: ruleKind, rule: rule, file: arg, add: false) { model.note("Couldn't remove the rule: " + error) }
            else { model.note("Removed \(ruleKind) rule \(rule).") }
            refresh(kind, block: blockID, project: project)
            return
        default:
            return
        }
        guard let work else { return }
        let overviewKind = kind
        Task { @MainActor in
            let (ok, output) = await work()
            let firstLine = output.split(separator: "\n").first.map(String.init) ?? (ok ? "Done" : "Failed")
            model.note((ok ? "" : "Failed: ") + (firstLine.count > 200 ? String(firstLine.prefix(200)) + "…" : firstLine))
            refresh(overviewKind, block: blockID, project: project)
        }
    }

    /// Reorders or removes a queued prompt. Claude Code only lets the newest queued message be
    /// pulled back (↑ into the prompt, ⌃U to clear), so the queue is drained newest first and
    /// sent again in the order wanted.
    private func requeue(action: String, id: Int) {
        guard provider == .claude, store.runtime[tabID]?.statusState == .working else { return }
        // ⌃X ⌃S: Claude Code interrupts the turn and takes the queue now.
        if action == "now" { store.sendKeys("\u{18}\u{13}", to: tabID); return }
        // Only prompts Claude Code has confirmed as queued; one still on its way can't be pulled back yet.
        let queued = model.blocks.filter { $0.kind == .user && $0.pending == "queued" }
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return }
        if model.blocks.contains(where: { $0.kind == .user && $0.pending == "queuing" }) { model.note("A prompt is still on its way to the queue; try again in a moment."); return }
        // ⌃U clears one line of the prompt, so a multi-line prompt can't be pulled back cleanly.
        if queued.contains(where: { $0.text.contains("\n") }) { model.note("A queued prompt spans several lines; reorder it with ↑ in the terminal."); return }
        var texts = queued.map(\.text)
        switch action {
        case "remove": texts.remove(at: index)
        case "up" where index > 0: texts.swapAt(index, index - 1)
        case "down" where index < texts.count - 1: texts.swapAt(index, index + 1)
        default: return
        }
        for block in queued { model.dismissEcho(block.id) }
        let count = queued.count
        Task { @MainActor in
            for _ in 0..<count {
                store.sendKeys("\u{1b}[A", to: tabID)
                try? await Task.sleep(for: .milliseconds(220))
                store.sendKeys("\u{15}", to: tabID)
                try? await Task.sleep(for: .milliseconds(220))
            }
            for text in texts {
                if store.sendText(text, to: tabID, submit: true) { model.echo(text, queued: true) }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func refresh(_ kind: String, block: Int, project: String) {
        let agent: SessionProvider = provider == .codex ? .codex : .claude
        Task.detached(priority: .userInitiated) {
            guard var overview = AgentConfig.overview(for: kind, project: project, provider: agent) else { return }
            if kind == "mcp", agent == .claude { overview.summary = "Checking connections… " + overview.summary }
            await MainActor.run { model.update(info: block, with: overview) }
            if kind == "mcp", agent == .claude {
                let live = AgentConfig.mcp(project: project, health: await AgentConfig.mcpHealth())
                await MainActor.run { model.update(info: block, with: live) }
            }
        }
    }

    /// Server names as Claude Code shows them: "hubspot", "claude.ai Gmail", "plugin:x:y".
    private static func validServerName(_ name: String) -> Bool {
        name.range(of: #"^[\w.:-]+( [\w.:-]+)*$"#, options: .regularExpression) != nil && name.count <= 80
    }

    // MARK: The /mcp dialog

    /// Drives Claude Code's /mcp dialog on the terminal: opens it, moves to the server, opens
    /// it, picks the option, waits for it, and closes the dialog. The terminal shows meanwhile.
    private func mcpDialog(server: String, option: String) async -> String {
        func screen() -> [String] { store.screenLines(tabID, count: 60) }
        func wait(_ seconds: Double, until condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(150))
            }
            return condition()
        }
        /// What the highlighted row says: the text after ❯, without the status mark and column.
        func highlighted() -> String? {
            guard let line = screen().last(where: { $0.contains("❯") }), let mark = line.range(of: "❯") else { return nil }
            var text = String(line[mark.upperBound...]).trimmingCharacters(in: .whitespaces)
            while let first = text.first, "✔✓⚠!✘✗◯○● ".contains(first) { text.removeFirst() }
            return text.components(separatedBy: "  ").first?.trimmingCharacters(in: .whitespaces)
        }
        func closeDialog() async {
            store.sendKeys("\u{1b}", to: tabID)
            try? await Task.sleep(for: .milliseconds(300))
            if screen().contains(where: { $0.contains("Esc to") }) { store.sendKeys("\u{1b}", to: tabID) }
        }
        TerminalPeek.shared.show(tabID, store: store, automatic: true)
        guard store.sendText("/mcp", to: tabID, submit: true) else { return "The session isn't running." }
        guard await wait(6, until: { screen().contains { $0.contains("Manage MCP servers") } }) else { return "The /mcp dialog didn't open." }
        try? await Task.sleep(for: .milliseconds(300))
        // Down the list until the highlight is on the server.
        var last: String?
        var found = false
        for _ in 0..<80 {
            let now = highlighted()
            if now == server { found = true; break }
            if let now, now == last { break }
            last = now
            store.sendKeys("\u{1b}[B", to: tabID)
            try? await Task.sleep(for: .milliseconds(120))
        }
        guard found else { await closeDialog(); return "\(server) isn't in the session's /mcp list." }
        store.sendKeys("\r", to: tabID)
        guard await wait(4, until: { screen().contains { $0.contains("Esc to back") } }) else { await closeDialog(); return "Couldn't open \(server) in the dialog." }
        try? await Task.sleep(for: .milliseconds(200))
        // Along the options until the highlight is on the one asked for: "1. Authenticate".
        var picked = false
        last = nil
        for _ in 0..<6 {
            let now = highlighted().map { $0.replacingOccurrences(of: #"^\d+\. ?"#, with: "", options: .regularExpression) }
            if let now, now.hasPrefix(option) || (option == "Authenticate" && now.hasPrefix("Re-authenticate")) { picked = true; break }
            if let now, now == last { break }
            last = now
            store.sendKeys("\u{1b}[B", to: tabID)
            try? await Task.sleep(for: .milliseconds(150))
        }
        guard picked else { await closeDialog(); return "\(server) has no \(option) option right now." }
        store.sendKeys("\r", to: tabID)
        if option == "Authenticate" {
            // The browser opens; the dialog reports when the server is connected.
            let done = await wait(180, until: { screen().contains { $0.contains("✔ connected") || $0.contains("✓ connected") } })
            await closeDialog()
            return done ? "\(server) is signed in and connected in this session." : "Sign-in to \(server) didn't finish. The browser may still be waiting."
        }
        let done = await wait(20, until: { screen().contains { $0.contains("✔ connected") || $0.contains("✓ connected") } })
        await closeDialog()
        return done ? "\(server) reconnected." : "\(server) didn't reconnect; its details are in the terminal's /mcp."
    }

    private var projectDirectory: String {
        store.tab(tabID)?.directory.map { ($0 as NSString).expandingTildeInPath } ?? store.runtime[tabID]?.cwd ?? NSHomeDirectory()
    }

    private var baseDirectory: String {
        store.runtime[tabID]?.cwd ?? store.tab(tabID)?.directory.map { ($0 as NSString).expandingTildeInPath } ?? NSHomeDirectory()
    }

    // MARK: Sending

    /// Types the prompt into the terminal; starts the agent first when the session has none.
    /// The agent is at its prompt: Claude Code once it reports status, Codex once its TUI has
    /// drawn its prompt, not while omux still connects it (its status says "working" then). A TUI
    /// that never says so counts as ready eight seconds after its command was typed.
    static func takesInput(_ rt: TabRuntime) -> Bool {
        guard rt.provider == .codex else { return rt.statusState != nil || rt.agentConnected }
        guard rt.agentConnected else { return false }
        return rt.tuiReady || (rt.agentConnectedAt.map { Date().timeIntervalSince($0) > 8 } ?? false)
    }

    private func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Overviews omux can draw from the agent's files, instead of the terminal's dialog.
        if provider != .custom, text.hasPrefix("/"), !text.contains(" "), AgentConfig.hasOverview(for: String(text.dropFirst())) {
            let command = String(text.dropFirst())
            let project = projectDirectory
            let agent: SessionProvider = provider == .codex ? .codex : .claude
            sendNotice = nil
            ComposeDrafts.text[tabID] = ""
            ComposeDrafts.version += 1
            Task.detached(priority: .userInitiated) {
                guard var overview = AgentConfig.overview(for: command, project: project, provider: agent) else { return }
                if command == "mcp", agent == .claude { overview.summary = "Checking connections… " + overview.summary }
                let id = await MainActor.run { model.show(overview) }
                // The live state takes a few seconds: the CLI connects to each server.
                if command == "mcp", agent == .claude {
                    let live = AgentConfig.mcp(project: project, health: await AgentConfig.mcpHealth())
                    await MainActor.run { model.update(info: id, with: live) }
                }
            }
            return
        }
        let runtime = store.runtime[tabID]
        let agentRunning = runtime.map { !$0.exited && Self.takesInput($0) } ?? false
        // A dialog takes Return as its answer: a permission or a question card, or one Claude
        // Code draws on the screen. The prompt waits until it's answered.
        if provider == .claude, !(runtime?.exited ?? true), !text.hasPrefix("/"),
           runtime?.awaitsPermission == true || runtime?.statusState == .blocked || store.dialogOnScreen(tabID) {
            held.append(text)
            model.echo(text, queued: true)
            model.remember(text)
            ComposeDrafts.text[tabID] = ""; ComposeDrafts.version += 1; ComposeDrafts.save()
            sendNotice = "Held until the dialog is answered"
            if runtime?.statusState != .blocked { releaseHeldWhenDialogGone() }
            return
        }
        if agentRunning || provider == .custom {
            if store.sendText(text, to: tabID, submit: true) {
                sent(text)
                if Self.opensDialog(text, provider: provider) {
                    // The command draws on the terminal, not in the transcript: show it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { TerminalPeek.shared.show(tabID, store: store, automatic: true) }
                }
            } else { sendNotice = "The session isn't running. Press ▶ to start it." }
            return
        }
        // No agent yet, or a plain shell: start the agent the way ▶ does, then type the prompt.
        let agentName = isAgent ? provider.label : (UserDefaults.standard.string(forKey: Prefs.playAgent) == "codex" ? "Codex" : "Claude Code")
        sendNotice = "Starting \(agentName)…"
        startAndSend(text, agentName: agentName)
    }

    /// Starts the agent (a no-op while it's already starting) and types the prompt once its
    /// input box is up. An agent that comes and went first is started again when Codex asked
    /// for that after updating itself; otherwise the prompt stays for the user.
    private func startAndSend(_ text: String, agentName: String) {
        starting.append(text)
        // A wait is already on; it sends this too, after what came before it.
        guard starting.count == 1 else { return }
        store.start(tabID)
        Task { @MainActor in
            defer { starting = [] }
            var sawAgent = false
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let rt = store.runtime[tabID], !rt.exited else { continue }
                if rt.statusState == .error { sendNotice = "Couldn't start: " + (rt.statusDetail ?? "see the terminal"); return }
                // The prompt goes into the agent's input box, not a shell: Codex's TUI exits
                // on its own after updating itself, and would take the text with it. Its box
                // on the screen is the sure sign it's up. Claude Code reports its status as
                // soon as it's ready; typed at before that, it has been seen to stop reporting.
                let composer = rt.provider == .codex && !store.isStarting(tabID) && store.composerVisible(tabID)
                if composer || (Self.takesInput(rt) && (rt.provider != .codex || rt.tuiReady)) {
                    // A beat for the prompt to be ready for input.
                    try? await Task.sleep(for: .seconds(1))
                    for (index, queued) in starting.enumerated() {
                        // The agent is busy with the first one: the next lands in its queue,
                        // once it has settled into the turn (typed right away, it's dropped).
                        if index > 0 { try? await Task.sleep(for: .seconds(2.5)) }
                        if store.sendText(queued, to: tabID, submit: true) { sent(queued) }
                    }
                    return
                }
                let running = store.shellRunsAgent(tabID)
                if running { sawAgent = true; continue }
                guard sawAgent, !store.isStarting(tabID) else { continue }
                // The agent came and went. omux starts Codex again after its self-update;
                // anything else is for the user to see in the terminal.
                store.refreshBusy(tabID)
                if store.isStarting(tabID) || store.shellRunsAgent(tabID) {
                    sawAgent = false
                    sendNotice = "\(agentName) updated itself; starting it again…"
                    continue
                }
                sendNotice = "\(agentName) quit before taking the prompt. Its last words are in the terminal."
                return
            }
            sendNotice = "The session didn't report ready. Send again once it's at the prompt."
        }
    }

    /// Sends what was held behind a dialog, in order.
    private func releaseHeld() {
        guard !held.isEmpty else { return }
        let texts = held; held = []
        for text in texts { _ = store.sendText(text, to: tabID, submit: true) }
        if sendNotice?.hasPrefix("Held") == true { sendNotice = nil }
    }

    /// A dialog drawn on the screen leaves no status change to wait for: watch the screen.
    private func releaseHeldWhenDialogGone() {
        Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(for: .milliseconds(500))
                guard !held.isEmpty else { return }
                if store.dialogOnScreen(tabID) || store.runtime[tabID]?.statusState == .blocked { continue }
                // A beat: after a model switch Claude Code re-reads its history first.
                try? await Task.sleep(for: .milliseconds(800))
                releaseHeld()
                return
            }
        }
    }

    /// Slash commands that open a dialog or print on the screen rather than into the conversation.
    /// Commands with an argument that just set something, and custom commands and skills, stay in chat.
    static func opensDialog(_ text: String, provider: SessionProvider) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        let command = words.first.map { String($0.dropFirst()) } ?? ""
        let hasArgument = words.count > 1
        if provider == .codex { return true }
        let inChat: Set<String> = ["compact", "clear", "init", "review", "pr-comments", "plan"]
        let setWithArgument: Set<String> = ["model", "effort", "add-dir"]
        if inChat.contains(command) { return false }
        if setWithArgument.contains(command) { return !hasArgument }
        let builtIn: Set<String> = ["mcp", "config", "permissions", "plugins", "plugin", "skills", "hooks", "agents", "memory", "doctor",
                                    "resume", "rewind", "help", "login", "logout", "status", "usage", "context", "cost", "vim",
                                    "terminal-setup", "statusline", "bug", "release-notes", "upgrade", "export", "privacy-settings",
                                    "settings", "theme", "keybindings", "ide", "install-github-app", "install-slack-app", "model", "effort"]
        // A custom command or skill replies in the conversation; anything else built in draws on screen.
        return builtIn.contains(command)
    }

    private func sent(_ text: String) {
        sendNotice = nil
        if isAgent, !text.hasPrefix("/") { model.echo(text, queued: store.runtime[tabID]?.statusState == .working) }
        model.remember(text)
        ComposeDrafts.text[tabID] = ""
        ComposeDrafts.version += 1
        ComposeDrafts.save()
    }
}

/// The tail of the conversation drawn natively from the cached model: what shows for the
/// fraction of a second a pane's page takes to load and paint, so switching projects never
/// flashes blank. Plain text, no markdown, no tools detail; the page takes over.
struct TranscriptStandIn: View {
    let blocks: [ChatBlock]
    let notice: String?
    var loading = false

    var body: some View {
        let tail = Array(blocks.suffix(14))
        VStack(alignment: .leading, spacing: 14) {
            Spacer(minLength: 0)
            if loading, tail.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading the conversation…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            } else if tail.isEmpty, let notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            ForEach(tail) { block in
                switch block.kind {
                case .user:
                    HStack { Spacer(minLength: 48); Text(Self.clip(block.text, 400)).font(.system(size: 13)).padding(.horizontal, 13).padding(.vertical, 9)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 12)) }
                case .assistant:
                    Text(Self.clip(block.text, 1200)).font(.system(size: 13)).lineSpacing(3).frame(maxWidth: .infinity, alignment: .leading)
                case .tools:
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(block.tools.suffix(6)) { row in
                            HStack(spacing: 10) {
                                Text(row.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                                Text(row.detail).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(row.result ?? "Running").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 12).frame(height: 30)
                        }
                    }
                    .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.09)))
                case .note:
                    Text(block.text).font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}
