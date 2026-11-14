import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The transcript view's compose box: a field that types into the terminal, with slash commands,
// @ file mentions, history, attachments, dictation, and the model, effort and mode chips.

/// Drafts kept per session while you switch around, and a counter the compose box watches.
@MainActor
enum ComposeDrafts {
    static var text: [UUID: String] = load()
    /// Files attached per session, kept while you switch around; sent with the next message.
    static var attachments: [UUID: [URL]] = [:]
    static var version = 0
    private static let key = "transcriptDrafts"

    /// Drafts survive a relaunch; saved a moment after typing stops.
    static func save() {
        let kept = text.filter { !$0.value.isEmpty }.reduce(into: [String: String]()) { $0[$1.key.uuidString] = $1.value }
        if kept.isEmpty { UserDefaults.standard.removeObject(forKey: key) } else { UserDefaults.standard.set(kept, forKey: key) }
    }

    private static func load() -> [UUID: String] {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:])
            .reduce(into: [UUID: String]()) { if let id = UUID(uuidString: $1.key) { $0[id] = $1.value } }
    }
}

struct ComposeBox: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let name: String
    let provider: SessionProvider
    let theme: Theme
    @ObservedObject var model: SessionTranscript
    @Binding var notice: String?
    let send: (String) -> Void
    /// The field took focus: the pane around it should become the selected one.
    var onFocus: () -> Void = {}

    @State private var draft = ""
    @State private var suggestions: [Suggestion] = []
    @State private var selected = 0
    @State private var historyIndex: Int?
    @State private var mode: String?
    /// The screen output `readMode` last read the status line at.
    @State private var modeRead = ScreenReadMemo<UInt64>()
    @State private var commands = CommandIndex()
    @State private var files: FileIndex?
    @State private var saveWork: DispatchWorkItem?
    @State private var attachments: [URL] = []
    /// Attached files are on their way to the session's machine; the message goes when they are there.
    @State private var uploading = false
    @State private var dropping = false
    /// ⌘V with an image or files on the clipboard attaches them; the field takes text as usual.
    @State private var pasteMonitor: Any?
    @FocusState private var focused: Bool

    struct Suggestion: Identifiable, Equatable {
        let id: String
        let title: String
        let detail: String
        /// What replaces the token being typed.
        let insert: String
    }

    /// Full model ids, so the choice is exact; Claude Code takes them as `/model <id>`. Read from
    /// the installed Claude Code, so a new model is listed the day it learns of it.
    @ObservedObject private var claudeModels = ClaudeModels.shared
    static let efforts = ["auto", "low", "medium", "high", "xhigh", "max"]
    /// Claude Code's permission modes, in the order shift-tab cycles them.
    static let modes = ["default", "accept edits", "plan", "auto"]

    private var isAgent: Bool { provider == .claude || provider == .codex }

    /// The word being typed: the text after the last whitespace.
    private var token: String {
        guard let last = draft.lastIndex(where: \.isWhitespace) else { return draft }
        return String(draft[draft.index(after: last)...])
    }

    var body: some View { WithRuntime(tabID) { _ in sessionBody } }

    /// Drawn again whenever this session's live state changes; see `WithRuntime`.
    @ViewBuilder private var sessionBody: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let runtime = store.runtime[tabID] ?? TabRuntime()
        VStack(alignment: .leading, spacing: 0) {
            if !suggestions.isEmpty { suggestionList }
            if !attachments.isEmpty { attachmentRow }
            TextField(placeholder, text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineSpacing(3)
                .lineLimit(2...10)
                .focused($focused)
                .onSubmit(submit)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    NSApp.sendAction(#selector(NSTextView.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                    return .handled
                }
                .onKeyPress(.upArrow) { moveUp() }
                .onKeyPress(.downArrow) { moveDown() }
                .onKeyPress(.tab) { accept() ? .handled : .ignored }
                .onKeyPress(.escape) { dismiss() }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            HStack(spacing: 10) {
                Button { attach() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Attach files: their paths go into the prompt. Pasting an image attaches it too.")
                if provider != .custom { modelChip }
                if provider == .claude { effortChip }
                if provider == .claude, let mode {
                    Menu {
                        ForEach(Self.modes, id: \.self) { name in
                            Toggle(name, isOn: Binding(get: { mode == name }, set: { if $0 { cycle(to: name) } }))
                        }
                    } label: { chip(mode) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Permission mode: default, accept edits, plan, or auto. Changed with shift-tab, as in the terminal.")
                }
                if let notice {
                    Text(notice).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                } else if provider == .shell {
                    Text("Sending starts \(UserDefaults.standard.string(forKey: Prefs.playAgent) == "codex" ? "Codex" : "Claude Code")").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                } else if isAgent, runtime.exited || (runtime.statusState == nil && !runtime.agentConnected) {
                    Text("Sending starts \(provider.label)").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                } else if isAgent {
                    Text("/ commands · @ files · ↑ history").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                if isAgent, runtime.statusState == .working {
                    // Escape interrupts the turn in Claude Code and in Codex.
                    Button { store.sendKeys("\u{1b}", to: tabID) } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Palette.error)
                            .frame(width: 26, height: 26)
                            .background(Palette.error.opacity(0.14), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(".", modifiers: .command)
                    .help("Interrupt the agent (⌘.)")
                }
                Button { dictate() } label: { Image(systemName: "mic") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dictate into the message")
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(empty ? Color.secondary : Color.white)
                        .frame(width: 26, height: 26)
                        .background(empty ? Color.primary.opacity(0.08) : Color.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(empty)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⏎ or ⌘⏎)")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background(.primary.opacity(dropping ? 0.09 : 0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropping ? Color.accent : focused ? Color.accent.opacity(0.7) : .primary.opacity(0.12), lineWidth: dropping ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: dropping)
        .padding(12)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .top) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .onPasteCommand(of: [UTType.fileURL, UTType.image, UTType.png, UTType.tiff]) { providers in take(providers) }
        .onDrop(of: [UTType.fileURL, UTType.image, UTType.png, UTType.tiff], isTargeted: $dropping) { providers in take(providers); return true }
        .onAppear {
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard focused, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                return pasteFromClipboard() ? nil : event
            }
            attachments = ComposeDrafts.attachments[tabID] ?? []
            draft = ComposeDrafts.text[tabID] ?? ""
            // Only the selected pane's box takes the keyboard; several panes appearing at once
            // would otherwise fight over it and move the selection to the last one.
            if store.selectedTabID == tabID { focused = true }
            commands.load(provider: provider, project: projectDirectory)
            files = machine.map { FileIndex.shared(for: remoteDirectory, host: $0) } ?? FileIndex.shared(for: projectDirectory)
        }
        .onChange(of: store.selectedTabID) { _, id in
            if id == tabID, !focused { focused = true }
        }
        .onChange(of: draft) { _, text in
            // A file dropped on the field lands as its path; an image becomes an attachment instead.
            if text.contains("/"), let (rest, found) = Self.imagePaths(in: text), !found.isEmpty {
                draft = rest
                add(found)
                return
            }
            ComposeDrafts.text[tabID] = text
            historyIndex = nil
            refreshSuggestions()
            saveSoon()
        }
        .onChange(of: ComposeDrafts.version) { _, _ in
            let text = ComposeDrafts.text[tabID] ?? ""
            if text != draft { draft = text }
            let files = ComposeDrafts.attachments[tabID] ?? []
            if files != attachments { attachments = files }
        }
        .onChange(of: focused) { _, now in if now { onFocus() } }
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
        .task(id: provider == .claude) {
            // Claude Code's permission mode, read from its status line now and then.
            guard provider == .claude else { mode = nil; return }
            while !Task.isCancelled {
                readMode()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var placeholder: String {
        provider == .custom ? "Type into \(name)…" : "Message \(name)… (⏎ to send, ⇧⏎ for a new line)"
    }

    private var projectDirectory: String {
        store.tab(tabID)?.directory.map { ($0 as NSString).expandingTildeInPath } ?? store.runtime[tabID]?.cwd ?? NSHomeDirectory()
    }

    /// The machine this session runs on, when it isn't this Mac.
    private var machine: String? { store.group(containing: tabID).flatMap { $0.isRemote ? $0.host : nil } }

    /// The session's folder there, as the project names it: "~" is that machine's home.
    private var remoteDirectory: String {
        store.tab(tabID)?.directory ?? store.group(containing: tabID)?.directory ?? "~"
    }

    // MARK: Chips

    /// The model in force: chosen here, else the project's, else what the transcript shows, else Claude Code's own default.
    private var modelNow: String? {
        store.tab(tabID)?.model ?? store.group(containing: tabID)?.model ?? model.lastModel ?? (provider == .claude ? AgentConfig.claudeDefaults().model : nil)
    }

    /// The effort in force: chosen here, else the project's, else Claude Code's default, which can be per model.
    private var effortNow: String {
        if let own = store.tab(tabID)?.effort ?? store.group(containing: tabID)?.effort { return own }
        let defaults = AgentConfig.claudeDefaults()
        if let saved = defaults.effort { return saved }
        if let model = modelNow, let perModel = defaults.effortByModel[model] { return perModel }
        return "auto"
    }

    /// Agent and model in one menu: Claude Code's models under its mark, Codex's under OpenAI's.
    /// Picking a model of the other agent switches the session to it.
    private var modelChip: some View {
        let current = modelNow
        let codexModels = CodexModels.list()
        return Menu {
            Section {
                let listed = claudeModels.list + (provider == .claude ? (current.map { claudeModels.list.contains($0) ? [] : [$0] } ?? []) : [])
                ForEach(listed, id: \.self) { id in
                    Toggle(isOn: Binding(get: { provider == .claude && (current == id || (id == "default" && current == nil)) }, set: { if $0 { pick(.claude, model: id) } })) {
                        Text(id == "default" ? "Default" : id)
                    }
                }
            } header: {
                Label { Text("Claude Code") } icon: { if let image = ProviderLogo.image(for: .claude) { Image(nsImage: image) } }
            }
            Section {
                if codexModels.isEmpty {
                    Toggle(isOn: Binding(get: { provider == .codex && current == nil }, set: { if $0 { pick(.codex, model: "default") } })) { Text("Default") }
                    Text("Loading the model list…")
                } else {
                    ForEach(codexModels, id: \.id) { model in
                        Toggle(isOn: Binding(get: { provider == .codex && (current == model.id || (model.isDefault && current == nil)) }, set: { if $0 { pick(.codex, model: model.id) } })) {
                            Text(model.name)
                        }
                    }
                }
            } header: {
                Label { Text("Codex") } icon: { if let image = ProviderLogo.image(for: .codex) { Image(nsImage: image) } }
            }
        } label: {
            // Plain, like the other chips; the marks live in the menu.
            chip(isAgent ? (current.map { provider == .codex ? Self.codexName($0, in: codexModels) : TranscriptPanel.shortModel($0) } ?? (provider == .codex ? (codexModels.first { $0.isDefault }?.name ?? "Model") : "Model")) : "Agent")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isAgent ? "Agent and model for this session. A model of the other agent switches the session to it." : "Start Claude Code or Codex in this session with the model you pick.")
    }

    private static func codexName(_ id: String, in models: [CodexModels.Model]) -> String {
        models.first { $0.id == id }?.name ?? id
    }

    /// A model of the session's own agent is set live (Claude Code's /model; Codex resumes its
    /// thread with the model); a model of the other agent switches the session to that agent.
    private func pick(_ agent: SessionProvider, model id: String) {
        let model: String? = id == "default" ? nil : id
        let runtime = store.runtime[tabID]
        let running = runtime.map { !$0.exited && ($0.statusState != nil || $0.agentConnected) } ?? false
        if agent == provider, running, agent == .claude { pickModel(id); return }
        if runtime?.statusState == .working {
            notice = "Stop the agent first (⌘.), then switch."
            return
        }
        if agent == provider {
            notice = "Restarting with \(model ?? "the default model")…"
            store.switchProvider(tabID, to: agent, model: model)
            return
        }
        // The other agent: what it hasn't seen goes to a file, and the first prompt points at it.
        // An agent that ran in this session before resumes its own conversation and gets only
        // the turns since; one that didn't gets the whole conversation.
        let from = provider.label
        let resuming = store.hasConversation(tabID, with: agent)
        let lastRequest = self.model.lastRequest ?? ""
        var handoff: String?
        if resuming ? self.model.hasTurnsSinceSwitch : !self.model.blocks.isEmpty {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omux-handoff", isDirectory: true)
            let file = dir.appendingPathComponent("\(tabID.uuidString).md")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? self.model.handoff(from: from, recent: resuming).write(to: file, atomically: true, encoding: .utf8)) != nil { handoff = file.path }
        }
        notice = resuming ? "Resuming \(agent.label)…" : "Switching to \(agent.label)…"
        store.switchProvider(tabID, to: agent, model: model)
        guard let handoff else { return }
        var prompt = resuming
            ? "I continued this work with \(from) in this folder since your last turn. Read \(handoff) first: it has what happened meanwhile and the files touched."
            : "Continue my work from a conversation with \(from) in this folder. Read \(handoff) first: it has the conversation so far and the files touched."
        if !lastRequest.isEmpty { prompt += " Then carry on from the last request: " + String(lastRequest.prefix(400)) }
        send(prompt)
    }

    private var effortChip: some View {
        let current = effortNow
        return Menu {
            ForEach(Self.efforts, id: \.self) { level in
                Toggle(level, isOn: Binding(get: { current == level }, set: { if $0 { pickEffort(level) } }))
            }
        } label: {
            chip("effort " + current)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Thinking effort for this session (/effort)")
    }

    /// Remembered on the session, so it holds across restarts and is passed when the session starts.
    private func pickModel(_ id: String) {
        store.updateTab(tabID) { $0.model = id == "default" ? nil : id }
        send("/model \(id)")
    }

    private func pickEffort(_ level: String) {
        store.updateTab(tabID) { $0.effort = level == "auto" ? nil : level }
        send("/effort \(level)")
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.08), in: Capsule())
    }

    // MARK: Suggestions

    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    Text(item.title).font(.system(size: 12, design: item.insert.hasPrefix("/") ? .default : .monospaced)).lineLimit(1)
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(index == selected ? Color.accent.opacity(0.18) : .clear)
                .contentShape(Rectangle())
                .onTapGesture { selected = index; _ = accept() }
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }

    private func refreshSuggestions() {
        let token = token
        if isAgent, token.hasPrefix("/"), draft == token {
            let query = token.dropFirst().lowercased()
            suggestions = commands.items.filter { query.isEmpty || $0.name.lowercased().contains(query) }
                .prefix(8)
                .map { Suggestion(id: "/" + $0.name, title: "/" + $0.name, detail: $0.detail, insert: "/" + $0.name) }
        } else if isAgent, token.hasPrefix("@"), token.count >= 2, let files {
            let query = String(token.dropFirst())
            suggestions = files.search(query, limit: 8).map { Suggestion(id: "@" + $0, title: ($0 as NSString).lastPathComponent, detail: $0, insert: "@" + $0) }
        } else {
            suggestions = []
        }
        selected = 0
    }

    private func accept() -> Bool {
        guard suggestions.indices.contains(selected) else { return false }
        let item = suggestions[selected]
        draft = String(draft.dropLast(token.count)) + item.insert + " "
        suggestions = []
        return true
    }

    private func moveUp() -> KeyPress.Result {
        if !suggestions.isEmpty { selected = max(0, selected - 1); return .handled }
        guard !model.history.isEmpty, draft.isEmpty || historyIndex != nil else { return .ignored }
        let index = (historyIndex ?? model.history.count) - 1
        guard index >= 0 else { return .handled }
        draft = model.history[index]
        DispatchQueue.main.async { historyIndex = index }
        return .handled
    }

    private func moveDown() -> KeyPress.Result {
        if !suggestions.isEmpty { selected = min(suggestions.count - 1, selected + 1); return .handled }
        guard let current = historyIndex else { return .ignored }
        let index = current + 1
        if index >= model.history.count { draft = ""; DispatchQueue.main.async { historyIndex = nil } }
        else { draft = model.history[index]; DispatchQueue.main.async { historyIndex = index } }
        return .handled
    }

    /// Escape closes the suggestions if any; otherwise it interrupts the agent, like the stop button.
    private func dismiss() -> KeyPress.Result {
        if !suggestions.isEmpty { suggestions = []; return .handled }
        guard isAgent, store.runtime[tabID]?.statusState == .working else { return .ignored }
        store.sendKeys("\u{1b}", to: tabID)
        return .handled
    }

    private func submit() {
        if accept() { return }
        let draft = draft
        func message(_ paths: [String]) -> String {
            // Attached files go after the message as paths, the way a drop onto the terminal lands.
            let quoted = paths.map { $0.contains(" ") ? "\"\($0)\"" : $0 }
            return quoted.isEmpty ? draft : (draft.trimmingCharacters(in: .whitespacesAndNewlines) + " " + quoted.joined(separator: " ")).trimmingCharacters(in: .whitespaces)
        }
        // An agent on another machine can't read a file on this one: what is attached is
        // copied there first, and it is the copy's path that goes into the prompt.
        if let machine, !attachments.isEmpty {
            guard !uploading else { return }
            uploading = true
            let files = attachments
            Task {
                var paths: [String] = []
                for file in files {
                    guard let path = await RemoteMachines.upload(file, to: machine) else {
                        uploading = false
                        Notices.shared.post("Couldn't send \(file.lastPathComponent) to \(machine)", detail: "The message wasn't sent. Check the connection and try again.", isError: true)
                        return
                    }
                    paths.append(path)
                }
                uploading = false
                send(message(paths))
            }
            return
        }
        let text = message(attachments.map(\.path))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // The panel clears the draft, attachments included, once the message went out; that
        // may be now, or once the agent is up or a dialog answered.
        send(text)
    }

    private func saveSoon() {
        saveWork?.cancel()
        let work = DispatchWorkItem { ComposeDrafts.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// macOS dictation into the field.
    private func dictate() {
        focused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
        }
    }

    // MARK: Attachments

    /// Attached files as chips above the field: a thumbnail for an image, an icon for the rest.
    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments, id: \.self) { url in
                    AttachmentChip(url: url) { remove(url) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
        }
    }

    /// Picks files and attaches them, the way a drop onto the terminal does.
    private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    /// ⌘V: files copied in Finder attach by path; an image with no text alongside attaches as
    /// a PNG. Text is left to the field. True when the paste was taken here.
    private func pasteFromClipboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            add(urls)
            return true
        }
        guard pasteboard.string(forType: .string) == nil else { return false }
        let types = pasteboard.types ?? []
        guard let type = [NSPasteboard.PasteboardType.png, .tiff].first(where: types.contains)
                ?? types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }),
              let data = pasteboard.data(forType: type) else { return false }
        let kind = UTType(type.rawValue) ?? .image
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = try? Self.savePNG(data, type: kind) else { return }
            Task { @MainActor in add([url]) }
        }
        return true
    }

    /// Pasted or dropped items: files by their path, images saved as PNG off the main thread.
    private func take(_ providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            } else if let type = [UTType.png, UTType.tiff, UTType.image].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) {
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                    guard let data, let url = try? Self.savePNG(data, type: type) else { return }
                    Task { @MainActor in add([url]) }
                }
            }
        }
    }

    /// Writes image data as a PNG under the temporary folder. PNG bytes go straight to disk;
    /// anything else is converted first. Runs on the provider's queue, not the main thread.
    nonisolated private static func savePNG(_ data: Data, type: UTType) throws -> URL {
        let png: Data
        if type == .png {
            png = data
        } else {
            guard let rep = NSBitmapImageRep(data: data) ?? NSImage(data: data).flatMap({ $0.tiffRepresentation }).flatMap({ NSBitmapImageRep(data: $0) }),
                  let converted = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            png = converted
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("omux-paste", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("image-\(UUID().uuidString).png")
        try png.write(to: url, options: .atomic)
        return url
    }

    /// Absolute paths to image files that exist, pulled out of the text: the rest, and the files.
    private static func imagePaths(in text: String) -> (String, [URL])? {
        let pattern = try! NSRegularExpression(pattern: #"(?:"((?:/|~/)[^"\n]+\.(?:png|jpe?g|gif|webp|heic|tiff?))"|((?:/|~/)\S+\.(?:png|jpe?g|gif|webp|heic|tiff?)))"#, options: .caseInsensitive)
        var out = text
        var urls: [URL] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let quoted = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            guard let path = quoted ?? Range(match.range(at: 2), in: text).map({ String(text[$0]) }) else { continue }
            let full = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: full), UTType(filenameExtension: (full as NSString).pathExtension)?.conforms(to: .image) == true,
                  let whole = Range(match.range, in: out) else { continue }
            urls.insert(URL(fileURLWithPath: full), at: 0)
            out.removeSubrange(whole)
        }
        guard !urls.isEmpty else { return nil }
        return (out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression), urls)
    }

    private func add(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) { attachments.append(url) }
        ComposeDrafts.attachments[tabID] = attachments
        focused = true
    }

    private func remove(_ url: URL) {
        attachments.removeAll { $0 == url }
        ComposeDrafts.attachments[tabID] = attachments.isEmpty ? nil : attachments
    }

    // MARK: Mode

    /// Presses shift-tab until the status line shows the mode asked for, a few tries at most:
    /// Claude Code has no command that sets the mode directly.
    private func cycle(to target: String) {
        guard target != mode else { return }
        Task { @MainActor in
            for _ in 0..<Self.modes.count {
                store.sendKeys("\u{1b}[Z", to: tabID)
                try? await Task.sleep(for: .milliseconds(350))
                readMode(force: true)
                if mode == target { return }
            }
        }
    }

    /// Claude Code's permission mode, from its status line on screen.
    private func readMode(force: Bool = false) {
        guard provider == .claude, !(store.runtime[tabID]?.exited ?? true) else { modeRead.key = nil; if mode != nil { mode = nil }; return }
        // The status line only changes with new output: none since the last read, same mode.
        let output = store.outputGeneration(tabID)
        if !force, mode != nil, let output, output == modeRead.key { return }
        modeRead.key = output
        let text = store.screenLines(tabID, count: 6).joined(separator: " ")
        // The default mode has no marker, and no shift+tab hint either: it's what the status
        // line shows nothing about.
        let found = ClaudeScreen.modes.first(where: { text.localizedCaseInsensitiveContains($0.0) })?.1 ?? "default"
        if mode != found { mode = found }
    }
}

