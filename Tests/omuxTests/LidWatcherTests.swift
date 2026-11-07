import XCTest
@testable import omux

final class LidWatcherTests: XCTestCase {
    /// Slow reads while the lid rests, at any angle; quick ones while it moves.
    func testReadsQuicklyOnlyWhileTheLidMoves() {
        XCTAssertEqual(LidWatcher.interval(angle: 95, previous: 95.4), 0.25)
        XCTAssertEqual(LidWatcher.interval(angle: 60, previous: 60), 0.25)
        XCTAssertEqual(LidWatcher.interval(angle: 110, previous: 118), 0.05)
        XCTAssertEqual(LidWatcher.interval(angle: 110, previous: nil), 0.05)
        XCTAssertEqual(LidWatcher.interval(angle: nil, previous: 110), 1)
    }
}
