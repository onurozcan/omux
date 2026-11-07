import ServiceManagement
import XCTest
@testable import omux

@MainActor
final class KeepAwakeTests: XCTestCase {
    final class FakeHelper: AwakeHelper {
        var holds = 0
        var releases = 0
        var answers: [AwakeHoldReply] = []
        func hold(lease: TimeInterval) async -> AwakeHoldReply {
            holds += 1
            return answers.isEmpty ? .holding : answers.removeFirst()
        }
        func release() async { releases += 1 }
        func disconnect() {}
    }

    /// Registration as SMAppService does it, with unregister held until the test lets it finish.
    final class FakeService: AwakeHelperService {
        var status: SMAppService.Status = .notRegistered
        var registers = 0
        private var pending: CheckedContinuation<Void, Never>?
        func register() throws { registers += 1; status = .enabled }
        func unregister() async throws {
            await withCheckedContinuation { pending = $0 }
            status = .notRegistered
        }
        var unregistering: Bool { pending != nil }
        func finishUnregister() { pending?.resume(); pending = nil }
    }

    /// One suite, cleared before and after each test, so runs don't leave a file per test.
    let suite = "omuxTests.KeepAwake"
    var defaults: UserDefaults!
    var now = Date(timeIntervalSince1970: 3_000_000)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: Prefs.keepAwake)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    var thermal = ProcessInfo.ThermalState.nominal

    func make(_ helper: FakeHelper, service: AwakeHelperService? = nil) -> KeepAwake {
        let env = KeepAwake.Environment(now: { [unowned self] in self.now }, thermal: { [unowned self] in self.thermal },
                                        power: { (onBattery: true, percent: 80) })
        return KeepAwake(helper: helper, service: service, defaults: defaults, environment: env)
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
        helper.answers = [.holding, .unreachable, .holding]
        let awake = make(helper)
        awake.update(runtime: working())
        await settle()
        now += 30; awake.evaluate(renew: true); await settle()
        XCTAssertFalse(awake.helperHolds)
        now += 30; awake.evaluate(renew: true); await settle()
        XCTAssertTrue(awake.helperHolds)
        XCTAssertEqual(helper.holds, 3)
    }

    /// A relaunch doesn't continue the last period with no agent working, so the Mac isn't kept
    /// awake for an agent that finished yesterday.
    func testRelaunchStartsNoPeriodWithoutAgents() async {
        let awake = make(FakeHelper())
        awake.update(runtime: working())
        await settle()
        XCTAssertTrue(awake.isHolding)
        let again = make(FakeHelper())
        again.evaluate()
        XCTAssertFalse(again.isHolding)
        XCTAssertNil(again.period.start)
    }

    /// Stopped by heat before quitting: after a relaunch it still waits for the agents to stop once.
    func testRelaunchKeepsTheLatch() async {
        defaults.set(try! JSONEncoder().encode(AwakePeriod(start: nil, latched: true)), forKey: Prefs.keepAwakePeriod)
        let helper = FakeHelper()
        let awake = make(helper)
        awake.update(runtime: working())
        await settle()
        XCTAssertFalse(awake.isHolding)
        XCTAssertTrue(awake.paused)
        XCTAssertEqual(helper.holds, 0)
    }

    /// An ad hoc build doesn't register a helper that would refuse it.
    func testUnsignedBuildDoesntRegister() {
        let service = FakeService()
        let awake = KeepAwake(helper: FakeHelper(), service: service, defaults: defaults,
                              environment: KeepAwake.Environment(now: { Date() }, thermal: { .nominal },
                                                                 power: { (onBattery: false, percent: nil) }),
                              signed: false)
        awake.setEnabled(true)
        XCTAssertEqual(service.registers, 0)
        guard case .unavailable = awake.helperStatus else { return XCTFail("expected unavailable") }
    }

    func testLimitInSeconds() {
        XCTAssertEqual(make(FakeHelper()).limit, KeepAwake.defaultLimit)
        defaults.set(120, forKey: Prefs.keepAwakeLimit)
        XCTAssertEqual(make(FakeHelper()).limit, 120)
    }

    /// The helper's own refusal (its 12-hour ceiling) is kept, so the popover can say why.
    func testKeepsTheHelpersRefusal() async {
        let helper = FakeHelper()
        helper.answers = [.refused("kept awake for 12 hours")]
        let awake = make(helper)
        awake.update(runtime: working())
        await settle()
        XCTAssertFalse(awake.helperHolds)
        XCTAssertEqual(awake.helperRefusal, "kept awake for 12 hours")
        now += 30; awake.evaluate(renew: true); await settle()
        XCTAssertTrue(awake.helperHolds)
        XCTAssertNil(awake.helperRefusal)
    }

    /// Heat stopping it is remembered for the popover until it holds again.
    func testRemembersWhyItStopped() async {
        let awake = make(FakeHelper())
        awake.update(runtime: working())
        await settle()
        thermal = .serious
        awake.evaluate()
        XCTAssertEqual(awake.stopReason, .thermal)
        XCTAssertTrue(awake.paused)
        thermal = .nominal
        awake.resume()
        XCTAssertNil(awake.stopReason)
        XCTAssertTrue(awake.isHolding)
    }

    /// Off and quickly on again: the unregistering that was still running doesn't leave the
    /// helper unregistered.
    func testQuickOffThenOnKeepsTheHelper() async {
        let service = FakeService()
        let awake = make(FakeHelper(), service: service)
        awake.setEnabled(true)
        awake.setEnabled(false)
        for _ in 0 ..< 20 where !service.unregistering { await Task.yield() }
        XCTAssertTrue(service.unregistering)
        awake.setEnabled(true)
        service.finishUnregister()
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertEqual(service.status, .enabled)
        XCTAssertEqual(awake.helperStatus, .enabled)
    }

    /// Off and on again before the helper has even let go: nothing is unregistered.
    func testOnAgainBeforeReleaseSkipsUnregister() async {
        let service = FakeService()
        let awake = make(FakeHelper(), service: service)
        awake.setEnabled(true)
        awake.setEnabled(false)
        awake.setEnabled(true)
        for _ in 0 ..< 20 { await Task.yield() }
        XCTAssertFalse(service.unregistering)
        XCTAssertEqual(service.status, .enabled)
    }

    func testHelperReplyMapping() {
        XCTAssertEqual(XPCAwakeHelper.reply(ok: true, reason: nil), .holding)
        XCTAssertEqual(XPCAwakeHelper.reply(ok: false, reason: "12 hours"), .refused("12 hours"))
        XCTAssertEqual(XPCAwakeHelper.reply(ok: false, reason: nil), .refused("the helper said no"))
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
