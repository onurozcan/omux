import Foundation

/// Claude Code's models, read from the installed `claude` program, which carries every model id
/// it knows. The newest of each family is offered, so a model shows up here the day Claude Code
/// learns of it. Scanned again whenever the program changes, as Claude Code updates itself.
@MainActor
final class ClaudeModels: ObservableObject {
    static let shared = ClaudeModels()

    /// "default", then the newest full id of each family, then "opusplan". Claude Code takes
    /// them as `/model <id>`.
    @Published private(set) var list: [String] = ClaudeModels.fallback
    /// Until the program has been read, or when it can't be.
    nonisolated static let fallback = ["default", "claude-fable-5-2", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "opusplan"]
    /// The families offered, in this order. Mythos ids are in the program too, but only
    /// verified organizations can use them.
    nonisolated static let families = ["fable", "opus", "sonnet", "haiku"]

    private var scanned: (path: String, modified: Date)?
    private var scanning = false

    /// Reads the program again if it changed since the last read; cheap otherwise.
    func refresh() {
        guard !scanning else { return }
        scanning = true
        let known = scanned
        Task.detached(priority: .utility) {
            defer { Task { @MainActor in self.scanning = false } }
            guard let program = Self.program() else { return }
            let modified = (try? FileManager.default.attributesOfItem(atPath: program.path))?[.modificationDate] as? Date ?? .distantPast
            if let known, known.path == program.path, known.modified == modified { return }
            let ids = (try? Data(contentsOf: program, options: .mappedIfSafe)).map(Self.ids(in:)) ?? []
            let newest = Self.newest(in: ids)
            await MainActor.run {
                self.scanned = (program.path, modified)
                if !newest.isEmpty { self.list = ["default"] + newest + ["opusplan"] }
            }
        }
    }

    /// The file that holds Claude Code's code: the native program behind the `claude` on the
    /// PATH, through its symlink; for an npm install, the `cli.js` its launcher runs.
    nonisolated static func program() -> URL? {
        for dir in ShellPath.current.split(separator: ":") {
            let path = String(dir) + "/claude"
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            let size = (try? FileManager.default.attributesOfItem(atPath: resolved.path))?[.size] as? Int ?? 0
            if size > 1 << 20 { return resolved }
            // A small launcher script: the code is next to it, or in npm's node_modules.
            for candidate in [resolved.deletingLastPathComponent().appendingPathComponent("cli.js"),
                              resolved.deletingLastPathComponent().appendingPathComponent("../lib/node_modules/@anthropic-ai/claude-code/cli.js")]
            where FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
            return resolved
        }
        return nil
    }

    /// Every `claude-<family>-<version>` the bytes mention, without dated snapshots such as
    /// `claude-opus-4-5-20251101`.
    nonisolated static func ids(in data: Data) -> Set<String> {
        var found: Set<String> = []
        let needle = Array("claude-".utf8)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count >= needle.count else { return }
            var cursor = 0
            while cursor + needle.count <= raw.count {
                guard let hit = memmem(base + cursor, raw.count - cursor, needle, needle.count) else { break }
                let start = UnsafeRawPointer(hit) - base
                var end = start + needle.count
                while end < raw.count, Self.isIDByte(raw[end]) { end += 1 }
                if let id = String(bytes: raw[start..<end], encoding: .utf8), isModelID(id) { found.insert(id) }
                cursor = start + needle.count
            }
        }
        return found
    }

    /// A lowercase letter, a digit or a hyphen: what a model id is made of.
    private nonisolated static func isIDByte(_ byte: UInt8) -> Bool {
        byte == 0x2d || (0x61...0x7a).contains(byte) || (0x30...0x39).contains(byte)
    }

    /// `claude-<family>-<major>` or `claude-<family>-<major>-<minor>`, families known or not.
    nonisolated static func isModelID(_ id: String) -> Bool {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count == 3 || parts.count == 4, parts[0] == "claude", parts[1].allSatisfy(\.isLetter) else { return false }
        return parts[2...].allSatisfy { !$0.isEmpty && $0.count < 4 && $0.allSatisfy(\.isNumber) }
    }

    /// The newest id of each offered family, in the families' order; a family with no id is skipped.
    nonisolated static func newest(in ids: Set<String>) -> [String] {
        families.compactMap { family in
            ids.filter { $0.hasPrefix("claude-\(family)-") }.max { version(of: $0).lexicographicallyPrecedes(version(of: $1)) }
        }
    }

    private nonisolated static func version(of id: String) -> [Int] {
        let numbers = id.split(separator: "-").dropFirst(2).compactMap { Int($0) }
        return numbers + Array(repeating: 0, count: max(0, 2 - numbers.count))
    }
}
