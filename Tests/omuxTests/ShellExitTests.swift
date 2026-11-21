import XCTest
@testable import omux

final class ShellExitTests: XCTestCase {
    /// `exit` or Ctrl-D in a local session's shell closes its tab, as in Terminal.app.
    func testCleanExitClosesTheTab() {
        XCTAssertTrue(Store.closesOnExit(code: 0, killed: false, remote: false, worktree: false))
    }

    /// Everything else keeps the tab, stopped, with its output to read.
    func testOtherEndingsKeepTheTab() {
        XCTAssertFalse(Store.closesOnExit(code: 1, killed: false, remote: false, worktree: false))
        XCTAssertFalse(Store.closesOnExit(code: nil, killed: false, remote: false, worktree: false))
        XCTAssertFalse(Store.closesOnExit(code: 0, killed: true, remote: false, worktree: false))
        XCTAssertFalse(Store.closesOnExit(code: 0, killed: false, remote: true, worktree: false))
        XCTAssertFalse(Store.closesOnExit(code: 0, killed: false, remote: false, worktree: true))
    }
}
