import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A program running on a pseudo-terminal of its own, with no window: what it prints comes
/// out as bytes, what is typed goes in as bytes. This is how the session host runs a shell or
/// an agent; a terminal view somewhere else, fed those bytes, shows it.
///
/// The program leads its own session with the terminal as its controlling terminal, as it
/// would under a terminal emulator, so job control, `/dev/tty` and window-size signals work.
public final class PtyProcess: @unchecked Sendable {
    public struct Size: Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public init(columns: Int, rows: Int) { self.columns = columns; self.rows = rows }
    }

    public enum Failure: Error, Equatable {
        case noTerminal(Int32)
        case notStarted(Int32)
    }

    public let pid: pid_t
    private let master: Int32
    private let queue = DispatchQueue(label: "omux.pty", qos: .userInitiated)
    private let source: DispatchSourceRead

    /// Starts `executable` in `directory`. `onOutput` and `onExit` are called on a private
    /// queue, `onExit` once with the exit code, or 128 plus the signal that ended the program.
    public init(executable: String, arguments: [String] = [], environment: [String: String], directory: String? = nil,
                size: Size = Size(columns: 80, rows: 24),
                onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        // The folder is entered by a shell on the way, the same on both systems.
        var argv = [executable] + arguments
        var path = executable
        if let directory {
            path = "/bin/sh"
            argv = ["sh", "-c", #"cd "$1" && shift && exec "$@""#, "sh", directory, executable] + arguments
        }
        // Asked of the program itself, not of the shell that enters the folder for it.
        guard access(executable, X_OK) == 0, access(path, X_OK) == 0 else { throw Failure.notStarted(errno) }
        var cArguments: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvironment: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArguments.forEach { free($0) }; cEnvironment.forEach { free($0) } }
        var opened: Int32 = -1
        var pid: pid_t = 0
        // A program inherits which signals its starter blocks and ignores, and we may well be
        // on a worker thread that blocks nearly all of them: a program started from there
        // couldn't be hung up on or interrupted. It starts with none blocked and none ignored.
        var noSignals = sigset_t()
        var allSignals = sigset_t()
        sigemptyset(&noSignals)
        sigfillset(&allSignals)

        #if canImport(Darwin)
        // macOS gives a program a controlling terminal only when the program asks for it
        // itself, between fork and exec; forkpty does that, and sets the size. Nothing but
        // exec runs in the child: everything it needs was made ready above.
        var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
        pid = forkpty(&opened, nil, nil, &window)
        if pid == 0 {
            sigprocmask(SIG_SETMASK, &noSignals, nil)
            for number in 1..<32 { signal(Int32(number), SIG_DFL) }
            execve(path, &cArguments, &cEnvironment)
            _exit(127)
        }
        guard pid > 0 else { throw Failure.noTerminal(errno) }
        let slave = ptsname(opened).map { String(cString: $0) }
        #else
        // glibc keeps posix_openpt and its companions from Swift, so the terminal is made the
        // way they make it: open the multiplexer, unlock the new terminal, ask for its number.
        opened = open("/dev/ptmx", O_RDWR | O_NOCTTY)
        guard opened >= 0 else { throw Failure.noTerminal(errno) }
        var unlocked: Int32 = 0
        var number: UInt32 = 0
        guard ioctl(opened, 0x4004_5431, &unlocked) == 0,  // TIOCSPTLCK
              ioctl(opened, 0x8004_5430, &number) == 0 else {  // TIOCGPTN
            let code = errno; close(opened); throw Failure.noTerminal(code)
        }
        let name = "/dev/pts/\(number)"
        let slave: String? = name
        Self.setSize(size, on: opened)
        // A session of its own, and the terminal opened as descriptor 0 while it has no
        // controlling terminal yet: on Linux that makes this one its controlling terminal.
        var actions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_addopen(&actions, 0, name, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        // POSIX_SPAWN_SETSID (0x80), which glibc only shows to C with _GNU_SOURCE, with
        // POSIX_SPAWN_SETSIGMASK and POSIX_SPAWN_SETSIGDEF.
        posix_spawnattr_setflags(&attributes, Int16(0x80 | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        // The child must not inherit our end, or the terminal never reports that it closed.
        _ = fcntl(opened, F_SETFD, FD_CLOEXEC)
        let result = posix_spawn(&pid, path, &actions, &attributes, &cArguments, &cEnvironment)
        guard result == 0 else { close(opened); throw Failure.notStarted(result) }
        #endif
        let master = opened
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Our own hold on the program's side. macOS discards output nobody has read yet the
        // moment the last holder of that side closes it, so a program that prints and exits
        // could say nothing; with this open, its last words wait until they are read.
        let hold = slave.map { open($0, O_RDWR | O_NOCTTY) } ?? -1
        if hold >= 0 { _ = fcntl(hold, F_SETFD, FD_CLOEXEC) }

        self.pid = pid
        self.master = master
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        self.source = source
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        // Reads whatever is there. False once the terminal has closed for good.
        let drain: @Sendable () -> Bool = {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(master, &buffer, buffer.count)
                if count > 0 { onOutput(Data(buffer[0..<count])); continue }
                if count < 0, errno == EINTR { continue }
                // Linux reports a closed terminal as an error, macOS as an end of file.
                return count < 0 && errno == EAGAIN
            }
        }
        source.setEventHandler { if !drain() { source.cancel() } }
        source.setCancelHandler { close(master); if hold >= 0 { close(hold) } }
        source.resume()
        // Waiting blocks, so it has a thread to itself for the life of the program.
        let queue = queue
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            let signal = status & 0x7f
            let code = signal == 0 ? (status >> 8) & 0xff : 128 + signal
            // On the reading queue, after what the program last printed: the exit comes last.
            queue.async {
                _ = drain()
                source.cancel()
                onExit(code)
            }
        }
    }

    /// Letting go of the object stops listening and closes the terminal, which hangs up on
    /// the program: keep it for as long as the program should run.
    deinit { source.cancel() }

    /// Types `data` into the program.
    public func write(_ data: Data) {
        queue.async { [master] in
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let sent = Foundation.write(master, bytes.baseAddress! + offset, bytes.count - offset)
                    if sent > 0 { offset += sent } else if errno != EINTR && errno != EAGAIN { return }
                }
            }
        }
    }

    public func write(_ text: String) { write(Data(text.utf8)) }

    /// Tells the program its terminal is now this big; it gets a window-size signal.
    public func resize(_ size: Size) {
        queue.async { [master] in Self.setSize(size, on: master) }
    }

    /// Hangs up, as closing a terminal window does: the program's whole session is told.
    public func terminate() {
        kill(-pid, SIGHUP)
    }

    private static func setSize(_ size: Size, on descriptor: Int32) {
        var window = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.columns), ws_xpixel: 0, ws_ypixel: 0)
        #if canImport(Darwin)
        let request: UInt = 0x8008_7467  // TIOCSWINSZ, a macro Swift can't import here
        #else
        let request: UInt = 0x5414       // TIOCSWINSZ
        #endif
        _ = ioctl(descriptor, request, &window)
    }
}
