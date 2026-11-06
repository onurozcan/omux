import Foundation
import SwiftUI

/// Reads Claude Code's OAuth token from the Keychain and polls the same usage
/// endpoint Claude Code's `/usage` command uses.
@MainActor
final class UsageMonitor: ObservableObject {
    struct Limit: Identifiable {
        let id: String
        let label: String
        let percent: Int
        let resetsAt: Date?

        var tint: Color {
            percent >= 90 ? Palette.error : percent >= 70 ? Palette.needs : Palette.quiet
        }

        var resetText: String {
            guard let resetsAt else { return label }
            let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
            let h = seconds / 3600, m = (seconds % 3600) / 60
            let when = seconds >= 86400 ? "\(seconds / 86400)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(m)m"
            return "\(label) resets in \(when)"
        }
    }

    @Published private(set) var limits: [Limit] = []
    /// Short, for the sidebar; `detail` says what to do about it.
    @Published private(set) var error: String?
    @Published private(set) var detail: String?

    private var timer: Timer?

    /// Polls at the interval chosen in Settings (seconds); re-arms when it changes.
    func start() {
        let interval = UserDefaults.standard.double(forKey: Prefs.usageInterval)
        schedule(every: interval > 0 ? interval : 300)
        refresh()
    }

    func schedule(every seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        Task { await load() }
    }

    private struct Response: Decodable {
        struct Entry: Decodable {
            struct Scope: Decodable {
                struct Model: Decodable { let display_name: String? }
                let model: Model?
            }
            let kind: String
            let percent: Int
            let resets_at: String?
            let scope: Scope?
        }
        let limits: [Entry]
    }

    private enum Credentials { case token(String), notFound, noPlan, denied(String) }

    private func fail(_ short: String, _ long: String) {
        limits = []; error = short; detail = long
    }

    private func load() async {
        let token: String
        switch await Task.detached(operation: Self.readToken).value {
        case .token(let value): token = value
        case .notFound:
            return fail("No Claude login", "No Claude Code login found. Run claude, then /login with a Claude.ai plan. Click to check again.")
        case .noPlan:
            return fail("Needs a Claude.ai plan", "Claude Code is signed in with an API key. Usage limits exist only for Claude.ai plans (/login in claude). Click to check again.")
        case .denied(let message):
            return fail("Keychain access denied", "Couldn't read Claude Code's login from the Keychain: \(message). Click to try again and choose Allow when macOS asks.")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 401 || status == 403 {
                    return fail("Claude login expired", "Claude Code's login no longer works. Run claude to sign in again, then click to check again.")
                }
                return fail("Usage unavailable", "Anthropic's usage endpoint answered \(status). Click to try again.")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            limits = decoded.limits.map { entry in
                let label: String
                switch entry.kind {
                case "session": label = "5h"
                case "weekly_all": label = "Week"
                default: label = entry.scope?.model?.display_name ?? entry.kind
                }
                return Limit(id: entry.kind + (entry.scope?.model?.display_name ?? ""),
                             label: label,
                             percent: entry.percent,
                             resetsAt: entry.resets_at.flatMap { iso.date(from: $0) })
            }
            error = nil; detail = nil
        } catch {
            fail("Usage unavailable", "Couldn't reach Anthropic's usage endpoint: \(error.localizedDescription). Click to try again.")
        }
    }

    /// Reads the token the way Claude Code stores it, through /usr/bin/security, which is
    /// already allowed on that Keychain item, so macOS never prompts for omux itself.
    private static func readToken() -> Credentials {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        guard (try? process.run()) != nil else { return .denied("couldn't run /usr/bin/security") }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 44 || message.contains("could not be found") { return .notFound }
            return .denied(message.isEmpty ? "security exited with \(process.terminationStatus)" : message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .denied("the Keychain item isn't the expected JSON") }
        guard let oauth = json["claudeAiOauth"] as? [String: Any], let token = oauth["accessToken"] as? String else { return .noPlan }
        return .token(token)
    }
}
