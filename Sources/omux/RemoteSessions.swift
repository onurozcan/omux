import Foundation
import OmuxCore
import OmuxHostKit

/// Projects that live on another machine. Their sessions run there, under `omux-host`, and
/// go on running when the Mac sleeps or omux quits. A session's terminal here is an SSH
/// connection attached to it: the same terminal view as a local session, fed from afar, so
/// status, titles and everything read off the screen work as they do locally.
enum RemoteHost {
    /// One authenticated connection per host, shared by everything omux runs there, so a
    /// password or a key's passphrase is asked for once and later connections open at once.
    /// Keep-alives notice a dead link in under a minute instead of hanging.
    static let options = ["-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/omux-%C", "-o", "ControlPersist=600",
                          "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
    static let remoteBinary = "~/.omux/bin/omux-host"

    /// Where this build keeps `omux-host` for the systems it can set up: in the app bundle,
    /// or a folder named by OMUX_HOST_BINARIES while developing.
    static var binaries: String? {
        if let path = ProcessInfo.processInfo.environment["OMUX_HOST_BINARIES"], !path.isEmpty { return path }
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("host").path,
              FileManager.default.fileExists(atPath: bundled) else { return nil }
        return bundled
    }

    /// Where the copies of a host's conversations are kept, one folder per session.
    static var mirrorRoot: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Persistence.isBeta ? "omux-beta" : "omux", isDirectory: true).appendingPathComponent("remote", isDirectory: true)
    }

    static func mirrorFolder(host: String, tab: UUID) -> URL {
        let safe = String(host.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
        return mirrorRoot.appendingPathComponent(safe, isDirectory: true).appendingPathComponent(tab.uuidString.lowercased(), isDirectory: true)
    }

    /// The mirrored transcript of a Claude Code session, on whichever host it runs.
    static func mirroredTranscript(_ session: String) -> URL? {
        let manager = FileManager.default
        for host in (try? manager.contentsOfDirectory(at: mirrorRoot, includingPropertiesForKeys: nil)) ?? [] {
            for tab in (try? manager.contentsOfDirectory(at: host, includingPropertiesForKeys: nil)) ?? [] {
                let file = tab.appendingPathComponent(session + ".jsonl")
                if manager.fileExists(atPath: file.path) { return file }
            }
        }
        return nil
    }

    /// The command for the far end: the session with the tab's id, started if it isn't running.
    static func remoteCommand(tab: UUID, name: String, directory: String?, run: String?) -> String {
        var words = ["exec", remoteBinary, "session", tab.uuidString.lowercased(), "--name", Git.quote(name)]
        // "~" and "~/…" are left for the host to expand: its home, not ours.
        if let directory, !directory.isEmpty { words += ["--dir", Git.quote(directory)] }
        if let run, !run.isEmpty { words += ["--run", Git.quote(run)] }
        return words.joined(separator: " ")
    }

    /// What a remote session's terminal runs here: set the host up if it isn't, then attach,
    /// and attach again whenever the connection drops. In the terminal, so whatever SSH asks
    /// (a password, a new host's key) is asked where it can be answered.
    static func script(host: String, tab: UUID, name: String, directory: String?, run: String?) -> String {
        let ssh = (["ssh"] + options).joined(separator: " ")
        return """
        H=\(Git.quote(host))
        BIN=\(Git.quote(binaries ?? ""))
        WANT='omux-host protocol \(HostProtocol.version)'
        if [ "$(\(ssh) "$H" '\(remoteBinary) version 2>/dev/null')" != "$WANT" ]; then
          printf 'Setting up omux on %s…\\n' "$H"
          SYS=$(\(ssh) "$H" 'uname -sm') || { printf "Couldn't reach %s.\\n" "$H"; exit 1; }
          case "$SYS" in
            "Linux x86_64") F=omux-host-linux-x86_64 ;;
            "Linux aarch64"|"Linux arm64") F=omux-host-linux-aarch64 ;;
            *) printf "omux can't run sessions on %s yet.\\n" "$SYS"; exit 1 ;;
          esac
          [ -f "$BIN/$F" ] || { printf 'This build of omux has no host program for %s.\\n' "$SYS"; exit 1; }
          \(ssh) "$H" 'mkdir -p ~/.omux/bin && cat > ~/.omux/bin/omux-host.new && chmod +x ~/.omux/bin/omux-host.new && mv ~/.omux/bin/omux-host.new ~/.omux/bin/omux-host' < "$BIN/$F" \\
            || { printf "Couldn't install omux on %s.\\n" "$H"; exit 1; }
          printf 'Ready.\\n'
        fi
        while :; do
          \(ssh) -t "$H" \(Git.quote(remoteCommand(tab: tab, name: name, directory: directory, run: run)))
          code=$?
          [ $code -ne 255 ] && exit $code
          printf '\\r\\n[connection to %s lost; the session keeps running there. Trying again…]\\r\\n' "$H"
          sleep 2
        done
        """
    }

    /// Runs one command on the host and forgets it: closing a session there.
    static func run(_ command: String, on host: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + ["-o", "BatchMode=yes", host, command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Keeps the copies of remote sessions' Claude Code files up to date, one SSH connection per
/// session, restarted when it drops for as long as the session is open here.
@MainActor
final class RemoteMirrors {
    static let shared = RemoteMirrors()

    private final class Running {
        let host: String, directory: String, session: String, folder: URL
        var process: Process?
        /// The far end's standard input, held open: its closing is how the far end knows to stop.
        var keep: Pipe?
        init(host: String, directory: String, session: String, folder: URL) {
            self.host = host; self.directory = directory; self.session = session; self.folder = folder
        }
    }
    private var mirrors: [UUID: Running] = [:]

    /// Follows `session`, a Claude Code session in `directory` on `host`, into the tab's folder.
    func follow(tab: UUID, host: String, directory: String, session: String) {
        let folder = RemoteHost.mirrorFolder(host: host, tab: tab)
        if let existing = mirrors[tab], existing.host == host, existing.directory == directory, existing.session == session { return }
        stop(tab)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let mirror = Running(host: host, directory: directory, session: session, folder: folder)
        mirrors[tab] = mirror
        connect(tab, mirror)
    }

    func stop(_ tab: UUID) {
        mirrors.removeValue(forKey: tab)?.process?.terminate()
    }

    /// Closing the session for good: its copy goes too.
    func forget(tab: UUID, host: String) {
        stop(tab)
        try? FileManager.default.removeItem(at: RemoteHost.mirrorFolder(host: host, tab: tab))
    }

    private func connect(_ tab: UUID, _ mirror: Running) {
        guard mirrors[tab] === mirror else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        let command = "\(RemoteHost.remoteBinary) mirror --dir \(Git.quote(mirror.directory)) --session \(mirror.session)"
        // Never asks for anything: the session's terminal does the asking, this rides its connection.
        process.arguments = RemoteHost.options + ["-o", "BatchMode=yes", mirror.host, command]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let folder = mirror.folder
        let splitter = SplitterBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let frames = try? splitter.feed(data) else { return }
            for frame in frames {
                if let update = try? Wire.decode(Mirror.Update.self, from: frame) { try? Mirror.apply(update, to: folder) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            output.fileHandleForReading.readabilityHandler = nil
            // Not set up yet, or the link dropped: again in a moment, while the session is open.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.connect(tab, mirror) }
        }
        do {
            try process.run()
            mirror.process = process
            // What the copy holds already, so only the rest is sent.
            if let have = try? Wire.encode(Mirror.have(in: folder, session: mirror.session)) {
                try? input.fileHandleForWriting.write(contentsOf: have)
            }
            mirror.keep = input
        } catch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.connect(tab, mirror) }
        }
    }
}

/// A frame splitter the pipe's reading queue can hold on to.
private final class SplitterBox: @unchecked Sendable {
    private var splitter = Wire.Splitter()
    func feed(_ data: Data) throws -> [Data] { try splitter.feed(data) }
}
