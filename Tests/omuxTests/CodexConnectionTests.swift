import XCTest
@testable import omux
@testable import OmuxCore

final class CodexConnectionTests: XCTestCase {
    /// A codex that exits while connecting (not on PATH, bad flag, crash) gets the
    /// "Install Codex CLI" message, not "Swift.CancellationError error 1", and no disconnect.
    @MainActor
    func testCodexExitingWhileConnectingIsUnavailable() async throws {
        guard (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").hasSuffix("/zsh") else {
            throw XCTSkip("Puts a fake codex on the login shell's PATH through ZDOTDIR")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = home.appendingPathComponent("bin/codex")
        try "#!/bin/sh\nexit 127\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        try "export PATH=\"\(home.path)/bin:$PATH\"\n".write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["ZDOTDIR"] = home.path
        let connection = CodexConnection(environment: env)
        defer { connection.close() }
        var disconnected = false
        connection.onDisconnect = { disconnected = true }
        do {
            try await connection.connect()
            XCTFail("Connected to a codex that exited")
        } catch CodexError.unavailable {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertFalse(disconnected)
    }

    /// What starts Codex's app-server on another machine, and where its token is kept there.
    func testTheRemoteServerCommand() throws {
        let script = CodexConnection.remoteServerScript(port: 51234, digest: "abc123")
        XCTAssertTrue(script.contains("codex app-server --listen ws://127.0.0.1:51234 --ws-auth capability-token --ws-token-sha256 abc123"))
        XCTAssertTrue(script.contains("cat >/dev/null"), "stops when the connection to this Mac goes")
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/sh")
        check.arguments = ["-n", "-c", script]
        try check.run(); check.waitUntilExit()
        XCTAssertEqual(check.terminationStatus, 0)
        XCTAssertEqual(CodexConnection.remoteTokenPath(name: "tab-1"), "$HOME/.omux/codex/tab-1.token")
    }

    /// Against a real machine, with a stand-in for Codex on it: the token stored there, the
    /// app-server started, reached through the tunnel with the token, asked something, and
    /// stopped with the connection. OMUX_LIVE_HOST=devbox swift test --filter CodexConnectionTests
    @MainActor
    func testATunnelToAnAppServerOnALiveMachine() async throws {
        guard let host = ProcessInfo.processInfo.environment["OMUX_LIVE_HOST"], !host.isEmpty else { throw XCTSkip("no OMUX_LIVE_HOST") }
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-codex.py")
        // On the login shell's PATH there, as the real one would be.
        let installed = RemotePath.run(#"mkdir -p "$HOME/.local/bin" "$HOME/bin" && cat > "$HOME/bin/codex" && chmod +x "$HOME/bin/codex" && "${SHELL:-/bin/sh}" -lc 'command -v codex'"#, on: host, input: fake)
        try XCTSkipIf(installed.status != 0 || !installed.text.contains("/bin/codex"), "couldn't put a stand-in codex on the PATH there: \(installed.text) \(installed.error)")
        defer { _ = RemotePath.run(#"rm -f "$HOME/bin/codex"; rm -rf "$HOME/.omux""#, on: host) }

        let connection = CodexConnection(remote: (host, "live-test"))
        try await connection.connect()
        XCTAssertNotEqual(connection.endpoint, connection.tuiEndpoint, "this Mac's end of the tunnel and the machine's")
        let started = try await connection.request("thread/start", params: ["cwd": "/tmp"])
        XCTAssertEqual((started["thread"] as? [String: Any])?["id"] as? String, "fake-thread-1")

        let there = RemotePath.run(#"stat -c '%a' "$HOME/.omux/codex/live-test.token"; pgrep -f '[c]odex app-server' | wc -l"#, on: host).text.split(whereSeparator: \.isNewline).map(String.init)
        XCTAssertEqual(there.first, "600", "the token is its owner's alone")
        XCTAssertNotEqual(there.last?.trimmingCharacters(in: .whitespaces), "0", "the app-server runs there")
        // The token there is the one this connection holds, so a TUI there can use it.
        let token = RemotePath.run(#"cat "$HOME/.omux/codex/live-test.token""#, on: host).text
        XCTAssertEqual(token, connection.token)

        connection.close()
        var left = "?"
        for _ in 0..<30 {
            left = RemotePath.run("pgrep -f '[c]odex app-server' | wc -l", on: host).text.trimmingCharacters(in: .whitespacesAndNewlines)
            if left == "0" { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(left, "0", "closing the connection stops the app-server there")
    }

    /// Opt-in: starts the installed CLI with a temporary CODEX_HOME and no real
    /// credentials. No model turn is sent and no user conversations are read.
    @MainActor
    func testRealServerPersistsAndResumesExactThread() async throws {
        guard ProcessInfo.processInfo.environment["OMUX_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip("Set OMUX_CODEX_INTEGRATION=1 to test the installed Codex CLI")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try """
        model_provider = "omux_test"
        model = "gpt-6.1-sol"
        [model_providers.omux_test]
        name = "Local test"
        base_url = "http://127.0.0.1:1/v1"
        wire_api = "responses"
        requires_openai_auth = false
        supports_websockets = false
        """.write(to: folder.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = folder.path
        env.removeValue(forKey: "OPENAI_API_KEY")
        env.removeValue(forKey: "CODEX_API_KEY")
        let connection = CodexConnection(environment: env)
        defer { connection.close() }
        try await connection.connect()
        let one = try await connection.request("thread/start", params: ["cwd": folder.path])
        let first = try XCTUnwrap((one["thread"] as? [String: Any])?["id"] as? String)
        _ = try await connection.request("thread/name/set", params: ["threadId": first, "name": "Omux integration test"])
        let two = try await connection.request("thread/start", params: ["cwd": folder.path])
        let second = try XCTUnwrap((two["thread"] as? [String: Any])?["id"] as? String)
        _ = try await connection.request("thread/name/set", params: ["threadId": second, "name": "Second Omux test"])
        XCTAssertNotEqual(first, second)
        connection.close()
        try await connection.connect()
        let resumed = try await connection.request("thread/resume", params: ["threadId": first, "excludeTurns": true])
        XCTAssertEqual((resumed["thread"] as? [String: Any])?["id"] as? String, first)
        let other = try await connection.request("thread/resume", params: ["threadId": second, "excludeTurns": true])
        XCTAssertEqual((other["thread"] as? [String: Any])?["id"] as? String, second)
        let independent = CodexConnection(environment: env)
        defer { independent.close() }
        try await independent.connect()
        let separate = try await independent.request("thread/start", params: ["cwd": folder.path])
        let third = try XCTUnwrap((separate["thread"] as? [String: Any])?["id"] as? String)
        _ = try await independent.request("thread/name/set", params: ["threadId": third, "name": "Independent Omux test"])
        connection.close()
        let stillAvailable = try await independent.request("thread/read", params: ["threadId": third])
        XCTAssertEqual((stillAvailable["thread"] as? [String: Any])?["id"] as? String, third,
                       "Closing one Omux server must not stop an independent server")
    }
}
