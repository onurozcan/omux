import Foundation

public enum RecentConversation: Identifiable {
    case claude(RecentSession), codex(CodexConversation)

    public var id: String {
        switch self {
        case .claude(let session): return "claude:" + session.id.uuidString.lowercased()
        case .codex(let session): return "codex:" + session.id
        }
    }
    public var cwd: String {
        switch self { case .claude(let s): return s.cwd; case .codex(let s): return s.cwd }
    }
    public var folder: String { cwd.tildeAbbreviated }
    public var prompt: String {
        switch self { case .claude(let s): return s.prompt; case .codex(let s): return s.name }
    }
    public var date: Date {
        switch self { case .claude(let s): return s.date; case .codex(let s): return s.date }
    }
}

/// A Claude Code conversation found in ~/.claude/projects.
public struct RecentSession: Identifiable, Hashable {
    public let id: UUID
    public let cwd: String
    public let prompt: String
    public let date: Date

    public var folder: String { cwd.tildeAbbreviated }

    /// Short name for a tab: first words of the first prompt.
    public var tabName: String {
        let words = prompt.split(separator: " ").prefix(5).joined(separator: " ")
        return words.count > 32 ? String(words.prefix(32)) + "…" : words
    }

    private struct Record: Decodable {
        struct Message: Decodable {
            public let content: Content?
            public enum Content: Decodable {
                case text(String), blocks([Block])
                public struct Block: Decodable { let text: String? }
                public init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
                }
                public var text: String {
                    switch self {
                    case .text(let s): return s
                    case .blocks(let b): return b.compactMap(\.text).joined(separator: " ")
                    }
                }
            }
        }
        let type: String
        let cwd: String?
        /// Claude Code's own text in a user record, e.g. a skill's instructions after its slash command.
        let isMeta: Bool?
        let message: Message?
    }

    /// Scans transcripts, newest first. Reads only the head of each file.
    public static func load(limit: Int = 300) -> [RecentSession] {
        let root = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var files: [(URL, Date)] = []
        for project in projects {
            guard let items = try? fm.contentsOfDirectory(at: project, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for url in items where url.pathExtension == "jsonl" {
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((url, date))
            }
        }
        files.sort { $0.1 > $1.1 }
        let decoder = JSONDecoder()
        var result: [RecentSession] = []
        for (url, date) in files.prefix(limit) {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let head = handle.readData(ofLength: 128 * 1024)
            try? handle.close()
            // Lossy: the cut can split a character, which only spoils the (partial) last line.
            let text = String(decoding: head, as: UTF8.self)
            // Claude Code's own text (isMeta) only stands in when the user typed nothing else.
            var found: (cwd: String, prompt: String)?
            for line in text.split(separator: "\n") {
                guard let record = try? decoder.decode(Record.self, from: Data(line.utf8)),
                      record.type == "user",
                      let cwd = record.cwd,
                      let prompt = record.message?.content?.text.trimmingCharacters(in: .whitespacesAndNewlines),
                      !prompt.isEmpty, !prompt.hasPrefix("<") // skip slash-command and system messages
                else { continue }
                if record.isMeta == true {
                    if found == nil { found = (cwd, prompt) }
                    continue
                }
                found = (cwd, prompt)
                break
            }
            if let found {
                result.append(RecentSession(id: id, cwd: found.cwd, prompt: found.prompt.replacingOccurrences(of: "\n", with: " "), date: date))
            }
        }
        return result
    }
}
