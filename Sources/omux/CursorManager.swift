import Foundation
import SwiftUI

struct CursorError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message.isEmpty ? "cursor-agent failed" : message
    }
}

/// Cursor's side of a session. `cursor-agent` runs as an ordinary command in the session's
/// shell, so this only covers the two things the terminal can't tell us: the chat a session
/// is pinned to, and how much of the account's included usage this billing cycle is gone.
@MainActor
final class CursorManager: ObservableObject {
    static let shared = CursorManager()

    @Published private(set) var limits: [UsageMonitor.Limit] = []
    @Published private(set) var usageError: String?

    private var refreshingUsage = false

    private init() {}

    /// A fresh, empty chat for a session to resume from here on. Cursor can't be told which
    /// id to use, the way Claude Code can, so omux asks it for one and keeps it.
    func createChat() async throws -> String {
        let output = try await Task.detached { try Self.run("cursor-agent create-chat") }.value
        // The command prints the id alone; an extra line means an update notice or a prompt.
        guard let id = output.split(separator: "\n").last.map(String.init),
              UUID(uuidString: id) != nil
        else { throw CursorError("cursor-agent create-chat didn't return a chat id") }
        return id
    }

    // MARK: Usage

    private struct Response: Decodable {
        struct Plan: Decodable {
            /// How much of the included usage is gone, the figure Cursor's own usage
            /// display prefers over the raw allowance.
            let totalPercentUsed: Double?
        }
        /// Milliseconds since the epoch, sent as a string.
        let billingCycleEnd: String?
        let planUsage: Plan?
    }

    func refreshUsage() async {
        guard !refreshingUsage else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }

        var secret = ProcessInfo.processInfo.environment["CURSOR_API_KEY"]
        if secret == nil { secret = await Task.detached(operation: Self.readToken).value }
        guard let token = secret, !token.isEmpty else {
            return fail("Cursor isn't signed in: run cursor-agent login")
        }

        let endpoint = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.httpBody = Data("{}".utf8)
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 401 || status == 403 {
                    return fail("Cursor login expired: run cursor-agent login")
                }
                return fail("Cursor's usage endpoint answered \(status)")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let percent = decoded.planUsage?.totalPercentUsed else {
                return fail("Cursor usage unavailable for this account")
            }
            limits = [UsageMonitor.Limit(
                id: "cursor-plan",
                label: "Plan",
                percent: Int(percent.rounded()),
                resetsAt: decoded.billingCycleEnd.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            )]
            usageError = nil
        } catch {
            fail("Couldn't reach Cursor's usage endpoint: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        limits = []
        usageError = message
    }

    /// Reads the login through /usr/bin/security, which is already allowed on that Keychain
    /// item, so macOS never prompts for omux itself. The token is never stored or logged.
    private static func readToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "cursor-access-token", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// Runs a Cursor command through the user's login shell. A non-interactive shell doesn't
    /// read `.zshrc`, so the places `cursor-agent` installs itself are named outright rather
    /// than left to whatever PATH omux was launched with.
    private nonisolated static func run(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        process.standardInput = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CursorError(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
