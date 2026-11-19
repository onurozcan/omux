import XCTest
@testable import omux
@testable import OmuxCore

final class FontSizeTests: XCTestCase {
    func testBiggerKey() {
        XCTAssertTrue(Fonts.isBiggerKey("=", .command))
        XCTAssertTrue(Fonts.isBiggerKey("=", [.command, .shift]))
        XCTAssertFalse(Fonts.isBiggerKey("=", []))
        XCTAssertFalse(Fonts.isBiggerKey("=", [.command, .option]))
        XCTAssertFalse(Fonts.isBiggerKey("-", .command))
    }

    func testSizeStaysInRange() {
        let stored = UserDefaults.standard.object(forKey: Prefs.fontSize)
        defer { UserDefaults.standard.set(stored, forKey: Prefs.fontSize) }
        Fonts.adjustSize(by: nil)
        XCTAssertEqual(Fonts.size, Fonts.defaultSize)
        Fonts.adjustSize(by: 100)
        XCTAssertEqual(Fonts.size, Fonts.sizes.upperBound)
        Fonts.adjustSize(by: -100)
        XCTAssertEqual(Fonts.size, Fonts.sizes.lowerBound)
    }
}
