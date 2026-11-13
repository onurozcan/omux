import Foundation
import OmuxCore

/// The sessions of one machine: started here, kept running with nobody attached, each with
/// the tail of what it printed so a client that comes later, or comes back, can catch up.
public final class SessionHost: @unchecked Sendable {
    /// Someone the host talks to: one connection.
    public final class Client: @unchecked Sendable {
        public let id = UUID()
        let send: @Sendable (HostFrame) -> Void
        public init(send: @escaping @Sendable (HostFrame) -> Void) { self.send = send }
    }

    private final class Hosted {
        var info: SessionInfo
        var process: PtyProcess?
        /// The newest output, starting at byte `base` of all the session printed.
        var buffer = Data()
        var base: UInt64 = 0
        var watchers: [UUID: Client] = [:]
        init(info: SessionInfo) { self.info = info }
    }

    private let queue = DispatchQueue(label: "omux.host")
    private var sessions: [String: Hosted] = [:]
    private var order: [String] = []
    /// Output kept per session for catching up; older output is dropped from the front.
    private let keep: Int
    /// Output is sent in pieces no larger than this, so one message never nears the frame limit.
    private static let chunk = 256 << 10

    public init(keep: Int = 4 << 20) { self.keep = keep }

    /// Answers one request. Output and exits of sessions the client attaches to follow on
    /// their own, through the client's `send`.
    public func handle(_ message: ClientMessage, from client: Client) -> HostMessage {
        queue.sync {
            switch message {
            case .hello:
                return .welcome(version: HostProtocol.version, host: ProcessInfo.processInfo.hostName, system: Self.system)
            case .list:
                return .sessions(list: order.compactMap { sessions[$0]?.info })
            case .start(let request):
                return start(request)
            case .attach(let id, let from):
                guard let session = sessions[id] else { return .failed(reason: "No session \(id)") }
                // What the client is missing first, then it hears the rest as it comes.
                let end = session.base + UInt64(session.buffer.count)
                let from = min(max(from ?? session.base, session.base), end)
                let missing = session.buffer.suffix(Int(end - from))
                Self.send(Data(missing), at: from, of: id, to: client)
                if let code = session.info.exited { client.send(HostFrame(message: .exited(session: id, code: code))) }
                session.watchers[client.id] = client
                return .started(info: session.info)
            case .detach(let id):
                sessions[id]?.watchers[client.id] = nil
                return .done
            case .input(let id, let data):
                guard let process = sessions[id]?.process else { return .failed(reason: "Session \(id) isn't running") }
                process.write(data)
                return .done
            case .resize(let id, let columns, let rows):
                guard let session = sessions[id] else { return .failed(reason: "No session \(id)") }
                session.info.columns = columns; session.info.rows = rows
                session.process?.resize(.init(columns: columns, rows: rows))
                return .done
            case .close(let id):
                guard let session = sessions[id] else { return .failed(reason: "No session \(id)") }
                if let process = session.process {
                    process.terminate()
                } else {
                    sessions[id] = nil
                    order.removeAll { $0 == id }
                }
                return .done
            }
        }
    }

    /// A connection went away: nothing more is sent to it.
    public func forget(_ client: Client) {
        queue.async { for session in self.sessions.values { session.watchers[client.id] = nil } }
    }

    /// Hangs up on every session, as the host itself stops.
    public func closeAll() {
        queue.sync { for session in sessions.values { session.process?.terminate() } }
    }

    private func start(_ request: StartRequest) -> HostMessage {
        var id: String
        repeat { id = String(format: "%08x", UInt32.random(in: 0...UInt32.max)) } while sessions[id] != nil
        let home = NSHomeDirectory()
        let directory = request.directory.map { ($0 as NSString).expandingTildeInPath } ?? home
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failed(reason: "No folder \(directory)")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["OMUX_HOST_SESSION"] = id
        for (key, value) in request.environment { environment[key] = value }
        // No program named: the user's shell, as a login shell, like a new terminal window.
        var command = request.command
        if command.isEmpty { command = [environment["SHELL"] ?? "/bin/sh", "-l"] }
        let executable = Self.resolve(command[0], path: environment["PATH"] ?? "/usr/bin:/bin")
        let name = request.name ?? (command[0] as NSString).lastPathComponent
        let info = SessionInfo(id: id, name: name, directory: directory, command: command, started: Date(),
                               columns: request.columns, rows: request.rows, outputEnd: 0, exited: nil)
        let session = Hosted(info: info)
        do {
            session.process = try PtyProcess(
                executable: executable, arguments: Array(command.dropFirst()), environment: environment, directory: directory,
                size: .init(columns: request.columns, rows: request.rows),
                onOutput: { [weak self] data in self?.queue.async { self?.printed(data, by: id) } },
                onExit: { [weak self] code in self?.queue.async { self?.ended(id, code: code) } })
        } catch {
            return .failed(reason: "Couldn't start \(command[0]): \(error)")
        }
        sessions[id] = session
        order.append(id)
        return .started(info: info)
    }

    private func printed(_ data: Data, by id: String) {
        guard let session = sessions[id] else { return }
        let offset = session.info.outputEnd
        session.info.outputEnd += UInt64(data.count)
        session.buffer.append(data)
        if session.buffer.count > keep {
            let drop = session.buffer.count - keep
            session.buffer = Data(session.buffer.dropFirst(drop))
            session.base += UInt64(drop)
        }
        for client in session.watchers.values { Self.send(data, at: offset, of: id, to: client) }
    }

    private func ended(_ id: String, code: Int32) {
        guard let session = sessions[id] else { return }
        session.info.exited = code
        session.process = nil
        for client in session.watchers.values { client.send(HostFrame(message: .exited(session: id, code: code))) }
    }

    private static func send(_ data: Data, at offset: UInt64, of id: String, to client: Client) {
        var sent = 0
        while sent < data.count {
            let piece = data.dropFirst(sent).prefix(chunk)
            client.send(HostFrame(message: .output(session: id, offset: offset + UInt64(sent), data: Data(piece))))
            sent += piece.count
        }
    }

    /// The program's full path, looked up along PATH the way a shell would.
    static func resolve(_ program: String, path: String) -> String {
        if program.contains("/") { return (program as NSString).expandingTildeInPath }
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/\(program)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return program
    }

    static var system: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "other"
        #endif
    }
}
