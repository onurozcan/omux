import XCTest
import OmuxAwakeProtocol

final class AwakeLeaseTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLeaseExpiresWithoutRenewal() {
        var lease = AwakeLease()
        XCTAssertEqual(lease.hold(lease: 120, now: t0), .granted)
        XCTAssertTrue(lease.tick(now: t0 + 119))
        XCTAssertFalse(lease.tick(now: t0 + 121))
    }

    func testRenewKeepsHolding() {
        var lease = AwakeLease()
        for step in 0 ..< 20 {
            XCTAssertEqual(lease.hold(lease: 120, now: t0 + Double(step) * 30), .granted)
        }
        XCTAssertTrue(lease.tick(now: t0 + 19 * 30 + 100))
    }

    func testReleaseStopsImmediately() {
        var lease = AwakeLease()
        _ = lease.hold(lease: 120, now: t0)
        lease.release(now: t0 + 10)
        XCTAssertFalse(lease.tick(now: t0 + 11))
    }

    func testCeilingTripsAfter12hAndRefusesFor30min() {
        var lease = AwakeLease()
        var now = t0
        while now < t0 + 12 * 3600 {
            XCTAssertEqual(lease.hold(lease: 120, now: now), .granted)
            XCTAssertTrue(lease.tick(now: now))
            now += 30
        }
        _ = lease.hold(lease: 120, now: now)
        XCTAssertFalse(lease.tick(now: now))
        guard case .refusedCooldown(let until) = lease.hold(lease: 120, now: now + 60) else {
            return XCTFail("expected a cooldown")
        }
        XCTAssertEqual(until.timeIntervalSince(now), 1800, accuracy: 31)
        XCTAssertEqual(lease.hold(lease: 120, now: now + 31 * 60), .granted)
        XCTAssertTrue(lease.tick(now: now + 31 * 60))
    }

    /// A new connection a few minutes after the last hold continues the same stretch, so
    /// reconnecting can't reset the ceiling.
    func testReconnectGapUnder5MinCountsTowardCeiling() {
        var lease = AwakeLease()
        var now = t0
        while now < t0 + 6 * 3600 { _ = lease.hold(lease: 120, now: now); now += 30 }
        lease.release(now: now)
        now += 4 * 60
        while now < t0 + 12 * 3600 + 10 * 60 {
            _ = lease.hold(lease: 120, now: now)
            now += 30
        }
        XCTAssertFalse(lease.tick(now: now))
    }

    func testGapOver5MinResetsCeiling() {
        var lease = AwakeLease()
        var now = t0
        while now < t0 + 11 * 3600 { _ = lease.hold(lease: 120, now: now); now += 30 }
        lease.release(now: now)
        now += 6 * 60
        let restart = now
        while now < restart + 2 * 3600 { _ = lease.hold(lease: 120, now: now); now += 30 }
        XCTAssertTrue(lease.tick(now: now - 1))
    }

    func testLabelRoundTrip() {
        XCTAssertEqual(AwakeHelperLabel.label(forBundleID: "net.pf1.omux"), "net.pf1.omux.awake")
        XCTAssertEqual(AwakeHelperLabel.bundleID(forLabel: "net.pf1.omux.beta.awake"), "net.pf1.omux.beta")
        XCTAssertNil(AwakeHelperLabel.bundleID(forLabel: "net.pf1.omux"))
    }
}
