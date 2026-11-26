import XCTest
import OmuxCLIProtocol
@testable import omux

/// The command server must survive a client that goes away before its reply is written.
final class CommandServerTests: XCTestCase {
    private func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EBADF) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { close(fd); throw POSIXError(.ECONNREFUSED) }
        return fd
    }

    /// The handler runs on the main thread, which this test holds until the client has closed,
    /// so the reply is always written to a socket nobody reads any more. Writing there raises
    /// SIGPIPE, which kills the process unless the server guards against it.
    func testClientThatHangsUpBeforeTheReplyDoesNotKillTheServer() throws {
        let server = CommandServer()
        let answered = expectation(description: "handler ran")
        server.handler = { request in
            answered.fulfill()
            return CLIResponse(ok: true, session: CLISession(id: request.from, name: "x", provider: "shell", state: "running"))
        }
        server.start()
        defer { server.stop() }
        let path = try XCTUnwrap(server.socketPath)

        let client = try connect(to: path)
        let request = try JSONEncoder().encode(CLIRequest(token: server.token(for: "tab-1"), from: "tab-1", command: "status"))
        let line = request + Data([UInt8(ascii: "\n")])
        let sent = line.withUnsafeBytes { write(client, $0.baseAddress!, line.count) }
        XCTAssertEqual(sent, line.count)
        close(client)

        // Now let the server answer, and give it time to write the reply.
        wait(for: [answered], timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // Still alive: the server is still accepting connections.
        let again = try connect(to: path)
        close(again)
    }
}
