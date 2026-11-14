import Foundation
import OmuxCore
import OmuxHostKit

/// What a look at a machine found.
struct MachineReport: Equatable {
    /// "Linux x86_64", as `uname -sm` says it.
    var system = ""
    var home = ""
    /// Whether `claude` is on the path of a login shell there.
    var claude = false
    /// "omux-host protocol 1 build …" when omux is set up there.
    var hostVersion: String?
    /// Whether the folder asked about exists; nil when none was asked about.
    var folderExists: Bool?
    var sessions: [SessionInfo] = []

    /// Whether this build of omux has a host program for that system.
    var supported: Bool { ["Linux x86_64", "Linux aarch64", "Linux arm64"].contains(system) }
    var running: [SessionInfo] { sessions.filter { $0.exited == nil } }
}

enum MachineState: Equatable {
    case unknown
    case checking
    case reachable(MachineReport)
    /// Why not, in words for the user.
    case unreachable(String)

    var report: MachineReport? { if case .reachable(let report) = self { return report }; return nil }
    var problem: String? { if case .unreachable(let why) = self { return why }; return nil }
}

/// The machines projects run on: which ones are known, whether each can be reached, and what
/// is on it. Everything goes through the user's own `ssh`, never asking for anything: a
/// machine that needs a password answered says so, and a session's terminal is where to answer.
@MainActor
final class RemoteMachines: ObservableObject {
    static let shared = RemoteMachines()

    @Published private(set) var states: [String: MachineState] = [:]
    /// Machines used before, newest first, kept so they can be picked again.
    @Published private(set) var remembered: [String]
    private static let key = "remoteMachines"
    private var timer: Timer?

    init() {
        remembered = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
    }

    func state(of host: String) -> MachineState { states[host] ?? .unknown }

    /// To offer when a machine is asked for: the ones used before, then the names in the
    /// user's SSH configuration.
    var suggestions: [String] {
        var seen: Set<String> = []
        return (remembered + Self.configuredHosts()).filter { seen.insert($0).inserted }
    }

    func remember(_ host: String) {
        guard Self.isValid(host) else { return }
        remembered.removeAll { $0 == host }
        remembered.insert(host, at: 0)
        UserDefaults.standard.set(remembered, forKey: Self.key)
    }

    func forget(_ host: String) {
        remembered.removeAll { $0 == host }
        states[host] = nil
        UserDefaults.standard.set(remembered, forKey: Self.key)
    }

    // MARK: What a destination may be

    /// Whether `host` can be handed to ssh as a destination: one word, and not something ssh
    /// would read as an option.
    nonisolated static func isValid(_ host: String) -> Bool {
        !host.isEmpty && host.count < 256 && !host.hasPrefix("-")
            && !host.unicodeScalars.contains { $0.properties.isWhitespace || $0.value < 0x20 || $0.value == 0x7f }
    }

