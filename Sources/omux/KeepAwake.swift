import AppKit
import Combine
import IOKit.ps
import OmuxAwakeProtocol
import ServiceManagement

/// The keep-awake helper as the app sees it, so tests can use a fake.
@MainActor
protocol AwakeHelper: AnyObject {
    /// Asks for sleep to stay disabled for `lease` more seconds. False when the helper can't be
    /// reached (not approved, restarting) or refuses.
    func hold(lease: TimeInterval) async -> Bool
    /// Lets the Mac sleep, and returns once the helper has (or after a short timeout).
    func release() async
    /// Drops the connection; the helper lets the Mac sleep when it notices.
    func disconnect()
}

/// Registration of the helper as a launch daemon. SMAppService in the app.
@MainActor
protocol AwakeHelperService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: AwakeHelperService {}

enum HelperStatus: Equatable {
    case notRegistered, requiresApproval, enabled
    case unavailable(String)
}

/// Keeps the Mac awake while agents work, lid closed included, once Settings › Keep Awake is on.
/// KeepAwakePolicy decides; this feeds it agent states, heat, battery and time, and carries the
/// decision out: an IOPMAssertion against idle sleep, and the helper for the lid.
@MainActor
final class KeepAwake: ObservableObject {
    struct Environment {
        var now: () -> Date
        var thermal: () -> ProcessInfo.ThermalState
        var power: () -> (onBattery: Bool, percent: Int?)

        static let live = Environment(now: Date.init, thermal: { ProcessInfo.processInfo.thermalState },
                                      power: KeepAwake.readPower)
    }

    static let shared: KeepAwake = {
        let bundleID = Bundle.main.bundleIdentifier ?? "net.pf1.omux"
        let label = AwakeHelperLabel.label(forBundleID: bundleID)
        let isApp = Bundle.main.bundleURL.pathExtension == "app"
        return KeepAwake(helper: XPCAwakeHelper(label: label),
                         service: isApp ? SMAppService.daemon(plistName: label + ".plist") : nil,
                         defaults: .standard, environment: .live)
    }()

    /// Notifications about keep awake share one id, so a new one replaces the last.
    static let notificationID = UUID(uuidString: "6F6D7578-0000-4177-616B-650000000001")!
    static let lease: TimeInterval = 120
    static let renewEvery: TimeInterval = 30
    static let defaultLimit: TimeInterval = 3 * 3600

    @Published private(set) var decision: AwakeDecision = .release(nil)
    @Published private(set) var activeAgents = 0
    @Published private(set) var helperStatus: HelperStatus = .notRegistered
    /// Whether the helper confirmed the last hold, so the lid can close.
    @Published private(set) var helperHolds = false
    private(set) var period: AwakePeriod
    /// Turned off from the indicator, or stopped by heat, battery or the time limit: waits until
    /// every agent has stopped once, or until turned on again.
    @Published private(set) var paused = false

    private let helper: AwakeHelper
    private let service: AwakeHelperService?
    private let defaults: UserDefaults
    private let env: Environment
    /// Prevents idle sleep while the lid is open, and keeps App Nap from delaying the renewals.
    private var activity: NSObjectProtocol?
    private var registrationError: Error?
    private var subscriptions: Set<AnyCancellable> = []
    private var timer: Timer?
    /// Agents working when the Mac went to sleep with the feature off, for the hint on wake.
    private var agentsAtSleep = 0
    /// The displays are asleep (lid closed, display sleep).
    private var displaysAsleep = false
    /// Screen Off or the lid has turned the screen dark.
    private var curtainDark = false
    /// Nobody is at the screen, so the time limit counts.
    var isDark: Bool { displaysAsleep || curtainDark }

    init(helper: AwakeHelper, service: AwakeHelperService?, defaults: UserDefaults, environment: Environment) {
        self.helper = helper
        self.service = service
        self.defaults = defaults
        self.env = environment
        period = defaults.data(forKey: Prefs.keepAwakePeriod)
            .flatMap { try? JSONDecoder().decode(AwakePeriod.self, from: $0) } ?? AwakePeriod()
        paused = period.latched
        refreshStatus()
    }

    var enabled: Bool { defaults.bool(forKey: Prefs.keepAwake) }
    var isHolding: Bool { if case .hold = decision { return true } else { return false } }
    var holdsAssertion: Bool { activity != nil }

    var limit: TimeInterval {
        let minutes = defaults.integer(forKey: Prefs.stayAwakeLimitMinutes)
        if minutes > 0 { return TimeInterval(minutes) * 60 }
        let seconds = defaults.double(forKey: Prefs.keepAwakeLimit)
        return seconds > 0 ? seconds : Self.defaultLimit
    }

