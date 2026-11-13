import Foundation

// The transcript as data: blocks of a conversation, as the page draws them.

public struct Todo: Equatable, Encodable {
    public var text: String
    /// pending, in_progress or completed, as Claude Code writes them.
    public var status: String

    public init(text: String, status: String) {
        self.text = text; self.status = status
    }
}

/// One block of the transcript: a prompt, a reply, thinking, a run of tool calls, a todo list, a note, or an overview.
public struct ChatBlock: Identifiable, Equatable, Encodable {
    public enum Kind: String, Equatable, Encodable { case user, assistant, thinking, tools, todos, note, info, summary }

    /// Where a prompt sent from the compose box stands until the agent's own record of it
    /// arrives. The record ends it: the block becomes that record, with no state.
    ///
    ///     sent ──────────────────────────────▶ recorded
    ///     queuing ──▶ queued ──▶ taken at the turn's end, or mid-turn ──▶ recorded
    ///         └──────────┴─────▶ removed (pulled back, dropped, or folded into another prompt)
    public enum Pending: String, Equatable, Encodable, Sendable {
        /// Sent to an idle agent; its record follows at once.
        case sent
        /// Sent while the agent worked; Claude Code hasn't recorded it in its queue yet.
        case queuing
        /// In Claude Code's queue, where it can be reordered or removed.
        case queued
        /// No longer a prompt of its own. The block stays, hidden, since ids are positions.
        case removed
    }

    /// A prompt the agent hasn't recorded yet and may still take.
    public var isWaiting: Bool { kind == .user && pending != nil && pending != .removed }
    /// A prompt in the agent's queue, or on its way into it.
    public var inQueue: Bool { kind == .user && (pending == .queued || pending == .queuing) }
    public let id: Int
    public var kind: Kind
    public var text: String
    public var time: Date?
    public var tools: [ToolRow] = []
    public var todos: [Todo] = []
    /// Images pasted into a prompt, as data URLs.
    public var images: [String] = []
    public var model: String?
    /// Context the reply was produced from (input plus cache), and tokens it wrote.
    public var tokensIn: Int?
    public var tokensOut: Int?
    /// The page shows a Changes link on edits of Claude Code sessions.
    public var claude = false
    public var messageID: String?
    /// An overview omux drew itself, for /mcp and the like.
    public var info: AgentConfig.Overview?
    /// A prompt sent from the compose box that the agent hasn't recorded yet: "sent" while it
    /// takes it, "queued" when it arrived mid-turn and waits for the next one.
    public var pending: Pending?
    /// Bumped whenever the block changes after it was first shown; the page redraws by it.
    public var rev = 0

    private enum CodingKeys: String, CodingKey { case id, kind, text, time, tools, todos, images, model, tokensIn, tokensOut, claude, info, rev, pending }

    public func encode(to encoder: Encoder) throws {
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

    public init(id: Int, kind: Kind, text: String, time: Date? = nil, tools: [ToolRow] = [], todos: [Todo] = [], images: [String] = [], model: String? = nil, tokensIn: Int? = nil, tokensOut: Int? = nil, claude: Bool = false, messageID: String? = nil, info: AgentConfig.Overview? = nil, pending: Pending? = nil, rev: Int = 0) {
        self.id = id; self.kind = kind; self.text = text; self.time = time; self.tools = tools; self.todos = todos; self.images = images; self.model = model; self.tokensIn = tokensIn; self.tokensOut = tokensOut; self.claude = claude; self.messageID = messageID; self.info = info; self.pending = pending; self.rev = rev
    }
}

public struct ToolRow: Identifiable, Equatable, Encodable {
    public let id: String
    public var name: String
    /// What the call was about, without the tool name: "src/app.tsx", "npm test".
    public var detail: String
    public var result: String?
    /// The result's text, for expanding the row.
    public var output: String?
    public var isError = false
    /// For edits: the text replaced and the text written, shown as a diff. ExitPlanMode keeps its plan in `new`.
    public var old: String?
    public var new: String?
    /// A unified diff, as Codex reports file changes.
    public var unified: String?
    /// AskUserQuestion's questions, answerable from the panel.
    public var questions: [Question] = []
    /// The file a Read, Edit or Write call named, in full.
    public var path: String?
    /// Where an edit landed in the file, found after the result arrived.
    public var line: Int?
    /// Images a tool returned, as data URLs.
    public var images: [String] = []
    /// Output, diff and images were dropped to bound memory; the first line of the result stays.
    public var trimmed = false
    public var running: Bool { result == nil }

    private enum CodingKeys: String, CodingKey { case id, name, detail, result, output, isError, old, new, unified, questions, path, line, images, trimmed, running }

    public func encode(to encoder: Encoder) throws {
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

    public init(id: String, name: String, detail: String, result: String? = nil, output: String? = nil, isError: Bool = false, old: String? = nil, new: String? = nil, unified: String? = nil, questions: [Question] = [], path: String? = nil, line: Int? = nil, images: [String] = [], trimmed: Bool = false) {
        self.id = id; self.name = name; self.detail = detail; self.result = result; self.output = output; self.isError = isError; self.old = old; self.new = new; self.unified = unified; self.questions = questions; self.path = path; self.line = line; self.images = images; self.trimmed = trimmed
    }
}
