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
                input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
                var models: [Model] = []
                var buffer = Data()
                let deadline = Date().addingTimeInterval(15)
                let handle = output.fileHandleForReading
                search: while Date() < deadline {
                    let chunk = handle.availableData
                    if chunk.isEmpty { if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.05); continue }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let line = buffer[..<newline]
                        buffer.removeSubrange(...newline)
                        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], object["id"] as? Int == 2 else { continue }
                        let data = (object["result"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
                        models = data.compactMap { entry in
                            guard entry["hidden"] as? Bool != true, let id = (entry["model"] ?? entry["id"]) as? String else { return nil }
                            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
                            return Model(id: id, name: entry["displayName"] as? String ?? id, isDefault: entry["isDefault"] as? Bool ?? false, efforts: efforts)
                        }
                        break search
                    }
                }
                if process.isRunning { process.terminate() }
                continuation.resume(returning: models)
            }
        }
    }
}
