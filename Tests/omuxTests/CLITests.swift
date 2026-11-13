import XCTest
import OmuxCLIProtocol
@testable import omux
@testable import OmuxCore

final class CLITests: XCTestCase {
    private func parse(_ line: String) -> Result<(command: CLICommand, json: Bool), CLIUsageError> {
        CLIArguments.parse(line.split(separator: " ").map(String.init))
    }

    func testCommandsParse() throws {
        XCTAssertEqual(try parse("list").get().command, .list)
        XCTAssertEqual(try parse("status").get().command, .status(target: nil))
        XCTAssertEqual(try parse("status api").get().command, .status(target: "api"))
        XCTAssertEqual(try parse("screen -n 10 api").get().command, .screen(target: "api", lines: 10))
        XCTAssertEqual(try parse("screen").get().command, .screen(target: nil, lines: 40))
        XCTAssertEqual(try parse("screen -n 9999").get().command, .screen(target: nil, lines: 500))
        XCTAssertEqual(try parse("send api fix the tests --submit").get().command, .send(target: "api", text: "fix the tests", submit: true))
        XCTAssertEqual(try parse("send api -").get().command, .send(target: "api", text: "-", submit: false))
        XCTAssertEqual(try parse("new --name Tests --provider shell").get().command, .new(name: "Tests", directory: nil, provider: "shell"))
        XCTAssertEqual(try parse("close api").get().command, .close(target: "api"))
        XCTAssertEqual(try parse("wait api --for done,blocked --timeout 30").get().command,
                       .wait(target: "api", states: ["done", "blocked"], timeout: 30))
        XCTAssertEqual(try parse("wait").get().command, .wait(target: nil, states: ["blocked", "done", "error", "stopped"], timeout: 600))
        XCTAssertTrue(try parse("--json list").get().json)
        XCTAssertEqual(try parse("").get().command, .help)
    }

    func testBadArgumentsAreRefused() {
        for line in ["frobnicate", "send api", "send", "new --provider python", "new extra", "screen -n x", "wait --for asleep",
                     "close", "status a b", "new --name"] {
            if case .success(let value) = parse(line) { XCTFail("\(line) parsed as \(value.command)") }
        }
    }

    func testRequestsCarryTheArguments() {
        let request = CLIArguments.request(for: .send(target: "api", text: "hi", submit: true))
        XCTAssertEqual(request, CLIRequest(command: "send", target: "api", text: "hi", submit: true))
        XCTAssertEqual(CLIArguments.request(for: .wait(target: "x", states: [], timeout: 1))?.command, "status")
        XCTAssertNil(CLIArguments.request(for: .help))
    }

    func testTargetsResolveByIdThenName() {
        let caller = UUID(), api = UUID(), web1 = UUID(), web2 = UUID()
        let sessions = [(id: caller, name: "Session 1"), (id: api, name: "API"), (id: web1, name: "web"), (id: web2, name: "Web")]
        XCTAssertEqual(try CLIScope.resolve(nil, caller: caller, sessions: sessions).get(), caller)
        XCTAssertEqual(try CLIScope.resolve(" ", caller: caller, sessions: sessions).get(), caller)
        XCTAssertEqual(try CLIScope.resolve(api.uuidString, caller: caller, sessions: sessions).get(), api)
        XCTAssertEqual(try CLIScope.resolve("API", caller: caller, sessions: sessions).get(), api)
        XCTAssertEqual(try CLIScope.resolve("api", caller: caller, sessions: sessions).get(), api)
        XCTAssertEqual(try CLIScope.resolve("web", caller: caller, sessions: sessions).get(), web1)
        XCTAssertEqual(try CLIScope.resolve("Web", caller: caller, sessions: sessions).get(), web2)
        // Two sessions match ignoring case: refused rather than guessed.
        if case .success = CLIScope.resolve("WEB", caller: caller, sessions: sessions) { XCTFail("ambiguous name resolved") }
        if case .success = CLIScope.resolve(UUID().uuidString, caller: caller, sessions: sessions) { XCTFail("foreign id resolved") }
        if case .success = CLIScope.resolve("nope", caller: caller, sessions: sessions) { XCTFail("unknown name resolved") }
    }

