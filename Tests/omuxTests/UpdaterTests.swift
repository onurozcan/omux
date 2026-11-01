import XCTest
@testable import omux

final class UpdaterTests: XCTestCase {
    private let keys = ["SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for key in keys { saved[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))  // lets the mirrored values settle first
        for key in keys { UserDefaults.standard.set(saved[key], forKey: key) }
    }

    @MainActor
    private func until(_ done: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !done(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    /// The settings write Sparkle's own preferences, and follow them when Sparkle changes them,
    /// as its update window's "Automatically download and install" box does.
    @MainActor
    func testSettingsFollowSparkle() {
        let updater = Updater.shared
        updater.automaticallyChecks = false
        XCTAssertFalse(updater.updater.automaticallyChecksForUpdates)
        updater.automaticallyChecks = true
        XCTAssertTrue(updater.updater.automaticallyChecksForUpdates)
        updater.automaticallyDownloads = true
        XCTAssertTrue(updater.updater.automaticallyDownloadsUpdates)

        updater.updater.automaticallyDownloadsUpdates = false
        XCTAssertTrue(until { !updater.automaticallyDownloads })
        updater.updater.automaticallyChecksForUpdates = false
        XCTAssertTrue(until { !updater.automaticallyChecks })
    }
}

final class QuitAlertTests: XCTestCase {
    @MainActor
    func testUpdateRelaunchSaysWhyAndCanWait() {
        let update = AppDelegate.quitAlert(running: 2, update: "0.9.2")
        XCTAssertEqual(update.messageText, "Relaunch to install omux 0.9.2?")
        XCTAssertTrue(update.informativeText.hasPrefix("2 sessions are running."))
        XCTAssertTrue(update.informativeText.contains("next time you quit"))
        XCTAssertEqual(update.buttons.map(\.title), ["Relaunch", "Later"])

        let quit = AppDelegate.quitAlert(running: 1, update: nil)
        XCTAssertEqual(quit.messageText, "Quit omux?")
        XCTAssertEqual(quit.informativeText, "1 session is running. Agent conversation IDs are saved so you can continue them next launch.")
        XCTAssertEqual(quit.buttons.map(\.title), ["Quit", "Cancel"])
    }
}
