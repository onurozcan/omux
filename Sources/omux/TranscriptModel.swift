import AppKit
import Foundation
import ImageIO

// The Transcript view's data: a session's conversation as blocks, read from Claude Code's
// transcript file or Codex's thread, kept per session while the app runs. TranscriptPanel.swift draws it.

struct Todo: Equatable, Encodable {
    var text: String
    /// pending, in_progress or completed, as Claude Code writes them.
    var status: String
}

struct Question: Equatable, Encodable {
    var text: String
    var options: [String]
    var multi: Bool
}

/// One block of the transcript: a prompt, a reply, thinking, a run of tool calls, a todo list, a note, or an overview.
struct ChatBlock: Identifiable, Equatable, Encodable {
    enum Kind: String, Equatable, Encodable { case user, assistant, thinking, tools, todos, note, info, summary }
    let id: Int
    var kind: Kind
    var text: String
    var time: Date?
    var tools: [ToolRow] = []
    var todos: [Todo] = []
    /// Images pasted into a prompt, as data URLs.
    var images: [String] = []
    var model: String?
    /// Context the reply was produced from (input plus cache), and tokens it wrote.
    var tokensIn: Int?
    var tokensOut: Int?
    /// The page shows a Changes link on edits of Claude Code sessions.
    var claude = false
    var messageID: String?
    /// An overview omux drew itself, for /mcp and the like.
    var info: AgentConfig.Overview?
    /// A prompt sent from the compose box that the agent hasn't recorded yet: "sent" while it
    /// takes it, "queued" when it arrived mid-turn and waits for the next one.
    var pending: String?
    /// Bumped whenever the block changes after it was first shown; the page redraws by it.
    var rev = 0

    private enum CodingKeys: String, CodingKey { case id, kind, text, time, tools, todos, images, model, tokensIn, tokensOut, claude, info, rev, pending }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encode(rev, forKey: .rev)
        try c.encodeIfPresent(time.map { Int($0.timeIntervalSince1970 * 1000) }, forKey: .time)
        if kind == .tools { try c.encode(tools, forKey: .tools); try c.encode(claude, forKey: .claude) }
        if kind == .todos { try c.encode(todos, forKey: .todos) }
        if !images.isEmpty { try c.encode(images, forKey: .images) }
        try c.encodeIfPresent(info, forKey: .info)
        try c.encodeIfPresent(pending, forKey: .pending)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(tokensIn, forKey: .tokensIn)
        try c.encodeIfPresent(tokensOut, forKey: .tokensOut)
    }
}

struct ToolRow: Identifiable, Equatable, Encodable {
    let id: String
    var name: String
    /// What the call was about, without the tool name: "src/app.tsx", "npm test".
    var detail: String
    var result: String?
    /// The result's text, for expanding the row.
    var output: String?
    var isError = false
    /// For edits: the text replaced and the text written, shown as a diff. ExitPlanMode keeps its plan in `new`.
    var old: String?
    var new: String?
    /// A unified diff, as Codex reports file changes.
    var unified: String?
    /// AskUserQuestion's questions, answerable from the panel.
    var questions: [Question] = []
    /// The file a Read, Edit or Write call named, in full.
    var path: String?
    /// Where an edit landed in the file, found after the result arrived.
    var line: Int?
    /// Images a tool returned, as data URLs.
    var images: [String] = []
    /// Output, diff and images were dropped to bound memory; the first line of the result stays.
    var trimmed = false
    var running: Bool { result == nil }

    private enum CodingKeys: String, CodingKey { case id, name, detail, result, output, isError, old, new, unified, questions, path, line, images, trimmed, running }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(detail, forKey: .detail)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(output, forKey: .output)
        try c.encode(isError, forKey: .isError)
        try c.encodeIfPresent(old, forKey: .old)
        try c.encodeIfPresent(new, forKey: .new)
        try c.encodeIfPresent(unified, forKey: .unified)
        if !questions.isEmpty { try c.encode(questions, forKey: .questions) }
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(line, forKey: .line)
        if !images.isEmpty { try c.encode(images, forKey: .images) }
        if trimmed { try c.encode(true, forKey: .trimmed) }
        try c.encode(running, forKey: .running)
    }
}

/// The models, one per session, kept while the app runs so switching sessions doesn't reread
/// and reparse the transcript. A model is paused while no panel shows it.
@MainActor
final class TranscriptModels {
    static let shared = TranscriptModels()
    private var models: [UUID: SessionTranscript] = [:]

    func model(for tab: TabItem, provider: SessionProvider, claudeFile: @escaping () -> URL?, claudeFolder: @escaping () -> URL? = { nil },
               codexThread: @escaping () -> String?) -> SessionTranscript {
        if let existing = models[tab.id] {
            existing.switchTo(provider)
            return existing
        }
        let model = SessionTranscript(tab: tab, provider: provider, claudeFile: claudeFile, claudeFolder: claudeFolder, codexThread: codexThread)
        models[tab.id] = model
        return model
    }

    /// Drops the models of sessions that no longer exist, and the content of ones nothing has
    /// shown for a while, so a workspace of many sessions doesn't hold every conversation.
    func prune(keeping ids: Set<UUID>) {
        for id in models.keys where !ids.contains(id) { models[id]?.pause(); models[id] = nil }
        for model in models.values {
            if let since = model.pausedAt, Date().timeIntervalSince(since) > Self.unloadAfter, model.memoryBytes > Self.unloadOver { model.unload() }
        }
    }
    private static let unloadAfter: TimeInterval = 10 * 60
    private static let unloadOver = 1 << 20
}

/// A session's conversation, read incrementally while a panel shows it.
@MainActor
final class SessionTranscript: ObservableObject {
    @Published private(set) var blocks: [ChatBlock] = []
    /// Bumped on every change to `blocks`; the view pushes `blocksJSON` to the page by it.
    @Published private(set) var version = 0
    /// The file was long, so reading started partway through it.
    @Published private(set) var truncated = false
    @Published private(set) var notice: String?
    /// Bumped when Claude Code refused a /restart because Remote Control is connected: omux
    /// does the restart then, the way the message asks, and resumes the conversation.
    @Published private(set) var restartAsked = 0
    /// The first read is done: what's in `blocks` is the conversation, not a conversation still loading.
    @Published private(set) var loaded = false
    /// When the latest prompt was sent and when the agent last wrote, for "worked for" durations.
    @Published private(set) var lastPrompt: Date?
    @Published private(set) var lastWrite: Date?
    /// Tokens over the session, each message counted once, and the latest reply's context and model.
    @Published private(set) var totalOut = 0
    @Published private(set) var lastContext: Int?
    @Published private(set) var lastModel: String?
    /// Prompts sent from the panel this run, newest last; `history` adds the conversation's own.
    private var sentPrompts: [String] = []
    /// For ↑ in the compose box: the conversation's prompts in order, so a session that isn't
    /// running or was opened after a relaunch still recalls its last prompt, then prompts sent
    /// from the panel that the conversation doesn't hold (slash commands, ones not yet recorded).
    var history: [String] {
        var list: [String] = []
        for block in blocks where block.kind == .user && block.pending != "removed" {
            let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, list.last != text { list.append(text) }
        }
        for text in sentPrompts where !list.contains(text) { list.append(text) }
        return Array(list.suffix(100))
    }

