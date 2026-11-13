import Foundation

/// The PATH the user's interactive shell has, for the `codex` and `claude` omux runs itself:
/// launched from the Dock, omux gets the system's PATH, and tools installed by nvm, volta or a
/// line in .zshrc aren't on it. Read once from `$SHELL -ilc`, with the inherited PATH and the
/// usual tool folders added, so a slow or silent dotfile still leaves a working PATH.
public enum ShellPath {
    nonisolated(unsafe) private static var cached: String?
    private static let lock = NSLock()

    /// Blocks on the first call for as long as the shell takes to start; call it off the main thread.
    public static var current: String {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let value = resolve()
        cached = value
        return value
    }

    public static func load() async -> String {
        await Task.detached(priority: .userInitiated) { current }.value
    }

    /// Reads the shell's PATH ahead of the first Codex start.
    public static func warmUp() {
        Task.detached(priority: .utility) { _ = current }
    }

    private static func resolve(home: String = NSHomeDirectory(), inherited: String? = ProcessInfo.processInfo.environment["PATH"], shell: String? = nil) -> String {
        var dirs: [String] = []
        if let shell = shell ?? readShellPath() { dirs += shell.split(separator: ":").map(String.init) }
        dirs += (inherited ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        dirs += ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.volta/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "\(home)/.cargo/bin"]
        let node = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: node) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.map { "\(node)/\($0)/bin" }
        }
        return Self.joined(dirs)
    }

    /// The folders in order, each once, empty ones dropped.
    public static func joined(_ dirs: [String]) -> String {
        var seen: Set<String> = []
        return dirs.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    private static func readShellPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "printf '\\n%s' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: deadline)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        deadline.cancel()
        // Dotfiles may print first; the PATH is the last line.
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0, let last = text.split(separator: "\n").last?.trimmingCharacters(in: .whitespaces), last.contains("/") else { return nil }
        return last
    }
}
