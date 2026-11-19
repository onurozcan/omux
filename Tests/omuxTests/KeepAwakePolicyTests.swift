import XCTest
@testable import omux

final class KeepAwakePolicyTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func inputs(agents: Int = 1, enabled: Bool = true, releaseWhenDone: Bool = false,
                thermal: ProcessInfo.ThermalState = .nominal, onBattery: Bool = true, battery: Int? = 80,
                dark: Bool = true, at offset: TimeInterval = 0) -> AwakeInputs {
        AwakeInputs(enabled: enabled, releaseWhenDone: releaseWhenDone, activeAgents: agents, thermal: thermal,
                    onBattery: onBattery, batteryPercent: battery, limit: 3 * 3600, dark: dark, now: t0 + offset)
    }

    func testStartsWhenAgentWorks() {
        var period = AwakePeriod()
        XCTAssertEqual(KeepAwakePolicy.step(inputs(agents: 0), period: &period), .release(nil))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(), period: &period), .hold(until: t0 + 3 * 3600))
        XCTAssertEqual(period.start, t0)
    }

    func testDisabledReleases() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(enabled: false), period: &period), .release(.disabled))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(enabled: false), period: &period), .release(nil))
        XCTAssertNil(period.start)
    }

    func testAgentsDoneKeepsHoldingByDefault() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(agents: 0, at: 60), period: &period), .hold(until: t0 + 3 * 3600))
    }

    func testAgentsDoneReleasesWhenOptedIn() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(releaseWhenDone: true), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(agents: 0, releaseWhenDone: true, at: 60), period: &period),
                       .release(.agentsDone))
        // Not latched: the next working agent starts a new period.
        XCTAssertEqual(KeepAwakePolicy.step(inputs(releaseWhenDone: true, at: 120), period: &period),
                       .hold(until: t0 + 120 + 3 * 3600))
    }

    func testThermalSeriousReleasesAndLatches() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(thermal: .fair, at: 10), period: &period), .hold(until: t0 + 3 * 3600))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(thermal: .serious, at: 20), period: &period), .release(.thermal))
        // Cooled down, agent still working: stays released.
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 30), period: &period), .release(nil))
        XCTAssertTrue(period.latched)
    }

    func testCriticalReleasesToo() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(thermal: .critical, at: 20), period: &period), .release(.thermal))
    }

    func testLatchClearsOnlyAfterAgentsGoIdle() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        _ = KeepAwakePolicy.step(inputs(thermal: .serious, at: 20), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(agents: 0, at: 40), period: &period), .release(nil))
        XCTAssertFalse(period.latched)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 60), period: &period), .hold(until: t0 + 60 + 3 * 3600))
    }

    func testLowBatteryAt10OnBattery() {
        var period = AwakePeriod()
        XCTAssertEqual(KeepAwakePolicy.step(inputs(battery: 11), period: &period), .hold(until: t0 + 3 * 3600))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(battery: 10, at: 30), period: &period), .release(.lowBattery))
        XCTAssertTrue(period.latched)
    }

    func testLowBatteryIgnoredOnPower() {
        var period = AwakePeriod()
        XCTAssertEqual(KeepAwakePolicy.step(inputs(onBattery: false, battery: 5), period: &period), .hold(until: t0 + 3 * 3600))
    }

    func testNoBatteryNeverReleases() {
        var period = AwakePeriod()
        XCTAssertEqual(KeepAwakePolicy.step(inputs(onBattery: true, battery: nil), period: &period), .hold(until: t0 + 3 * 3600))
    }

    func testTimeLimitReleases() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 3 * 3600 - 1), period: &period), .hold(until: t0 + 3 * 3600))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 3 * 3600), period: &period), .release(.timeLimit))
        XCTAssertTrue(period.latched)
    }

    /// A dark stretch saved before a relaunch continues from when it began, never from scratch.
    func testPersistedPeriodContinuesAfterRelaunch() throws {
        var period = AwakePeriod(start: t0, latched: false, darkSince: t0)
        let restored = try JSONDecoder().decode(AwakePeriod.self, from: JSONEncoder().encode(period))
        period = restored
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 3600), period: &period), .hold(until: t0 + 3 * 3600))
        var expired = AwakePeriod(start: t0 - 4 * 3600, latched: false, darkSince: t0 - 4 * 3600)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(), period: &expired), .release(.timeLimit))
    }

    /// A period saved by an older omux, without darkSince, still decodes.
    func testDecodesPeriodWithoutDarkSince() throws {
        let data = Data(#"{"start":0,"latched":false}"#.utf8)
        let period = try JSONDecoder().decode(AwakePeriod.self, from: data)
        XCTAssertNil(period.darkSince)
        XCTAssertNotNil(period.start)
    }

    /// While someone is at the screen the limit doesn't count; it starts when the screen goes dark
    /// and starts over each time.
    func testLimitCountsOnlyWhileDark() {
        var period = AwakePeriod()
        XCTAssertEqual(KeepAwakePolicy.step(inputs(dark: false), period: &period), .hold(until: nil))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(dark: false, at: 10 * 3600), period: &period), .hold(until: nil))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 10 * 3600), period: &period), .hold(until: t0 + 13 * 3600))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 12 * 3600), period: &period), .hold(until: t0 + 13 * 3600))
        // Back at the screen, then dark again: a full limit from there.
        XCTAssertEqual(KeepAwakePolicy.step(inputs(dark: false, at: 12.5 * 3600), period: &period), .hold(until: nil))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 14 * 3600), period: &period), .hold(until: t0 + 17 * 3600))
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 17 * 3600), period: &period), .release(.timeLimit))
        XCTAssertNil(period.darkSince)
    }

    /// Heat and battery stop it whether or not anyone is at the screen.
    func testHeatAndBatteryApplyWithScreenOn() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(dark: false), period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(thermal: .serious, dark: false, at: 10), period: &period), .release(.thermal))
        var low = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(dark: false), period: &low)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(battery: 10, dark: false, at: 10), period: &low), .release(.lowBattery))
    }

    func testFuturePersistedStartIsExpired() {
        var period = AwakePeriod(start: t0 + 3600, latched: false, darkSince: t0 + 3600)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(), period: &period), .release(.timeLimit))
        XCTAssertTrue(period.latched)
    }

    func testUserEndLatches() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        KeepAwakePolicy.endByUser(period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 10), period: &period), .release(nil))
    }

    /// Turned on again after Turn Off: holds right away while an agent works.
    func testResumeAfterUserEnd() {
        var period = AwakePeriod()
        _ = KeepAwakePolicy.step(inputs(), period: &period)
        KeepAwakePolicy.endByUser(period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 10), period: &period), .release(nil))
        KeepAwakePolicy.resume(period: &period)
        XCTAssertEqual(KeepAwakePolicy.step(inputs(at: 20), period: &period), .hold(until: t0 + 20 + 3 * 3600))
    }

    func testAgentActive() {
        var claude = TabRuntime()
        claude.provider = .claude
        claude.statusState = .working
        XCTAssertTrue(claude.isAgentActive)

        var shell = TabRuntime()
        shell.provider = .shell
        shell.busy = true
        XCTAssertFalse(shell.isAgentActive)

        var subagents = TabRuntime()
        subagents.provider = .claude
        subagents.statusState = .idle
        subagents.statusChildren = [.init(id: "a", state: .working, kind: nil, message: nil, title: nil)]
        XCTAssertTrue(subagents.isAgentActive)

        var codex = TabRuntime()
        codex.provider = .codex
        codex.statusState = .blocked
        XCTAssertTrue(codex.isAgentActive)

        var done = TabRuntime()
        done.statusState = .done
        XCTAssertFalse(done.isAgentActive)

        var exited = TabRuntime()
        exited.statusState = .working
        exited.exited = true
        XCTAssertFalse(exited.isAgentActive)
    }
}
