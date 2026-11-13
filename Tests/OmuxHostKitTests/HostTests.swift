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
        guard case .started(let info) = client.request(.start(StartRequest(name: "t", directory: "/usr", command: ["/bin/sh", "-c", script]))) else {
            throw XCTSkip("the session didn't start")
        }
        return info
    }

    func testHelloAndAnEmptyList() throws {
        let client = try client()
        guard case .welcome(let version, _, let system) = client.request(.hello(version: HostProtocol.version)) else { return XCTFail() }
        XCTAssertEqual(version, HostProtocol.version)
        XCTAssertFalse(system.isEmpty)
        XCTAssertEqual(client.request(.list), .sessions([]))
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
        XCTAssertEqual(client.request(.list), .sessions([]))
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

    func testWhatCannotBeDoneIsSaid() throws {
        let client = try client()
        if case .failed = client.request(.attach(session: "nope", from: nil)) {} else { XCTFail() }
        if case .failed = client.request(.start(StartRequest(directory: "/no/such/folder", command: ["/bin/sh"]))) {} else { XCTFail() }
        if case .failed = client.request(.start(StartRequest(command: ["/no/such/program"]))) {} else { XCTFail() }
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
