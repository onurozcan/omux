import Foundation
import SwiftUI

@MainActor
final class AntigravityManager: ObservableObject {
    static let shared = AntigravityManager()

    @Published private(set) var limits: [UsageMonitor.Limit] = []
    @Published private(set) var usageError: String?
    @Published private(set) var plan: String?
    @Published private(set) var model: String?
    @Published private(set) var detail: String?

    private var refreshing = false

    func refreshUsage() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        // 1. Read active model from settings.json
        loadLocalSettings()

        // 2. Read token from macOS Keychain (service "gemini", account "antigravity")
        let token = await Task.detached(operation: Self.readToken).value
        guard let token, !token.isEmpty else {
            limits = []
            plan = "Antigravity"
            usageError = "Antigravity not signed in: run agy"
            return
        }

        // 3. Query Cloud Code API for plan verification
        do {
            var request = URLRequest(url: URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if status == 401 || status == 403 {
                    limits = []
                    usageError = "Antigravity login expired: run agy to sign in"
                    return
                }
                limits = []
                usageError = "Antigravity usage unavailable"
                return
            }

            struct LoadResponse: Decodable {
                struct Tier: Decodable {
                    let id: String?
                    let name: String?
                    let description: String?
                }
                let allowedTiers: [Tier]?
            }

            let decoded = try JSONDecoder().decode(LoadResponse.self, from: data)
            if let firstTier = decoded.allowedTiers?.first {
                plan = firstTier.name ?? "Gemini Code Assist"
                detail = firstTier.description ?? "Active coding plan"

                // Calculate rolling 5-hour and weekly usage metrics (dolmuş kullanım hakkı)
                let (w5h, wWeek) = await Task.detached(operation: Self.readUsageMetrics).value

                // Nominal rolling limits: 100 steps per 5h window, 500 steps per week
                let used5h = min(100, max(0, Int(round(Double(w5h.count) / 100.0 * 100))))
                let usedWeek = min(100, max(0, Int(round(Double(wWeek.count) / 500.0 * 100))))

                let resets5h = w5h.oldestDate.map { $0.addingTimeInterval(5 * 3600) } ?? Date().addingTimeInterval(5 * 3600)
                let resetsWeek = wWeek.oldestDate.map { $0.addingTimeInterval(7 * 86400) } ?? Date().addingTimeInterval(7 * 86400)

                limits = [
                    UsageMonitor.Limit(
                        id: "agy-5h",
                        label: "5h",
                        percent: used5h,
                        resetsAt: resets5h
                    ),
                    UsageMonitor.Limit(
                        id: "agy-week",
                        label: "Week",
                        percent: usedWeek,
                        resetsAt: resetsWeek
                    )
                ]
                usageError = nil
            } else {
                plan = "Antigravity"
                limits = []
                usageError = "No active Antigravity tier found"
            }
        } catch {
            limits = []
            usageError = error.localizedDescription
        }
    }

    private func loadLocalSettings() {
        let path = NSHomeDirectory() + "/.gemini/antigravity-cli/settings.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let m = json["model"] as? String, !m.isEmpty {
            self.model = m
        }
    }

    struct StepWindow {
        let count: Int
        let oldestDate: Date?
    }

    private static func readUsageMetrics() -> (StepWindow, StepWindow) {
        let w5h = readWindow(hours: 5)
        let wWeek = readWindow(hours: 24 * 7)
        return (w5h, wWeek)
    }

    private static func readWindow(hours: Int) -> StepWindow {
        let home = NSHomeDirectory()
        let dbPaths = [
            "\(home)/.gemini/antigravity-cli/conversation_summaries.db",
            "\(home)/.gemini/antigravity/conversation_summaries.db"
        ]
        guard let dbPath = dbPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return StepWindow(count: 0, oldestDate: nil)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dbPath,
            "SELECT coalesce(sum(step_count), 0), coalesce(min(last_modified_time), '') FROM conversation_summaries WHERE last_modified_time > datetime('now', '-\(hours) hours');"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return StepWindow(count: 0, oldestDate: nil) }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return StepWindow(count: 0, oldestDate: nil)
        }
        let parts = text.split(separator: "|", omittingEmptySubsequences: false)
        let count = parts.first.flatMap { Int($0) } ?? 0
        let dateStr = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let oldestDate = parseDate(dateStr)
        return StepWindow(count: count, oldestDate: oldestDate)
    }

    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd HH:mm:ss.SSSSSSZZZZZ",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss"
        ] {
            df.dateFormat = format
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    private static func readToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "gemini", "-a", "antigravity", "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let raw = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return nil
        }
        var jsonString = raw
        if raw.hasPrefix("go-keyring-base64:") {
            let base64Part = String(raw.dropFirst("go-keyring-base64:".count))
            if let decodedData = Data(base64Encoded: base64Part),
               let decoded = String(data: decodedData, encoding: .utf8) {
                jsonString = decoded
            }
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let tokenObj = root["token"] as? [String: Any],
              let accessToken = tokenObj["access_token"] as? String, !accessToken.isEmpty else {
            return nil
        }
        return accessToken
    }
}
