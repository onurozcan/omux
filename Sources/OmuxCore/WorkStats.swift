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

/// Tokens the model read and wrote: what a conversation cost.
public struct WorkTokens: Codable, Hashable {
    public var input = 0
    public var output = 0
    /// Context written to the prompt cache.
    public var cacheWrite = 0
    /// Context read back from the prompt cache: most of a long conversation's tokens.
    public var cacheRead = 0
    public init(input: Int = 0, output: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0) {
        self.input = input; self.output = output; self.cacheWrite = cacheWrite; self.cacheRead = cacheRead
    }
    public var total: Int { input + output + cacheWrite + cacheRead }
    public static func + (a: WorkTokens, b: WorkTokens) -> WorkTokens {
        WorkTokens(input: a.input + b.input, output: a.output + b.output,
                   cacheWrite: a.cacheWrite + b.cacheWrite, cacheRead: a.cacheRead + b.cacheRead)
    }
    public static func += (a: inout WorkTokens, b: WorkTokens) { a = a + b }

    /// From a message's `usage`.
    init?(usage: Any?) {
        guard let usage = usage as? [String: Any] else { return nil }
        func int(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        self.init(input: int("input_tokens"), output: int("output_tokens"),
                  cacheWrite: int("cache_creation_input_tokens"), cacheRead: int("cache_read_input_tokens"))
    }
}

/// A conversation's tokens on one day, or in one hour.
public struct WorkTokenDay: Codable, Hashable {
    /// Local midnight, or the start of the hour.
    public var day: Date
    public var tokens: WorkTokens
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
    /// Its tokens day by day, its subagents' included.
    public var tokenDays: [WorkTokenDay] = []
    /// The same hour by hour, for ranges that don't start at midnight.
    public var tokenHours: [WorkTokenDay] = []

    public var tokens: WorkTokens { tokenDays.reduce(WorkTokens()) { $0 + $1.tokens } }
    /// Its tokens in the hours in [from, to).
    public func tokens(from: Date, to: Date) -> WorkTokens {
        (tokenHours.isEmpty ? tokenDays : tokenHours).reduce(WorkTokens()) { $1.day >= from && $1.day < to ? $0 + $1.tokens : $0 }
    }

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
    public static let cacheVersion = 4
    static let maxPrompts = 40
    static let maxPromptLength = 240

    // MARK: Reading a transcript

    /// Reads one transcript. nil when it has no conversation in it (only bookkeeping records).
    public static func read(_ url: URL) -> WorkSession? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        // Subagents keep their own transcripts beside it; their tokens are this conversation's.
        let folder = url.deletingPathExtension().appendingPathComponent("subagents")
        let subagents = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        return parse(data, id: url.deletingPathExtension().lastPathComponent, subagents: subagents)
    }

    public static func parse(_ data: Data, id: String, subagents: [Data] = []) -> WorkSession? {
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
        // A reply streamed in parts repeats its usage on every part: one count per message.
        var usage: [String: (Date, WorkTokens)] = [:]

        func scan(_ data: Data, main: Bool) {
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
                    guard let text = lastTimestamp(in: line), let when = date(text) else { continue }
                    if main { times.append(when) }
                    if let (id, tokens) = bigLineUsage(line) { usage[id] = (when, tokens) }
                    continue
                }
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                let type = object["type"] as? String
                if type == "assistant", let message = object["message"] as? [String: Any],
                   let tokens = WorkTokens(usage: message["usage"]),
                   let stamp = object["timestamp"] as? String, let when = date(stamp) {
                    let key = (message["id"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
                    usage[key] = (when, tokens)
                }
                guard main else { continue }
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
        }
        scan(data, main: true)
        for subagent in subagents { scan(subagent, main: false) }
        guard let cwd, !times.isEmpty else { return nil }
        let calendar = Calendar.current
        var byDay: [Date: WorkTokens] = [:]
        var byHour: [Date: WorkTokens] = [:]
        for (when, tokens) in usage.values {
            byDay[calendar.startOfDay(for: when), default: WorkTokens()] += tokens
            byHour[calendar.dateInterval(of: .hour, for: when)?.start ?? when, default: WorkTokens()] += tokens
        }
        times.sort()
        let title = customTitle ?? aiTitle ?? prompts.first?.text ?? "Untitled session"
        return WorkSession(id: id, cwd: cwd, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                           branch: branch, prompts: prompts, spans: spans(times),
                           tokenDays: byDay.map { WorkTokenDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day },
                           tokenHours: byHour.map { WorkTokenDay(day: $0.key, tokens: $0.value) }.sorted { $0.day < $1.day })
    }

    /// The message id and usage of a line too big to parse whole: the id comes before the
    /// content and the usage after it.
    static func bigLineUsage(_ line: UnsafeBufferPointer<UInt8>) -> (String, WorkTokens)? {
        guard let usageAt = find("\"usage\":{", in: line, backward: true) else { return nil }
        let open = usageAt + 8
        var depth = 0, end = open
        while end < line.count {
            if line[end] == 0x7B { depth += 1 } else if line[end] == 0x7D { depth -= 1; if depth == 0 { break } }
            end += 1
        }
        guard end < line.count,
              let object = try? JSONSerialization.jsonObject(with: Data(UnsafeBufferPointer(rebasing: line[open...end]))),
              let tokens = WorkTokens(usage: object) else { return nil }
        var id = "line-\(line.count)-\(usageAt)"
        if let at = find("\"id\":\"msg_", in: line, backward: false) {
            var close = at + 6
            while close < line.count, line[close] != 0x22 { close += 1 }
            id = String(decoding: UnsafeBufferPointer(rebasing: line[(at + 6)..<close]), as: UTF8.self)
        }
        return (id, tokens)
    }

    /// Where `text` first (or last) starts in the line.
    static func find(_ text: String, in line: UnsafeBufferPointer<UInt8>, backward: Bool) -> Int? {
        let key = Array(text.utf8)
        guard line.count >= key.count else { return nil }
        let last = line.count - key.count
        var i = backward ? last : 0
        while i >= 0, i <= last {
            if line[i] == key[0] {
                var match = true
                for k in 1..<key.count where line[i + k] != key[k] { match = false; break }
                if match { return i }
            }
            i += backward ? -1 : 1
        }
        return nil
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
        per(.day, spans, calendar: calendar)
    }

    /// How much of `spans` falls in each day or hour.
    public static func per(_ unit: Calendar.Component, _ spans: [WorkSpan], calendar: Calendar = .current) -> [Date: TimeInterval] {
        var result: [Date: TimeInterval] = [:]
        for span in spans {
            var cursor = span.start
            while cursor < span.end {
                guard let day = calendar.dateInterval(of: unit, for: cursor)?.start,
                      let next = calendar.date(byAdding: unit, value: 1, to: day) else { break }
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
