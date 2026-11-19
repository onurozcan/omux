import Foundation

/// A folder on another machine, written as one string, so that whatever takes a folder can be
/// handed one that is somewhere else: `omux-ssh://devbox//srv/app`, `omux-ssh://me@host/~/code`.
/// The machine is whatever ssh takes as a destination; the path follows the first slash after
/// it, and may start with `~` for that machine's home.
public enum RemotePath {
    private static let scheme = "omux-ssh://"

    /// One authenticated connection per machine, shared by everything omux runs there, so a
    /// password or a key's passphrase is asked for once and later commands start at once.
    /// Keep-alives notice a dead link in under a minute instead of hanging.
    public static let options = ["-o", "ControlMaster=auto", "-o", "ControlPath=~/.ssh/omux-%C", "-o", "ControlPersist=600",
                                 "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]

    public static func make(host: String, path: String) -> String { scheme + host + "/" + (path.isEmpty ? "~" : path) }

    public static func parse(_ location: String) -> (host: String, path: String)? {
        guard location.hasPrefix(scheme) else { return nil }
        let rest = location.dropFirst(scheme.count)
        guard let slash = rest.firstIndex(of: "/"), slash != rest.startIndex else { return nil }
        let path = String(rest[rest.index(after: slash)...])
        return (String(rest[..<slash]), path.isEmpty ? "~" : path)
    }

    public static func isRemote(_ location: String) -> Bool { location.hasPrefix(scheme) }

    /// Shell lines that make `$D` a real path there: `~` and `~/x` worked out against that
    /// machine's home, without its shell expanding anything else in the name.
    public static let resolve = #"case "$D" in "~") D=$HOME ;; "~/"*) D="$HOME/${D#\~/}" ;; esac"#

    /// The script's opening: `$D` set to `path`, and the shell standing in it.
    public static func entering(_ path: String) -> String {
        "D=" + Git.quote(path) + "\n" + resolve + "\ncd \"$D\" 2>/dev/null || exit 127\n"
    }

    public struct Answer: Sendable {
        public var status: Int32
        public var output: Data
        public var error: String
        public var text: String { String(decoding: output, as: UTF8.self) }
    }

    /// Runs `script` under sh on the machine and waits, never asking the user for anything: a
    /// machine that would need a password answered fails here, and a session's terminal is
    /// where that gets answered. `input` goes in as the script's standard input; the output
    /// comes back as bytes, so a file can be fetched whole.
    public static func run(_ script: String, on host: String, input: URL? = nil, timeout: Int = 10) -> Answer {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=\(timeout)", host, "sh -c " + Git.quote(script)]
        let output = Pipe(), error = Pipe()
        process.standardInput = input.flatMap { try? FileHandle(forReadingFrom: $0) } ?? FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return Answer(status: 255, output: Data(), error: "\(error)") }
        // Standard error on its own thread: a full pipe would otherwise block the far end.
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let reading = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: reading) { box.data = error.fileHandleForReading.readDataToEndOfFile() }
        let out = output.fileHandleForReading.readDataToEndOfFile()
        reading.wait()
        process.waitUntilExit()
        return Answer(status: process.terminationStatus, output: out, error: String(decoding: box.data, as: UTF8.self))
    }
}
