import Foundation

// What was worked on, when, and for how long, read from Claude Code's transcripts in
// ~/.claude/projects: one record per conversation, with the stretches of time it was active.
// The statistics window builds its graph of projects and sessions and its daily log on this.

/// One stretch of continuous work: events no more than `WorkStats.idleGap` apart.
public struct WorkSpan: Codable, Hashable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Something the user asked in a conversation, with when.
public struct WorkPrompt: Codable, Hashable {
    public var date: Date
    public var text: String
}

/// One Claude Code conversation, as much of it as the statistics show.
public struct WorkSession: Codable, Hashable, Identifiable {
    public var id: String
    /// The folder it ran in.
    public var cwd: String
    /// Claude Code's own title for it, or else the first thing asked.
    public var title: String
    public var branch: String?
    public var prompts: [WorkPrompt]
    public var spans: [WorkSpan]

    public var start: Date { spans.first?.start ?? .distantPast }
    public var end: Date { spans.last?.end ?? .distantPast }
    public var activeTime: TimeInterval { spans.reduce(0) { $0 + $1.duration } }
    /// The project's name: its folder's.
    public var projectName: String { cwd == NSHomeDirectory() ? "~" : (cwd as NSString).lastPathComponent }
}

public enum WorkStats {
    /// Events further apart than this end a stretch of work: a break, not thinking time.
    public static let idleGap: TimeInterval = 10 * 60
    /// A stretch with a single event still took some time.
    public static let minimumSpan: TimeInterval = 60
    /// Bumped when what is read from a transcript changes, so cached readings are redone.
    public static let cacheVersion = 2
    static let maxPrompts = 40
    static let maxPromptLength = 240

    // MARK: Reading a transcript