    /// Time left before the limit; nil while it isn't counting (screen on) or nothing is held.
    var remaining: TimeInterval? {
        guard case .hold(let until?) = decision else { return nil }
        return max(0, until.timeIntervalSince(env.now()))
    }

    // MARK: Running

    /// Starts watching sessions, heat and sleep. Called once at launch.
    func start() {
        Store.shared.$runtime
            .sink { [weak self] runtime in self?.update(runtime: runtime) }
            .store(in: &subscriptions)
        let center = NotificationCenter.default
        center.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &subscriptions)
        center.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.evaluate() }
            .store(in: &subscriptions)
        center.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.refreshStatus() }
            .store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in self?.willSleep() }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.didWake() }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.screensDidSleepNotification)
            .sink { [weak self] _ in self?.displaysAsleep = true; self?.evaluate() }
            .store(in: &subscriptions)
        workspace.publisher(for: NSWorkspace.screensDidWakeNotification)
            .sink { [weak self] _ in self?.displaysAsleep = false; self?.evaluate() }
            .store(in: &subscriptions)
        let renewal = Timer(timeInterval: Self.renewEvery, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate(renew: true) }
        }
        // .common, so menus and sheets don't hold the renewal back past the lease.
        RunLoop.main.add(renewal, forMode: .common)
        timer = renewal
        // On, but the helper isn't registered (omux was reinstalled or moved): register it again.
        if enabled, let service, service.status == .notRegistered {
            do { try service.register() } catch { registrationError = error }
            refreshStatus()
        }
        evaluate()
    }

    /// Lets the Mac sleep as omux quits. The period stays saved, so a relaunch continues it.
    func shutdown() {
        releaseAssertion()
        helper.disconnect()
        helperHolds = false
    }

    func update(runtime: [UUID: TabRuntime]) {
        let count = runtime.values.filter(\.isAgentActive).count
        guard count != activeAgents || !isHolding && count > 0 else { return }
        activeAgents = count
        evaluate()
    }

    /// Decides again. `renew` asks the helper for another lease while holding; otherwise it's
    /// only asked when a hold starts.
    func evaluate(renew: Bool = false) {
        let wasHolding = isHolding
        let power = env.power()
        let input = AwakeInputs(enabled: enabled,
                                releaseWhenDone: defaults.bool(forKey: Prefs.keepAwakeReleaseWhenDone),
                                activeAgents: activeAgents, thermal: env.thermal(),
                                onBattery: power.onBattery, batteryPercent: power.percent,
                                limit: limit, dark: isDark, now: env.now())
        var next = period
        let decided = KeepAwakePolicy.step(input, period: &next)
        if next != period { save(next) }
        if decided != decision { decision = decided }
        apply(decided, wasHolding: wasHolding, renew: renew)
    }

    /// Screen Off and the lid tell this when the screen has gone dark and when it's back.
    func setCurtainDark(_ dark: Bool) {
        guard dark != curtainDark else { return }
        curtainDark = dark
        evaluate()
    }

    /// The indicator's Turn On after Turn Off: keep the Mac awake again while agents work.
    func resume() {
        KeepAwakePolicy.resume(period: &period)
        save(period)
        evaluate()
    }

    /// The indicator's Turn Off: let the Mac sleep now, until agents next start working.
    func endNow() {
        KeepAwakePolicy.endByUser(period: &period)
        save(period)
        evaluate()
    }

    private func apply(_ decided: AwakeDecision, wasHolding: Bool, renew: Bool) {
        switch decided {
        case .hold:
            takeAssertion()
            guard !wasHolding || renew else { return }
            Task {
                let ok = await helper.hold(lease: Self.lease)
                if isHolding { helperHolds = ok } else if ok { await helper.release() }
            }
        case .release(let reason):
            releaseAssertion()
            if wasHolding || helperHolds { Task { await helper.release() } }
            helperHolds = false
            // Only for a period this launch held: a relaunch after the limit passed says nothing.
            if let reason, wasHolding { notify(reason) }
        }
    }

    private func save(_ next: AwakePeriod) {
        period = next
        if paused != next.latched { paused = next.latched }
        if let data = try? JSONEncoder().encode(next), defaults.data(forKey: Prefs.keepAwakePeriod) != data {
            defaults.set(data, forKey: Prefs.keepAwakePeriod)
        }
    }

    private func takeAssertion() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                         reason: "omux: agents are working")
    }

    private func releaseAssertion() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func notify(_ reason: AwakeReleaseReason) {
        let body: String
        switch reason {
        case .thermal: body = "It got hot, so omux stopped keeping it awake."
        case .lowBattery: body = "The battery is at \(KeepAwakePolicy.batteryFloor)%, so omux stopped keeping it awake."
        case .timeLimit: body = "Keep Awake reached its time limit."
        case .disabled, .agentsDone, .user: return
        }
        Notifier.shared.post(tabID: Self.notificationID, title: "Your Mac can sleep again", subtitle: nil, body: body)
    }

    // MARK: Turning it on and off

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Prefs.keepAwake)
        registrationError = nil
        if on {
            do { try service?.register() } catch { registrationError = error }
            refreshStatus()
            if helperStatus == .requiresApproval { openLoginItems() }
            evaluate()
        } else {
            evaluate()
            // Unregistering stops the helper; make sure it has let the Mac sleep first.
            Task {
                await helper.release()
                helper.disconnect()
                try? await service?.unregister()
                refreshStatus()
            }
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    func refreshStatus() {
        guard let service else {
            helperStatus = .unavailable("The helper only runs from the omux app.")
            return
        }
        helperStatus = Self.helperStatus(from: service.status, error: registrationError)
        // Approved in System Settings since the last try: the next renewal reaches the helper.
        if helperStatus == .enabled, isHolding, !helperHolds { evaluate(renew: true) }
    }

    static func helperStatus(from status: SMAppService.Status, error: Error?) -> HelperStatus {
        if let error, status != .enabled, status != .requiresApproval { return .unavailable(error.localizedDescription) }
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable("The helper isn't in this build of omux.")
        default: return .notRegistered
        }
    }

    // MARK: The hint after sleeping while agents worked

    private func willSleep() {
        agentsAtSleep = enabled ? 0 : activeAgents
    }

    private func didWake() {
        defer { agentsAtSleep = 0 }
        guard let hint = SleepHint.message(agents: agentsAtSleep, enabled: enabled,
                                           shown: defaults.bool(forKey: Prefs.keepAwakeHintShown)) else { return }
        defaults.set(true, forKey: Prefs.keepAwakeHintShown)
        Notices.shared.post(hint.title, detail: hint.detail, isError: false)
    }

    // MARK: Power

    nonisolated static func readPower() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPSBatteryPowerValue
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            return (onBattery, current * 100 / maximum)
        }
        return (onBattery, nil)
    }
}

