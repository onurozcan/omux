import XCTest
@testable import OmuxHostKit

/// A host and a client talking over a real socket, with real programs on real terminals:
/// what `omux-host` does, minus the command line. Runs on Linux too.
final class HostTests: XCTestCase {
    private final class Screen: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var offsets: [UInt64] = []
        private var code: Int32?
        func take(_ message: HostMessage) {
            lock.lock(); defer { lock.unlock() }
            switch message {
            case .output(_, let offset, let bytes): offsets.append(offset); data.append(bytes)
            case .exited(_, let status): code = status
            default: break
            }
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var end: UInt64 { lock.lock(); defer { lock.unlock() }; return (offsets.first ?? 0) + UInt64(data.count) }
        var first: UInt64? { lock.lock(); defer { lock.unlock() }; return offsets.first }
        var status: Int32? { lock.lock(); defer { lock.unlock() }; return code }
    }

    private var server: HostServer!
    private var socket = ""

    override func setUp() {
        signal(SIGPIPE, SIG_IGN)
        // Short: a socket path has little room.
        socket = NSTemporaryDirectory() + "omux-t-\(UInt32.random(in: 0...99999))/h.sock"
        server = HostServer(host: SessionHost(keep: 64 << 10))
        XCTAssertNoThrow(try server.listen(at: socket))
    }

    override func tearDown() {
        server.host.closeAll()
        server.stop()
        try? FileManager.default.removeItem(atPath: (socket as NSString).deletingLastPathComponent)
    }

    private func until(_ seconds: Double = 5, _ holds: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !holds(), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    }

    private func client(_ screen: Screen? = nil) throws -> HostClient {
        let client = try HostClient(socket: socket)
        if let screen { client.onEvent = { screen.take($0) } }
        return client
    }

    private func start(_ client: HostClient, _ script: String) throws -> SessionInfo {
        guard case .started(let info) = client.request(.start(request: StartRequest(name: "t", directory: "/usr", command: ["/bin/sh", "-c", script]))) else {
            throw XCTSkip("the session didn't start")
        }
        return info
    }

    func testHelloAndAnEmptyList() throws {
        let client = try client()
        guard case .welcome(let version, _, let system, let build, let oldest, let running) = client.request(.hello(version: HostProtocol.version)) else { return XCTFail() }
        XCTAssertEqual(version, HostProtocol.version)
        XCTAssertFalse(system.isEmpty)
        XCTAssertEqual(build, Daemon.build)
        XCTAssertEqual(oldest, HostProtocol.oldest)
        XCTAssertEqual(running, 0)
        XCTAssertEqual(client.request(.list), .sessions(list: []))
    }

