import Foundation
import OmuxCore
import OmuxHostKit
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

// omux-host: the session host as a program, and a command line to it.
//
// Sessions started through it belong to a host process that stays behind when the command,
// the terminal or the SSH connection that started them goes away. The Mac app reaches the
// same host with `omux-host connect` over SSH.

let usage = """
omux-host — sessions that keep running on this machine

omux-host new [--name NAME] [--dir DIR] [--attach] [-- PROGRAM ARGS…]
                              start a session (your login shell when no program); prints its id
omux-host list                the sessions here
omux-host attach SESSION      show a session and type into it; Ctrl-\\ leaves it running
omux-host close SESSION       hang up on a running session, or clear an ended one
omux-host session ID [--dir DIR] [--name NAME] [--run COMMAND]
                              show the session with this id, starting it first if it isn't
                              running: a login shell, with COMMAND typed into it
omux-host mirror --dir DIR --session ID
                              send a Claude Code session's files as they grow (for the app)
omux-host serve               run the host in the foreground (it starts itself when needed)
omux-host connect             speak the host's protocol on standard input and output
omux-host version

--socket PATH before the command uses another host than \(HostServer.defaultSocket).
A session is named by its id, the start of its id, or its name.
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("omux-host: " + message + "\n").utf8))
    exit(code)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var socket = HostServer.defaultSocket
if arguments.first == "--socket" {
    guard arguments.count >= 2 else { fail("--socket needs a path") }
    socket = arguments[1]
    arguments.removeFirst(2)
}
let command = arguments.first ?? "help"
arguments = Array(arguments.dropFirst())
signal(SIGPIPE, SIG_IGN)

func connect() -> HostClient {
    do {
        var client = try Daemon.connect(to: socket)
        guard case .welcome(let version, _, _, let build, let oldest, _) = client.request(.hello(version: HostProtocol.version)) else { fail("the host didn't answer") }
        // A host from an earlier build of this program, with nothing running: it makes way.
        // With sessions running it stays, and is talked to as it is.
        if let build, build != Daemon.build, case .done = client.request(.retire) {
            client.close()
            for _ in 0..<60 where FileManager.default.fileExists(atPath: socket) { Thread.sleep(forTimeInterval: 0.05) }
            client = try Daemon.connect(to: socket)
            guard case .welcome = client.request(.hello(version: HostProtocol.version)) else { fail("the new host didn't answer") }
            return client
        }
        guard HostProtocol.speaks(version: version, oldest: oldest) else {
            fail("the host running here is from an omux too old for this one to talk to. Its sessions keep running; when they have ended, it makes way for the new one.")
        }
        return client
    } catch { fail("\(error)") }
}

func sessions(_ client: HostClient) -> [SessionInfo] {
    guard case .sessions(let list) = client.request(.list) else { fail("the host didn't list its sessions") }
    return list
}

func find(_ name: String, _ client: HostClient) -> SessionInfo {
    let list = sessions(client)
    let matches = list.filter { $0.id == name } + list.filter { $0.id != name && ($0.id.hasPrefix(name) || $0.name == name) }
    guard let first = matches.first else { fail("no session \(name)") }
    guard matches.count == 1 else { fail("\(name) names \(matches.count) sessions: \(matches.map(\.id).joined(separator: ", "))") }
    return first
}

/// The size of the terminal this command runs in, when it runs in one.
func terminalSize() -> (columns: Int, rows: Int)? {
    var window = winsize()
    #if canImport(Darwin)
    let request: UInt = 0x4008_7468  // TIOCGWINSZ
    #else
    let request: UInt = 0x5413
    #endif
    guard isatty(STDOUT_FILENO) == 1, ioctl(STDOUT_FILENO, request, &window) == 0, window.ws_col > 0 else { return nil }
    return (Int(window.ws_col), Int(window.ws_row))
}

/// Shows a session in this terminal until it ends or Ctrl-\ leaves it.
func attach(_ session: SessionInfo, _ client: HostClient) -> Never {
    let interactive = isatty(STDIN_FILENO) == 1
    var saved = termios()
    if interactive {
        tcgetattr(STDIN_FILENO, &saved)
        var raw = saved
        raw.c_iflag &= ~tcflag_t(IGNBRK | BRKINT | PARMRK | ISTRIP | INLCR | IGNCR | ICRNL | IXON)
        raw.c_oflag &= ~tcflag_t(OPOST)
        raw.c_lflag &= ~tcflag_t(ECHO | ECHONL | ICANON | ISIG | IEXTEN)
        raw.c_cflag |= tcflag_t(CS8)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }
    let restore: @Sendable (String, Int32) -> Never = { note, code in
        if interactive { var saved = saved; tcsetattr(STDIN_FILENO, TCSANOW, &saved) }
        if !note.isEmpty { FileHandle.standardError.write(Data(("\r\n[" + note + "]\r\n").utf8)) }
        exit(code)
    }
    client.onEvent = { message in
        switch message {
        case .output(_, _, let data): FileHandle.standardOutput.write(data)
        case .exited(_, let code): restore("session ended with \(code)", code)
        default: break
        }
    }
    client.onClose = { restore("the host went away", 1) }
    if let size = terminalSize() { client.send(.resize(session: session.id, columns: size.columns, rows: size.rows)) }
    client.send(.attach(session: session.id, from: nil)) { answer in
        if case .failed(let why) = answer { restore(why, 1) }
    }
    // The terminal changed size: so does the session's.
    signal(SIGWINCH, SIG_IGN)
    let resized = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    resized.setEventHandler {
        if let size = terminalSize() { client.send(.resize(session: session.id, columns: size.columns, rows: size.rows)) }
    }
    resized.resume()
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count <= 0 { if count < 0, errno == EINTR { continue }; break }
            // Ctrl-\ leaves the session running.
            if interactive, buffer[0..<count].contains(0x1c) { restore("detached; the session keeps running", 0) }
            client.send(.input(session: session.id, data: Data(buffer[0..<count])))
        }
        // Input ran out (a pipe): let the session say what it has to, then go.
        if !interactive { Thread.sleep(forTimeInterval: 0.3); restore("", 0) }
    }
    dispatchMain()
}

switch command {
case "serve":
    let server = HostServer()
    do { try server.listen(at: socket) } catch { fail("\(error)") }
    print("omux-host \(HostProtocol.version) listening at \(socket)")
    fflush(stdout)
    // Asked to stop, the host hangs up on its sessions first, as closing a terminal would.
    server.host.onRetire = { server.stop(); exit(0) }
    // Nothing running for a while: stop, and let the next command start whatever is installed.
    let idle = DispatchSource.makeTimerSource(queue: .main)
    idle.schedule(deadline: .now() + 60, repeating: 60)
    idle.setEventHandler { if let quiet = server.host.idleFor, quiet > HostServer.idleLimit { server.stop(); exit(0) } }
    idle.resume()
    var stops: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { server.host.closeAll(); server.stop(); exit(0) }
        source.resume()
        stops.append(source)
    }
    dispatchMain()

case "list":
    let list = sessions(connect())
    if list.isEmpty { print("No sessions.") }
    for session in list {
        let state = session.exited.map { "ended \($0)" } ?? "running"
        print("\(session.id)  \(state.padding(toLength: 9, withPad: " ", startingAt: 0))  \(session.name.padding(toLength: 16, withPad: " ", startingAt: 0))  \(session.directory)  \(session.command.joined(separator: " "))")
    }

case "new":
    var request = StartRequest()
    var attachAfter = false
    var rest = arguments
    while let argument = rest.first {
        rest.removeFirst()
        switch argument {
        case "--name": guard !rest.isEmpty else { fail("--name needs a name") }; request.name = rest.removeFirst()
        case "--dir": guard !rest.isEmpty else { fail("--dir needs a folder") }; request.directory = rest.removeFirst()
        case "--attach": attachAfter = true
        case "--": request.command = rest; rest = []
        default: request.command = [argument] + rest; rest = []
        }
    }
    if request.directory == nil { request.directory = FileManager.default.currentDirectoryPath }
    if let size = terminalSize() { request.columns = size.columns; request.rows = size.rows }
    let client = connect()
    switch client.request(.start(request: request)) {
    case .started(let info):
        if attachAfter { attach(info, client) }
        print(info.id)
    case .failed(let why): fail(why)
    default: fail("the host didn't start the session")
    }

case "attach":
    guard let name = arguments.first else { fail("attach needs a session") }
    let client = connect()
    attach(find(name, client), client)

case "close":
    guard let name = arguments.first else { fail("close needs a session") }
    let client = connect()
    if case .failed(let why) = client.request(.close(session: find(name, client).id)) { fail(why) }

case "session":
    // What the app runs at the far end of SSH for a session of its own: the one with this id
    // if it is still running, as after a dropped connection or a restart of the app; else new.
    guard let id = arguments.first else { fail("session needs an id") }
    var request = StartRequest(id: id)
    var rest = Array(arguments.dropFirst())
    while let argument = rest.first {
        rest.removeFirst()
        guard !rest.isEmpty else { fail("\(argument) needs a value") }
        switch argument {
        case "--name": request.name = rest.removeFirst()
        case "--dir": request.directory = rest.removeFirst()
        case "--run": request.initialInput = rest.removeFirst() + "\n"
        default: fail("unknown option \(argument)")
        }
    }
    if let size = terminalSize() { request.columns = size.columns; request.rows = size.rows }
    let client = connect()
    switch client.request(.start(request: request)) {
    case .started(let info): attach(info, client)
    case .failed(let why): fail(why)
    default: fail("the host didn't start the session")
    }

case "mirror":
    var directory: String?
    var session: String?
    var rest = arguments
    while let argument = rest.first {
        rest.removeFirst()
        guard !rest.isEmpty else { fail("\(argument) needs a value") }
        switch argument {
        case "--dir": directory = rest.removeFirst()
        case "--session": session = rest.removeFirst()
        default: fail("unknown option \(argument)")
        }
    }
    guard let directory, let session else { fail("mirror needs --dir and --session") }
    let folder = (directory as NSString).expandingTildeInPath
    let root = ClaudePaths.projectURL(for: folder.isEmpty ? NSHomeDirectory() : folder).path
    // The other side says first what it holds; then standard input stays open for as long
    // as it is there, and its end is the sign to stop.
    final class Input: @unchecked Sendable { var have = Mirror.Have(); var closed = false; let ready = DispatchSemaphore(value: 0) }
    let input = Input()
    Thread.detachNewThread {
        var splitter = Wire.Splitter()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        var told = false
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count <= 0 { if count < 0, errno == EINTR { continue }; break }
            if !told, let frame = (try? splitter.feed(Data(buffer[0..<count])))?.first, let have = try? Wire.decode(Mirror.Have.self, from: frame) {
                input.have = have; told = true; input.ready.signal()
            }
        }
        input.closed = true
        input.ready.signal()
    }
    _ = input.ready.wait(timeout: .now() + 5)
    Mirror.serve(root: root, session: session, have: input.have, stopped: { input.closed }) { update in
        guard let frame = try? Wire.encode(update) else { return true }
        return frame.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let wrote = write(STDOUT_FILENO, bytes.baseAddress! + sent, bytes.count - sent)
                if wrote <= 0 { if wrote < 0, errno == EINTR { continue }; return false }
                sent += wrote
            }
            return true
        }
    }

case "connect":
    // Standard input and output become the socket: what the app runs at the far end of SSH.
    do { _ = try Daemon.connect(to: socket) } catch { fail("\(error)") }
    let address = socket
    func pump(from input: Int32, to output: Int32) {
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count <= 0 { if count < 0, errno == EINTR { continue }; break }
            var sent = 0
            while sent < count {
                let wrote = buffer.withUnsafeBytes { write(output, $0.baseAddress! + sent, count - sent) }
                if wrote <= 0 { if wrote < 0, errno == EINTR { continue }; exit(0) }
                sent += wrote
            }
        }
        exit(0)
    }
    guard let descriptor = try? UnixSocket.rawConnect(address) else { fail("no host at \(address)") }
    Thread.detachNewThread { pump(from: STDIN_FILENO, to: descriptor) }
    pump(from: descriptor, to: STDOUT_FILENO)

case "version", "--version":
    print("omux-host protocol \(HostProtocol.version) build \(Daemon.build)")

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command \(command)\n\n" + usage, code: 2)
}