    /// A prompt or command sent from the panel, for ↑.
    func remember(_ text: String) {
        guard sentPrompts.last != text else { return }
        sentPrompts.append(text)
        if sentPrompts.count > 100 { sentPrompts.removeFirst(sentPrompts.count - 100) }
    }
    /// For the summary strip: prompts so far, when the first one was sent, files edited.
    @Published private(set) var promptCount = 0
    @Published private(set) var firstPrompt: Date?
    @Published private(set) var filesTouched: Set<String> = []

    /// Each block encoded once, as the page takes it; ids equal indices, since blocks only append.
    private var encoded: [String] = []
    private var encodedBytes = 0
    private let encoder = JSONEncoder()
    /// Which blocks each version touched, newest last, so a page can ask for just the difference.
    private var changeLog: [(version: Int, ids: [Int])] = []
    /// Blocks before this index have had their heavy content dropped.
    private var trimmedUpTo = 0

    let tabID: UUID
    private(set) var provider: SessionProvider = .shell
    private let claudeFile: () -> URL?
    private let claudeFolder: () -> URL?
    private let codexThread: () -> String?
    private var url: URL?
    private var offset: UInt64 = 0
    private var remainder = Data()
    private var toolRows: [String: (block: Int, row: Int)] = [:]
    /// Tool calls without a result yet, oldest first.
    private var running: [String] = []
    /// Queued prompts Claude Code took together; the next prompt record stands for them all.
    private var takenEchoes: Set<Int> = []
    /// Prompts taken one at a time from the queue whose records haven't arrived yet.
    private var dequeues = 0
    /// Blocks before this index came from an earlier agent; Codex's items fill in after them.
    private var codexBase = 0
    /// The reply Codex is writing, from its deltas, and the block showing it.
    private var codexLive: (id: String, text: String)?
    private var codexLiveBlock: Int?
    /// The newest item read from the thread. Coming back to Codex shows only what follows it,
    /// since the earlier items are already in view above the hand-over line.
    private var codexLastItem: String?
    private var codexSkipThrough: String?
    /// Prompts the thread listed at the last read; more means echoes were taken.
    private var codexUserCount = 0
    private var codexReloadPending = false
    /// A Claude Code conversation that resumes is already in view: reading starts at its end.
    private var startAtEnd = false
    private var countedMessages: Set<String> = []
    private var imagesKept = 0
    /// The note a slash command made, so the command's output can replace its text.
    private var commandNote: Int?
    private var loading = false
    /// Bumped by `unload`, so a read in flight when it ran is dropped instead of applied.
    private var generation = 0
    private(set) var pausedAt: Date?
    var memoryBytes: Int { encodedBytes }
    /// A safety net behind the watchers, for a file system that doesn't report changes.
    private var timer: Timer?
    private var next = 0
    private var paused = false
    /// Wakes on every append, so the view follows the terminal within a frame of the write.
    private var watcher: PathWatcher?
    /// Wakes when the project folder changes: the transcript appearing, or a new one after /clear.
    private var folderWatcher: PathWatcher?

    /// Reading a long transcript starts this far from its end.
    private static let tailBytes: UInt64 = 4 << 20
    /// Encoded blocks are kept under this; past it, the oldest blocks lose output, diffs,
    /// images and thinking until the total is back under `retainBytes`.
    private static let retainBytes = 6 << 20
    private static let retainCeiling = 8 << 20
    /// Rows at the end of the newest tool run that trimming leaves alone.
    private static let keepRows = 30
    /// A tool block is encoded and sent whole each time a call or result lands in it, so a long
    /// run continues in a new block past this many rows.
    private static let maxToolRows = 80
    private static let changeLogLength = 400
    /// Pasted and returned images beyond these are left out: the page carries every image on each change.
    nonisolated private static let maxImageChars = 1_000_000
    private static let maxImages = 12

    struct Meta: Equatable {
        var messageID: String?
        var model: String?
        var context: Int?
        var output: Int?
    }

    private enum Event {
        case user(String, images: [String], Date?)
        case assistant(String, Date?, Meta?)
        /// A message's model and token usage, once per message, text or not.
        case usage(Meta)
        case thinking(String, Date?)
        case tool(ToolRow, Date?)
        case result(id: String, text: String, error: Bool, images: [String], Date?)
        case todos([Todo], Date?)
        case note(String)
        /// A slash command the user ran, and what it printed.
        case command(name: String, args: String)
        case commandOutput(String)
        /// Claude Code's queue: a prompt sent while it worked, one it took in the middle of the
        /// turn (those never get a record of their own), one it will take at the next turn, and
        /// one it dropped.
        case queued(String, Date?)
        case absorbed(String, Date?)
        case taken(String)
        case unqueued(String)
        /// One waiting prompt taken at the turn's end; its record follows.
        case dequeued
        /// The summary Claude Code wrote when it compacted the context, folded like thinking.
        case summary(String)
        /// Claude Code's remote-control status, with the link to continue elsewhere.
        case bridge(String)
    }

    init(tab: TabItem, provider: SessionProvider, claudeFile: @escaping () -> URL?, claudeFolder: @escaping () -> URL? = { nil },
         codexThread: @escaping () -> String?) {
        tabID = tab.id
        self.claudeFile = claudeFile
        self.claudeFolder = claudeFolder
        self.codexThread = codexThread
        switchTo(provider, force: true)
    }

    deinit {
        timer?.invalidate()
    }

    /// Follows the session's provider: a shell that ▶ or the compose box turns into an agent
    /// session starts reading that agent's conversation without being rebuilt.
    func switchTo(_ provider: SessionProvider, force: Bool = false) {
        guard force || provider != self.provider else { return }
        let changed = provider != self.provider
        let from = self.provider
        self.provider = provider
        stopReading()
        if changed, !blocks.isEmpty, provider == .claude || provider == .codex {
            // The other agent carries on: the turns so far stay above a line, and reading
            // starts over from the new agent's conversation after them.
            handOver(from: from, to: provider)
        } else if changed {
            reset()
        } else {
            url = nil; offset = 0; remainder = Data()
        }
        if provider == .shell || provider == .custom {
            let agent = UserDefaults.standard.string(forKey: Prefs.playAgent) == "codex" ? "Codex" : "Claude Code"
            notice = "Send a message below to start \(agent) in this session."
            loaded = true
        }
        if !paused { startReading() }
    }

    /// Stops reading while no panel shows the session; what was read stays.
    func pause() {
        paused = true
        pausedAt = Date()
        stopReading()
    }

    /// Lets go of the conversation while nothing shows it; `resume` reads it again from the file
    /// or the thread. Drafts, history and the provider stay.
    func unload() {
        guard paused else { return }
        reset()
    }

    /// Keeps the conversation shown and reads the next agent's after it.
    private func handOver(from: SessionProvider, to: SessionProvider) {
        generation += 1
        loading = false
        url = nil; offset = 0; remainder = Data()
        running = []; takenEchoes = []; dequeues = 0; countedMessages = []; commandNote = nil
        lastPrompt = nil
        var list = blocks
        for index in list.indices where list[index].kind == .user && list[index].pending != nil { list[index].pending = "removed" }
        list.append(ChatBlock(id: next, kind: .note, text: "Continued with \(to.label)" + (from == .claude || from == .codex ? ", handed the conversation so far" : ""))); next += 1
        codexBase = list.count
        codexLive = nil; codexLiveBlock = nil; codexUserCount = 0; codexReloadPending = false
        // An agent that ran here before resumes its conversation: only what it adds now is read.
        startAtEnd = to == .claude && claudeFile() != nil
        codexSkipThrough = to == .codex && codexThread() != nil ? codexLastItem : nil
        commit(list, touched: Set(list.indices.filter { list[$0].kind == .user && list[$0].pending == "removed" }))
        loaded = true
    }

