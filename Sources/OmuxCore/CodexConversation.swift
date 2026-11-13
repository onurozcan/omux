import Foundation

public struct CodexConversation: Identifiable, Hashable {
    public let id: String
    public let cwd: String
    public let name: String
    public let date: Date

    public init?(_ raw: [String: Any]) {
        guard let id = raw["id"] as? String, let cwd = raw["cwd"] as? String else { return nil }
        self.id = id; self.cwd = cwd
        name = (raw["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (raw["preview"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Codex conversation"
        date = Date(timeIntervalSince1970: (raw["updatedAt"] as? NSNumber)?.doubleValue ?? 0)
    }
}
