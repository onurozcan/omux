import XCTest
@testable import omux

final class ClaudeTitleTests: XCTestCase {
    private func scan(_ lines: [String]) -> ClaudeTitle {
        var title = ClaudeTitle()
        title.scan(Data(lines.joined(separator: "\n").utf8))
        return title
    }

    func testLastCustomTitleWins() {
        let title = scan([
            #"{"type":"custom-title","customTitle":"first","sessionId":"s"}"#,
            #"{"type":"user","message":{"content":"hi"}}"#,
            #"{"type":"custom-title","customTitle":"second","sessionId":"s"}"#,
        ])
        XCTAssertEqual(title.best, "second")
    }

    func testAiTitleIsUsedWithoutRename() {
        let title = scan([#"{"type":"ai-title","aiTitle":"Fix login bug","sessionId":"s"}"#])
        XCTAssertNil(title.custom)
        XCTAssertEqual(title.best, "Fix login bug")
    }

    func testCustomTitleBeatsAiTitleInAnyOrder() {
        XCTAssertEqual(scan([
            #"{"type":"custom-title","customTitle":"mine","sessionId":"s"}"#,
            #"{"type":"ai-title","aiTitle":"auto","sessionId":"s"}"#,
        ]).best, "mine")
        XCTAssertEqual(scan([
            #"{"type":"ai-title","aiTitle":"auto","sessionId":"s"}"#,
            #"{"type":"custom-title","customTitle":"mine","sessionId":"s"}"#,
        ]).best, "mine")
    }

    func testNoTitleEmptyTitleAndBrokenLines() {
        XCTAssertNil(scan([#"{"type":"user"}"#]).best)
        XCTAssertNil(scan([#"{"type":"custom-title","customTitle":"   ","sessionId":"s"}"#]).best)
        XCTAssertEqual(scan([
            #"{"type":"ai-title","aiTitle":"ok","sessionId":"s"}"#,
            #"{"type":"custom-title","customTi"#,
        ]).best, "ok")
    }

    func testIncrementalScanKeepsEarlierTitles() {
        var title = ClaudeTitle()
        title.scan(Data(#"{"type":"custom-title","customTitle":"kept","sessionId":"s"}"#.utf8))
        title.scan(Data(#"{"type":"ai-title","aiTitle":"auto","sessionId":"s"}"#.utf8))
        XCTAssertEqual(title.best, "kept")
    }

    func testAiTitleReplacesOnlyDefaultOrSyncedNames() {
        let ai = ClaudeTitle(custom: nil, ai: "auto")
        XCTAssertEqual(ClaudeTitle.nameUpdate(tabName: "Session 3", lastApplied: nil, title: ai), "auto")
        XCTAssertEqual(ClaudeTitle.nameUpdate(tabName: "Session", lastApplied: nil, title: ai), "auto")
        XCTAssertEqual(ClaudeTitle.nameUpdate(tabName: "old auto", lastApplied: "old auto", title: ai), "auto")
        XCTAssertNil(ClaudeTitle.nameUpdate(tabName: "Typed by me", lastApplied: nil, title: ai))
        XCTAssertNil(ClaudeTitle.nameUpdate(tabName: "Typed by me", lastApplied: "old auto", title: ai))
        XCTAssertNil(ClaudeTitle.nameUpdate(tabName: "Session 3x", lastApplied: nil, title: ai))
    }

    func testRenameAppliesOnlyWhenItChanges() {
        let custom = ClaudeTitle(custom: "mine", ai: "auto")
        XCTAssertEqual(ClaudeTitle.nameUpdate(tabName: "Typed by me", lastApplied: nil, title: custom), "mine")
        // Renamed in omux after the sync: kept until Claude's title changes again.
        XCTAssertNil(ClaudeTitle.nameUpdate(tabName: "Typed later", lastApplied: "mine", title: custom))
        XCTAssertEqual(ClaudeTitle.nameUpdate(tabName: "Typed later", lastApplied: "mine",
                                              title: ClaudeTitle(custom: "newer", ai: nil)), "newer")
    }

    func testWorkspaceWithoutClaudeTitleDecodes() throws {
        let data = Data(#"{"tabs":[{"name":"Existing"}]}"#.utf8)
        let group = try JSONDecoder().decode(TabGroup.self, from: data)
        XCTAssertNil(group.tabs[0].claudeTitle)
        var tab = group.tabs[0]
        tab.claudeTitle = "mine"
        let round = try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(tab))
        XCTAssertEqual(round.claudeTitle, "mine")
    }
}
