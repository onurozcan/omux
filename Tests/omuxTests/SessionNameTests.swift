import XCTest
@testable import omux
@testable import OmuxCore

final class SessionNameTests: XCTestCase {
    func testTopicDropsClaudeCodeStatusGlyph() {
        XCTAssertEqual(TabItem.name(fromTitle: "✳ Fix login bug"), "Fix login bug")
        XCTAssertEqual(TabItem.name(fromTitle: "⠂ Fix login bug"), "Fix login bug")
        XCTAssertEqual(TabItem.name(fromTitle: "Oturum adları"), "Oturum adları")
        XCTAssertEqual(TabItem.name(fromTitle: "✳ 3D viewer"), "3D viewer")
    }

    func testTitlesThatAreNotATopicAreIgnored() {
        XCTAssertNil(TabItem.name(fromTitle: ""))
        XCTAssertNil(TabItem.name(fromTitle: "✳"))
        XCTAssertNil(TabItem.name(fromTitle: "✳ Claude Code"))
        XCTAssertNil(TabItem.name(fromTitle: "claude"))
        XCTAssertNil(TabItem.name(fromTitle: String(repeating: "a", count: 81)))
    }

    func testOnlyMadeUpNamesFollowTheTitle() {
        XCTAssertTrue(TabItem(name: "Session 3").autoName)
        XCTAssertTrue(TabItem(name: "Session").autoName)
        XCTAssertFalse(TabItem(name: "API work").autoName)
        XCTAssertFalse(TabItem(name: "Session 3 notes").autoName)
    }

    func testSavedWorkspacesDecodeAutoName() throws {
        let decode = { (json: String) in try JSONDecoder().decode(TabItem.self, from: Data(json.utf8)) }
        XCTAssertTrue(try decode(#"{"name":"Session 2"}"#).autoName)
        XCTAssertFalse(try decode(#"{"name":"Renamed"}"#).autoName)
        XCTAssertFalse(try decode(#"{"name":"Fix login bug","autoName":false}"#).autoName)
        XCTAssertTrue(try decode(#"{"name":"Fix login bug","autoName":true}"#).autoName)
        let tab = try decode(#"{"name":"Fix login bug","autoName":true}"#)
        XCTAssertTrue(try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(tab)).autoName)
    }
}
