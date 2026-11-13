import XCTest
@testable import omux
@testable import OmuxCore

final class AgentTranscriptTests: XCTestCase {
    @MainActor
    private func entries(_ lines: [String]) async throws -> [String] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let transcript = AgentTranscript(url: url)
        let end = ContinuousClock.now + .seconds(5)
        while transcript.entries.count < 2, ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
        return transcript.entries.map { "\($0.kind): \($0.title)" }
    }

    /// Claude Code's reminders are isMeta user records, not the agent's text.
    @MainActor
    func testMetaRecordsAreLeftOut() async throws {
        let shown = try await entries([
            #"{"type":"user","message":{"content":"Audit the parser"}}"#,
            #"{"type":"user","isMeta":true,"message":{"content":"<system-reminder>Report soon</system-reminder>"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."}]}}"#,
        ])
        XCTAssertEqual(shown, ["task: Audit the parser", "text: Looking."])
    }

    /// A fork's transcript opens with its parent's spawning call, then its directive next to that call's result.
    @MainActor
    func testForkShowsItsDirectiveAsTheTask() async throws {
        let shown = try await entries([
            #"{"type":"fork-context-ref"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"p1","name":"Agent","input":{"description":"Patch loans"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"p1","content":"Fork started"},{"type":"text","text":"<fork-boilerplate>\nshared\n</fork-boilerplate>\n\nFix the loan rounding"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"On it."}]}}"#,
        ])
        XCTAssertEqual(shown, ["task: Fix the loan rounding", "text: On it."])
    }
}
