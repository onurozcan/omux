import Foundation
import os

/// Timestamps for the moments a prompt and a reply pass through, for reading back with
/// `log show --predicate 'subsystem == "net.pf1.omux" and category == "timing"'`.
/// Nothing the user wrote is logged, only which session and what happened.
enum Timing {
    static let log = Logger(subsystem: "net.pf1.omux", category: "timing")

    static func mark(_ what: StaticString, _ tab: UUID, _ detail: String = "") {
        log.info("\(what, privacy: .public) \(tab.uuidString.prefix(8), privacy: .public) \(detail, privacy: .public)")
    }
}
