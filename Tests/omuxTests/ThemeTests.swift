import AppKit
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

    func testResolveManualIgnoresSystemAppearance() {
        XCTAssertEqual(
            Theme.resolve(followSystem: false, manual: Theme.dracula.rawValue, dark: Theme.nord.rawValue,
                          light: Theme.githubLight.rawValue, systemIsDark: false),
            .dracula
        )
        XCTAssertEqual(
            Theme.resolve(followSystem: false, manual: Theme.solarizedLight.rawValue, dark: Theme.nord.rawValue,
                          light: Theme.githubLight.rawValue, systemIsDark: true),
            .solarizedLight
        )
        XCTAssertEqual(
            Theme.resolve(followSystem: false, manual: "nonexistent", dark: Theme.nord.rawValue,
                          light: Theme.githubLight.rawValue, systemIsDark: false),
            .black
        )
    }

    func testResolveFollowsSystemAppearance() {
        XCTAssertEqual(
            Theme.resolve(followSystem: true, manual: Theme.light.rawValue, dark: Theme.catppuccin.rawValue,
                          light: Theme.catppuccinLatte.rawValue, systemIsDark: true),
            .catppuccin
        )
        XCTAssertEqual(
            Theme.resolve(followSystem: true, manual: Theme.black.rawValue, dark: Theme.catppuccin.rawValue,
                          light: Theme.catppuccinLatte.rawValue, systemIsDark: false),
            .catppuccinLatte
        )
    }

    func testResolveFallsBackWhenPolarityMismatches() {
        XCTAssertEqual(
            Theme.resolve(followSystem: true, manual: Theme.black.rawValue, dark: Theme.light.rawValue,
                          light: Theme.githubLight.rawValue, systemIsDark: true),
            .black
        )
        XCTAssertEqual(
            Theme.resolve(followSystem: true, manual: Theme.black.rawValue, dark: Theme.dracula.rawValue,
                          light: Theme.dracula.rawValue, systemIsDark: false),
            .light
        )
    }

    func testCounterpartPairsMatchingThemes() {
        XCTAssertEqual(Theme.catppuccin.counterpart, .catppuccinLatte)
        XCTAssertEqual(Theme.catppuccinLatte.counterpart, .catppuccin)
        XCTAssertEqual(Theme.solarizedDark.counterpart, .solarizedLight)
        XCTAssertEqual(Theme.solarizedLight.counterpart, .solarizedDark)
        XCTAssertEqual(Theme.midnight.counterpart, .githubLight)
        XCTAssertEqual(Theme.githubLight.counterpart, .midnight)
        XCTAssertEqual(Theme.dracula.counterpart, .light)
        XCTAssertEqual(Theme.light.counterpart, .black)
    }

    func testSystemAppearanceDetectsAquaAndDarkAqua() {
        XCTAssertTrue(SystemAppearance.isDark(NSAppearance(named: .darkAqua)))
        XCTAssertFalse(SystemAppearance.isDark(NSAppearance(named: .aqua)))
    }
}
