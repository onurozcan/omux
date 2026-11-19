import Foundation

public enum Transcript {
    /// JSON objects for the complete lines appended after `offset`; a partial last line
    /// waits in `remainder` for the next read.
    public static func newObjects(_ url: URL, offset: inout UInt64, remainder: inout Data) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return [] }
        try? handle.seek(toOffset: offset)
        let chunk = handle.readData(ofLength: Int(min(size - offset, 64 << 20)))
        offset += UInt64(chunk.count)
        let data = remainder + chunk
        guard let end = data.lastIndex(of: 0x0A) else { remainder = data; return [] }
        remainder = Data(data[data.index(after: end)...])
        return data[..<end].split(separator: 0x0A).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
        }
    }

    /// "Grep "useTheme"", "Read src/app.tsx", "Bash npm test".
    public static func summary(name: String, input: [String: Any]) -> String {
        var detail = ""
        if let command = input["command"] as? String {
            detail = command
        } else if let path = (input["file_path"] ?? input["notebook_path"]) as? String {
            detail = (path as NSString).lastPathComponent
        } else if let pattern = input["pattern"] as? String {
            detail = "\"\(pattern)\""
        } else if let other = ["url", "query", "description", "prompt", "path"].lazy.compactMap({ input[$0] as? String }).first {
            detail = other
        }
        detail = detail.replacingOccurrences(of: "\n", with: " ")
        if detail.count > 90 { detail = String(detail.prefix(90)) + "…" }
        return detail.isEmpty ? name : "\(name) \(detail)"
    }

    public static func text(of content: Any?) -> String {
        if let string = content as? String { return string }
        if let items = content as? [[String: Any]] {
            return items.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        }
        return ""
    }
}
