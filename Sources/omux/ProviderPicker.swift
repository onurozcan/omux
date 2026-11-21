import AppKit
import SwiftUI

/// The Claude and OpenAI marks, from the app bundle, drawn as template images in the current colour.
struct ProviderLogo: View {
    let provider: SessionProvider
    var size: CGFloat = 11

    var body: some View {
        if let image = Self.image(for: provider) {
            Image(nsImage: image).renderingMode(.template).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Image(systemName: provider == .codex ? "circle.hexagongrid" : "asterisk").font(.system(size: size - 1, weight: .semibold))
        }
    }

    nonisolated(unsafe) private static var cache: [SessionProvider: NSImage] = [:]

    static func image(for provider: SessionProvider) -> NSImage? {
        if let hit = cache[provider] { return hit }
        let name = provider == .codex ? "openai" : provider == .claude ? "claude" : nil
        guard let name, let url = Bundle.main.resourceURL?.appendingPathComponent("icons/\(name).svg"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 14, height: 14)
        cache[provider] = image
        return image
    }
}

/// The models Codex offers, asked of `codex app-server` and kept for a while.
@MainActor
enum CodexModels {
    struct Model: Equatable {
        var id: String
        var name: String
        var isDefault: Bool
        var efforts: [String]
    }

    private(set) static var cached: [Model] = []
    private static var fetchedAt: Date?
    private static var fetching = false

    /// The cached list, refreshing in the background when it's stale; empty until the first answer.
    static func list() -> [Model] {
        if fetchedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true, !fetching {
            fetching = true
            Task.detached(priority: .utility) {
                let found = await fetch()
                await MainActor.run { if !found.isEmpty { cached = found }; fetchedAt = Date(); fetching = false }
            }
        }
        return cached
    }

    /// One short app-server conversation over stdio: initialize, then model/list.
    nonisolated private static func fetch() async -> [Model] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", "exec codex app-server"]
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = ShellPath.current
                process.environment = environment
                let input = Pipe(), output = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { continuation.resume(returning: []); return }
                let lines = [
                    #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"omux","title":"omux","version":"0"}}}"#,
                    #"{"method":"initialized"}"#,
                    #"{"id":2,"method":"model/list","params":{}}"#,
                ]
                // A server that already quit fails the write instead of raising SIGPIPE in the app.
                _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                try? input.fileHandleForWriting.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
                // Read as it comes, so the deadline holds even when the server never says a word.
                let reply = Reply()
                output.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { reply.finish([]); return }
                    if let found = reply.lines(adding: chunk).lazy.compactMap(modelList).first { reply.finish(found) }
                }
                let models = reply.models(within: 15)
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                continuation.resume(returning: models)
            }
        }
    }

    /// The models in the answer to model/list; nil for any other line.
    nonisolated private static func modelList(_ line: Data) -> [Model]? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] as? Int == 2 else { return nil }
        let data = (object["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return data.compactMap { entry in
            guard entry["hidden"] as? Bool != true, let id = (entry["model"] ?? entry["id"]) as? String else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            return Model(id: id, name: entry["displayName"] as? String ?? id, isDefault: entry["isDefault"] as? Bool ?? false, efforts: efforts)
        }
    }

    /// What the app-server printed, gathered off its pipe, and the list once it is in.
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var list: [Model]?
        private let ended = DispatchSemaphore(value: 0)

        /// The whole lines in so far, with `chunk` added.
        func lines(adding chunk: Data) -> [Data] {
            lock.withLock {
                buffer.append(chunk)
                var lines: [Data] = []
                while let newline = buffer.firstIndex(of: 0x0A) {
                    lines.append(Data(buffer[..<newline]))
                    buffer.removeSubrange(...newline)
                }
                return lines
            }
        }

        /// The first call wins: the list, or nothing when the output ended without one.
        func finish(_ models: [Model]) {
            lock.withLock {
                guard list == nil else { return }
                list = models
                ended.signal()
            }
        }

        /// The list, or none when it isn't in within `seconds`.
        func models(within seconds: TimeInterval) -> [Model] {
            _ = ended.wait(timeout: .now() + seconds)
            return lock.withLock { list ?? [] }
        }
    }
}
