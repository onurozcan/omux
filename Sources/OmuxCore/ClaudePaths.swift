import Foundation

/// Where Claude Code keeps a project's conversations.
public enum ClaudePaths {
    /// Claude Code's folder name for a project: its path with everything but ASCII letters
    /// and digits turned into "-".
    public static func projectFolder(for directory: String) -> String {
        var path = (directory as NSString).expandingTildeInPath
        // Without a trailing slash or doubled ones, as Claude Code sees the folder it runs in.
        path = "/" + path.split(separator: "/").joined(separator: "/")
        return String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// ~/.claude/projects/<project> on this machine for a session's working folder.
    public static func projectURL(for directory: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects/" + projectFolder(for: directory))
    }
}
