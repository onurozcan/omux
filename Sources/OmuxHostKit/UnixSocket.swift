import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private func closeDescriptor(_ descriptor: Int32) { _ = close(descriptor) }

/// One end of a stream of framed messages: a local socket, or a pair of pipes such as the
/// standard streams an SSH connection hands over.
public final class Connection: @unchecked Sendable {
    private let input: Int32
    private let output: Int32
    private let reading = DispatchQueue(label: "omux.connection.read")
    private let writing = DispatchQueue(label: "omux.connection.write")
    private var source: DispatchSourceRead?
    private var splitter = Wire.Splitter()
    private var closed = false

    /// `input` and `output` may be one descriptor, a socket, or two, a pair of pipes.
    public init(input: Int32, output: Int32) {
        self.input = input
        self.output = output
    }

    /// Starts reading. `onFrame` gets each message's body, in order; `onClose` is called once,
    /// when the other end goes away or sends something that isn't the protocol.
    public func start(onFrame: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: input, queue: reading)
        self.source = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let count = read(self.input, &buffer, buffer.count)
            if count > 0, let frames = try? self.splitter.feed(Data(buffer[0..<count])) {
                frames.forEach(onFrame)
            } else if count < 0, errno == EINTR || errno == EAGAIN {
                return
            } else {
                source.cancel()
            }
        }
        source.setCancelHandler { [input, output] in
            closeDescriptor(input)
            if output != input { closeDescriptor(output) }
            onClose()
        }
        source.resume()
    }

    public func send<T: Encodable>(_ value: T) {
        guard let frame = try? Wire.encode(value) else { return }
        writing.async { [weak self] in
            guard let self, !self.closed else { return }
            frame.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let sent = write(self.output, bytes.baseAddress! + offset, bytes.count - offset)
                    if sent > 0 { offset += sent } else if errno != EINTR { self.closed = true; return }
                }
            }
        }
    }

    /// Lets what was sent go out, then hangs up.
    public func close() {
        writing.async { [weak self] in
            self?.closed = true
            self?.source?.cancel()
        }
    }
}

public enum UnixSocket {
    public enum Failure: Error, CustomStringConvertible {
        case pathTooLong(String), system(String, Int32)
        public var description: String {
            switch self {
            case .pathTooLong(let path): return "The socket path is too long: \(path)"
            case .system(let what, let code): return "\(what): \(String(cString: strerror(code)))"
            }
        }
    }

    private static func make() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    private static func with<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// Connects to the socket at `path`.
    public static func connect(_ path: String) throws -> Connection {
        let descriptor = try rawConnect(path)
        return Connection(input: descriptor, output: descriptor)
    }

    /// The connected descriptor itself, for passing bytes through untouched.
    public static func rawConnect(_ path: String) throws -> Int32 {
        let descriptor = make()
        guard descriptor >= 0 else { throw Failure.system("socket", errno) }
        let result = try with(path) { Foundation.connect(descriptor, $0, $1) }
        guard result == 0 else { let code = errno; close(descriptor); throw Failure.system("connect", code) }
        return descriptor
    }

    /// Listens at `path`, in a folder only this user can enter. A socket left there by a host
    /// that is gone is replaced; one a running host answers on is an error.
    public final class Listener: @unchecked Sendable {
        public let path: String
        private let descriptor: Int32
        private let source: DispatchSourceRead

        public init(path: String, onConnection: @escaping @Sendable (Connection) -> Void) throws {
            let folder = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let existing = try? UnixSocket.connect(path) {
                existing.close()
                throw Failure.system("A host is already running at \(path)", EADDRINUSE)
            }
            unlink(path)
            let descriptor = UnixSocket.make()
            guard descriptor >= 0 else { throw Failure.system("socket", errno) }
            let bound = try UnixSocket.with(path) { bind(descriptor, $0, $1) }
            guard bound == 0 else { let code = errno; close(descriptor); throw Failure.system("bind", code) }
            chmod(path, 0o600)
            guard listen(descriptor, 16) == 0 else { let code = errno; close(descriptor); throw Failure.system("listen", code) }
            self.path = path
            self.descriptor = descriptor
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: DispatchQueue(label: "omux.listener"))
            self.source = source
            source.setEventHandler {
                let accepted = accept(descriptor, nil, nil)
                if accepted >= 0 { onConnection(Connection(input: accepted, output: accepted)) }
            }
            source.setCancelHandler { close(descriptor); unlink(path) }
            source.resume()
        }

