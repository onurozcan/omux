import XCTest
@testable import omux

/// The conversation a session's `claude` is on, which its transcript and its subagents follow.
final class LiveSessionTests: XCTestCase {
    /// KERN_PROCARGS2 as macOS lays it out: argc, the executable's path padded with NULs, the
    /// arguments, then the environment up to an empty string.
    private func procargs(arguments: [String], environment: [String]) -> [UInt8] {
        var argc = Int32(arguments.count)
        var bytes = withUnsafeBytes(of: &argc) { Array($0) }
        bytes += Array("/usr/local/bin/claude".utf8) + [0, 0, 0, 0]
        for string in arguments + environment { bytes += Array(string.utf8) + [0] }
        return bytes + [0, 0, 0]
    }

    func testReadsTheEnvironmentAfterTheArguments() {
        let bytes = procargs(arguments: ["claude", "", "--resume", "a1b2"],
                             environment: ["HOME=/Users/me", "CLAUDE_CONFIG_DIR=/Users/me/.claude-work", "EMPTY="])
        let parsed = Store.processArguments(bytes)
        XCTAssertEqual(parsed.arguments, ["claude", "", "--resume", "a1b2"])
        XCTAssertEqual(parsed.environment["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-work")
        XCTAssertEqual(parsed.environment["HOME"], "/Users/me")
        XCTAssertEqual(parsed.environment["EMPTY"], "")
    }

    func testTruncatedRecordGivesWhatItHas() {
        XCTAssertTrue(Store.processArguments([1, 0]).arguments.isEmpty)
        let cut = Array(procargs(arguments: ["claude"], environment: ["A=1"]).prefix(30))
        XCTAssertTrue(Store.processArguments(cut).environment.isEmpty)
    }

    func testTheRecordIsInTheProcesssConfigFolder() {
        XCTAssertEqual(Store.claudePidFile(42, configDirectory: nil, home: "/Users/me"), "/Users/me/.claude/sessions/42.json")
        XCTAssertEqual(Store.claudePidFile(42, configDirectory: "", home: "/Users/me"), "/Users/me/.claude/sessions/42.json")
        XCTAssertEqual(Store.claudePidFile(42, configDirectory: "/Users/me/.claude-work", home: "/Users/me"),
                       "/Users/me/.claude-work/sessions/42.json")
        XCTAssertTrue(Store.claudePidFile(42, configDirectory: "~/.claude-work", home: "/Users/me").hasSuffix("/.claude-work/sessions/42.json"))
    }

    /// The case in #88: `claude --resume` typed into the session put it on another conversation,
    /// and the subagents were still looked for under the id omux had started it with.
    func testSubagentsAreReadFromTheConversationClaudeIsOn() {
        let project = URL(fileURLWithPath: "/projects/app")
        let transcripts = ["resumed": URL(fileURLWithPath: "/projects/other/resumed.jsonl")]
        let resumed = Store.claudeConversation(pinned: "pinned", live: ["resumed"], project: project, lookup: { transcripts[$0] })
        XCTAssertEqual(resumed.session, "resumed")
        XCTAssertEqual(resumed.project?.path, "/projects/other")
        // Not written yet: the session's own conversation, in its own folder.
        let fresh = Store.claudeConversation(pinned: "pinned", live: ["unwritten"], project: project, lookup: { transcripts[$0] })
        XCTAssertEqual(fresh.session, "pinned")
        XCTAssertEqual(fresh.project, project)
        // On its own conversation, or with no `claude` running: unchanged.
        for live in [["pinned"], []] {
            let own = Store.claudeConversation(pinned: "pinned", live: live, project: project, lookup: { _ in URL(fileURLWithPath: "/x/pinned.jsonl") })
            XCTAssertEqual(own.session, "pinned")
            XCTAssertEqual(own.project, project)
        }
    }

    /// Also #88: `claude` ran with CLAUDE_CONFIG_DIR set, so its record was not under ~/.claude.
    func testReadsTheSessionOfARecordInAnotherConfigFolder() throws {
        let config = FileManager.default.temporaryDirectory.appendingPathComponent("omux-config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: config) }
        try FileManager.default.createDirectory(at: config.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let record = #"{"pid":42,"sessionId":"AB12CD34-0000-4000-8000-000000000001","kind":"interactive"}"#
        try Data(record.utf8).write(to: config.appendingPathComponent("sessions/42.json"))
        let path = Store.claudePidFile(42, configDirectory: config.path, home: "/nowhere")
        XCTAssertEqual(Store.claudeSessionID(pidFile: path), "ab12cd34-0000-4000-8000-000000000001")
        XCTAssertNil(Store.claudeSessionID(pidFile: Store.claudePidFile(42, configDirectory: nil, home: "/nowhere")))
        // The id becomes part of a path: a record that names something else is no session.
        try Data(#"{"sessionId":"../../outside"}"#.utf8).write(to: config.appendingPathComponent("sessions/43.json"))
        XCTAssertNil(Store.claudeSessionID(pidFile: Store.claudePidFile(43, configDirectory: config.path, home: "/nowhere")))
    }
}
