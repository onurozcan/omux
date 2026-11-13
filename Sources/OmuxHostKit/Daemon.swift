import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Starting the host so that it outlives whoever started it: an SSH connection that ends, a
/// terminal that closes.
public enum Daemon {
    /// Runs `executable` in a session of its own, reading nothing and writing to `log`.
    /// Returns its process id, or nil when it couldn't be started.
    @discardableResult
    public static func spawnDetached(_ executable: String, arguments: [String], log: String) -> pid_t? {
        try? FileManager.default.createDirectory(atPath: (log as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        #if canImport(Darwin)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        let newSession = Int16(POSIX_SPAWN_SETSID)
        #else
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        let newSession: Int16 = 0x80  // POSIX_SPAWN_SETSID
        #endif
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawnattr_setflags(&attributes, newSession)
        var cArguments: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArguments.forEach { free($0) }; cEnvironment.forEach { free($0) } }
        var pid: pid_t = 0
        return posix_spawn(&pid, executable, &actions, &attributes, &cArguments, &cEnvironment) == 0 ? pid : nil
    }

    /// This program's own path, for starting itself again as the host.
    public static var ownPath: String {
        #if os(Linux)
        if let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return path }
        #endif
        return Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    /// A client connected to the host at `socket`, starting the host first if none answers.
    public static func connect(to socket: String, startingHost: Bool = true) throws -> HostClient {
        if let client = try? HostClient(socket: socket) { return client }
        guard startingHost else { throw UnixSocket.Failure.system("No host is running at \(socket)", ECONNREFUSED) }
        let log = (socket as NSString).deletingLastPathComponent + "/host.log"
        guard spawnDetached(ownPath, arguments: ["--socket", socket, "serve"], log: log) != nil else {
            throw UnixSocket.Failure.system("Couldn't start the host", errno)
        }
        for _ in 0..<60 {
            Thread.sleep(forTimeInterval: 0.05)
            if let client = try? HostClient(socket: socket) { return client }
        }
        throw UnixSocket.Failure.system("The host didn't come up; see \(log)", ETIMEDOUT)
    }
}
