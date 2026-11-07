// omux-awake: the launch daemon that keeps the Mac awake with the lid closed while omux asks it
// to. It runs as root only because `pmset disablesleep` needs it, and does nothing else:
// - it answers omux alone (same signing team and bundle id), over local XPC, never the network;
// - a hold lasts one lease, which omux renews; a crashed or hung omux lets the Mac sleep again;
// - losing the connection that holds lets the Mac sleep at once;
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

/// Sets the system-wide "sleep disabled" flag when it changes. `again` sets it even if this
/// helper last set it the same way, since another program (the other build's helper starting
/// up, or `sudo pmset`) may have changed it since.
final class SleepSwitch {
    private var disabled: Bool?

    func set(disabled wanted: Bool, again: Bool = false) {
        guard again || wanted != disabled else { return }
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

/// One connection's view of the helper: what it asks carries which connection asked, so the
/// lease knows whose hold a dropped connection was.
final class Client: NSObject, AwakeHelperXPC {
    private let helper: Helper
    let id: Int

    init(helper: Helper, id: Int) {
        self.helper = helper
        self.id = id
    }

    func hold(leaseSeconds: Double, reply: @escaping (Bool, String?) -> Void) {
        helper.hold(leaseSeconds: leaseSeconds, client: id, reply: reply)
    }

    func release(reply: @escaping () -> Void) {
        helper.release(client: id, reply: reply)
    }
}

/// The helper's state, touched only on the main queue (connection ids aside, under their lock).
final class Helper: NSObject, NSXPCListenerDelegate {
    private var lease = AwakeLease()
    private let sleep = SleepSwitch()
    private var timer: Timer?
    private let requirement: String?
    private var nextClient = 0
    private let clientLock = NSLock()

    override init() {
        requirement = Helper.clientRequirement()
        super.init()
        sleep.set(disabled: false)
    }

    /// Sets sleep to what the lease says, and wakes again only when that next changes, so an
    /// idle helper does nothing. `granted`: a hold was just granted, so disable sleep again
    /// even if this helper had already, once per renewal.
    private func apply(granted: Bool = false) {
        let disabled = lease.tick(now: Date())
        sleep.set(disabled: disabled, again: granted && disabled)
        timer?.invalidate()
        timer = nil
        guard let next = lease.nextChange else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.apply() }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    // MARK: What clients ask

    func hold(leaseSeconds: Double, client: Int, reply: @escaping (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            let seconds = min(max(leaseSeconds, 10), 300)
            switch self.lease.hold(lease: seconds, now: Date(), owner: client) {
            case .granted:
                self.apply(granted: true)
                reply(true, nil)
            case .refusedCooldown(let until):
                self.apply()
                let hours = Int(self.lease.ceiling / 3600)
                reply(false, "the Mac has been kept awake for \(hours) hours, so it may sleep until \(until.formatted(date: .omitted, time: .shortened))")
            }
        }
    }

    func release(client: Int, reply: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.lease.release(by: client, now: Date())
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
        let id = clientLock.withLock { nextClient += 1; return nextClient }
        let client = Client(helper: self, id: id)
        connection.exportedInterface = NSXPCInterface(with: AwakeHelperXPC.self)
        connection.exportedObject = client
        connection.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.lease.dropped(owner: client.id, now: Date())
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
