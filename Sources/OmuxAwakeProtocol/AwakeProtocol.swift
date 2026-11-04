import Foundation
import Security

/// What omux asks its keep-awake helper over XPC. Nothing else: no commands, no paths.
@objc public protocol AwakeHelperXPC {
    /// Keeps system sleep disabled for `leaseSeconds` more. Replies false, with the reason,
    /// when the helper refuses (it has held for its ceiling and is cooling down).
    func hold(leaseSeconds: Double, reply: @escaping (Bool, String?) -> Void)
    /// Lets the Mac sleep again now.
    func release(reply: @escaping () -> Void)
}

/// The helper's launchd label is the app's bundle id plus `.awake`, so the release and beta
/// builds each have their own, and the helper knows which app may talk to it.
public enum AwakeHelperLabel {
    public static let suffix = ".awake"

    public static func label(forBundleID bundleID: String) -> String { bundleID + suffix }

    public static func bundleID(forLabel label: String) -> String? {
        guard label.hasSuffix(suffix), label.count > suffix.count else { return nil }
        return String(label.dropLast(suffix.count))
    }
}

/// The helper's own rules for how long it keeps sleep disabled, independent of the app.
/// - A hold lasts only as long as its lease; the app renews it while it wants the Mac awake,
///   so a crashed or hung app lets the Mac sleep within one lease.
/// - However it's renewed, one stretch of being awake ends at `ceiling`, and then holds are
///   refused for `cooldown`. A stretch continues across reconnects less than `reconnectGap`
///   apart, so reconnecting can't reset it.
public struct AwakeLease: Equatable {
    public enum HoldResult: Equatable {
        case granted
        case refusedCooldown(until: Date)
    }

    public let ceiling: TimeInterval
    public let reconnectGap: TimeInterval
    public let cooldown: TimeInterval

    private var stretchStart: Date?
    private var lastActive: Date?
    private var expiry: Date?
    private var cooldownUntil: Date?

    public init(ceiling: TimeInterval = 12 * 3600, reconnectGap: TimeInterval = 300, cooldown: TimeInterval = 1800) {
        self.ceiling = ceiling
        self.reconnectGap = reconnectGap
        self.cooldown = cooldown
    }

    public mutating func hold(lease: TimeInterval, now: Date) -> HoldResult {
        // Bring the state up to now first: this may be the moment the ceiling is reached.
        _ = tick(now: now)
        if let until = cooldownUntil {
            if now < until { return .refusedCooldown(until: until) }
            cooldownUntil = nil
        }
        let continues = expiry != nil || lastActive.map { now.timeIntervalSince($0) < reconnectGap } == true
        if stretchStart == nil || !continues { stretchStart = now }
        if let start = stretchStart, now.timeIntervalSince(start) >= ceiling {
            trip(now: now)
            return .refusedCooldown(until: cooldownUntil!)
        }
        expiry = now.addingTimeInterval(lease)
        lastActive = now
        return .granted
    }

    public mutating func release(now: Date) {
        if expiry != nil { lastActive = now }
        expiry = nil
    }

    /// Whether sleep should be disabled right now. Call it periodically.
    public mutating func tick(now: Date) -> Bool {
        guard let end = expiry else { return false }
        if now >= end {
            expiry = nil
            lastActive = end
            return false
        }
        if let start = stretchStart, now.timeIntervalSince(start) >= ceiling {
            trip(now: now)
            return false
        }
        lastActive = now
        return true
    }

    private mutating func trip(now: Date) {
        expiry = nil
        stretchStart = nil
        lastActive = nil
        cooldownUntil = now.addingTimeInterval(cooldown)
    }
}

/// Code signing requirements that tie omux and its helper to each other: the other side must
/// have the expected identifier and be signed by the same team as this process.
public enum AwakeSigning {
    /// This process's signing team, or nil when it's signed ad hoc.
    public static func teamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { return nil }
        return team
    }

    public static func requirement(forIdentifier identifier: String) -> String? {
        guard let team = teamIdentifier() else { return nil }
        return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }
}
