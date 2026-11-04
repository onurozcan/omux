import ServiceManagement
import XCTest
@testable import omux

@MainActor
final class KeepAwakeTests: XCTestCase {
    final class FakeHelper: AwakeHelper {
        var holds = 0
        var releases = 0
        var answers: [Bool] = []
        func hold(lease: TimeInterval) async -> Bool {
            holds += 1
            return answers.isEmpty ? true : answers.removeFirst()
        }
        func release() async { releases += 1 }
        func disconnect() {}
    }

    var defaults: UserDefaults!
    var now = Date(timeIntervalSince1970: 3_000_000)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "KeepAwakeTests-\(UUID().uuidString)")
        defaults.set(true, forKey: Prefs.keepAwake)
    }

    func make(_ helper: FakeHelper) -> KeepAwake {
        let env = KeepAwake.Environment(now: { [unowned self] in self.now }, thermal: { .nominal },
                                        power: { (onBattery: true, percent: 80) })
        return KeepAwake(helper: helper, service: nil, defaults: defaults, environment: env)
    }

    func working() -> [UUID: TabRuntime] {
        var tab = TabRuntime()
        tab.provider = .claude
        tab.statusState = .working
        return [UUID(): tab]
    }

    func settle() async { for _ in 0 ..< 5 { await Task.yield() } }

    func testHoldsAndRenews() async {
        let helper = FakeHelper()
        let awake = make(helper)
        awake.update(runtime: working())
        await settle()
        XCTAssertTrue(awake.isHolding)
        XCTAssertTrue(awake.holdsAssertion)
        XCTAssertEqual(helper.holds, 1)
        // The limit only counts once the screen is dark.
        XCTAssertNil(awake.remaining)
        awake.setCurtainDark(true)
        await settle()
        // Re-deciding without a renewal doesn't ask the helper again.
        awake.evaluate()
        await settle()
        XCTAssertEqual(helper.holds, 1)
        now += 30
        awake.evaluate(renew: true)
        await settle()
        XCTAssertEqual(helper.holds, 2)
        awake.setCurtainDark(false)
        XCTAssertNil(awake.remaining)
        awake.setCurtainDark(true)
        XCTAssertEqual(awake.remaining ?? 0, 3 * 3600, accuracy: 1)
    }

    func testReleasesOnDisable() async {
        let helper = FakeHelper()
        let awake = make(helper)
        awake.update(runtime: working())
        await settle()
        defaults.set(false, forKey: Prefs.keepAwake)
        awake.evaluate()
        await settle()
        XCTAssertFalse(awake.isHolding)
        XCTAssertFalse(awake.holdsAssertion)
        XCTAssertEqual(helper.releases, 1)
    }

    /// A helper that dropped the connection (or restarted) gets the hold again on the next renewal.
    func testReholdsAfterHelperDrop() async {
        let helper = FakeHelper()
        helper.answers = [true, false, true]
        let awake = make(helper)
        awake.update(runtime: working())
        await settle()
        now += 30; awake.evaluate(renew: true); await settle()
        XCTAssertFalse(awake.helperHolds)
        now += 30; awake.evaluate(renew: true); await settle()
        XCTAssertTrue(awake.helperHolds)
        XCTAssertEqual(helper.holds, 3)
    }

    func testPeriodIsSavedAndRestored() async {
        let awake = make(FakeHelper())
        awake.update(runtime: working())
        await settle()
        let again = make(FakeHelper())
        XCTAssertEqual(again.period.start, now)
    }

    /// Relaunching after the time limit passed doesn't notify about a period this launch never held.
    func testExpiredSavedPeriodReleasesQuietly() async {
        defaults.set(try! JSONEncoder().encode(AwakePeriod(start: now - 4 * 3600, latched: false, darkSince: now - 4 * 3600)),
                     forKey: Prefs.keepAwakePeriod)
        let helper = FakeHelper()
        let awake = make(helper)
        awake.setCurtainDark(true)
        awake.update(runtime: working())
        await settle()
        XCTAssertFalse(awake.isHolding)
        XCTAssertEqual(helper.releases, 0)
    }

    func testHiddenLimitInMinutes() {
        defaults.set(2, forKey: Prefs.stayAwakeLimitMinutes)
        XCTAssertEqual(make(FakeHelper()).limit, 120)
        defaults.removeObject(forKey: Prefs.stayAwakeLimitMinutes)
        defaults.set(3600.0, forKey: Prefs.keepAwakeLimit)
        XCTAssertEqual(make(FakeHelper()).limit, 3600)
    }

    func testHelperStatusMapping() {
        XCTAssertEqual(KeepAwake.helperStatus(from: .requiresApproval, error: nil), .requiresApproval)
        XCTAssertEqual(KeepAwake.helperStatus(from: .enabled, error: nil), .enabled)
        XCTAssertEqual(KeepAwake.helperStatus(from: .notRegistered, error: nil), .notRegistered)
        XCTAssertEqual(KeepAwake.helperStatus(from: .notFound, error: nil), .unavailable("The helper isn't in this build of omux."))
        let error = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "Operation not permitted"])
        XCTAssertEqual(KeepAwake.helperStatus(from: .notRegistered, error: error), .unavailable("Operation not permitted"))
    }
}
