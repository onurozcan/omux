import XCTest
@testable import omux

final class ThemeTests: XCTestCase {
    func testEveryThemeHasSixteenColours() {
        for theme in Theme.allCases { XCTAssertEqual(theme.palette.count, 16, theme.label) }
    }

    func testVesperIsDark() {
        XCTAssertTrue(Theme.darkThemes.contains(.vesper))
        XCTAssertEqual(Theme.vesper.label, "Vesper")
    }
}
