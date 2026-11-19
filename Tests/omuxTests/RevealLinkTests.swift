import XCTest
@testable import omux
@testable import OmuxCore

final class RevealLinkTests: XCTestCase {
    func testParsesEachKindOfLink() throws {
        let id = UUID()
        XCTAssertEqual(RevealLink(URL(string: "omux://reveal?tab=\(id.uuidString)")!), .tab(id))
        XCTAssertEqual(RevealLink(URL(string: "omux://reveal?claude-session=\(id.uuidString.lowercased())")!), .claudeSession(id))
        XCTAssertEqual(RevealLink(URL(string: "omux://reveal?codex-thread=019a-thread")!), .codexThread("019a-thread"))
    }

    /// Anything else is ignored rather than guessed at.
    func testRejectsOtherLinks() {
        XCTAssertNil(RevealLink(URL(string: "omux://reveal")!))
        XCTAssertNil(RevealLink(URL(string: "omux://reveal?tab=not-a-uuid")!))
        XCTAssertNil(RevealLink(URL(string: "omux://reveal?codex-thread=")!))
        XCTAssertNil(RevealLink(URL(string: "omux://send?tab=\(UUID().uuidString)")!))
        XCTAssertNil(RevealLink(URL(string: "https://reveal?tab=\(UUID().uuidString)")!))
    }
}
