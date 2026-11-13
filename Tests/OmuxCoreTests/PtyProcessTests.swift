import XCTest
@testable import OmuxCore

/// A program on a pseudo-terminal with no window, as the session host runs agents. On Linux
/// too, where the host lives.
final class PtyProcessTests: XCTestCase {
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var code: Int32?
        func add(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
        func ended(_ status: Int32) { lock.lock(); code = status; lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
        var status: Int32? { lock.lock(); defer { lock.unlock() }; return code }
    }

    private func until(_ seconds: Double = 5, _ holds: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while !holds(), Date() < end { Thread.sleep(forTimeInterval: 0.02) }
    }

    private func run(_ script: String, directory: String? = nil, size: PtyProcess.Size = .init(columns: 80, rows: 24)) throws -> (PtyProcess, Collected) {
        let out = Collected()
        let process = try PtyProcess(executable: "/bin/sh", arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
                                     directory: directory, size: size, onOutput: { out.add($0) }, onExit: { out.ended($0) })
        return (process, out)
    }

    func testOutputExitCodeAndFolder() throws {
        // Printing and exiting at once: the last words must still arrive, and before the exit.
        let (process, out) = try run("pwd; exit 7", directory: "/usr")
        defer { _ = process }
        until { out.status != nil && out.text.contains("/usr") }
        XCTAssertTrue(out.text.contains("/usr"), out.text)
        XCTAssertEqual(out.status, 7, "text=<\(out.text)>")
    }

    func testItIsARealTerminalOfTheGivenSize() throws {
        // /dev/tty opens only for a process with a controlling terminal.
        let (process, out) = try run(#"test -t 0 && echo is-a-tty; : < /dev/tty && echo has-controlling-tty; stty size"#, size: .init(columns: 132, rows: 43))
        defer { _ = process }
        until { out.status != nil && out.text.contains("43 132") }
        XCTAssertTrue(out.text.contains("is-a-tty"), out.text)
        XCTAssertTrue(out.text.contains("has-controlling-tty"), out.text)
        XCTAssertTrue(out.text.contains("43 132"), out.text)
    }

    func testTypingAndResizing() throws {
        let (process, out) = try run(#"read line; echo "got:$line"; read again; stty size"#)
        process.write("hello\n")
        until { out.text.contains("got:hello") }
        XCTAssertTrue(out.text.contains("got:hello"), out.text)
        process.resize(.init(columns: 100, rows: 30))
        process.write("\n")
        until { out.text.contains("30 100") }
        XCTAssertTrue(out.text.contains("30 100"), out.text)
    }

    func testHangingUpEndsTheProgram() throws {
        let (process, out) = try run("echo ready; sleep 60")
        until { out.text.contains("ready") }
        process.terminate()
        until { out.status != nil }
        XCTAssertEqual(out.status, 128 + 1, "ended by the hang-up signal")
    }

    func testAProgramThatIsNotThere() {
        XCTAssertThrowsError(try PtyProcess(executable: "/nonexistent/program", environment: [:], onOutput: { _ in }, onExit: { _ in }))
    }
}