// MARK: - Indexes

/// Slash commands for the compose box: the agent's built-ins plus the user's and project's own.
struct CommandIndex {
    struct Command { let name: String; let detail: String }
    var items: [Command] = []

    static let claude: [Command] = [
        .init(name: "mcp", detail: "MCP servers · overview here"), .init(name: "plugins", detail: "Installed plugins · overview here"),
        .init(name: "skills", detail: "Skills · overview here"), .init(name: "agents", detail: "Custom agents · overview here"),
        .init(name: "hooks", detail: "Hooks · overview here"), .init(name: "permissions", detail: "Allowed and denied tools · overview here"),
        .init(name: "commands", detail: "Custom commands · overview here"), .init(name: "status", detail: "Version and account · overview here"),
        .init(name: "clear", detail: "Start a fresh conversation"), .init(name: "compact", detail: "Summarize the conversation to free context"),
        .init(name: "config", detail: "Settings · opens in the terminal"), .init(name: "cost", detail: "Token usage and cost"), .init(name: "doctor", detail: "Check the installation"),
        .init(name: "help", detail: "Commands and shortcuts"), .init(name: "init", detail: "Write a CLAUDE.md for the project"),
        .init(name: "memory", detail: "Edit memory files"), .init(name: "model", detail: "Choose the model"), .init(name: "effort", detail: "Thinking effort"),
        .init(name: "plan", detail: "Plan before editing"), .init(name: "review", detail: "Review a pull request"),
        .init(name: "resume", detail: "Resume a conversation"), .init(name: "rewind", detail: "Go back to an earlier turn"),
        .init(name: "context", detail: "What's in the context window"), .init(name: "usage", detail: "Plan limits"),
        .init(name: "remote-control", detail: "Continue this session from claude.ai or your phone"),
        .init(name: "add-dir", detail: "Let the agent work in another folder too"), .init(name: "fast", detail: "Faster output, on or off"),
        .init(name: "code-review", detail: "Review the current changes for bugs"), .init(name: "security-review", detail: "Security review of the pending changes"),
        .init(name: "simplify", detail: "Clean up the changed code"), .init(name: "pr-comments", detail: "Read a pull request's comments"),
        .init(name: "loop", detail: "Repeat a prompt or command on an interval"), .init(name: "schedule", detail: "Scheduled cloud agents"),
        .init(name: "output-style", detail: "How replies are written · opens in the terminal"), .init(name: "export", detail: "Save the conversation · opens in the terminal"),
        .init(name: "tasks", detail: "Background tasks · opens in the terminal"), .init(name: "todos", detail: "The agent's to-do list · opens in the terminal"),
        .init(name: "ide", detail: "Connect an editor · opens in the terminal"), .init(name: "statusline", detail: "Set up the status line"),
        .init(name: "terminal-setup", detail: "Key bindings for the terminal"), .init(name: "vim", detail: "Vim keys in the prompt"),
        .init(name: "release-notes", detail: "What's new in Claude Code"), .init(name: "feedback", detail: "Send feedback to Anthropic"),
        .init(name: "upgrade", detail: "Change plan"), .init(name: "login", detail: "Sign in · opens in the terminal"), .init(name: "logout", detail: "Sign out"),
    ] + machines
    static let codex: [Command] = [
        .init(name: "mcp", detail: "MCP servers · overview here"), .init(name: "skills", detail: "Skills · overview here"),
        .init(name: "hooks", detail: "Hooks · overview here"), .init(name: "permissions", detail: "Approvals and sandbox · overview here"),
        .init(name: "model", detail: "Choose the model and reasoning"), .init(name: "approvals", detail: "Approval mode"), .init(name: "review", detail: "Review changes"),
        .init(name: "new", detail: "Start a new thread"), .init(name: "init", detail: "Write an AGENTS.md"), .init(name: "compact", detail: "Summarize the thread"),
        .init(name: "diff", detail: "Show the diff"), .init(name: "mention", detail: "Mention a file"), .init(name: "status", detail: "Session status"),
        .init(name: "quit", detail: "Exit Codex"),
    ] + machines
    /// omux's own, about the machines projects run on; they never reach the agent.
    static let machines: [Command] = [
        .init(name: "machines", detail: "Machines projects run on · overview here"),
        .init(name: "machine", detail: "How this session's machine is · overview here"),
        .init(name: "remote", detail: "New project on another machine: /remote devbox ~/code/app"),
    ]

