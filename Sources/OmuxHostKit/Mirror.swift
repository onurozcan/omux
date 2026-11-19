import Foundation
import OmuxCore

/// Keeps a copy of one session's Claude Code files on another machine: its transcript and
/// its subagents' folder. The files only grow, so the copy is kept by sending what was added.
///
/// The app reads conversations from files. With these mirrored beside it, the transcript view
/// and the subagent list read a remote session exactly as they read a local one.
public enum Mirror {
    /// What the receiving side already holds, by path under the project folder, so a
    /// reconnect sends only what is new.
    public struct Have: Codable, Equatable, Sendable {
        public var sizes: [String: UInt64]
        public init(sizes: [String: UInt64] = [:]) { self.sizes = sizes }
    }

    public enum Update: Codable, Equatable, Sendable {
        /// Bytes of the file at `path`, starting at byte `offset`.
        case data(path: String, offset: UInt64, data: Data)
        /// The file is shorter than what was sent: it starts over.
        case reset(path: String)
        /// Everything there was has been sent; what follows is new.
        case synced
    }

    /// The session's files under `root`: its transcript, and whatever is in its own folder.
    static func files(root: String, session: String) -> [String] {
        var found: [String] = []
        if FileManager.default.fileExists(atPath: "\(root)/\(session).jsonl") { found.append("\(session).jsonl") }
        if let walker = FileManager.default.enumerator(atPath: "\(root)/\(session)") {
            for case let name as String in walker {
                var isDirectory: ObjCBool = false
                let path = "\(session)/\(name)"
                if FileManager.default.fileExists(atPath: "\(root)/\(path)", isDirectory: &isDirectory), !isDirectory.boolValue { found.append(path) }
            }
        }
        return found.sorted()
    }

    /// One look at the files: sends what was added since `sent`, which it brings up to date.
    static func pass(root: String, session: String, sent: inout [String: UInt64], send: (Update) -> Bool) -> Bool {
        for path in files(root: root, session: session) {
            let full = "\(root)/\(path)"
            guard let size = (try? FileManager.default.attributesOfItem(atPath: full)[.size] as? NSNumber)?.uint64Value else { continue }
            var from = sent[path] ?? 0
            if size < from {
                guard send(.reset(path: path)) else { return false }
                from = 0
            }
            guard size > from, let handle = FileHandle(forReadingAtPath: full) else { sent[path] = from; continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: from)
            while from < size {
                let piece = handle.readData(ofLength: Int(min(size - from, 256 << 10)))
                if piece.isEmpty { break }
                guard send(.data(path: path, offset: from, data: piece)) else { return false }
                from += UInt64(piece.count)
            }
            sent[path] = from
        }
        return true
    }

    /// Sends the session's files and then every addition, until `send` says the other side is
    /// gone or `stopped` says to stop. Looks every `interval`; a transcript is appended to a
    /// few times a second at most, and a look at a handful of files costs next to nothing.
    public static func serve(root: String, session: String, have: Have = Have(), interval: TimeInterval = 0.3,
                             stopped: () -> Bool = { false }, send: (Update) -> Bool) {
        var sent = have.sizes
        guard pass(root: root, session: session, sent: &sent, send: send), send(.synced) else { return }
        while !stopped() {
            Thread.sleep(forTimeInterval: interval)
            guard pass(root: root, session: session, sent: &sent, send: send) else { return }
        }
    }

    /// What `folder` holds of a session, for telling the sending side.
    public static func have(in folder: URL, session: String) -> Have {
        var sizes: [String: UInt64] = [:]
        for path in files(root: folder.path, session: session) {
            sizes[path] = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(path).path)[.size] as? NSNumber)?.uint64Value
        }
        return Have(sizes: sizes)
    }

    public enum Failure: Error { case outside(String) }

    /// Applies one update to the copy under `folder`.
    public static func apply(_ update: Update, to folder: URL) throws {
        func url(_ path: String) throws -> URL {
            // Only ever inside the folder: a path that climbs out of it is refused.
            // Judged as the file system reads it, byte by byte: split as text, a "/" with a
            // combining mark after it is no separator, and the ".." beside it goes unseen.
            let parts = path.utf8.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
            guard !path.isEmpty, !path.utf8.contains(0), !parts.contains(where: { $0.isEmpty || $0.elementsEqual("..".utf8) || $0.elementsEqual(".".utf8) }) else {
                throw Failure.outside(path)
            }
            // And as it resolves: the place it names must be inside the folder.
            let file = folder.appendingPathComponent(path).standardizedFileURL
            guard file.path.hasPrefix(folder.standardizedFileURL.path + "/") else { throw Failure.outside(path) }
            return file
        }
        switch update {
        case .synced:
            break
        case .reset(let path):
            try Data().write(to: url(path))
        case .data(let path, let offset, let data):
            let file = try url(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            // At its offset, whatever the copy held there: sent twice, a piece lands once.
            try handle.truncate(atOffset: min(offset, try handle.seekToEnd()))
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
        }
    }
}
