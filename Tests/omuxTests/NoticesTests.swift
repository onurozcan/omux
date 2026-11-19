import XCTest
@testable import omux
@testable import OmuxCore

@MainActor
final class NoticesTests: XCTestCase {
    func testResultsGoAwayAndErrorsStay() async throws {
        let notices = Notices(resultLifetime: .milliseconds(50))
        notices.post("Pushed", detail: "", isError: false)
        notices.post("Couldn't push", detail: "rejected\n", isError: true)
        XCTAssertEqual(notices.list.count, 2)
        XCTAssertEqual(notices.list.last?.detail, "rejected")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(notices.list.map(\.title), ["Couldn't push"])
    }

    func testSameErrorDoesNotStack() {
        let notices = Notices()
        notices.post("Couldn't push", detail: "rejected", isError: true)
        notices.post("Couldn't push", detail: "rejected", isError: true)
        XCTAssertEqual(notices.list.count, 1)
        notices.dismiss(notices.list[0])
        XCTAssertTrue(notices.list.isEmpty)
    }
}
