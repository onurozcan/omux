import Foundation

/// Timestamps for the moments a prompt and a reply pass through. The core only names the
/// moments; whoever runs it decides where they go, such as the system log in the Mac app.
/// Nothing the user wrote is passed, only which session and what happened.
public enum Timing {
    nonisolated(unsafe) public static var sink: (_ what: String, _ tab: UUID, _ detail: String) -> Void = { _, _, _ in }

    public static func mark(_ what: String, _ tab: UUID, _ detail: String = "") { sink(what, tab, detail) }
}