    func testOnlyOwnChildrenMayBeSteered() {
        let caller = UUID(), child = UUID(), other = UUID()
        XCTAssertTrue(CLIScope.maySteer(caller, caller: caller, children: []))
        XCTAssertTrue(CLIScope.maySteer(child, caller: caller, children: [child]))
        XCTAssertFalse(CLIScope.maySteer(other, caller: caller, children: [child]))
    }

    func testNewSessionsStayInsideTheProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: root + "/app/src", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/elsewhere", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root + "/app/escape", withDestinationPath: root + "/elsewhere")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let project = root + "/app"
        XCTAssertTrue(CLIScope.allowed(directory: project, within: [project]))
        XCTAssertTrue(CLIScope.allowed(directory: project + "/", within: [project]))
        XCTAssertTrue(CLIScope.allowed(directory: project + "/src", within: [project]))
        XCTAssertTrue(CLIScope.allowed(directory: project + "/src/../src", within: [project]))
        XCTAssertFalse(CLIScope.allowed(directory: project + "/../elsewhere", within: [project]))
        XCTAssertFalse(CLIScope.allowed(directory: root + "/application", within: [project]))
        XCTAssertFalse(CLIScope.allowed(directory: "/", within: [project]))
        XCTAssertFalse(CLIScope.allowed(directory: "~", within: [project]))
        // A symlink out of the project is followed before the check.
        XCTAssertFalse(CLIScope.allowed(directory: project + "/escape", within: [project]))
        XCTAssertFalse(CLIScope.allowed(directory: project, within: []))
    }

    func testProtocolRoundTrips() throws {
        let request = CLIRequest(token: "t", from: "f", command: "screen", target: "api", lines: 12)
        let decoded = try JSONDecoder().decode(CLIRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
        let response = CLIResponse(ok: true, session: CLISession(id: "1", name: "API", provider: "claude", state: "blocked", kind: "permission"), screen: ["a", "b"])
        XCTAssertEqual(try JSONDecoder().decode(CLIResponse.self, from: JSONEncoder().encode(response)), response)
    }

    /// The built tool against a live server: socket, peer check, framing and the token gate.
    /// A wrong token is answered by the server alone; a right one reaches the handler.
    func testToolReachesTheServerOverTheSocket() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let tool = products.appendingPathComponent("omux-cli").path
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: tool), "omux-cli isn't built next to the tests")
        let server = CommandServer()
        server.handler = { request in
            CLIResponse(ok: true, session: CLISession(id: request.from, name: "echo \(request.command)", provider: "shell", state: "running"))
        }
        server.start()
        defer { server.stop() }
        let socket = try XCTUnwrap(server.socketPath)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: socket))[.posixPermissions] as? Int, 0o600)

        // The server answers on the main thread, so the tool runs off it while the test
        // spins the run loop; blocking the main thread here would hang both.
        func run(_ args: [String], token: String) throws -> (status: Int32, out: String, err: String) {
            let done = expectation(description: args.joined(separator: " "))
            var result: (status: Int32, out: String, err: String) = (-1, "", "")
            var failure: Error?
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: tool)
                process.arguments = args
                process.environment = ["OMUX_SOCKET": socket, "OMUX_TOKEN": token, "OMUX_TAB_ID": "tab-1", "PATH": "/usr/bin:/bin"]
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                    let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    result = (process.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
                } catch { failure = error }
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
            if let failure { throw failure }
            return result
        }
        let good = try run(["status"], token: server.token)
        XCTAssertEqual(good.status, 0, good.err)
        XCTAssertTrue(good.out.contains("echo status"), good.out)
        let bad = try run(["status"], token: "nope")
        XCTAssertNotEqual(bad.status, 0)
        XCTAssertTrue(bad.err.contains("bad token"), bad.err)
        let json = try run(["--json", "list"], token: server.token)
        XCTAssertTrue(json.out.contains("\"ok\" : true"), json.out)
    }
}
