import XCTest
@testable import omux
@testable import OmuxCore

final class RecentSessionsTests: XCTestCase {
    /// After a skill's slash command, Claude Code writes the skill's instructions as an isMeta
    /// user record; that isn't what the user asked, so it isn't the session's title.
    func testSkillInstructionsAreNotThePrompt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let project = home + "/.claude/projects/-tmp-x"
        try FileManager.default.createDirectory(atPath: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let skill = UUID(), metaOnly = UUID()
        let command = #"{"type":"user","cwd":"/tmp/x","message":{"content":"<command-name>/audit</command-name>"}}"#
        let meta = #"{"type":"user","cwd":"/tmp/x","isMeta":true,"message":{"content":[{"type":"text","text":"Base directory for this skill: /x"}]}}"#
        let prompt = #"{"type":"user","cwd":"/tmp/x","message":{"content":"keep the diff small"}}"#
        try [command, meta, prompt].joined(separator: "\n")
            .write(toFile: "\(project)/\(skill.uuidString.lowercased()).jsonl", atomically: true, encoding: .utf8)
        try [command, meta].joined(separator: "\n")
            .write(toFile: "\(project)/\(metaOnly.uuidString.lowercased()).jsonl", atomically: true, encoding: .utf8)
        setenv("CFFIXED_USER_HOME", home, 1)
        defer { unsetenv("CFFIXED_USER_HOME") }
        let prompts = Dictionary(uniqueKeysWithValues: RecentSession.load().map { ($0.id, $0.prompt) })
        XCTAssertEqual(prompts[skill], "keep the diff small")
        // Nothing typed: the session is still listed, under the only text there is.
        XCTAssertEqual(prompts[metaOnly], "Base directory for this skill: /x")
    }
}
