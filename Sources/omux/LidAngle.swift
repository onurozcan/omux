import Combine
import Foundation
import IOKit.hid

/// The lid angle sensor of recent MacBooks, read through IOKit HID: Apple's vendor sensor page
/// (0x20), usage 0x8A, feature report 1 holding the angle in degrees. Apple doesn't document it;
/// on a Mac without one (or if a future macOS changes it) `angle()` is nil and nothing happens.
final class LidAngleSensor {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let device: IOHIDDevice

    init?() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x05AC,
                                                kIOHIDPrimaryUsagePageKey: 0x20,
                                                kIOHIDPrimaryUsageKey: 0x8A] as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first else { return nil }
        self.device = device
    }

    deinit { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    /// Degrees between the lid and the keyboard: 0 closed, about 100–130 open.
    func angle() -> Double? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(report.count)
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &report, &length) == kIOReturnSuccess,
              length >= 3 else { return nil }
        return Double(UInt16(report[1]) | UInt16(report[2]) << 8)
    }
}

/// While omux keeps the Mac awake, closing the lid partway plays Screen Off's animation on
/// the built-in screen and turns its brightness and the keyboard lights down, so the screen goes out with the omux ring
/// instead of being cut off; opening it again brings the brightness back and plays it back.
/// Reads the sensor only while Keep Awake holds: four times a second while the lid rests,
/// twenty while it moves.
@MainActor
final class LidWatcher {
    static let shared = LidWatcher()

    /// Below this the screen goes dark; above `openAngle` it comes back. The gap keeps it from
    /// flickering when the lid rests near the threshold.
    nonisolated static let closingAngle = 80.0
    static let openAngle = 90.0

    /// How long until the next read: quick while the lid moves, slow while it rests. Closing it
    /// briskly takes about half a second from upright to `closingAngle`, so a resting read
    /// still notices the movement in time for the animation.
    nonisolated static func interval(angle: Double?, previous: Double?) -> TimeInterval {
        guard let angle else { return 1 }
        guard let previous, abs(angle - previous) < 1 else { return 0.05 }
        return 0.25
    }

    private var sensor: LidAngleSensor?
    private var timer: Timer?
    private var holding: AnyCancellable?
    private var dimmed = false
    private var lastAngle: Double?
    /// Reads in a row that got no angle; a few while dimmed bring the screen back, since the
    /// lid's curtain has no other way out.
    private var misses = 0

    func start() {
        guard holding == nil else { return }
        holding = KeepAwake.shared.$decision
            .map { if case .hold = $0 { return true } else { return false } }
            .removeDuplicates()
            // After the change, not during @Published's willSet: waking Screen Off re-decides.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] holds in
                MainActor.assumeIsolated { holds ? self?.watch() : self?.stopWatching() }
            }
    }

    private func watch() {
        guard timer == nil else { return }
        if sensor == nil { sensor = LidAngleSensor() }
        guard sensor != nil else { return }
        schedule(after: 0.05)
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                let previous = self.lastAngle
                let angle = self.check()
                self.lastAngle = angle
                guard self.timer != nil else { return }
                self.schedule(after: Self.interval(angle: angle, previous: previous))
            }
        }
        timer.tolerance = seconds / 5
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        if dimmed { ScreenOff.shared.wake() }
        dimmed = false
        lastAngle = nil
        misses = 0
    }

    /// Reads the angle and acts on it; returns what it read.
    private func check() -> Double? {
        guard let angle = sensor?.angle() else {
            misses += 1
            if dimmed, misses >= 3 {
                dimmed = false
                ScreenOff.shared.wake()
            }
            return nil
        }
        misses = 0
        if !dimmed, angle < Self.closingAngle {
            dimmed = true
            if !ScreenOff.shared.isShowing { ScreenOff.shared.start(lid: true) }
        } else if dimmed, angle > Self.openAngle {
            dimmed = false
            ScreenOff.shared.wake()
        }
        return angle
    }
}
