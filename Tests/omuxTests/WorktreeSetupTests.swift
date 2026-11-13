import XCTest
@testable import omux
@testable import OmuxCore

final class WorktreeSetupTests: XCTestCase {
    func testSessionStartsOnlyAfterSetupSucceeds() {
        XCTAssertEqual(Store.afterSetup("npm install", "claude"), "npm install && claude")
        XCTAssertEqual(Store.afterSetup("npm install", nil), "npm install")
    }

    /// "x; && claude" and "x & && claude" are parse errors: neither the setup nor the session ran.
    func testTrailingSeparatorsStillParse() {
        XCTAssertEqual(Store.afterSetup("cp \"$OMUX_REPO/.env\" .;", "claude"), "cp \"$OMUX_REPO/.env\" . && claude")
        XCTAssertEqual(Store.afterSetup("npm i ; ; ", "claude"), "npm i && claude")
        XCTAssertEqual(Store.afterSetup("npm run dev &", "claude"), "npm run dev & claude")
        XCTAssertEqual(Store.afterSetup("a && b", "claude"), "a && b && claude")
        XCTAssertEqual(Store.afterSetup("find . -exec touch {} \\;", "claude"), "find . -exec touch {} \\; && claude")
    }
}