/// The one-time banner after the Mac slept while agents were working with Keep Awake off.
enum SleepHint {
    static func message(agents: Int, enabled: Bool, shown: Bool) -> (title: String, detail: String)? {
        guard agents > 0, !enabled, !shown else { return nil }
        let who = agents == 1 ? "an agent was" : "\(agents) agents were"
        return ("Your Mac slept while \(who) working",
                "Settings › Keep Awake can keep it awake while agents work, even with the lid closed.")
    }
}

/// The helper over XPC. A dropped connection is made again on the next call.
@MainActor
final class XPCAwakeHelper: AwakeHelper {
    private let label: String
    private var connection: NSXPCConnection?

    init(label: String) { self.label = label }

    private func current() -> NSXPCConnection {
        if let connection { return connection }
        let made = NSXPCConnection(machServiceName: label, options: .privileged)
        made.remoteObjectInterface = NSXPCInterface(with: AwakeHelperXPC.self)
        // Only the helper this omux shipped with, signed by the same team.
        if let requirement = AwakeSigning.requirement(forIdentifier: label) { made.setCodeSigningRequirement(requirement) }
        let madeID = ObjectIdentifier(made)
        let drop: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // A late call from an older connection mustn't drop the current one.
                    guard let self, let current = self.connection, ObjectIdentifier(current) == madeID else { return }
                    self.connection = nil
                    current.invalidate()
                }
            }
        }
        made.invalidationHandler = drop
        made.interruptionHandler = drop
        made.resume()
        connection = made
        return made
    }

    func hold(lease: TimeInterval) async -> Bool {
        let connection = current()
        return await Self.call(timeout: 5, fallback: false) { done in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done(false) } as? AwakeHelperXPC
            guard let proxy else { return done(false) }
            proxy.hold(leaseSeconds: lease) { ok, _ in done(ok) }
        }
    }

    func release() async {
        guard let connection else { return }
        await Self.call(timeout: 2, fallback: ()) { done in
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in done(()) } as? AwakeHelperXPC
            guard let proxy else { return done(()) }
            proxy.release { done(()) }
        }
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
    }

    /// Runs an XPC call and returns its reply, or `fallback` if neither the reply nor an error
    /// comes within `timeout`, so a stuck helper can't leave a caller waiting.
    private static func call<T: Sendable>(timeout: TimeInterval, fallback: T,
                                          _ body: @escaping (@escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.resume(fallback) }
            body { once.resume($0) }
        }
    }

    /// Resumes a continuation once, whichever of the reply, the error and the timeout comes first.
    private final class Once<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Never>?
        private let lock = NSLock()
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func resume(_ value: T) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
