import CryptoKit
import Foundation
import OmuxCLIProtocol

/// Serves the `omux` command line tool. The socket lives in a folder only this user can
/// open, each connection must come from this user, and each request must carry the token
/// of the session it says it comes from, which only that session has in its environment.
final class CommandServer: @unchecked Sendable {
    static let shared = CommandServer()

    /// Fresh on every launch; never leaves the app.
    private let secret = SymmetricKey(size: .bits256)

    /// The session's own token, given to it as OMUX_TOKEN. One token for every session let a
    /// session pass for another by changing OMUX_TAB_ID to an id `omux list` shows, and then
    /// type into that session and steer the sessions it started. A token tied to the id
    /// proves the id: another session's token can't be made from one's own.
    func token(for session: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(session.utf8), using: secret).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether `request` carries the token of the session it names, compared in constant time.
    func authenticates(_ request: CLIRequest) -> Bool {
        guard let mac = Self.bytes(hex: request.token) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(mac, authenticating: Data(request.from.utf8), using: secret)
    }

    private static func bytes(hex: String) -> Data? {
        let digits = Array(hex.utf8)
        guard digits.count == 64 else { return nil }
        var data = Data(capacity: 32)
        for index in stride(from: 0, to: 64, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            data.append(byte)
        }
        return data
    }

    private(set) var socketPath: String?
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "omux.cli", qos: .userInitiated)
    /// Answers a request whose token checked out. The app's Store, or a stand-in in tests.
    var handler: @MainActor (CLIRequest) -> CLIResponse = { Store.shared.handleCLI($0) }

    init() {}

    /// Where the tool is in the app bundle; sessions get it on their PATH.
    static var binDirectory: String? {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("bin").path,
              FileManager.default.isExecutableFile(atPath: dir + "/omux") else { return nil }
        return dir
    }

    func start() {
        guard socketPath == nil else { return }
        removeStaleFolders()
        let dir = NSTemporaryDirectory() + "omux-\(getpid())"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = dir + "/cli.sock"
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        // Sessions are forked from this process; they must not inherit the socket.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { close(fd); unlink(path); return }
        listenFD = fd
        socketPath = path
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        self.source = source
    }

    /// Folders of earlier instances that didn't get to clean up (a crash, a kill).
    private func removeStaleFolders() {
        let tmp = NSTemporaryDirectory()
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix("omux-") {
            guard let pid = Int32(name.dropFirst("omux-".count)), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(atPath: tmp + name)
        }
    }

    func stop() {
        source?.cancel()
        source = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        if let path = socketPath {
            unlink(path)
            rmdir((path as NSString).deletingLastPathComponent)
        }
        socketPath = nil
    }

    private func accept() {
        let client = Darwin.accept(listenFD, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
        // A session started while this request is answered (omux new) would otherwise inherit
        // the connection, keep it open, and leave the tool waiting for the end of the reply.
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        var uid = uid_t(0), gid = gid_t(0)
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { return }
        guard let line = readLine(client) else { return }
        let response: CLIResponse
        if let request = try? JSONDecoder().decode(CLIRequest.self, from: line) {
            if !authenticates(request) {
                // Decided here, before anything in the app is touched.
                response = .failure("bad token; run omux inside a session omux started")
            } else {
                response = DispatchQueue.main.sync { MainActor.assumeIsolated { handler(request) } }
            }
        } else {
            response = .failure("malformed request")
        }
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(UInt8(ascii: "\n"))
        // A tool that hung up before the reply would make a plain write raise SIGPIPE, which
        // kills the app and every session in it; SIGPIPE isn't ignored app-wide because shells
        // inherit that. Not SO_NOSIGPIPE either: a socket whose peer left before accept()
        // refuses the option with EINVAL, and that is the case it would be there for.
        // SIGPIPE is also held back on this thread while the reply is written, so the write is
        // safe whatever a system's kernel makes of the flag: a signal raised anyway stays pending
        // here and is taken off before the thread's signals are let through again.
        var pipe = sigset_t(), before = sigset_t()
        sigemptyset(&pipe)
        sigaddset(&pipe, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &pipe, &before)
        defer {
            var pending = sigset_t()
            sigpending(&pending)
            if sigismember(&pending, SIGPIPE) == 1 { var taken: Int32 = 0; sigwait(&pipe, &taken) }
            pthread_sigmask(SIG_SETMASK, &before, nil)
        }
        var sent = 0, flags = MSG_NOSIGNAL
        while sent < data.count {
            let n = data.withUnsafeBytes { raw in Darwin.send(client, raw.baseAddress! + sent, data.count - sent, flags) }
            // A kernel that doesn't know the flag refuses it: the write goes without, behind the mask.
            if n < 0, errno == EINVAL, flags != 0 { flags = 0; continue }
            guard n > 0 else { return }
            sent += n
        }
    }

    /// One request line, within 2 seconds and 1 MB.
    private func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let deadline = Date().addingTimeInterval(2)
        while !data.contains(UInt8(ascii: "\n")) {
            let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            guard remaining > 0, poll(&poller, 1, remaining) > 0 else { return nil }
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            data.append(buffer, count: n)
            guard data.count <= 1 << 20 else { return nil }
        }
        return data.prefix(while: { $0 != UInt8(ascii: "\n") })
    }
}
