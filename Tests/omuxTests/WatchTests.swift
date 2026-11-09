import XCTest
@testable import omux

/// The transcript and subagent readers follow their files through vnode events, with timers
/// only as a ten-second safety net; these tests would take that long if the watchers failed.
final class WatchTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omux-watch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func record(_ text: String) -> String {
        #"{"type":"user","timestamp":"2026-11-09T10:00:00.000Z","message":{"role":"user","content":"\#(text)"}}"# + "\n"
    }

    @MainActor
    private func until(_ deadline: Duration = .seconds(3), _ holds: () -> Bool) async throws {
        let end = ContinuousClock.now + deadline
        while !holds(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor
    func testAFileWatcherWakesOnAppendsAndAFolderWatcherOnNewEntries() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "".write(to: file, atomically: true, encoding: .utf8)
        var fileEvents = 0, folderEvents = 0
        let fileWatcher = PathWatcher(path: file.path) { fileEvents += 1 }
        let folderWatcher = PathWatcher(path: dir.path, directory: true) { folderEvents += 1 }
        XCTAssertNotNil(fileWatcher); XCTAssertNotNil(folderWatcher)
        XCTAssertNil(PathWatcher(path: dir.appendingPathComponent("missing").path) {})

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("hello\n".utf8)); try handle.close()
        try await until { fileEvents > 0 }
        XCTAssertGreaterThan(fileEvents, 0)
        XCTAssertEqual(folderEvents, 0, "writing inside a file is not a change to the folder's entries")

        try "".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await until { folderEvents > 0 }
        XCTAssertGreaterThan(folderEvents, 0)
        _ = fileWatcher; _ = folderWatcher
    }

    /// A new session has no transcript until its first prompt: the model waits on the project
    /// folder and reads the file the moment it appears.
    @MainActor
    func testATranscriptThatAppearsLaterIsReadAtOnce() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("session.jsonl")
        let model = SessionTranscript(tab: TabItem(name: "t"), provider: .claude,
                                      claudeFile: { FileManager.default.fileExists(atPath: file.path) ? file : nil },
                                      claudeFolder: { dir }, codexThread: { nil })
        try await until { model.loaded }
        XCTAssertEqual(model.notice, "No conversation yet. Send the first message below.")
        XCTAssertTrue(model.blocks.isEmpty)

        try record("first prompt").write(to: file, atomically: true, encoding: .utf8)
        try await until { model.blocks.contains { $0.text == "first prompt" } }
        XCTAssertEqual(model.blocks.map(\.text), ["first prompt"])
        XCTAssertNil(model.notice)

        // Appends to the file itself follow too.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(record("second").utf8)); try handle.close()
        try await until { model.blocks.count == 2 }
        XCTAssertEqual(model.blocks.last?.text, "second")
    }

    /// /clear makes Claude Code write a new file: the model follows it when the folder changes.
    @MainActor
    func testANewConversationFileIsFollowed() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = dir.appendingPathComponent("one.jsonl")
        let second = dir.appendingPathComponent("two.jsonl")
        try record("old").write(to: first, atomically: true, encoding: .utf8)
        var current = first
        let model = SessionTranscript(tab: TabItem(name: "t"), provider: .claude, claudeFile: { current }, claudeFolder: { dir }, codexThread: { nil })
        try await until { model.blocks.count == 1 }
        XCTAssertEqual(model.blocks.first?.text, "old")

        current = second
        try record("fresh").write(to: second, atomically: true, encoding: .utf8)
        try await until { model.blocks.contains { $0.text == "fresh" } }
        XCTAssertTrue(model.blocks.contains { $0.kind == .note && $0.text == "New conversation" })
        XCTAssertEqual(model.blocks.last?.text, "fresh")
    }

    /// A subagent's own transcript view follows its file.
    @MainActor
    func testASubagentTranscriptFollowsItsFile() async throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent.jsonl")
        try record("Audit the parser").write(to: file, atomically: true, encoding: .utf8)
        let transcript = AgentTranscript(url: file)
        try await until { transcript.entries.count == 1 }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."}]}}"# + "\n").utf8))
        try handle.close()
        try await until { transcript.entries.count == 2 }
        XCTAssertEqual(transcript.entries.last?.title, "Looking.")
    }
}