    mutating func load(provider: SessionProvider, project: String) {
        var list = provider == .codex ? Self.codex : provider == .claude ? Self.claude : []
        guard provider == .claude else { items = list; return }
        let home = NSHomeDirectory()
        for (root, label) in [("\(home)/.claude/commands", "user command"), ("\(project)/.claude/commands", "project command")] {
            for name in Self.markdownNames(in: root) { list.append(.init(name: name, detail: label)) }
        }
        for (root, label) in [("\(home)/.claude/skills", "skill"), ("\(project)/.claude/skills", "project skill")] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names.sorted() where FileManager.default.fileExists(atPath: "\(root)/\(name)/SKILL.md") {
                list.append(.init(name: name, detail: label))
            }
        }
        list += Self.pluginCommands(project: project)
        var seen: Set<String> = []
        items = list.filter { seen.insert($0.name).inserted }
    }

    /// Commands and skills of installed plugins, as Claude Code names them: "plugin:command".
    /// A plugin installed for one project counts only in that project.
    static func pluginCommands(project: String, registry: String = NSHomeDirectory() + "/.claude/plugins/installed_plugins.json") -> [Command] {
        guard let data = FileManager.default.contents(atPath: registry),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = object["plugins"] as? [String: Any] else { return [] }
        let here = ((project as NSString).expandingTildeInPath as NSString).standardizingPath
        var found: [Command] = []
        for key in plugins.keys.sorted() {
            let plugin = String(key.split(separator: "@").first ?? Substring(key))
            for install in plugins[key] as? [[String: Any]] ?? [] {
                guard let path = install["installPath"] as? String else { continue }
                if install["scope"] as? String == "project" {
                    guard let owner = install["projectPath"] as? String, here == owner || here.hasPrefix(owner + "/") else { continue }
                }
                for name in markdownNames(in: path + "/commands") { found.append(.init(name: "\(plugin):\(name)", detail: "\(plugin) plugin")) }
                for name in ((try? FileManager.default.contentsOfDirectory(atPath: path + "/skills")) ?? []).sorted()
                where FileManager.default.fileExists(atPath: "\(path)/skills/\(name)/SKILL.md") {
                    found.append(.init(name: "\(plugin):\(name)", detail: "\(plugin) plugin skill"))
                }
            }
        }
        return found
    }

    /// "review.md" → "review", "git/commit.md" → "git:commit".
    private static func markdownNames(in root: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root) else { return [] }
        var names: [String] = []
        for case let path as String in enumerator where path.hasSuffix(".md") {
            names.append(String(path.dropLast(3)).replacingOccurrences(of: "/", with: ":"))
        }
        return names.sorted()
    }
}

