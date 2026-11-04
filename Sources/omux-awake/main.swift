// omux-awake: the launch daemon that keeps the Mac awake with the lid closed while omux asks it
// to. It runs as root only because `pmset disablesleep` needs it, and does nothing else:
// - it answers omux alone (same signing team and bundle id), over local XPC, never the network;
// - a hold lasts one lease, which omux renews; a crashed or hung omux lets the Mac sleep again;
// - a lost connection lets the Mac sleep at once;
// - launchd starts it at boot (RunAtLoad), when it turns sleep back on, in case the Mac went
//   down while it held;
// - its own ceiling (AwakeLease) ends any stretch after 12 hours, whatever omux asks.
import Foundation
import OmuxAwakeProtocol
import os

let label = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"].flatMap { $0.isEmpty ? nil : $0 }
    ?? CommandLine.arguments.dropFirst().first
    ?? "net.pf1.omux.awake"
let log = Logger(subsystem: label, category: "helper")

/// Sets the system-wide "sleep disabled" flag, only when it changes.
final class SleepSwitch {
    private var disabled: Bool?

    func set(disabled wanted: Bool) {
        guard wanted != disabled else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", wanted ? "1" : "0"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                disabled = wanted
                log.notice("sleep \(wanted ? "disabled" : "enabled", privacy: .public)")
            } else {
                log.error("pmset exited with \(process.terminationStatus)")
            }
        } catch {
            log.error("pmset failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The helper's state, touched only on the main queue.
final class Helper: NSObject, NSXPCListenerDelegate, AwakeHelperXPC {
    private var lease = AwakeLease()
    private let sleep = SleepSwitch()
    private var timer: Timer?
    private let requirement: String?

    override init() {
        requirement = Helper.clientRequirement()
        super.init()
        sleep.set(disabled: false)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.apply() }
    }

    private func apply() {
        sleep.set(disabled: lease.tick(now: Date()))
    }

    // MARK: AwakeHelperXPC

    func hold(leaseSeconds: Double, reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            let seconds = min(max(leaseSeconds, 10), 300)
            switch self.lease.hold(lease: seconds, now: Date()) {
            case .granted:
                self.apply()
                reply(true, nil)
            case .refusedCooldown(let until):
                self.apply()
                reply(false, "kept awake for 12 hours; sleep is allowed again until \(until.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    func release(reply: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.lease.release(now: Date())
            self.apply()
            reply()
        }
    }

    // MARK: NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let requirement else {
            log.error("refusing a connection: the helper isn't signed by a team")
            return false
        }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: AwakeHelperXPC.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lease.release(now: Date())
                self.apply()
            }
        }
        connection.resume()
        return true
    }

    /// omux, signed by the same team as this helper. Without a team (an ad hoc build) nothing is
    /// accepted, since the requirement couldn't tell omux from any other program.
    static func clientRequirement() -> String? {
        AwakeHelperLabel.bundleID(forLabel: label).flatMap(AwakeSigning.requirement(forIdentifier:))
    }

    /// launchd stops the helper with SIGTERM when it's unregistered, switched off in Login
    /// Items, or the app is replaced. Turn sleep back on before going.
    func stop() -> Never {
        sleep.set(disabled: false)
        exit(0)
    }
}

let helper = Helper()
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let stopSignals = [SIGTERM, SIGINT].map { number in
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { helper.stop() }
    source.resume()
    return source
}
let listener = NSXPCListener(machServiceName: label)
listener.delegate = helper
listener.resume()
log.notice("listening as \(label, privacy: .public)")
RunLoop.main.run()
