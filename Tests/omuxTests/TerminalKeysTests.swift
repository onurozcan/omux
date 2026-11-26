import AppKit
import XCTest
@testable import omux

final class TerminalKeysTests: XCTestCase {
    private let left = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private let right = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    func testLineEditingKeys() {
        XCTAssertEqual(TermView.commandKey("\u{7f}", .command), .send([0x15]))
        XCTAssertEqual(TermView.commandKey(left, .command), .send([0x01]))
        XCTAssertEqual(TermView.commandKey(right, .command), .send([0x05]))
        // Arrow events also carry the function and numeric pad flags.
        XCTAssertEqual(TermView.commandKey(left, [.command, .function, .numericPad]), .send([0x01]))
    }

    func testOtherModifiersLeaveLineKeysAlone() {
        for key in ["\u{7f}", left, right] {
            for extra: NSEvent.ModifierFlags in [.option, .control, .shift] {
                XCTAssertNil(TermView.commandKey(key, [.command, extra]))
            }
            XCTAssertNil(TermView.commandKey(key, []))
        }
        XCTAssertNil(TermView.commandKey("a", .command))
        XCTAssertNil(TermView.commandKey("k", .command))
        XCTAssertNil(TermView.commandKey(nil, .command))
    }

    func testFindKeys() {
        XCTAssertEqual(TermView.commandKey("f", .command), .find(.showFindPanel))
        XCTAssertEqual(TermView.commandKey("g", .command), .find(.next))
        XCTAssertEqual(TermView.commandKey("G", [.command, .shift]), .find(.previous))
        XCTAssertNil(TermView.commandKey("f", [.command, .option]))
        XCTAssertNil(TermView.commandKey("f", [.command, .shift]))
        XCTAssertNil(TermView.commandKey("g", [.command, .control]))
    }

    @MainActor
    func testClearHistoryEmptiesScreenAndScrollback() {
        let view = TermView(tabID: UUID())
        view.feed(text: (1 ... 200).map { "line \($0)" }.joined(separator: "\r\n"))
        XCTAssertTrue(view.canScroll)
        XCTAssertEqual(view.lastLines(1), ["line 200"])
        view.clearHistory()
        XCTAssertFalse(view.canScroll)
        XCTAssertEqual(view.lastLines(300), [])
    }
}
