import Foundation
import os

extension Timing {
    /// Sends the core's timing marks to the system log, for reading back with
    /// `log show --predicate 'subsystem == "net.pf1.omux" and category == "timing"'`.
    static func logToSystem() {
        let log = Logger(subsystem: "net.pf1.omux", category: "timing")
        sink = { what, tab, detail in
            log.notice("\(what, privacy: .public) \(tab.uuidString.prefix(8), privacy: .public) \(detail, privacy: .public)")
        }
    }
}
