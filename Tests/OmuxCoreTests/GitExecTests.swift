import XCTest
@testable import OmuxCore

/// Running a command must end when the command ends, not when the last process holding its
/// output does. A hook, a dotfile or a shell command can leave a background child behind.
final class GitExecTests: XCTestCase {
    func testLoginReturnsWhenTheShellExitsDespiteABackgroundChild() throws {
        #if os(Linux)
        throw XCTSkip("Linux's Foundation reports the exit only once the background child closes the inherited pipes")
        #endif
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let start = Date()
        // The sleep inherits stdout and stderr and keeps them open after the shell exits.
        let result = Git.login("sleep 20 & echo done", in: dir)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 5, "waited \(elapsed)s for a background child to close the output pipe")
        XCTAssertTrue(result.out.contains("done"), "out=<\(result.out)> err=<\(result.err)>")
    }

    func testRunKillsACommandPastItsTimeout() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        let start = Date()
        let result = ChildProcess.run(process, timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 4, "waited \(elapsed)s for a timed-out command")
        XCTAssertEqual(result.status, -1)
        XCTAssertTrue(String(decoding: result.err, as: UTF8.self).contains("Timed out"), "err=<\(String(decoding: result.err, as: UTF8.self))>")
    }
}