    func testStartAttachTypeAndExit() throws {
        let screen = Screen()
        let client = try client(screen)
        let info = try start(client, #"pwd; read line; echo "got:$line"; exit 3"#)
        XCTAssertEqual(info.directory, "/usr")
        guard case .started = client.request(.attach(session: info.id, from: nil)) else { return XCTFail() }
        until { screen.text.contains("/usr") }
        XCTAssertEqual(client.request(.input(session: info.id, data: Data("hi\n".utf8))), .done)
        until { screen.status != nil }
        XCTAssertTrue(screen.text.contains("got:hi"), screen.text)
        XCTAssertEqual(screen.status, 3)
        // Ended, it stays listed with its exit code until closed.
        guard case .sessions(let listed) = client.request(.list) else { return XCTFail() }
        XCTAssertEqual(listed.map(\.exited), [3])
        XCTAssertEqual(listed.first?.outputEnd, screen.end)
        XCTAssertEqual(client.request(.close(session: info.id)), .done)
        XCTAssertEqual(client.request(.list), .sessions(list: []))
    }

    /// The point of a host: the session goes on with nobody attached, and a client that comes
    /// back says how far it got and is sent only the rest.
    func testASessionOutlivesItsClientAndCatchesItUp() throws {
        let first = Screen()
        var client: HostClient? = try self.client(first)
        let info = try start(client!, #"echo one; read a; echo two; read b; echo three"#)
        _ = client!.request(.attach(session: info.id, from: nil))
        until { first.text.contains("one") }
        let seen = first.end
        client!.close(); client = nil

        // Nobody is attached while it prints "two".
        let other = try self.client()
        XCTAssertEqual(other.request(.input(session: info.id, data: Data("\n".utf8))), .done)
        until { if case .sessions(let list) = other.request(.list) { return (list.first?.outputEnd ?? 0) > seen + 4 } else { return false } }

        let second = Screen()
        let back = try self.client(second)
        _ = back.request(.attach(session: info.id, from: seen))
        until { second.text.contains("two") }
        XCTAssertEqual(second.first, seen, "sent from where the first client stopped")
        XCTAssertTrue(second.text.contains("two"), second.text)
        XCTAssertFalse(second.text.contains("one"), "not what it already had")
        _ = back.request(.input(session: info.id, data: Data("\n".utf8)))
        until { second.status != nil }
        XCTAssertTrue(second.text.contains("three"))
        XCTAssertEqual(second.status, 0)
    }

    func testTwoClientsWatchOneSessionAndCloseHangsUp() throws {
        let a = Screen(), b = Screen()
        let one = try client(a), two = try client(b)
        let info = try start(one, "echo ready; sleep 60")
        _ = one.request(.attach(session: info.id, from: nil))
        _ = two.request(.attach(session: info.id, from: nil))
        until { a.text.contains("ready") && b.text.contains("ready") }
        XCTAssertTrue(a.text.contains("ready") && b.text.contains("ready"))
        XCTAssertEqual(two.request(.close(session: info.id)), .done)
        until { a.status != nil && b.status != nil }
        XCTAssertEqual(a.status, 129, "hung up")
        XCTAssertEqual(b.status, 129)
    }

    func testOnlyTheTailOfLongOutputIsKept() throws {
        let screen = Screen()
        let client = try client(screen)
        // 200 KB printed into a host that keeps 64 KB.
        let info = try start(client, "i=0; while [ $i -lt 2000 ]; do printf '%0100d\\n' $i; i=$((i+1)); done")
        until { if case .sessions(let list) = client.request(.list) { return list.first?.exited != nil } else { return false } }
        _ = client.request(.attach(session: info.id, from: 0))
        until { screen.status != nil }
        XCTAssertGreaterThan(screen.first ?? 0, 0, "the start is gone")
        XCTAssertLessThanOrEqual(screen.text.utf8.count, 64 << 10)
        XCTAssertTrue(screen.text.contains(String(format: "%0100d", 1999)), "the end is there")
    }

    /// The app names its sessions itself and asks again after a restart or a dropped
    /// connection: the running one is the answer, with nothing typed into it a second time.
    func testASessionAskedForByIdIsStartedOnceAndGetsItsCommandOnce() throws {
        let screen = Screen()
        let client = try client(screen)
        let request = StartRequest(id: "tab-1", directory: "/usr", command: ["/bin/sh"], initialInput: "echo typed-$((40+2))\n")
        guard case .started(let first) = client.request(.start(request: request)) else { return XCTFail() }
        XCTAssertEqual(first.id, "tab-1")
        _ = client.request(.attach(session: "tab-1", from: nil))
        until { screen.text.contains("typed-42") }
        XCTAssertTrue(screen.text.contains("typed-42"), screen.text)

        guard case .started(let second) = client.request(.start(request: request)) else { return XCTFail() }
        XCTAssertEqual(second.started, first.started, "the same session, not a second one")
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(screen.text.components(separatedBy: "typed-42").count - 1, 1, "typed once")
        guard case .sessions(let list) = client.request(.list) else { return XCTFail() }
        XCTAssertEqual(list.count, 1)

        // Ended, its id is free for a new session.
        _ = client.request(.input(session: "tab-1", data: Data("exit\n".utf8)))
        until { screen.status != nil }
        guard case .started(let third) = client.request(.start(request: request)) else { return XCTFail() }
        XCTAssertNotEqual(third.started, first.started)
        XCTAssertNil(third.exited)
    }

    /// How a machine comes to run a newer host: the old one makes way when asked, but only
    /// with nothing running. Sessions are never dropped for an update.
    func testAHostRetiresOnlyWithNothingRunning() throws {
        let retired = DispatchSemaphore(value: 0)
        server.host.onRetire = { retired.signal() }
        let client = try client()
        let info = try start(client, "sleep 60")
        guard case .failed(let why) = client.request(.retire) else { return XCTFail("retired with a session running") }
        XCTAssertTrue(why.contains("1 session is running"), why)
        XCTAssertEqual(retired.wait(timeout: .now() + 0.5), .timedOut)
        XCTAssertNil(server.host.idleFor, "not idle while it runs")

        _ = client.request(.close(session: info.id))
        until { if case .sessions(let list) = client.request(.list) { return list.first?.exited != nil } else { return false } }
        XCTAssertNotNil(server.host.idleFor)
        XCTAssertEqual(client.request(.retire), .done)
        XCTAssertEqual(retired.wait(timeout: .now() + 2), .success)
    }

    /// Removing omux from a machine: the host hangs up on what runs and then goes.
    func testShutdownHangsUpOnEverythingAndStopsTheHost() throws {
        let stopped = DispatchSemaphore(value: 0)
        server.host.onRetire = { stopped.signal() }
        let screen = Screen()
        let client = try client(screen)
        let info = try start(client, "echo ready; sleep 60")
        _ = client.request(.attach(session: info.id, from: nil))
        until { screen.text.contains("ready") }
        XCTAssertEqual(client.request(.shutdown), .done)
        until { screen.status != nil }
        XCTAssertEqual(screen.status, 129)
        XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
    }

    /// A request this host has never heard of, from a newer omux, is refused under its own
    /// number at once, not left unanswered.
    func testAnUnknownRequestIsRefusedByNumber() throws {
        let descriptor = try UnixSocket.rawConnect(socket)
        defer { close(descriptor) }
        let body = Data(#"{"id":41,"message":{"teleport":{"to":"mars"}}}"#.utf8)
        var frame = Data([0, 0, 0, UInt8(body.count)]); frame.append(body)
        _ = frame.withUnsafeBytes { write(descriptor, $0.baseAddress!, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = read(descriptor, &buffer, buffer.count)
        XCTAssertGreaterThan(count, 4)
        let answer = try Wire.decode(HostFrame.self, from: Data(buffer[4..<max(count, 4)]))
        XCTAssertEqual(answer.reply, 41)
        if case .failed = answer.message {} else { XCTFail() }
    }

    func testWhichVersionsCanTalk() {
        XCTAssertTrue(HostProtocol.speaks(version: HostProtocol.version, oldest: HostProtocol.oldest))
        XCTAssertTrue(HostProtocol.speaks(version: HostProtocol.version + 3, oldest: HostProtocol.version), "a newer host that still speaks ours")
        XCTAssertFalse(HostProtocol.speaks(version: HostProtocol.version + 3, oldest: HostProtocol.version + 1), "a newer host that dropped ours")
        XCTAssertFalse(HostProtocol.speaks(version: HostProtocol.oldest - 1, oldest: nil), "a host older than we still speak")
    }

    func testWhatCannotBeDoneIsSaid() throws {
        let client = try client()
        if case .failed = client.request(.attach(session: "nope", from: nil)) {} else { XCTFail() }
        if case .failed = client.request(.start(request: StartRequest(directory: "/no/such/folder", command: ["/bin/sh"]))) {} else { XCTFail() }
        if case .failed = client.request(.start(request: StartRequest(command: ["/no/such/program"]))) {} else { XCTFail() }
    }

    func testMessagesSurviveBeingSplitOnTheWire() throws {
        let frames = try [ClientFrame(id: 1, message: .list), ClientFrame(id: 2, message: .input(session: "ab", data: Data([0, 255, 10])))].map(Wire.encode)
        let stream = frames.reduce(Data(), +)
        var splitter = Wire.Splitter()
        var out: [ClientFrame] = []
        for byte in stream { out += try splitter.feed(Data([byte])).map { try Wire.decode(ClientFrame.self, from: $0) } }
        XCTAssertEqual(out.map(\.id), [1, 2])
        XCTAssertEqual(out.last?.message, .input(session: "ab", data: Data([0, 255, 10])))
    }
}