    /// Reads one transcript. nil when it has no conversation in it (only bookkeeping records).
    public static func read(_ url: URL) -> WorkSession? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return parse(data, id: url.deletingPathExtension().lastPathComponent)
    }

    public static func parse(_ data: Data, id: String) -> WorkSession? {
        var times: [Date] = []
        var prompts: [WorkPrompt] = []
        var cwd: String?
        var branch: String?
        var aiTitle: String?
        var customTitle: String?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func date(_ text: String) -> Date? { iso.date(from: text) ?? plain.date(from: text) }

        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            let bytes = buffer.bindMemory(to: UInt8.self)
            var lineStart = 0
            let count = bytes.count
            while lineStart < count {
                var lineEnd = lineStart
                while lineEnd < count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
                defer { lineStart = lineEnd + 1 }
                guard lineEnd > lineStart else { continue }
                let line = UnsafeBufferPointer(rebasing: bytes[lineStart..<lineEnd])
                // Most of the bytes are tool output in a few huge lines; parsing those fully
                // costs a lot and gives nothing but their time.
                if line.count > 64 * 1024 {
                    if let text = lastTimestamp(in: line), let when = date(text) { times.append(when) }
                    continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let type = object["type"] as? String
                switch type {
                case "ai-title": aiTitle = (object["aiTitle"] as? String) ?? aiTitle
                case "custom-title": customTitle = (object["customTitle"] as? String) ?? (object["title"] as? String) ?? customTitle
                case "summary": aiTitle = aiTitle ?? (object["summary"] as? String)
                case "user", "assistant":
                    // A subagent's side conversation is its parent's work, already timed there.
                    if object["isSidechain"] as? Bool == true { continue }
                    guard let stamp = object["timestamp"] as? String, let when = date(stamp) else { continue }
                    times.append(when)
                    if cwd == nil, let value = object["cwd"] as? String, !value.isEmpty { cwd = value }
                    if let value = object["gitBranch"] as? String, !value.isEmpty, value != "HEAD" { branch = value }
                    if type == "user", object["isMeta"] as? Bool != true, prompts.count < maxPrompts,
                       let text = promptText(object["message"]) {
                        prompts.append(WorkPrompt(date: when, text: text))
                    }
                default: continue
                }
            }
        }
        guard let cwd, !times.isEmpty else { return nil }
        times.sort()
        let title = customTitle ?? aiTitle ?? prompts.first?.text ?? "Untitled session"
        return WorkSession(id: id, cwd: cwd, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           branch: branch, prompts: prompts, spans: spans(times))
    }

    /// What the user typed, from a user record's message: text, not tool results, slash
    /// commands or the system's own notes.
    static func promptText(_ message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            // A tool result is not something the user said.
            if blocks.contains(where: { $0["type"] as? String == "tool_result" }) { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        }
        guard var text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, !text.hasPrefix("<") else { return nil }
        // Pasted text stands as a mark, not as the paste itself.
        text = text.replacingOccurrences(of: "<pasted_content[^>]*>[\\s\\S]*?</pasted_content>", with: "[pasted text]", options: .regularExpression)
        if let open = text.range(of: "<pasted_content") { text = String(text[..<open.lowerBound]) + "[pasted text]" }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if text.count > maxPromptLength { text = String(text.prefix(maxPromptLength)) + "…" }
        return text
    }

    /// The value of the last `"timestamp":"…"` in a line: the record's own, which comes after
    /// its (possibly huge) message.
    static func lastTimestamp(in line: UnsafeBufferPointer<UInt8>) -> String? {
        let key = Array("\"timestamp\":\"".utf8)
        guard line.count > key.count else { return nil }
        var i = line.count - key.count
        while i >= 0 {
            if line[i] == key[0] {
                var match = true
                for k in 1..<key.count where line[i + k] != key[k] { match = false; break }
                if match {
                    let start = i + key.count
                    var end = start
                    while end < line.count, line[end] != 0x22 { end += 1 }
                    return String(decoding: UnsafeBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
                }
            }
            i -= 1
        }
        return nil
    }

    /// Sorted event times as stretches of work.
    public static func spans(_ times: [Date]) -> [WorkSpan] {
        var result: [WorkSpan] = []
        for time in times {
            if var last = result.last, time.timeIntervalSince(last.end) <= idleGap {
                last.end = max(last.end, time)
                result[result.count - 1] = last
            } else {
                result.append(WorkSpan(start: time, end: time))
            }
        }
        return result.map { $0.duration < minimumSpan ? WorkSpan(start: $0.start, end: $0.start.addingTimeInterval(minimumSpan)) : $0 }
    }

    // MARK: Adding up

    /// The stretches as one timeline without overlaps: two sessions at once are one hour
    /// worked, not two.
    public static func union(_ spans: [WorkSpan]) -> [WorkSpan] {
        var result: [WorkSpan] = []
        for span in spans.sorted(by: { $0.start < $1.start }) {
            if var last = result.last, span.start <= last.end {
                last.end = max(last.end, span.end)
                result[result.count - 1] = last
            } else {
                result.append(span)
            }
        }
        return result
    }

    /// How much of `spans` falls on each day (local midnight to midnight).
    public static func perDay(_ spans: [WorkSpan], calendar: Calendar = .current) -> [Date: TimeInterval] {
        var result: [Date: TimeInterval] = [:]
        for span in spans {
            var cursor = span.start
            while cursor < span.end {
                let day = calendar.startOfDay(for: cursor)
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let end = min(next, span.end)
                result[day, default: 0] += end.timeIntervalSince(cursor)
                cursor = end
            }
        }
        return result
    }

    /// The parts of `spans` inside [from, to).
    public static func clip(_ spans: [WorkSpan], from: Date, to: Date) -> [WorkSpan] {
        spans.compactMap { span in
            let start = max(span.start, from), end = min(span.end, to)
            return end > start ? WorkSpan(start: start, end: end) : nil
        }
    }

    // MARK: Every transcript, with a cache

    /// Where transcripts are; folders of Claude Code runs that aren't the user's work (an app's
    /// cache asking Claude in the background) are left out.
    public static func transcriptFiles(root: URL = URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects")) -> [URL] {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.filter { !$0.lastPathComponent.contains("-Library-") }.flatMap { folder in
            ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
        }
    }

    private struct CacheEntry: Codable {
        var size: Int
        var modified: Date
        var session: WorkSession?
    }

    /// Every session, read from the transcripts that changed since the last call and from
    /// `cache` for the rest. The cache is rewritten when anything was read.
    public static func load(cache: URL, files: [URL] = transcriptFiles()) -> [WorkSession] {
        var entries = (try? Data(contentsOf: cache)).flatMap { try? JSONDecoder.workStats.decode([String: CacheEntry].self, from: $0) } ?? [:]
        var changed = false
        var seen = Set<String>()
        for url in files {
            let path = url.path
            seen.insert(path)
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate ?? .distantPast
            // Dates go through JSON as Doubles, so compare them as such, not to the nanosecond.
            if let entry = entries[path], entry.size == size, abs(entry.modified.timeIntervalSince(modified)) < 0.01 { continue }
            entries[path] = CacheEntry(size: size, modified: modified, session: read(url))
            changed = true
        }
        if entries.keys.contains(where: { !seen.contains($0) }) {
            entries = entries.filter { seen.contains($0.key) }
            changed = true
        }
        if changed, let data = try? JSONEncoder.workStats.encode(entries) {
            try? data.write(to: cache, options: .atomic)
        }
        return entries.values.compactMap(\.session).sorted { $0.start > $1.start }
    }
}

// MARK: Commits

/// A commit in a project's repository: what got made, beside what was asked.
public struct WorkCommit: Hashable, Identifiable {
    public var id: String
    public var date: Date
    public var subject: String
    public var repository: String
}

extension WorkStats {
    /// Commits in `directory`'s repository between the two dates, by the configured git user
    /// when there is one. Empty when it isn't a repository.
    public static func commits(in directory: String, from: Date, to: Date) -> [WorkCommit] {
        func git(_ arguments: [String]) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", directory] + arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
        }
        guard FileManager.default.fileExists(atPath: directory) else { return [] }
        var arguments = ["log", "--all", "--no-merges", "--since=@\(Int(from.timeIntervalSince1970))",
                         "--until=@\(Int(to.timeIntervalSince1970))", "--pretty=format:%H%x1f%at%x1f%s"]
        if let email = git(["config", "user.email"])?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            arguments.append("--author=\(email)")
        }
        guard let output = git(arguments) else { return [] }
        // --all sees a rebased or cherry-picked commit twice; it is one piece of work.
        var seen = Set<String>()
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\u{1f}", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let seconds = TimeInterval(parts[1]), seen.insert("\(parts[1]) \(parts[2])").inserted else { return nil }
            return WorkCommit(id: String(parts[0]), date: Date(timeIntervalSince1970: seconds),
                              subject: String(parts[2]), repository: directory)
        }
    }
}

extension JSONDecoder {
    static let workStats: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}

extension JSONEncoder {
    static let workStats: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}
