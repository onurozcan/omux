import Foundation
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Reads Claude Code's transcript records into events: what was said, called and returned,
/// with nothing of how it is shown.
public enum TranscriptParser {
    /// Built once: a formatter costs more than parsing the record it stamps. Both are thread-safe.
    nonisolated(unsafe) static let fractionalDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) static let wholeDates: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()

    /// Pasted and returned images beyond these are left out: the page carries every image on each change.
    public static let maxImageChars = 1_000_000

    public struct Meta: Equatable {
        public var messageID: String?
        public var model: String?
        public var context: Int?
        public var output: Int?
    }

    public enum Event {
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

    public static func date(of object: [String: Any]) -> Date? {
        guard let stamp = object["timestamp"] as? String else { return nil }
        return fractionalDates.date(from: stamp) ?? wholeDates.date(from: stamp)
    }

    public static func dataURL(of item: [String: Any]) -> String? {
        guard let source = item["source"] as? [String: Any], source["type"] as? String == "base64",
              let data = source["data"] as? String, data.count < maxImageChars else { return nil }
        return "data:\(source["media_type"] as? String ?? "image/png");base64,\(data)"
    }

    /// Claude Code writes one JSON object per line: user turns (prompts and tool results),
    /// assistant turns (text, thinking and tool calls), and housekeeping records.
    public static func events(of object: [String: Any]) -> [Event] {
        var events: [Event] = []
        let message = object["message"] as? [String: Any]
        switch object["type"] as? String {
        case "queue-operation":
            if object["operation"] as? String == "dequeue" { return [.dequeued] }
            guard let content = object["content"] as? String else { return [] }
            // A pasted prompt is queued in its <pasted_content> wrapper; without it, it is the
            // prompt as typed, which is what its echo holds.
            let text = content.replacingOccurrences(of: #"\n?</?pasted_content[^>]*>\n?"#, with: "\n", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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
                            let options = (q["options"] as? [[String: Any]] ?? []).filter { $0["label"] is String }
                            return Question(text: q["question"] as? String ?? "",
                                            header: q["header"] as? String,
                                            options: options.map { $0["label"] as? String ?? "" },
                                            descriptions: options.map { $0["description"] as? String ?? "" },
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
    public static func inlineImages(in text: String, thumbnails: Bool = true) -> (text: String, images: [String]) {
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
    public static func thumbnail(of path: String) -> String? {
        #if canImport(AppKit) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 900,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
        #else
        // No image codecs in Foundation on Linux: the session host sends paths, and the app
        // that shows the transcript makes the thumbnails.
        return nil
        #endif
    }

    public static func cap(_ text: String) -> String {
        text.count > 100_000 ? String(text.prefix(100_000)) + "\n…" : text
    }

    /// What an edit replaced and wrote, capped so a huge file doesn't flood the page.
    public static func edit(of tool: String, input: [String: Any]) -> (String?, String?) {
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
    public static func userEvents(_ raw: String, images: [String], time: Date?) -> [Event] {
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

    public static func element(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"), let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex) else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a slash command did, in a few words; nil for commands whose effect shows on its own.
    public static func describe(command name: String, args: String) -> String? {
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

    public static func isRestartRefusal(_ output: String) -> Bool {
        output.contains("Can't restart while Remote Control is connected")
    }

    /// The first line of a command's output, short enough for a note.
    public static func commandSummary(_ output: String) -> String? {
        guard var line = output.split(separator: "\n").first.map(String.init) else { return nil }
        line = line.replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespaces)
        if let cut = line.range(of: " (") { line = String(line[..<cut.lowerBound]) }
        if line.count > 140 { line = String(line.prefix(140)) + "…" }
        return line.isEmpty ? nil : line
    }

    // MARK: Applying
}