    /// Forgets the conversation; a read in flight is dropped when it lands.
    private func reset() {
        generation += 1
        codexBase = 0
        codexLive = nil; codexLiveBlock = nil; codexLastItem = nil; codexSkipThrough = nil; codexUserCount = 0; codexReloadPending = false
        startAtEnd = false
        loading = false
        url = nil; offset = 0; remainder = Data()
        blocks = []; encoded = []; encodedBytes = 0; changeLog = []; trimmedUpTo = 0
        toolRows = [:]; running = []; takenEchoes = []; dequeues = 0; countedMessages = []; imagesKept = 0; commandNote = nil; next = 0
        lastPrompt = nil; lastWrite = nil; totalOut = 0; lastContext = nil; lastModel = nil
        promptCount = 0; firstPrompt = nil; filesTouched = []
        truncated = false; notice = nil; loaded = false
        version += 1
    }

    /// Reads again, catching up on what was written meanwhile.
    func resume() {
        guard paused else { return }
        paused = false
        pausedAt = nil
        if provider == .shell || provider == .custom, !loaded { switchTo(provider, force: true); return }
        startReading()
    }

    private func startReading() {
        switch provider {
        case .claude:
            load()
            watchFolder()
            timer = Timer.scheduledTimer(withTimeInterval: Self.safetyInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        case .codex:
            // The app-server says when items start, complete and stream; the timer is a safety net.
            CodexManager.shared.listen(tabID) { [weak self] event in self?.codexEvent(event) }
            loadCodex()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.loadCodex() }
            }
        case .shell, .custom:
            break
        }
    }

    private func stopReading() {
        timer?.invalidate(); timer = nil
        watcher = nil
        folderWatcher = nil
        CodexManager.shared.listen(tabID, nil)
    }

    /// The tool call the agent is waiting on, if any: the newest one without a result.
    var pendingTool: ToolRow? {
        guard let id = running.last, let place = toolRows[id], blocks.indices.contains(place.block),
              blocks[place.block].tools.indices.contains(place.row) else { return nil }
        return blocks[place.block].tools[place.row]
    }

    // MARK: Claude Code

    private static let safetyInterval: TimeInterval = 10

    private func watch(_ url: URL) {
        watcher = PathWatcher(path: url.path) { [weak self] in self?.load() }
    }

    /// The project folder: a new session writes its first record at the first prompt, and
    /// /clear starts a new conversation in a new file. Claude Code makes the folder with the
    /// first record, so this may have to wait for a later try.
    private func watchFolder() {
        guard folderWatcher == nil, let folder = claudeFolder() else { return }
        folderWatcher = PathWatcher(path: folder.path, directory: true) { [weak self] in
            guard let self else { return }
            if self.url == nil { self.load() } else { self.followNewConversation() }
        }
    }

    /// The session writes to another file now: start over from it.
    private func followNewConversation() {
        guard url != nil, let now = claudeFile(), now != url else { return }
        stopReading()
        url = now; offset = 0; remainder = Data()
        note("New conversation")
        startReading()
    }

    /// The safety net's turn: whatever the watchers would have said.
    private func tick() {
        watchFolder()
        followNewConversation()
        load()
    }

    private func load() {
        guard !loading, !paused else { return }
        if url == nil {
            url = claudeFile()
            guard let url else {
                if notice == nil { notice = "No conversation yet. Send the first message below." }
                loaded = true
                return
            }
            if startAtEnd, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 {
                offset = size; truncated = false
            } else {
                offset = Self.tailStart(url, keep: Self.tailBytes)
                truncated = offset > 0
            }
            startAtEnd = false
            watch(url)
        }
        guard let url else { return }
        // The file was replaced or truncated under us: read it from the start.
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size < offset {
            offset = 0; remainder = Data()
        }
        loading = true
        var offset = self.offset
        var remainder = self.remainder
        let generation = generation
        Task.detached {
            var events: [Event] = []
            for object in Transcript.newObjects(url, offset: &offset, remainder: &remainder) {
                events.append(contentsOf: Self.events(of: object))
            }
            let (read, rest, found) = (offset, remainder, events)
            await MainActor.run {
                guard generation == self.generation else { return }
                self.offset = read
                self.remainder = rest
                if !found.isEmpty { self.notice = nil }
                self.apply(found)
                self.loading = false
                self.loaded = true
            }
        }
    }

    /// The byte after the first newline at or past `size - keep`, or 0 for a short file.
    private static func tailStart(_ url: URL, keep: UInt64) -> UInt64 {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > keep else { return 0 }
        let start = size - keep
        try? handle.seek(toOffset: start)
        let chunk = handle.readData(ofLength: 1 << 20)
        guard let newline = chunk.firstIndex(of: 0x0A) else { return 0 }
        return start + UInt64(newline - chunk.startIndex) + 1
    }

    /// Built once: a formatter costs more than parsing the record it stamps. Both are thread-safe.
    nonisolated(unsafe) private static let fractionalDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let wholeDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    nonisolated private static func date(of object: [String: Any]) -> Date? {
        guard let stamp = object["timestamp"] as? String else { return nil }
        return fractionalDates.date(from: stamp) ?? wholeDates.date(from: stamp)
    }

    nonisolated private static func dataURL(of item: [String: Any]) -> String? {
        guard let source = item["source"] as? [String: Any], source["type"] as? String == "base64",
              let data = source["data"] as? String, data.count < maxImageChars else { return nil }
        return "data:\(source["media_type"] as? String ?? "image/png");base64,\(data)"
    }

    /// Claude Code writes one JSON object per line: user turns (prompts and tool results),
    /// assistant turns (text, thinking and tool calls), and housekeeping records.
    nonisolated private static func events(of object: [String: Any]) -> [Event] {
        var events: [Event] = []
        let message = object["message"] as? [String: Any]
        switch object["type"] as? String {
        case "queue-operation":
            if object["operation"] as? String == "dequeue" { return [.dequeued] }
            guard let content = object["content"] as? String else { return [] }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Injected records (task notifications, agent messages) pass through the queue too.
            guard !text.isEmpty, !text.hasPrefix("<") else { return [] }
            let shown = cap(inlineImages(in: text, thumbnails: false).text)
            switch object["operation"] as? String {
            case "enqueue": return [.queued(shown, date(of: object))]
            case "popAll": return [.taken(shown)]
            case "remove": return [(object["reason"] as? String) == "absorbed_mid_turn" ? .absorbed(shown, date(of: object)) : .unqueued(shown)]
            default: return []
            }
        case "user":
            // Claude Code's own reminders and notices, not something the user typed.
            if object["isMeta"] as? Bool == true { return [] }
            if object["isCompactSummary"] as? Bool == true {
                let text = Transcript.text(of: message?["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? [] : [.summary(cap(text))]
            }
            let time = date(of: object)
            if let items = message?["content"] as? [[String: Any]] {
                var texts: [String] = []
                var images: [String] = []
                for item in items {
                    switch item["type"] as? String {
                    case "tool_result":
                        let text = Transcript.text(of: item["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
                        let pictures = (item["content"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "image" }.compactMap(dataURL)
                        events.append(.result(id: item["tool_use_id"] as? String ?? "", text: text, error: item["is_error"] as? Bool ?? false, images: pictures, time))
                    case "text":
                        texts.append(item["text"] as? String ?? "")
                    case "image":
                        if let url = dataURL(of: item) { images.append(url) }
                    default:
                        break
                    }
                }
                events.append(contentsOf: userEvents(texts.joined(separator: "\n"), images: images, time: time))
            } else if let text = message?["content"] as? String {
                events.append(contentsOf: userEvents(text, images: [], time: time))
            }
        case "assistant":
            let time = date(of: object)
            let model = message?["model"] as? String
            // Claude Code writes its own notices as "<synthetic>" assistant messages: no model, no usage.
            let synthetic = model?.hasPrefix("<") == true
            var meta = Meta(messageID: message?["id"] as? String, model: synthetic ? nil : model)
            if !synthetic, let usage = message?["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                let cacheWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                meta.context = input + cacheRead + cacheWrite
                meta.output = usage["output_tokens"] as? Int
                events.append(.usage(meta))
            }
            for item in message?["content"] as? [[String: Any]] ?? [] {
                switch item["type"] as? String {
                case "text":
                    let text = cap((item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    guard !text.isEmpty else { continue }
                    if synthetic { if text.count <= 160 { events.append(.note(text)) } } else { events.append(.assistant(text, time, meta)) }
                case "thinking":
                    let text = cap((item["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                    if !text.isEmpty { events.append(.thinking(text, time)) }
                case "tool_use":
                    let name = item["name"] as? String ?? "Tool"
                    let input = item["input"] as? [String: Any] ?? [:]
                    let id = item["id"] as? String ?? UUID().uuidString
                    if name == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                        events.append(.todos(todos.map { Todo(text: $0["content"] as? String ?? "", status: $0["status"] as? String ?? "pending") }, time))
                        continue
                    }
                    let summary = Transcript.summary(name: name, input: input)
                    let detail = summary.hasPrefix(name + " ") ? String(summary.dropFirst(name.count + 1)) : ""
                    var row = ToolRow(id: id, name: name, detail: detail)
                    (row.old, row.new) = edit(of: name, input: input)
                    row.path = (input["file_path"] ?? input["notebook_path"] ?? input["path"]) as? String
                    if name == "AskUserQuestion", let questions = input["questions"] as? [[String: Any]] {
                        row.questions = questions.map { q in
                            Question(text: q["question"] as? String ?? "",
                                     options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                     multi: q["multiSelect"] as? Bool ?? false)
                        }
                    }
                    events.append(.tool(row, time))
                default:
                    break
                }
            }
        case "system":
            switch object["subtype"] as? String {
            case "compact_boundary": events.append(.note("Context compacted"))
            case "bridge_status": if let text = object["content"] as? String, !text.isEmpty { events.append(.bridge(text)) }
            // What a slash command printed, the way Claude Code 2.1 records it.
            case "local_command": if let text = object["content"] as? String, let out = element("local-command-stdout", in: text) { events.append(.commandOutput(out)) }
            default: break
            }
        default:
            break
        }
        return events
    }

    /// A text block longer than this is cut; the terminal keeps the rest.
    /// Paths of images on this Mac in a prompt, as a pasted or attached image lands there: the
    /// text without them, and each as a small data URL for the bubble. Only absolute paths to
    /// files that exist count, so a file name in prose is left alone.
    nonisolated static func inlineImages(in text: String, thumbnails: Bool = true) -> (text: String, images: [String]) {
        guard text.contains("/") else { return (text, []) }
        let pattern = try! NSRegularExpression(pattern: #"(?:"((?:/|~/)[^"\n]+\.(?:png|jpe?g|gif|webp|heic|tiff?))"|((?:/|~/)\S+\.(?:png|jpe?g|gif|webp|heic|tiff?)))"#, options: .caseInsensitive)
        var out = text
        var images: [String] = []
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let quoted = Range(match.range(at: 1), in: text).map { String(text[$0]) }
            guard let path = quoted ?? Range(match.range(at: 2), in: text).map({ String(text[$0]) }) else { continue }
            let full = (path as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: full), let whole = Range(match.range, in: out) else { continue }
            if thumbnails, let url = thumbnail(of: full) { images.insert(url, at: 0) }
            out.removeSubrange(whole)
        }
        guard !images.isEmpty || out != text else { return (text, []) }
        let cleaned = out.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, images)
    }

    /// A JPEG at most 900 px on its long side, as a data URL; nil for anything that isn't an image.
    nonisolated private static func thumbnail(of path: String) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 900,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    nonisolated private static func cap(_ text: String) -> String {
        text.count > 100_000 ? String(text.prefix(100_000)) + "\n…" : text
    }

    /// What an edit replaced and wrote, capped so a huge file doesn't flood the page.
    nonisolated private static func edit(of tool: String, input: [String: Any]) -> (String?, String?) {
        func cap(_ s: String?) -> String? { s.map { $0.count > 20000 ? String($0.prefix(20000)) + "\n…" : $0 } }
        switch tool {
        case "Edit":
            return (cap(input["old_string"] as? String), cap(input["new_string"] as? String))
        case "Write":
            return (nil, cap(input["content"] as? String))
        case "NotebookEdit":
            return (nil, cap(input["new_source"] as? String))
        case "MultiEdit":
            let edits = input["edits"] as? [[String: Any]] ?? []
            let old = edits.compactMap { $0["old_string"] as? String }.joined(separator: "\n")
            let new = edits.compactMap { $0["new_string"] as? String }.joined(separator: "\n")
            return (cap(old), cap(new))
        case "ExitPlanMode":
            return (nil, cap(input["plan"] as? String))
        default:
            return (nil, nil)
        }
    }

    /// A typed prompt, or what Claude Code records as prompts without the user typing it:
    /// slash commands and their output, interruptions, background agent notifications, and
    /// other injected records.
    nonisolated private static func userEvents(_ raw: String, images: [String], time: Date?) -> [Event] {
        var text = raw
        // Reminders Claude Code attaches around a real prompt.
        while let start = text.range(of: "<system-reminder>"), let end = text.range(of: "</system-reminder>", range: start.upperBound..<text.endIndex) {
            text.removeSubrange(start.lowerBound..<end.upperBound)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return [] }
        if let name = element("command-name", in: text) {
            return [.command(name: name.hasPrefix("/") ? String(name.dropFirst()) : name, args: element("command-args", in: text) ?? "")]
        }
        if text.hasPrefix("[Request interrupted") { return [.note("Interrupted")] }
        // Long pastes are wrapped in <pasted_content id="…"> … </pasted_content id="…">; show what was pasted.
        if text.contains("<pasted_content") {
            text = text.replacingOccurrences(of: #"\n?</?pasted_content[^>]*>\n?"#, with: "\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A record that is one XML element start to end was injected, not typed.
        if let tagRange = text.range(of: #"^<[a-z][\w-]*>"#, options: .regularExpression),
           case let tag = String(text[tagRange].dropFirst().dropLast()), text.hasSuffix("</\(tag)>") {
            switch tag {
            case "task-notification":
                return [.note(element("summary", in: text) ?? "Background agent finished")]
            case "bash-input":
                return [.note("! " + (element("bash-input", in: text) ?? ""))]
            case "local-command-stdout":
                return [.commandOutput(element("local-command-stdout", in: text) ?? "")]
            default:
                return []
            }
        }
        if text.hasPrefix("<local-command") { return [] }
        let inline = inlineImages(in: text)
        return [.user(cap(inline.text), images: images + inline.images, time)]
    }

    nonisolated private static func element(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a slash command did, in a few words; nil for commands whose effect shows on its own.
    nonisolated static func describe(command name: String, args: String) -> String? {
        let args = args.trimmingCharacters(in: .whitespaces)
        switch name {
        case "model": return args.isEmpty ? "Model picker opened" : "Model changed to \(args)"
        case "effort": return args.isEmpty ? "Effort picker opened" : "Effort changed to \(args)"
        case "clear": return "Conversation cleared"
        case "compact": return nil
        case "resume": return "Resumed a conversation"
        default: return "Ran /\(name)" + (args.isEmpty ? "" : " " + args)
        }
    }

    nonisolated static func isRestartRefusal(_ output: String) -> Bool {
        output.contains("Can't restart while Remote Control is connected")
    }

    /// The first line of a command's output, short enough for a note.
    nonisolated static func commandSummary(_ output: String) -> String? {
        guard var line = output.split(separator: "\n").first.map(String.init) else { return nil }
        line = line.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        if let cut = line.range(of: " (") { line = String(line[..<cut.lowerBound]) }
        if line.count > 140 { line = String(line.prefix(140)) + "…" }
        return line.isEmpty ? nil : line
    }

    // MARK: Applying

    private func apply(_ events: [Event]) {
        guard !events.isEmpty else { return }
        var list = blocks
        var touched: Set<Int> = []
        var lookups: [String] = []
        func wrote(_ time: Date?) { if let time, time > (lastWrite ?? .distantPast) { lastWrite = time } }
        func append(_ block: ChatBlock) { list.append(block); next += 1 }
        for event in events {
            switch event {
            case .queued(let text, let time):
                // Typed here, it's already echoed and now confirmed; typed in the terminal, it shows now.
                if let index = pendingIndex(for: text, in: list) {
                    if list[index].time == nil { list[index].time = time }
                    list[index].pending = "queued"
                    touched.insert(index)
                    continue
                }
                var block = ChatBlock(id: next, kind: .user, text: text, time: time)
                block.pending = "queued"
                append(block)
            case .absorbed(let text, let time):
                // Handed to the agent mid-turn: a real prompt from here on, with no record coming.
                guard let index = pendingIndex(for: text, in: list) else { continue }
                list[index].pending = nil
                list[index].time = time ?? list[index].time
                touched.insert(index)
                promptCount += 1
                if firstPrompt == nil { firstPrompt = time }
            case .taken(let text):
                // Taken together with the others waiting; one record with them all follows.
                if let index = pendingIndex(for: text, in: list) { takenEchoes.insert(index) }
            case .unqueued(let text):
                guard let index = pendingIndex(for: text, in: list) else { continue }
                list[index].pending = "removed"
                touched.insert(index)
            case .dequeued:
                dequeues += 1
            case .summary(let text):
                append(ChatBlock(id: next, kind: .summary, text: text))
            case .user(let text, let images, let time):
                // Prompts taken all at once arrive as one record: the first keeps it, the rest go.
                var taken = takenEchoes.sorted().filter { list.indices.contains($0) && list[$0].pending != nil }
                takenEchoes = []
                // One taken from the queue: the oldest waiting prompt is the one this record is.
                if taken.isEmpty, dequeues > 0, let oldest = list.indices.first(where: { list[$0].kind == .user && list[$0].pending != nil && list[$0].pending != "removed" }) {
                    dequeues -= 1
                    taken = [oldest]
                }
                if let first = taken.first {
                    for index in taken.dropFirst() { list[index].pending = "removed"; touched.insert(index) }
                    list[first].text = text
                    list[first].time = time
                    list[first].images = keep(images)
                    list[first].pending = nil
                    touched.insert(first)
                    lastPrompt = time
                    lastWrite = time
                    promptCount += 1
                    if firstPrompt == nil { firstPrompt = time }
                    commandNote = nil
                    continue
                }
                // A prompt echoed from the compose box becomes its real record, in place.
                if let index = echoIndex(for: text, in: list, at: time) {
                    list[index].text = text
                    list[index].time = time
                    list[index].images = keep(images)
                    list[index].pending = nil
                    touched.insert(index)
                    lastPrompt = time
                    lastWrite = time
                    promptCount += 1
                    if firstPrompt == nil { firstPrompt = time }
                    commandNote = nil
                    continue
                }
                // Close the previous turn with how long the agent worked on it.
                if let start = lastPrompt, let end = lastWrite, end.timeIntervalSince(start) >= 2 {
                    append(ChatBlock(id: next, kind: .note, text: "Worked for " + Self.duration(end.timeIntervalSince(start))))
                }
                // Anything still waiting from long before this prompt was never taken: hide it.
                for index in list.indices where list[index].kind == .user && list[index].pending != nil && list[index].pending != "removed"
                    && (list[index].time.map { (time ?? Date()).timeIntervalSince($0) > 600 } ?? false) {
                    list[index].pending = "removed"; touched.insert(index)
                }
                append(ChatBlock(id: next, kind: .user, text: text, time: time, images: keep(images)))
                lastPrompt = time
                lastWrite = time
                promptCount += 1
                if firstPrompt == nil { firstPrompt = time }
                commandNote = nil
            case .assistant(let text, let time, let meta):
                wrote(time)
                var block = ChatBlock(id: next, kind: .assistant, text: text, messageID: meta?.messageID)
                if let meta {
                    block.model = meta.model
                    block.tokensIn = meta.context
                    block.tokensOut = meta.output
                }
                append(block)
                commandNote = nil
            case .usage(let meta):
                // Claude Code writes one record per content block; the usage repeats on each.
                if let id = meta.messageID, !countedMessages.contains(id) {
                    countedMessages.insert(id)
                    totalOut += meta.output ?? 0
                }
                if let context = meta.context { lastContext = context }
                if let model = meta.model { lastModel = model }
            case .thinking(let text, let time):
                wrote(time)
                append(ChatBlock(id: next, kind: .thinking, text: text))
            case .note(let text):
                append(ChatBlock(id: next, kind: .note, text: text))
            case .command(let name, let args):
                commandNote = nil
                if let text = Self.describe(command: name, args: args) {
                    commandNote = list.count
                    append(ChatBlock(id: next, kind: .note, text: text))
                }
            case .bridge(let text):
                // What /remote-control did, in place of "Ran /remote-control"; else on its own.
                if let index = commandNote, list.indices.contains(index) {
                    list[index].text = text; touched.insert(index)
                } else if list.last?.text != text {
                    append(ChatBlock(id: next, kind: .note, text: text))
                }
                commandNote = nil
            case .commandOutput(let output):
                // The command's own words, in place of ours, when it said something.
                if let index = commandNote, list.indices.contains(index), let summary = Self.commandSummary(output),
                   !list[index].text.hasPrefix("Model changed"), !list[index].text.hasPrefix("Effort changed") {
                    list[index].text = summary
                    touched.insert(index)
                }
                // Claude Code can't restart itself under Remote Control; omux can. Only for a
                // refusal that just happened, not one read back from the file.
                if Self.isRestartRefusal(output), loaded {
                    if let index = commandNote, list.indices.contains(index) {
                        list[index].text = "Claude Code can't restart itself while Remote Control is connected. omux restarted it and resumed the conversation; run /remote-control again to reconnect."
                        touched.insert(index)
                    }
                    restartAsked += 1
                }
                commandNote = nil
            case .todos(let todos, let time):
                wrote(time)
                // One list per turn, updated in place as Claude Code rewrites it.
                if let index = list.lastIndex(where: { $0.kind == .todos }),
                   !list[(index + 1)...].contains(where: { $0.kind == .user }) {
                    list[index].todos = todos
                    touched.insert(index)
                } else {
                    append(ChatBlock(id: next, kind: .todos, text: "", todos: todos))
                }
            case .tool(let row, let time):
                wrote(time)
                running.append(row.id)
                if let last = list.indices.last, list[last].kind == .tools, list[last].tools.count < Self.maxToolRows {
                    list[last].tools.append(row)
                    toolRows[row.id] = (last, list[last].tools.count - 1)
                    touched.insert(last)
                } else {
                    append(ChatBlock(id: next, kind: .tools, text: "", tools: [row], claude: true))
                    toolRows[row.id] = (list.count - 1, 0)
                }
                if ["Edit", "Write", "MultiEdit", "NotebookEdit"].contains(row.name), let path = row.path { filesTouched.insert(path) }
            case .result(let id, let text, let error, let images, let time):
                wrote(time)
                running.removeAll { $0 == id }
                guard let place = toolRows[id], list.indices.contains(place.block),
                      list[place.block].tools.indices.contains(place.row) else { continue }
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? "Done"
                var row = list[place.block].tools[place.row]
                row.result = firstLine.count > 120 ? String(firstLine.prefix(120)) + "…" : (images.isEmpty ? firstLine : "\(images.count) image\(images.count == 1 ? "" : "s")")
                row.output = text.isEmpty ? nil : String(text.prefix(60000))
                row.isError = error
                row.images = keep(images)
                list[place.block].tools[place.row] = row
                touched.insert(place.block)
                if !error, row.path != nil, row.new != nil, row.name == "Edit" || row.name == "MultiEdit" { lookups.append(id) }
            }
        }
        commit(list, touched: touched)
        for id in lookups { lookUpLine(for: id) }
    }

    /// Images are carried by every change, so only the first few are kept.
    private func keep(_ images: [String]) -> [String] {
        let room = max(0, Self.maxImages - imagesKept)
        let kept = Array(images.prefix(room))
        imagesKept += kept.count
        return kept
    }

    /// Stores the new list, re-encoding only the blocks that changed, and tells the view.
    private func commit(_ list: [ChatBlock], touched: Set<Int>) {
        var list = list
        var changed = touched
        for index in touched where index < encoded.count { list[index].rev += 1 }
        if encoded.count > list.count {
            for json in encoded[list.count...] { encodedBytes -= json.utf8.count }
            encoded.removeLast(encoded.count - list.count)
        }
        let needing = list.indices.filter { $0 >= encoded.count || touched.contains($0) }
        if needing.count > 64 {
            // A first read brings hundreds of blocks at once: encode them across the cores.
            var results = [String](repeating: "", count: needing.count)
            results.withUnsafeMutableBufferPointer { buffer in
                let snapshot = needing.map { list[$0] }
                DispatchQueue.concurrentPerform(iterations: snapshot.count) { i in
                    buffer[i] = (try? JSONEncoder().encode(snapshot[i])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                }
            }
            for (i, index) in needing.enumerated() { store(results[i], at: index) }
        } else {
            for index in needing { encode(list[index], at: index) }
        }
        changed.formUnion(needing)
        // Over the ceiling: the oldest blocks lose what weighs, back under the retain line. A long
        // run of tool calls is one block, so the newest block is trimmed too, all but its last rows.
        var index = trimmedUpTo
        while encodedBytes > Self.retainCeiling, index < list.count {
            let newest = index == list.count - 1
            if Self.trim(&list[index], keepRows: newest ? Self.keepRows : 0) {
                list[index].rev += 1
                encode(list[index], at: index)
                changed.insert(index)
            }
            if encodedBytes <= Self.retainBytes || newest { break }
            index += 1
        }
        // The newest block gets more rows later, so it is revisited; the ones before it are done.
        trimmedUpTo = max(trimmedUpTo, min(index, max(list.count - 1, 0)))
        blocks = list
        version += 1
        changeLog.append((version, changed.sorted()))
        if changeLog.count > Self.changeLogLength { changeLog.removeFirst(changeLog.count - Self.changeLogLength) }
    }

    private func encode(_ block: ChatBlock, at index: Int) {
        store((try? encoder.encode(block)).map { String(decoding: $0, as: UTF8.self) } ?? "{}", at: index)
    }

    private func store(_ json: String, at index: Int) {
        if index < encoded.count { encodedBytes -= encoded[index].utf8.count; encoded[index] = json } else { encoded.append(json) }
        encodedBytes += json.utf8.count
    }

    /// Drops a block's heavy content, keeping the last `keepRows` tool rows. True when something was dropped.
    private static func trim(_ block: inout ChatBlock, keepRows: Int) -> Bool {
        var dropped = false
        switch block.kind {
        case .tools:
            for i in block.tools.indices where i < block.tools.count - keepRows && !block.tools[i].trimmed && !block.tools[i].running {
                let row = block.tools[i]
                guard row.output != nil || row.old != nil || row.new != nil || row.unified != nil || !row.images.isEmpty else { continue }
                block.tools[i].output = nil
                block.tools[i].old = nil; block.tools[i].new = nil; block.tools[i].unified = nil
                block.tools[i].images = []
                block.tools[i].trimmed = true
                dropped = true
            }
        case .thinking:
            if keepRows == 0, block.text.count > 200 { block.text = String(block.text.prefix(200)) + "…"; dropped = true }
        case .user:
            if !block.images.isEmpty { block.images = []; dropped = true }
        default:
            break
        }
        return dropped
    }

    /// What the page needs to catch up from `version`: the blocks that changed since, or
    /// everything when it has nothing or the log no longer reaches back that far. Nil when
    /// nothing changed. Ids equal indices, so the page keeps blocks in an array by id.
    func delta(since sent: Int) -> String? {
        guard sent != version else { return nil }
        var ids: [Int]
        var full = false
        // Versions are consecutive, so the log reaches back far enough when its first entry after `sent` is the next one.
        if sent >= 0, let start = changeLog.firstIndex(where: { $0.version > sent }), changeLog[start].version == sent + 1 {
            var set: Set<Int> = []
            for entry in changeLog[start...] { set.formUnion(entry.ids) }
            ids = set.filter { $0 < encoded.count }.sorted()
        } else {
            full = true
            ids = Array(encoded.indices)
        }
        return "{\"full\":\(full),\"total\":\(encoded.count),\"blocks\":[" + ids.map { encoded[$0] }.joined(separator: ",") + "]}"
    }

    /// Where an edit landed, read from the file off the main thread once the result is in.
    private func lookUpLine(for id: String) {
        guard let place = toolRows[id], blocks.indices.contains(place.block),
              blocks[place.block].tools.indices.contains(place.row) else { return }
        let row = blocks[place.block].tools[place.row]
        guard let path = row.path, let new = row.new else { return }
        Task.detached(priority: .utility) {
            guard let line = Self.lineNumber(of: new, in: path) else { return }
            await MainActor.run {
                guard let place = self.toolRows[id], self.blocks.indices.contains(place.block),
                      self.blocks[place.block].tools.indices.contains(place.row) else { return }
                var list = self.blocks
                list[place.block].tools[place.row].line = line
                self.commit(list, touched: [place.block])
            }
        }
    }

    /// The line the written text starts on; nil for big files or text not found.
    nonisolated private static func lineNumber(of text: String, in path: String) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), (attributes[.size] as? Int ?? 0) < 2_000_000,
              let data = FileManager.default.contents(atPath: path), let contents = String(data: data, encoding: .utf8) else { return nil }
        let probe = text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? text
        guard !probe.trimmingCharacters(in: .whitespaces).isEmpty, let range = contents.range(of: probe) else { return nil }
        return contents[..<range.lowerBound].filter { $0 == "\n" }.count + 1
    }

    /// Feeds transcript records straight in, for tests and for anything that already has them.
    func ingest(_ objects: [[String: Any]]) {
        apply(objects.flatMap { Self.events(of: $0) })
        // As after a file's first read: what comes next is live.
        loaded = true
    }

    /// Shows an overview omux built from the agent's files, in place of the terminal dialog.
    @discardableResult
    func show(_ overview: AgentConfig.Overview) -> Int {
        var list = blocks
        let id = next
        list.append(ChatBlock(id: id, kind: .info, text: "", info: overview)); next += 1
        commit(list, touched: [])
        return id
    }

    /// Redraws an overview after an action changed what it shows.
    func update(info id: Int, with overview: AgentConfig.Overview) {
        guard let index = blocks.firstIndex(where: { $0.id == id && $0.kind == .info }) else { return }
        var list = blocks
        list[index].info = overview
        commit(list, touched: [index])
    }

    /// Shows a prompt the moment it's sent, marked queued when the agent is mid-turn; the
    /// agent's own record of it replaces it in place when it takes it.
    func echo(_ text: String, queued: Bool) {
        var list = blocks
        // The previous turn closes here, where its record would otherwise close it.
        if !queued, let start = lastPrompt, let end = lastWrite, end.timeIntervalSince(start) >= 2 {
            list.append(ChatBlock(id: next, kind: .note, text: "Worked for " + Self.duration(end.timeIntervalSince(start)))); next += 1
            lastPrompt = nil
        }
        let inline = Self.inlineImages(in: text)
        var block = ChatBlock(id: next, kind: .user, text: inline.text, time: Date(), images: keep(inline.images))
        // "queuing" until Claude Code's own queue record confirms it; then it can be reordered.
        block.pending = queued ? "queuing" : "sent"
        list.append(block); next += 1
        commit(list, touched: [])
    }

    /// The waiting prompt a queue record names: the one with that text, newest first.
    private func pendingIndex(for text: String, in list: [ChatBlock]) -> Int? {
        list.indices.last { list[$0].kind == .user && list[$0].pending != nil && list[$0].pending != "removed" && list[$0].text.trimmingCharacters(in: .whitespacesAndNewlines) == text }
    }

    /// The echo a real prompt record stands for: the one with the same text, else the oldest
    /// still waiting. Echoes from more than ten minutes before the record were never taken.
    private func echoIndex(for text: String, in list: [ChatBlock], at time: Date?) -> Int? {
        let now = time ?? Date()
        let fresh = list.indices.filter { list[$0].kind == .user && list[$0].pending != nil && list[$0].pending != "removed" && (list[$0].time.map { now.timeIntervalSince($0) < 600 } ?? false) }
        return fresh.first { list[$0].text == text } ?? fresh.first
    }

    /// Pulls back the prompts the agent never took: their echoes go, and the text comes back
    /// for the compose box. Nil when none was waiting.
    func takeUnsent() -> String? {
        let waiting = blocks.indices.filter { blocks[$0].kind == .user && blocks[$0].pending != nil && blocks[$0].pending != "removed" }
        guard !waiting.isEmpty else { return nil }
        var list = blocks
        for index in waiting { list[index].pending = "removed" }
        commit(list, touched: Set(waiting))
        return waiting.map { blocks[$0].text }.joined(separator: "\n\n")
    }

    /// Drops a queued prompt the user pulled back: the block stays, hidden, since ids are positions.
    func dismissEcho(_ id: Int) {
        guard blocks.indices.contains(id), blocks[id].pending != nil else { return }
        var list = blocks
        list[id].pending = "removed"
        commit(list, touched: [id])
    }

    /// The conversation so far as markdown for the next agent: prompts, replies, the tools
    /// used and the files touched, newest turns kept whole when it has to be cut.
    /// The last thing the user asked for, for the next agent to carry on from. Not a hand-off
    /// prompt omux wrote on an earlier switch: those would nest.
    var lastRequest: String? {
        blocks.last { $0.kind == .user && $0.pending == nil && !$0.text.isEmpty && !Self.isHandoffPrompt($0.text) }?.text
    }

    /// Whether a prompt is one omux wrote to hand a conversation to the next agent.
    nonisolated static func isHandoffPrompt(_ text: String) -> Bool {
        text.hasPrefix("Continue my work from a conversation with ") || text.hasPrefix("I continued this work with ")
    }

    func handoff(from agent: String, recent: Bool = false, limit: Int = 60_000) -> String {
        var parts: [String] = []
        for block in blocks[(recent ? switchIndex : 0)...] {
            switch block.kind {
            case .user where block.pending == nil && !block.text.isEmpty:
                parts.append("**User:** " + block.text)
            case .assistant where !block.text.isEmpty:
                parts.append("**\(agent):** " + block.text)
            case .tools:
                let rows = block.tools.prefix(14).map { row -> String in
                    var line = row.name + (row.detail.isEmpty ? "" : " " + row.detail)
                    if let result = row.result, !result.isEmpty, result != "Done" { line += " → " + result }
                    return line
                }
                if !rows.isEmpty { parts.append("_Tools:_ " + rows.joined(separator: " · ") + (block.tools.count > 14 ? " · …" : "")) }
            case .summary:
                parts.append("**Earlier context (summary):**\n" + block.text)
            case .todos:
                parts.append("_Todos:_ " + block.todos.map { "[\($0.status == "completed" ? "x" : " ")] \($0.text)" }.joined(separator: " · "))
            default:
                break
            }
        }
        var kept: [String] = []
        var size = 0
        for part in parts.reversed() {
            if size + part.count > limit, !kept.isEmpty { kept.append("_(earlier turns left out)_"); break }
            kept.append(part); size += part.count
        }
        let files = filesTouched.sorted().map { "- " + $0 }.joined(separator: "\n")
        let about = recent
            ? "Written by omux when this session switched back to you. This is what happened with \(agent) in this folder since your last turn, oldest first. Continue from the last request; don't redo what's done."
            : "Written by omux when this session switched agents. This is the conversation so far in this folder, oldest first. Continue from the last request; don't redo what's done."
        return "# Hand-off from \(agent)\n\n\(about)\n\n"
            + (files.isEmpty ? "" : "## Files touched\n\(files)\n\n") + "## Conversation\n\n" + kept.reversed().joined(separator: "\n\n") + "\n"
    }

    /// Where the current agent's turns begin: after the last hand-over line, else the start.
    private var switchIndex: Int {
        blocks.lastIndex { $0.kind == .note && $0.text.hasPrefix("Continued with") }.map { $0 + 1 } ?? 0
    }

    /// Whether anything happened since the last hand-over, so a return has something to hand back.
    var hasTurnsSinceSwitch: Bool {
        blocks[switchIndex...].contains { ($0.kind == .user && $0.pending == nil) || $0.kind == .assistant || $0.kind == .tools }
    }

    /// A line between messages, for what an action did.
    func note(_ text: String) {
        var list = blocks
        list.append(ChatBlock(id: next, kind: .note, text: text)); next += 1
        commit(list, touched: [])
    }

    /// "48s", "1m 48s", "1h 02m".
    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return String(format: "%dh %02dm", s / 3600, s % 3600 / 60)
    }

    // MARK: Codex

    /// What the app-server says the thread did: a read follows at once, and the reply's text
    /// shows as it streams, so the answer is in view when the turn ends, not a poll later.
    private func codexEvent(_ event: CodexManager.TranscriptEvent) {
        guard provider == .codex, !paused else { return }
        switch event {
        case .delta(let item, let text):
            codexDelta(item: item, text: text)
        case .item(let id, _, let completed):
            if completed, codexLive?.id == id { codexLive = nil }
            loadCodex()
        case .turn(let completed):
            if completed { codexLive = nil }
            loadCodex()
        }
    }

    /// A piece of the reply Codex is writing: shown at the end, and replaced by the thread's own
    /// record of the message when it completes.
    func codexDelta(item: String, text: String) {
        var list = blocks
        if codexLive?.id == item, let index = codexLiveBlock, list.indices.contains(index), list[index].kind == .assistant {
            codexLive?.text += text
            list[index].text = codexLive?.text ?? text
            commit(list, touched: [index])
        } else {
            codexLive = (item, text)
            list.append(ChatBlock(id: list.count, kind: .assistant, text: text))
            codexLiveBlock = list.count - 1
            commit(list, touched: [])
        }
        next = blocks.count
    }

    /// Codex keeps the thread; its app-server lists the latest items, so the list is rebuilt each
    /// time. A read asked for while one is in flight follows it. Prompts echoed from the box that
    /// the thread doesn't list yet, and the reply still streaming in, stay at the end.
    private func loadCodex() {
        guard !paused else { return }
        guard !loading else { codexReloadPending = true; return }
        guard let thread = codexThread() else {
            if blocks.isEmpty { notice = "No conversation yet. Send the first message below." }
            loaded = true
            return
        }
        loading = true
        let generation = generation
        Task {
            defer {
                if generation == self.generation, codexReloadPending { codexReloadPending = false; loadCodex() }
            }
            do {
                var items = try await CodexManager.shared.transcriptItems(threadID: thread, tabID: tabID)
                guard generation == self.generation else { return }
                loading = false; loaded = true
                if let skip = codexSkipThrough, let index = items.lastIndex(where: { $0["id"] as? String == skip }) {
                    items.removeFirst(index + 1)
                }
                if let last = items.last?["id"] as? String { codexLastItem = last }
                let base = min(codexBase, blocks.count)
                let fresh = Self.blocks(fromCodex: items, base: base, skipping: codexLive?.id)
                var list = Array(blocks.prefix(base)) + fresh
                // Echoes at the end stay until the thread lists their prompts: one more prompt
                // listed than last time means the oldest echo was taken.
                let users = fresh.filter { $0.kind == .user }.count
                var echoes: [ChatBlock] = []
                var index = blocks.count - 1
                while index >= base, blocks[index].kind == .user, let pending = blocks[index].pending, pending != "removed" {
                    echoes.insert(blocks[index], at: 0); index -= 1
                }
                echoes.removeFirst(min(max(0, users - codexUserCount), echoes.count))
                codexUserCount = users
                codexLiveBlock = nil
                if let live = codexLive {
                    list.append(ChatBlock(id: list.count, kind: .assistant, text: live.text))
                    codexLiveBlock = list.count - 1
                }
                for echo in echoes {
                    var block = ChatBlock(id: list.count, kind: .user, text: echo.text, time: echo.time, images: echo.images)
                    block.pending = echo.pending
                    list.append(block)
                }
                if list != blocks {
                    // Items keep their place, so only the ones that changed are re-encoded.
                    var touched: Set<Int> = []
                    for index in list.indices where index < blocks.count && list[index] != blocks[index] { touched.insert(index) }
                    var merged = list
                    for index in touched { merged[index].rev = blocks[index].rev }
                    promptCount = merged.filter { $0.kind == .user }.count
                    commit(merged, touched: touched)
                }
                // Echoes and notes take the next id after the items.
                next = blocks.count
                notice = nil
            } catch {
                guard generation == self.generation else { return }
                loading = false; loaded = true
                if blocks.isEmpty { notice = "Start the session to load its transcript." }
            }
        }
    }

    /// `skipping` is the message still streaming in, shown from its deltas instead.
    private static func blocks(fromCodex items: [[String: Any]], base: Int = 0, skipping live: String? = nil) -> [ChatBlock] {
        var list: [ChatBlock] = []
        var next = base
        func add(_ kind: ChatBlock.Kind, _ text: String, tools: [ToolRow] = []) {
            list.append(ChatBlock(id: next, kind: kind, text: text, tools: tools)); next += 1
        }
        func tool(_ row: ToolRow) {
            if let last = list.indices.last, list[last].kind == .tools { list[last].tools.append(row) } else { add(.tools, "", tools: [row]) }
        }
        func finish(_ row: inout ToolRow, status: String) {
            if status != "inProgress" { row.result = status.isEmpty ? "Done" : status.capitalized; row.isError = status == "failed" }
        }
        for item in items {
            let id = item["id"] as? String ?? UUID().uuidString
            let status = item["status"] as? String ?? ""
            switch item["type"] as? String {
            case "userMessage":
                let content = item["content"] as? [[String: Any]] ?? []
                let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { add(.user, text) }
            case "agentMessage":
                guard id != live else { break }
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { add(.assistant, text) }
            case "reasoning":
                let parts = (item["summary"] as? [String] ?? []) + (item["content"] as? [String] ?? [])
                let text = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { add(.thinking, text) }
            case "commandExecution":
                let output = (item["aggregatedOutput"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let exit = item["exitCode"] as? Int
                var row = ToolRow(id: id, name: "Bash", detail: (item["command"] as? String ?? "").replacingOccurrences(of: "\n", with: " "))
                if status != "inProgress" {
                    let firstLine = output.split(separator: "\n").first.map(String.init) ?? "Done"
                    row.result = exit.map { $0 == 0 ? "Done" : "Exit \($0)" } ?? (firstLine.isEmpty ? "Done" : firstLine)
                    row.output = output.isEmpty ? nil : String(output.prefix(6000))
                    row.isError = (exit ?? 0) != 0 || status == "failed"
                }
                tool(row)
            case "fileChange":
                let changes = item["changes"] as? [[String: Any]] ?? []
                let paths = changes.compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }
                var row = ToolRow(id: id, name: "Edit", detail: paths.isEmpty ? "files" : paths.joined(separator: ", "))
                let diffs = changes.compactMap { $0["diff"] as? String }
                if !diffs.isEmpty { row.unified = String(diffs.joined(separator: "\n").prefix(20000)) }
                finish(&row, status: status)
                tool(row)
            case "mcpToolCall":
                var row = ToolRow(id: id, name: item["tool"] as? String ?? "MCP", detail: item["server"] as? String ?? "")
                finish(&row, status: status)
                tool(row)
            case "webSearch":
                var row = ToolRow(id: id, name: "Search", detail: item["query"] as? String ?? "")
                row.result = "Done"
                tool(row)
            default:
                break
            }
        }
        return list
    }
}
