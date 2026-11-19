import CryptoKit
import Foundation

enum CodexError: LocalizedError {
    case unavailable, disconnected, timeout, server(String)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Couldn't connect to Codex. Install Codex CLI 0.165.0 or later and check that `codex` runs in your shell."
        case .disconnected: return "The Codex connection closed. Restart this session to reconnect to its saved conversation."
        case .timeout: return "Codex didn't respond in time. Try restarting this session."
        case .server(let message): return message
        }
    }
}

enum CodexRequestID: Hashable {
    case number(Int), string(String)

    init?(_ value: Any?) {
        if let value = value as? Int { self = .number(value) }
        else if let value = value as? String { self = .string(value) }
        else { return nil }
    }

    var value: Any {
        switch self { case .number(let n): return n; case .string(let s): return s }
    }
}

/// Owns only the app-server launched by Omux. A random bearer token protects the
/// loopback listener; neither the token nor Codex credentials go in command arguments.
@MainActor
final class CodexConnection {
    let token = UUID().uuidString + UUID().uuidString
    private(set) var endpoint: String?
    private(set) var isReady = false
    var onMessage: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?

    private var process: Process?
    private var socket: URLSessionWebSocketTask?
    private var connecting: Task<Void, Error>?
    private var reader: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var retiring: [Process] = []
    private let environment: [String: String]?
    /// The machine Codex runs on, when it isn't this Mac, and a name for what is kept there.
    let remote: (host: String, name: String)?
    /// Where the TUI, running where Codex does, reaches the app-server: the same address as
    /// `endpoint` on this Mac, the far end of the tunnel on another machine.
    private(set) var tuiEndpoint: String?
    /// The tunnel to cancel when the connection closes: it rides the shared SSH connection,
    /// which would otherwise keep it.
    private var forward: String?
    /// Held open for as long as the app-server there should live: its closing is what stops it.
    private var lifeline: Pipe?

    init(environment: [String: String]? = nil, remote: (host: String, name: String)? = nil) {
        self.environment = environment
        self.remote = remote
    }

    /// What starts the app-server on another machine: in the user's login shell there, for
    /// its PATH, and stopped when this command's standard input closes, which it does when the
    /// connection to this Mac goes for any reason. An app-server left behind would hold its
    /// thread's writer lock, and the next omux couldn't resume the conversation.
    nonisolated static func remoteServerScript(port: UInt16, digest: String) -> String {
        """
        "${SHELL:-/bin/sh}" -lc 'exec codex app-server --listen ws://127.0.0.1:\(port) --ws-auth capability-token --ws-token-sha256 \(digest) -c analytics.enabled=false' </dev/null >/dev/null 2>&1 &
        child=$!
        trap 'kill $child 2>/dev/null; exit' TERM INT HUP
        cat >/dev/null
        kill $child 2>/dev/null
        """
    }

    /// Where the session's token is kept on the machine, readable by its owner only, so the
    /// TUI's command can take it from there instead of having it typed into a terminal.
    nonisolated static func remoteTokenPath(name: String) -> String { "$HOME/.omux/codex/\(name).token" }

    /// The app-server on another machine, with a tunnel to it. Returns the port on this Mac.
    private func startRemote(host: String, name: String, digest: String) async throws -> (process: Process, port: UInt16) {
        let local = try Self.availablePort()
        let far = UInt16.random(in: 49152...64999)
        // The token goes over as a file's contents, never as an argument.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("omux-codex-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: file) }
        let path = Self.remoteTokenPath(name: name)
        let stored = await Task.detached {
            RemotePath.run("umask 077; mkdir -p \"$HOME/.omux/codex\" && cat > \"\(path)\"", on: host, input: file)
        }.value
        guard stored.status == 0 else { throw CodexError.server(RemoteMachines.explain(stored.error, host: host)) }

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let spec = "\(local):127.0.0.1:\(far)"
        child.arguments = RemotePath.options + ["-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-L", spec, host,
                                                "sh -c " + Git.quote(Self.remoteServerScript(port: far, digest: digest))]
        let lifeline = Pipe()
        child.standardInput = lifeline
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { throw CodexError.unavailable }
        self.lifeline = lifeline
        self.forward = spec
        self.endpoint = "ws://127.0.0.1:\(local)"
        self.tuiEndpoint = "ws://127.0.0.1:\(far)"
        return (child, local)
    }

