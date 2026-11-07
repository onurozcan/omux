import Foundation

/// Why omux stopped keeping the Mac awake.
enum AwakeReleaseReason: String, Equatable {
    case disabled, agentsDone, thermal, lowBattery, timeLimit, user
}

/// Everything the keep-awake decision depends on, read fresh each time.
struct AwakeInputs {
    var enabled: Bool
    var releaseWhenDone: Bool
    var activeAgents: Int
    var thermal: ProcessInfo.ThermalState
    var onBattery: Bool
    /// nil on a Mac without a battery.
    var batteryPercent: Int?
    var limit: TimeInterval
    /// The screens are off or dark (lid closing, Screen Off, display sleep): nobody is at the Mac.
    var dark: Bool
    var now: Date
}

/// One stretch of keeping the Mac awake. Saved, so a relaunch keeps the latch.
struct AwakePeriod: Codable, Equatable {
    /// When this period began; nil when the Mac is allowed to sleep.
    var start: Date?
    /// Ended by heat, battery, the time limit or the user. A new period starts only after every
    /// agent has stopped once, so a Mac in a bag doesn't cycle between hot and awake.
    var latched = false
    /// When the screens last went dark during this period. The time limit counts from here and
    /// starts over each time they do; while someone is at the screen it doesn't count.
    var darkSince: Date?
}

enum AwakeDecision: Equatable {
    /// `until` is when the time limit ends, nil while the screen is on and it isn't counting.
    case hold(until: Date?)
    /// The reason is nil when nothing was being held.
    case release(AwakeReleaseReason?)
}

enum KeepAwakePolicy {
    static let batteryFloor = 10

    static func step(_ input: AwakeInputs, period: inout AwakePeriod) -> AwakeDecision {
        guard input.enabled else {
            let wasHolding = period.start != nil
            period = AwakePeriod()
            return .release(wasHolding ? .disabled : nil)
        }
        if input.activeAgents == 0 { period.latched = false }
        if period.start == nil {
            guard input.activeAgents > 0, !period.latched else { return .release(nil) }
            period.start = input.now
        }
        if input.dark {
            if period.darkSince == nil { period.darkSince = input.now }
        } else {
            period.darkSince = nil
        }
        let until = period.darkSince.map { $0.addingTimeInterval(input.limit) }
        let reason: AwakeReleaseReason?
        if let darkSince = period.darkSince, darkSince > input.now || input.now >= until! {
            reason = .timeLimit
        } else if input.thermal == .serious || input.thermal == .critical {
            reason = .thermal
        } else if input.onBattery, let percent = input.batteryPercent, percent <= batteryFloor {
            reason = .lowBattery
        } else if input.activeAgents == 0, input.releaseWhenDone {
            period.start = nil
            period.darkSince = nil
            return .release(.agentsDone)
        } else {
            reason = nil
        }
        guard let reason else { return .hold(until: until) }
        period.start = nil
        period.darkSince = nil
        period.latched = true
        return .release(reason)
    }

    /// Turned on again from the indicator after Turn Off (or heat, battery, the limit): a new
    /// period can start right away instead of waiting for every agent to stop once.
    static func resume(period: inout AwakePeriod) {
        period.latched = false
    }

    static func endByUser(period: inout AwakePeriod) {
        guard period.start != nil else { return }
        period.start = nil
        period.darkSince = nil
        period.latched = true
    }
}

extension TabRuntime {
    /// An agent in this session is working or waiting on you, itself or through a subagent.
    /// Only agents report a status, so plain shells never count, however busy.
    var isAgentActive: Bool {
        guard !exited else { return false }
        let active: (StatusState?) -> Bool = { $0 == .working || $0 == .blocked }
        return active(statusState) || statusChildren.contains { active($0.state) }
    }
}