        public func stop() { source.cancel() }
        deinit { source.cancel() }
    }
}

/// A session host answering on a local socket.
public final class HostServer: @unchecked Sendable {
    public let host: SessionHost
    private var listener: UnixSocket.Listener?

    public init(host: SessionHost = SessionHost()) { self.host = host }

    public func listen(at path: String) throws {
        let host = host
        listener = try UnixSocket.Listener(path: path) { connection in HostServer.serve(connection, with: host) }
    }

    /// Answers the requests of one connection until it closes.
    public static func serve(_ connection: Connection, with host: SessionHost) {
        let client = SessionHost.Client { [weak connection] frame in connection?.send(frame) }
        connection.start(onFrame: { body in
            guard let frame = try? Wire.decode(ClientFrame.self, from: body) else {
                // A request from a newer omux: said so under its own number, so the asker
                // hears no at once instead of waiting for an answer that isn't coming.
                struct Numbered: Decodable { var id: Int }
                let id = (try? Wire.decode(Numbered.self, from: body))?.id
                connection.send(HostFrame(reply: id, message: .failed(reason: "This host is older than the omux asking and doesn't know that request")))
                return
            }
            connection.send(HostFrame(reply: frame.id, message: host.handle(frame.message, from: client)))
        }, onClose: { [connection] in
            // The connection is kept until here, so it lives as long as its descriptor does.
            _ = connection
            host.forget(client)
        })
    }

    public func stop() { listener?.stop(); listener = nil }

    /// A host with nothing running for this long stops; the next command starts one again,
    /// from whatever build of the program is installed by then. That is how a machine comes
    /// to run a newer host without a session ever being dropped for it.
    public static let idleLimit: TimeInterval = 15 * 60

    /// Where a user's host listens unless told otherwise.
    public static var defaultSocket: String {
        if let runtime = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"], !runtime.isEmpty { return runtime + "/omux/host.sock" }
        return NSHomeDirectory() + "/.omux/host.sock"
    }
}

/// The client's side of a connection: requests that wait for their answer, and a place for
/// what the host says unasked.
public final class HostClient: @unchecked Sendable {
    private let connection: Connection
    private let lock = NSLock()
    private var next = 1
    private var waiting: [Int: (HostMessage) -> Void] = [:]
    /// Output and exits of attached sessions.
    public var onEvent: (@Sendable (HostMessage) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    public init(_ connection: Connection) {
        self.connection = connection
        connection.start(onFrame: { [weak self] body in
            guard let self, let frame = try? Wire.decode(HostFrame.self, from: body) else { return }
            if let reply = frame.reply {
                self.lock.lock(); let handler = self.waiting.removeValue(forKey: reply); self.lock.unlock()
                handler?(frame.message)
            } else {
                self.onEvent?(frame.message)
            }
        }, onClose: { [weak self] in
            guard let self else { return }
            self.lock.lock(); let handlers = Array(self.waiting.values); self.waiting = [:]; self.lock.unlock()
            handlers.forEach { $0(.failed(reason: "The host closed the connection")) }
            self.onClose?()
        })
    }

    public convenience init(socket path: String) throws { self.init(try UnixSocket.connect(path)) }

    public func send(_ message: ClientMessage, reply: @escaping (HostMessage) -> Void = { _ in }) {
        lock.lock(); let id = next; next += 1; waiting[id] = reply; lock.unlock()
        connection.send(ClientFrame(id: id, message: message))
    }

    /// Sends and waits for the answer. Not from the queue answers arrive on.
    public func request(_ message: ClientMessage, timeout: TimeInterval = 10) -> HostMessage {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        send(message) { box.value = $0; done.signal() }
        return done.wait(timeout: .now() + timeout) == .success ? (box.value ?? .failed(reason: "No answer")) : .failed(reason: "The host didn't answer")
    }

    public func close() { connection.close() }

    private final class Box: @unchecked Sendable { var value: HostMessage? }
}
