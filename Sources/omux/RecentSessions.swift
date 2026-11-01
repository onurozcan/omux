import Foundation

enum RecentConversation: Identifiable {
    case claude(RecentSession), codex(CodexConversation), antigravity(AntigravitySession)

    var id: String {
        switch self {
        case .claude(let session): return "claude:" + session.id.uuidString.lowercased()
        case .codex(let session): return "codex:" + session.id
        case .antigravity(let session): return "antigravity:" + session.id
        }
    }
    var cwd: String {
        switch self {
        case .claude(let s): return s.cwd
        case .codex(let s): return s.cwd
        case .antigravity(let s): return s.cwd
        }
    }
    var folder: String { (cwd as NSString).abbreviatingWithTildeInPath }
    var prompt: String {
        switch self {
        case .claude(let s): return s.prompt
        case .codex(let s): return s.name
        case .antigravity(let s): return s.prompt
        }
    }
    var date: Date {
        switch self {
        case .claude(let s): return s.date
        case .codex(let s): return s.date
        case .antigravity(let s): return s.date
        }
    }
}

/// A Claude Code conversation found in ~/.claude/projects.
struct RecentSession: Identifiable, Hashable {
    let id: UUID
    let cwd: String
    let prompt: String
    let date: Date

    var folder: String { (cwd as NSString).abbreviatingWithTildeInPath }

    /// Short name for a tab: first words of the first prompt.
    var tabName: String {
        let words = prompt.split(separator: " ").prefix(5).joined(separator: " ")
        return words.count > 32 ? String(words.prefix(32)) + "…" : words
    }

    private struct Record: Decodable {
        struct Message: Decodable {
            let content: Content?
            enum Content: Decodable {
                case text(String), blocks([Block])
                struct Block: Decodable { let text: String? }
                init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let s = try? c.decode(String.self) { self = .text(s) } else { self = .blocks(try c.decode([Block].self)) }
                }
                var text: String {
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
    static func load(limit: Int = 300) -> [RecentSession] {
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

/// An Antigravity CLI conversation found in ~/.gemini/antigravity-cli or ~/.gemini/antigravity.
struct AntigravitySession: Identifiable, Hashable {
    let id: String
    let cwd: String
    let prompt: String
    let date: Date

    var folder: String { (cwd as NSString).abbreviatingWithTildeInPath }

    /// Short name for a tab: first words of the prompt.
    var tabName: String {
        let words = prompt.split(separator: " ").prefix(5).joined(separator: " ")
        return words.count > 32 ? String(words.prefix(32)) + "…" : words
    }

    private struct Row: Decodable {
        let conversation_id: String
        let title: String?
        let preview: String?
        let workspace_uris: String?
        let timestamp: Double?
    }

    /// Loads recent conversations from SQLite summary databases.
    static func load(limit: Int = 300) -> [AntigravitySession] {
        let home = NSHomeDirectory()
        let paths = [
            "\(home)/.gemini/antigravity-cli/conversation_summaries.db",
            "\(home)/.gemini/antigravity/conversation_summaries.db"
        ]
        var seenIDs = Set<String>()
        var result: [AntigravitySession] = []

        let decoder = JSONDecoder()
        for dbPath in paths where FileManager.default.fileExists(atPath: dbPath) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [
                "-json",
                dbPath,
                "SELECT conversation_id, title, preview, workspace_uris, CAST(strftime('%s', last_modified_time) AS INTEGER) AS timestamp FROM conversation_summaries WHERE killed = 0 ORDER BY last_modified_time DESC LIMIT \(limit);"
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let rows = try? decoder.decode([Row].self, from: data) else { continue }

            for row in rows {
                guard !seenIDs.contains(row.conversation_id) else { continue }
                seenIDs.insert(row.conversation_id)

                let prompt = [row.title, row.preview].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty }) ?? "Antigravity conversation"

                var cwd = home
                if let urisRaw = row.workspace_uris,
                   let urisArray = try? JSONDecoder().decode([String].self, from: Data(urisRaw.utf8)),
                   let first = urisArray.first,
                   let url = URL(string: first) {
                    cwd = url.path
                }
                let date = row.timestamp.map { Date(timeIntervalSince1970: $0) } ?? Date()
                result.append(AntigravitySession(id: row.conversation_id, cwd: cwd, prompt: prompt.replacingOccurrences(of: "\n", with: " "), date: date))
            }
        }
        result.sort { $0.date > $1.date }
        return Array(result.prefix(limit))
    }
}