    /// The names a user gave machines in ~/.ssh/config and the files it includes: `Host`
    /// entries that name one machine, not patterns.
    nonisolated static func configuredHosts(config: String = NSHomeDirectory() + "/.ssh/config", depth: Int = 0) -> [String] {
        guard depth < 4, let text = try? String(contentsOfFile: config, encoding: .utf8) else { return [] }
        let folder = (config as NSString).deletingLastPathComponent
        var hosts: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map(String.init)
            guard let keyword = words.first?.lowercased(), words.count > 1 else { continue }
            if keyword == "host" {
                hosts += words.dropFirst().filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") && isValid($0) }
            } else if keyword == "include" {
                for pattern in words.dropFirst() {
                    var path = (pattern as NSString).expandingTildeInPath
                    if !path.hasPrefix("/") { path = folder + "/" + path }
                    for file in glob(path) { hosts += configuredHosts(config: file, depth: depth + 1) }
                }
            }
        }
        var seen: Set<String> = []
        return hosts.filter { seen.insert($0).inserted }
    }

    /// The files a path with `*` in its last part names; the path itself when it has none.
    private nonisolated static func glob(_ path: String) -> [String] {
        let name = (path as NSString).lastPathComponent
        guard name.contains("*") else { return [path] }
        let folder = (path as NSString).deletingLastPathComponent
        let pattern = "^" + NSRegularExpression.escapedPattern(for: name).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            .filter { $0.range(of: pattern, options: .regularExpression) != nil }
            .map { folder + "/" + $0 }
    }

    // MARK: Asking a machine

    struct Answer: Sendable { var status: Int32; var output: String; var error: String }

    /// Runs `script` under sh on the machine and waits for it, without ever asking the user
    /// for anything.
    nonisolated static func run(_ script: String, on host: String, timeout: Int = 10) async -> Answer {
        guard isValid(host) else { return Answer(status: 255, output: "", error: "not a machine name") }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = RemoteHost.options + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", host, "sh -c " + Git.quote(script)]
            let output = Pipe(), error = Pipe()
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error
            do { try process.run() } catch { return Answer(status: 255, output: "", error: "\(error)") }
            let out = output.fileHandleForReading.readDataToEndOfFile()
            let err = error.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return Answer(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self), error: String(decoding: err, as: UTF8.self))
        }.value
    }

    /// Why ssh couldn't get there, said plainly, from what it printed.
    nonisolated static func explain(_ error: String, host: String) -> String {
        let text = error.lowercased()
        if text.contains("could not resolve hostname") { return "No machine is known by the name \(host). Check the spelling, or add it to ~/.ssh/config." }
        if text.contains("permission denied") { return "\(host) wants a password or a key omux can't give without asking. Open a session there to answer, or set up a key for it." }
        if text.contains("host key verification failed") { return "ssh doesn't know \(host) yet. Open a session there once to confirm it is the machine you mean." }
        if text.contains("connection refused") { return "\(host) refused the connection. Is its SSH server running?" }
        if text.contains("timed out") || text.contains("no route to host") || text.contains("network is unreachable") { return "\(host) didn't answer. It may be off, asleep, or not reachable from this network." }
        let last = error.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return last.isEmpty ? "Couldn't reach \(host)." : "Couldn't reach \(host): \(last)"
    }

    /// `~` and `~/x` made into real paths on the machine, without the machine's shell ever
    /// expanding anything of the user's.
    private nonisolated static let resolve = #"case "$D" in "~") D=$HOME ;; "~/"*) D="$HOME/${D#\~/}" ;; esac"#

    nonisolated static func probeScript(folder: String?) -> String {
        """
        D=\(Git.quote(folder ?? ""))
        \(resolve)
        printf 'sys=%s\\n' "$(uname -sm)"
        printf 'home=%s\\n' "$HOME"
        if "${SHELL:-/bin/sh}" -lc 'command -v claude' >/dev/null 2>&1; then echo claude=yes; else echo claude=no; fi
        if [ -x "$HOME/.omux/bin/omux-host" ]; then
          printf 'host=%s\\n' "$("$HOME/.omux/bin/omux-host" version 2>/dev/null)"
          printf 'sessions=%s\\n' "$("$HOME/.omux/bin/omux-host" list --json 2>/dev/null)"
        fi
        if [ -n "$D" ]; then if [ -d "$D" ]; then echo dir=yes; else echo dir=no; fi; fi
        """
    }

    /// Reads what the probe printed, one `key=value` a line.
    nonisolated static func report(from output: String) -> MachineReport? {
        var report = MachineReport()
        var seen = false
        for line in output.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...])
            switch line[..<equals] {
            case "sys": report.system = value; seen = true
            case "home": report.home = value
            case "claude": report.claude = value == "yes"
            case "host": report.hostVersion = value.isEmpty ? nil : value
            case "dir": report.folderExists = value == "yes"
            case "sessions": report.sessions = (try? JSONDecoder().decode([SessionInfo].self, from: Data(value.utf8))) ?? []
            default: break
            }
        }
        return seen ? report : nil
    }

    /// Looks at a machine: what it is, whether omux and Claude Code are there, what runs
    /// there, and whether `folder` exists.
    @discardableResult
    func check(_ host: String, folder: String? = nil, quietly: Bool = false) async -> MachineState {
        guard Self.isValid(host) else { return .unreachable("A machine is one word, such as devbox or me@10.0.0.5.") }
        if !quietly || states[host] == nil { states[host] = .checking }
        let answer = await Self.run(Self.probeScript(folder: folder), on: host)
        let state: MachineState
        if let report = Self.report(from: answer.output) {
            state = .reachable(report)
        } else {
            state = .unreachable(Self.explain(answer.error, host: host))
        }
        if states[host] != state { states[host] = state }
        return state
    }

    /// The folders in `path` on the machine, and where that is once `~` is worked out.
    nonisolated static func folders(on host: String, in path: String) async -> Result<(path: String, names: [String]), MachineProblem> {
        let script = """
        D=\(Git.quote(path.isEmpty ? "~" : path))
        \(resolve)
        cd "$D" 2>/dev/null || exit 3
        pwd
        ls -1p 2>/dev/null | grep '/$' | head -400
        """
        let answer = await run(script, on: host)
        if answer.status == 3 { return .failure(MachineProblem(text: "No folder \(path) on \(host).")) }
        guard answer.status == 0 else { return .failure(MachineProblem(text: explain(answer.error, host: host))) }
        var lines = answer.output.split(whereSeparator: \.isNewline).map(String.init)
        guard !lines.isEmpty else { return .failure(MachineProblem(text: "\(host) said nothing.")) }
        let here = lines.removeFirst()
        return .success((here, lines.map { String($0.dropLast()) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }))
    }

    /// Hangs up on one session there.
    func close(session id: String, on host: String) async {
        guard id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return }
        _ = await Self.run(#""$HOME/.omux/bin/omux-host" close \#(id)"#, on: host)
        await check(host, quietly: true)
    }

    /// Takes omux off the machine: hangs up on everything it runs there, stops it, and removes
    /// its folder. Returns what went wrong, if anything did.
    func removeOmux(from host: String) async -> String? {
        // Asked nicely first; then by signal, which every build of the host takes as "hang up
        // on your sessions and go", including one too old to know the request. Its socket
        // lives outside ~/.omux when the system gives users a runtime folder.
        let script = #"""
        [ -x "$HOME/.omux/bin/omux-host" ] && "$HOME/.omux/bin/omux-host" shutdown
        pkill -TERM -u "$(id -u)" -x omux-host 2>/dev/null
        i=0; while pgrep -u "$(id -u)" -x omux-host >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 0.1; i=$((i+1)); done
        pkill -KILL -u "$(id -u)" -x omux-host 2>/dev/null
        rm -rf "$HOME/.omux"
        [ -n "$XDG_RUNTIME_DIR" ] && rm -rf "$XDG_RUNTIME_DIR/omux"
        exit 0
        """#
        let answer = await Self.run(script, on: host, timeout: 15)
        await check(host, quietly: true)
        return answer.status == 0 ? nil : Self.explain(answer.error, host: host)
    }

    // MARK: Keeping watch

    /// Looks now and then at the machines that have projects, so the sidebar can say when one
    /// has gone away. Over the connection a session already holds, a look is a few bytes.
    func watch(_ hosts: @escaping @MainActor () -> Set<String>) {
        timer?.invalidate()
        let look = { [weak self] in
            guard let self else { return }
            for host in hosts() { Task { await self.check(host, quietly: true) } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in Task { @MainActor in look() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { look() }
    }
}

struct MachineProblem: Error, Equatable { var text: String }
