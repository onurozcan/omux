import XCTest
@testable import OmuxHostKit

/// A session's Claude Code files copied to another folder as they grow, the way the app
/// keeps a remote conversation beside it.
final class MirrorTests: XCTestCase {
    private var source: URL!
    private var copy: URL!
    private let session = "0b1c2d3e-0000-4000-8000-000000000001"

    override func setUp() {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("omux-mirror-\(UUID().uuidString)")
        source = base.appendingPathComponent("there"); copy = base.appendingPathComponent("here")
        try? FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }

    private func append(_ text: String, to path: String) throws {
        let file = source.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
    }

    private func read(_ path: String) -> String? { try? String(contentsOf: copy.appendingPathComponent(path), encoding: .utf8) }

    /// One look at the source, applied to the copy; returns how many updates it took.
    @discardableResult
    private func sync(_ sent: inout [String: UInt64]) throws -> Int {
        var updates: [Mirror.Update] = []
        _ = Mirror.pass(root: source.path, session: session, sent: &sent) { updates.append($0); return true }
        // Through the wire, as they travel.
        for update in updates { try Mirror.apply(Wire.decode(Mirror.Update.self, from: Wire.encode(update).dropFirst(4)), to: copy) }
        return updates.count
    }

    func testTheTranscriptAndItsSubagentsFollowTheSource() throws {
        var sent: [String: UInt64] = [:]
        try append("{\"a\":1}\n", to: "\(session).jsonl")
        try append("other session\n", to: "ffffffff-0000-4000-8000-000000000002.jsonl")
        try sync(&sent)
        XCTAssertEqual(read("\(session).jsonl"), "{\"a\":1}\n")
        XCTAssertNil(read("ffffffff-0000-4000-8000-000000000002.jsonl"), "only this session's files")

        try append("{\"b\":2}\n", to: "\(session).jsonl")
        try append("{\"agent\":true}", to: "\(session)/subagents/agent-1.meta.json")
        try append("{\"t\":1}\n", to: "\(session)/subagents/agent-1.jsonl")
        XCTAssertEqual(try sync(&sent), 3, "one piece per file that grew")
        XCTAssertEqual(read("\(session).jsonl"), "{\"a\":1}\n{\"b\":2}\n")
        XCTAssertEqual(read("\(session)/subagents/agent-1.meta.json"), "{\"agent\":true}")
        XCTAssertEqual(try sync(&sent), 0, "nothing new, nothing sent")
    }

    func testAReconnectSendsOnlyWhatTheCopyLacks() throws {
        var sent: [String: UInt64] = [:]
        try append("one\n", to: "\(session).jsonl")
        try sync(&sent)
        try append("two\n", to: "\(session).jsonl")
        // A new connection: all it knows is what the copy holds.
        var again = Mirror.have(in: copy, session: session).sizes
        XCTAssertEqual(again, ["\(session).jsonl": 4])
        var updates: [Mirror.Update] = []
        _ = Mirror.pass(root: source.path, session: session, sent: &again) { updates.append($0); return true }
        XCTAssertEqual(updates, [.data(path: "\(session).jsonl", offset: 4, data: Data("two\n".utf8))])
    }

    func testAFileThatStartsOverIsStartedOver() throws {
        var sent: [String: UInt64] = [:]
        try append("a long first version\n", to: "\(session).jsonl")
        try sync(&sent)
        try Data("short\n".utf8).write(to: source.appendingPathComponent("\(session).jsonl"))
        try sync(&sent)
        XCTAssertEqual(read("\(session).jsonl"), "short\n")
    }

    func testAPieceSentTwiceLandsOnceAndNothingLeavesTheFolder() throws {
        let piece = Mirror.Update.data(path: "\(session).jsonl", offset: 0, data: Data("once\n".utf8))
        try Mirror.apply(piece, to: copy); try Mirror.apply(piece, to: copy)
        XCTAssertEqual(read("\(session).jsonl"), "once\n")
        XCTAssertThrowsError(try Mirror.apply(.data(path: "../escaped.txt", offset: 0, data: Data("x".utf8)), to: copy))
        XCTAssertThrowsError(try Mirror.apply(.data(path: "/tmp/escaped.txt", offset: 0, data: Data("x".utf8)), to: copy))
    }

    func testServingStopsWhenTheOtherSideIsGone() throws {
        try append("x\n", to: "\(session).jsonl")
        var seen: [Mirror.Update] = []
        Mirror.serve(root: source.path, session: session, interval: 0.01) { seen.append($0); return seen.count < 2 }
        XCTAssertEqual(seen.last, .synced)
    }
}
