import XCTest
@testable import omux
@testable import OmuxCore

final class CodexManagerTests: XCTestCase {
    /// An app-server that outlives its 10 s shutdown wait makes the next start fail once with
    /// "still stopping"; the start after that must not get the same stale error again.
    @MainActor
    func testASlowShutdownBlocksOnlyOneRestart() async throws {
        guard (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").hasSuffix("/zsh") else {
            throw XCTSkip("Puts a fake codex on the login shell's PATH through ZDOTDIR")
        }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"), withIntermediateDirectories: true)
        let pids = home.appendingPathComponent("pids")
        let fake = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/fake-codex.py")
        let codex = home.appendingPathComponent("bin/codex")
        // Records itself and the shell watching it, so the test can stop both.
        try "#!/bin/sh\necho $$ $PPID >> '\(pids.path)'\nexec python3 '\(fake.path)' \"$@\"\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        // The shell that runs the app-server ignores SIGTERM and can't install its own trap,
        // so closing the connection leaves it running: a shutdown that never finishes.
        try "export PATH=\"\(home.path)/bin:$PATH\"\nbuiltin trap '' TERM INT HUP\ntrap() { :; }\n"
            .write(to: home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        // Cached for the whole process: read it before ZDOTDIR points at this test's shell setup.
        _ = await ShellPath.load()
        let previousZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        setenv("ZDOTDIR", home.path, 1)
        let manager = CodexManager()
        defer {
            manager.shutdown()
            if let previousZDOTDIR { setenv("ZDOTDIR", previousZDOTDIR, 1) } else { unsetenv("ZDOTDIR") }
            let text = (try? String(contentsOf: pids, encoding: .utf8)) ?? ""
            for pid in text.split(whereSeparator: { $0 == " " || $0 == "\n" }).compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
            try? FileManager.default.removeItem(at: home)
        }

        let tab = UUID()
        let started = try await manager.prepare(tabID: tab, threadID: nil, cwd: "/tmp", name: "Session")
        XCTAssertEqual(started.threadID, "fake-thread-1")
        manager.close(tab)

        // The old server is still running after the wait: this restart reports it.
        var first: Error?
        do { _ = try await manager.prepare(tabID: tab, threadID: nil, cwd: "/tmp", name: "Session") }
        catch { first = error }
        XCTAssertTrue(first?.localizedDescription.contains("still stopping") == true, "first restart: \(String(describing: first))")

        // The failed wait was already reported: the next restart starts a new server.
        do {
            let again = try await manager.prepare(tabID: tab, threadID: nil, cwd: "/tmp", name: "Session")
            XCTAssertEqual(again.threadID, "fake-thread-1")
        } catch {
            XCTFail("The second restart failed with the stored shutdown error again: \(error.localizedDescription)")
        }
    }
}