    func connect() async throws {
        if let connecting { return try await connecting.value }
        if socket != nil { return }
        let task = Task { try await open() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func open() async throws {
        try await waitForShutdown()
        let digest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        if let remote {
            let started = try await startRemote(host: remote.host, name: remote.name, digest: digest)
            started.process.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.process === child, self.isReady else { return }
                    self.close(notify: true)
                }
            }
            process = started.process
            // Through the tunnel, the machine and Codex's own start: a little longer than here.
            try await openSocket(port: started.port, child: started.process, endpoint: "ws://127.0.0.1:\(started.port)", attempts: 200)
            return
        }
        let port = try Self.availablePort()
        let endpoint = "ws://127.0.0.1:\(port)"
        self.endpoint = endpoint
        self.tuiEndpoint = endpoint
        let child = Process()
        child.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        // Under a shell that watches omux: an app-server left behind by a crash or a kill would
        // hold its thread's writer lock, and the next omux couldn't resume the conversation.
        child.arguments = ["-lc", Self.watchedCommand("codex app-server --listen \(endpoint) --ws-auth capability-token --ws-token-sha256 \(digest) -c 'analytics.enabled=false'", parent: getpid())]
        var env = environment ?? ProcessInfo.processInfo.environment
        // The user's shell PATH: from the Dock, omux's own has no nvm or ~/.local/bin on it.
        env["PATH"] = await ShellPath.load()
        child.environment = env
        child.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                // While connecting, open() sees the exit and reports .unavailable; closing here
                // would cancel it into a bare CancellationError and report a disconnect.
                guard let self, self.process === child, self.isReady else { return }
                self.close(notify: true)
            }
        }
        do { try child.run() } catch { throw CodexError.unavailable }
        process = child
        try await openSocket(port: port, child: child, endpoint: endpoint, attempts: 80)
    }

    private func openSocket(port: UInt16, child: Process, endpoint: String, attempts: Int) async throws {
        // Probe readiness before opening the authenticated WebSocket. Never send a
        // model prompt, create a thread, or alter authentication during connection.
        do {
            var ready = false
            for _ in 0..<attempts {
                try Task.checkCancellation()
                guard child.isRunning else { throw CodexError.unavailable }
                var probe = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/readyz")!)
                probe.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                probe.timeoutInterval = 0.3
                if let (_, response) = try? await URLSession.shared.data(for: probe),
                   (response as? HTTPURLResponse)?.statusCode == 200 { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready else { throw CodexError.unavailable }
            var request = URLRequest(url: URL(string: endpoint)!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let socket = URLSession.shared.webSocketTask(with: request)
            self.socket = socket
            socket.resume()
            reader = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard let self, self.socket === socket else { return }
                        let data: Data
                        switch message {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        self.receive(data)
                    }
                } catch {
                    guard let self, self.socket === socket else { return }
                    self.close(notify: true)
                }
            }
            _ = try await self.request("initialize", params: ["clientInfo": ["name": "omux", "title": "omux", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"]])
            try await send(["method": "initialized"])
            isReady = true
        } catch {
            close(notify: false)
            throw error
        }
    }

    func request(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard socket != nil else { throw CodexError.disconnected }
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            deadlines[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finish(id, result: .failure(CodexError.timeout))
            }
            Task {
                do { try await send(["id": id, "method": method, "params": params]) }
                catch { finish(id, result: .failure(error)) }
            }
        }
    }

    func respond(to id: CodexRequestID, result: [String: Any]) async throws {
        try await send(["id": id.value, "result": result])
    }

    private func send(_ object: [String: Any]) async throws {
        guard let socket else { throw CodexError.disconnected }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if object["method"] == nil, let id = object["id"] as? Int {
            if let error = object["error"] as? [String: Any] {
                finish(id, result: .failure(CodexError.server(error["message"] as? String ?? "Codex request failed")))
            } else {
                finish(id, result: .success(object["result"] as? [String: Any] ?? [:]))
            }
        } else { onMessage?(object) }
    }

    private func finish(_ id: Int, result: Result<[String: Any], Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    /// `command` in the background, killed when `parent` is gone or the shell is told to stop.
    nonisolated static func watchedCommand(_ command: String, parent: pid_t) -> String {
        "\(command) & child=$!; trap 'kill $child 2>/dev/null; exit' TERM INT HUP; while kill -0 \(parent) 2>/dev/null; do sleep 1; done; kill $child 2>/dev/null"
    }

    func close(notify: Bool = false) {
        connecting?.cancel()
        reader?.cancel(); reader = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        let child = process
        process = nil
        if let child, child.isRunning { retiring.append(child); child.terminate() }
        // The far app-server stops when its standard input closes; the tunnel is taken down too.
        try? lifeline?.fileHandleForWriting.close()
        lifeline = nil
        if let forward, let host = remote?.host {
            let cancel = Process()
            cancel.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            cancel.arguments = RemotePath.options + ["-O", "cancel", "-L", forward, host]
            cancel.standardOutput = FileHandle.nullDevice; cancel.standardError = FileHandle.nullDevice
            try? cancel.run()
        }
        forward = nil
        tuiEndpoint = nil
        endpoint = nil
        isReady = false
        for id in Array(pending.keys) { finish(id, result: .failure(CodexError.disconnected)) }
        if notify { onDisconnect?() }
    }

    func waitForShutdown() async throws {
        for _ in 0..<100 {
            retiring.removeAll { !$0.isRunning }
            if retiring.isEmpty { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CodexError.server("The previous Codex server is still stopping. Try restarting the session again.")
    }

    private static func availablePort() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexError.unavailable }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { throw CodexError.unavailable }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard read == 0 else { throw CodexError.unavailable }
        return UInt16(bigEndian: address.sin_port)
    }
}
