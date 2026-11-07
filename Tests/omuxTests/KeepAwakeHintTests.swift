import XCTest
@testable import omux

final class KeepAwakeHintTests: XCTestCase {
    func testHintOnlyOnceAndOnlyWhenOff() {
        XCTAssertNotNil(SleepHint.message(agents: 2, enabled: false, shown: false))
        XCTAssertNil(SleepHint.message(agents: 2, enabled: false, shown: true))
        XCTAssertNil(SleepHint.message(agents: 2, enabled: true, shown: false))
        XCTAssertNil(SleepHint.message(agents: 0, enabled: false, shown: false))
    }

    func testHintPluralization() {
        XCTAssertEqual(SleepHint.message(agents: 1, enabled: false, shown: false)?.title,
                       "Your Mac slept while an agent was working")
        XCTAssertEqual(SleepHint.message(agents: 3, enabled: false, shown: false)?.title,
                       "Your Mac slept while 3 agents were working")
        XCTAssertEqual(SleepHint.message(agents: 3, enabled: false, shown: false)?.detail,
                       "Settings › Sessions › Keep Awake can keep it awake while agents work, even with the lid closed.")
    }
}