/// A project's files, for @ mentions: walked once in the background, hidden and build folders
/// skipped, shared by every compose box on the project and refreshed when it gets old.
final class FileIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    private var loadedAt: Date?
    private var loading = false
    let root: String

    private static var indexes: [String: FileIndex] = [:]
    private static let registry = NSLock()
    private static let skipped: Set<String> = ["node_modules", ".git", ".build", "build", "dist", ".next", "target", "DerivedData", "Pods", ".worktrees", "vendor", ".venv", "venv", "__pycache__"]
    private static let maxAge: TimeInterval = 120

    /// The machine the folder is on, when it isn't this Mac.
    let host: String?

    private init(root: String, host: String? = nil) { self.root = root; self.host = host }

    static func shared(for root: String, host: String? = nil) -> FileIndex {
        registry.lock(); defer { registry.unlock() }
        let key = host.map { $0 + ":" + root } ?? root
        let index = indexes[key] ?? FileIndex(root: root, host: host)
        indexes[key] = index
        index.refreshIfStale()
        return index
    }

    private func refreshIfStale() {
        lock.lock()
        let stale = loadedAt.map { Date().timeIntervalSince($0) > Self.maxAge } ?? true
        guard stale, !loading else { lock.unlock(); return }
        loading = true
        lock.unlock()
        let root = root
        if let host {
            // A folder on another machine is listed there, in one go.
            Task.detached { [self] in
                let found = await RemoteMachines.files(on: host, in: root)
                take(found, keepingWhatIsThereIfEmpty: true)
            }
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var found: [String] = []
            let url = URL(fileURLWithPath: root)
            if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for case let file as URL in enumerator {
                    let name = file.lastPathComponent
                    if Self.skipped.contains(name) { enumerator.skipDescendants(); continue }
                    if (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                    found.append(String(file.path.dropFirst(root.count + 1)))
                    if found.count >= 8000 { break }
                }
            }
            lock.lock()
            paths = found
            loadedAt = Date()
            loading = false
            lock.unlock()
        }
    }

    /// What a listing found. A listing from another machine that came back empty, as when it
    /// couldn't be reached, leaves what was known in place.
    private func take(_ found: [String], keepingWhatIsThereIfEmpty keep: Bool) {
        lock.lock()
        if !found.isEmpty || !keep || paths.isEmpty { paths = found }
        loadedAt = Date()
        loading = false
        lock.unlock()
    }

    func search(_ query: String, limit: Int) -> [String] {
        lock.lock(); let paths = self.paths; lock.unlock()
        let q = query.lowercased()
        guard !q.isEmpty else { return Array(paths.prefix(limit)) }
        var scored: [(String, Int)] = []
        for path in paths {
            let lower = path.lowercased()
            let name = (lower as NSString).lastPathComponent
            if name.hasPrefix(q) { scored.append((path, 0)) }
            else if name.contains(q) { scored.append((path, 1)) }
            else if lower.contains(q) { scored.append((path, 2)) }
            else if Self.subsequence(q, in: name) { scored.append((path, 3)) }
            if scored.count > 400 { break }
        }
        return scored.sorted { $0.1 == $1.1 ? $0.0.count < $1.0.count : $0.1 < $1.1 }.prefix(limit).map(\.0)
    }

    private static func subsequence(_ query: String, in text: String) -> Bool {
        var i = query.startIndex
        for c in text where i < query.endIndex && c == query[i] { i = query.index(after: i) }
        return i == query.endIndex
    }
}

/// One attached file: a thumbnail or icon, its name, and an ✕ that shows on hover.
private struct AttachmentChip: View {
    let url: URL
    let remove: () -> Void
    @State private var thumbnail: NSImage?
    @State private var hovering = false

    private var isImage: Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true }

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(url.lastPathComponent)
                .font(.system(size: 11.5))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 16, height: 16)
                    .background(.primary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove")
        }
        .padding(.leading, isImage ? 4 : 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.1), lineWidth: 1))
        .onHover { hovering = $0 }
        .help(url.path)
        .task(id: url) {
            guard isImage else { thumbnail = nil; return }
            let path = url.path
            thumbnail = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 112, kCGImageSourceCreateThumbnailWithTransform: true]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }.value
        }
    }
}
