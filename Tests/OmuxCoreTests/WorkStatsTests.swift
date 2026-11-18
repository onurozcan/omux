import XCTest
@testable import OmuxCore

final class WorkStatsTests: XCTestCase {
    func testParseTitlePromptsAndSpans() throws {
        let lines = [
            #"{"type":"permission-mode","sessionId":"s"}"#,
            #"{"type":"user","isSidechain":false,"cwd":"/p/app","gitBranch":"main","timestamp":"2026-11-17T09:00:00.000Z","message":{"role":"user","content":"Fix the login bug"}}"#,
            #"{"type":"assistant","isSidechain":false,"cwd":"/p/app","timestamp":"2026-11-17T09:04:00.000Z","message":{"content":[{"type":"text","text":"ok"}]}}"#,
            #"{"type":"user","isSidechain":false,"cwd":"/p/app","timestamp":"2026-11-17T09:05:00.000Z","message":{"content":[{"type":"tool_result","content":"x"}]}}"#,
            #"{"type":"user","isSidechain":true,"cwd":"/p/app","timestamp":"2026-11-17T12:00:00.000Z","message":{"content":"sub"}}"#,
            #"{"type":"user","isSidechain":false,"cwd":"/p/app","timestamp":"2026-11-17T11:00:00.000Z","message":{"content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"ai-title","aiTitle":"Login bug fix"}"#,
        ]
        let session = try XCTUnwrap(WorkStats.parse(Data(lines.joined(separator: "\n").utf8), id: "s"))
        XCTAssertEqual(session.title, "Login bug fix")
        XCTAssertEqual(session.cwd, "/p/app")
        XCTAssertEqual(session.branch, "main")
        XCTAssertEqual(session.prompts.map(\.text), ["Fix the login bug"])
        // 09:00–09:05 is one stretch; 11:00 alone is a minute; the sidechain doesn't count.
        XCTAssertEqual(session.spans.count, 2)
        XCTAssertEqual(session.activeTime, 5 * 60 + 60, accuracy: 0.001)
    }

    func testBookkeepingOnlyIsNil() {
        XCTAssertNil(WorkStats.parse(Data(#"{"type":"last-prompt","sessionId":"s"}"#.utf8), id: "s"))
    }

    func testUnionAndPerDaySplitAtMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let base = Date(timeIntervalSince1970: 1_800_000_000) // some UTC time
        let day = calendar.startOfDay(for: base)
        let a = WorkSpan(start: day.addingTimeInterval(23 * 3600), end: day.addingTimeInterval(25 * 3600))
        let b = WorkSpan(start: day.addingTimeInterval(23.5 * 3600), end: day.addingTimeInterval(24.5 * 3600))
        let union = WorkStats.union([b, a])
        XCTAssertEqual(union.count, 1)
        let perDay = WorkStats.perDay(union, calendar: calendar)
        XCTAssertEqual(perDay[day], 3600)
        XCTAssertEqual(perDay[day.addingTimeInterval(86400)], 3600)
    }

    func testHugeLineGivesItsTimestamp() throws {
        let big = String(repeating: "a", count: 70_000)
        let lines = [
            #"{"type":"user","cwd":"/p","timestamp":"2026-11-17T09:00:00.000Z","message":{"content":"hi"}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"\#(big) \"timestamp\":\"1999-01-01T00:00:00.000Z\""}]},"timestamp":"2026-11-17T09:03:00.000Z"}"#,
        ]
        let session = try XCTUnwrap(WorkStats.parse(Data(lines.joined(separator: "\n").utf8), id: "s"))
        XCTAssertEqual(session.activeTime, 180, accuracy: 0.001)
    }

    func testPastedContentIsAMark() {
        let message: [String: Any] = ["content": "fix prices <pasted_content id=\"1\">A\nB</pasted_content> please"]
        XCTAssertEqual(WorkStats.promptText(message), "fix prices [pasted text] please")
        XCTAssertEqual(WorkStats.promptText(["content": "see <pasted_content id=\"2\"> cut off"]), "see [pasted text]")
    }
}
