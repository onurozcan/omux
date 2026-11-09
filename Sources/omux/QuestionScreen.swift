import Foundation

/// Claude Code's question dialog, read back from the terminal screen so the card can follow it.
/// The dialog has a row of tabs along the top, one per question and then Submit; the current
/// question's options as numbered rows, with "Type something" and "Chat about this" after them
/// and, for a multi-select question, a Submit row; and a review page at the end, which asks
/// "Ready to submit your answers?". The highlighted row carries ❯.
struct QuestionDialog: Equatable {
    enum Kind: Equatable {
        /// An option of the current question, by index.
        case option(Int)
        /// "Type something": a typed answer.
        case type
        /// A multi-select question's own Submit row.
        case submit
        /// "Chat about this": rejects the questions and lets you reply.
        case chat
        /// The review page's "Submit answers" and "Cancel".
        case submitAnswers, cancel
    }
    struct Row: Equatable {
        var kind: Kind
        /// The number the dialog gives the row, when it has one.
        var number: Int?
        /// A multi-select box: ticked or not. nil for rows without one.
        var checked: Bool?
    }
    enum Page: Equatable { case question(Int), review }

    var page: Page
    var rows: [Row]
    /// Which row carries ❯.
    var cursor: Int?
    /// Per question tab, whether it shows as answered (☒ rather than ☐).
    var answered: [Bool]
    /// On the review page, the "question → answer" lines as shown.
    var review: [String] = []

    func row(_ kind: Kind) -> Int? { rows.firstIndex { $0.kind == kind } }
}

enum QuestionScreen {
    static let up = "\u{1b}[A"
    static let down = "\u{1b}[B"
    static let enter = "\r"
    private static let rowPattern = try! NSRegularExpression(pattern: #"^\s*(❯)?\s*(\d+)\.\s+(?:\[([^\]])\]\s+)?(.*?)\s*$"#)
    private static let submitPattern = try! NSRegularExpression(pattern: #"^\s*(❯)?\s+Submit\s*$"#)

    /// The dialog on screen, or nil when the screen doesn't show one (the agent moved on, or the
    /// typed-answer field is open). `questions` tells which question the page shows.
    static func parse(_ lines: [String], questions: [Question]) -> QuestionDialog? {
        guard let header = lines.lastIndex(where: { $0.contains("✔ Submit") && ($0.contains("☐") || $0.contains("☒")) }) else { return nil }
        let answered = lines[header].compactMap { $0 == "☒" ? true : $0 == "☐" ? false : nil }
        let body = Array(lines[(header + 1)...])
        let hint = body.firstIndex { $0.contains("Esc to cancel") || $0.contains("Enter to select") } ?? body.count
        let page = Array(body[..<hint])

        if page.contains(where: { $0.contains("Ready to submit your answers?") }) {
            var rows: [QuestionDialog.Row] = []
            var cursor: Int?
            var review: [String] = []
            for line in page {
                if let m = rowPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let label = line[Range(m.range(at: 4), in: line)!]
                    let kind: QuestionDialog.Kind = label.hasPrefix("Submit") ? .submitAnswers : .cancel
                    if m.range(at: 1).location != NSNotFound { cursor = rows.count }
                    rows.append(.init(kind: kind, number: Int(line[Range(m.range(at: 2), in: line)!]), checked: nil))
                } else {
                    let t = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "│ "))
                    if t.hasPrefix("●") { review.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                    else if t.hasPrefix("→"), !review.isEmpty { review[review.count - 1] += " → " + String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
                }
            }
            return QuestionDialog(page: .review, rows: rows, cursor: cursor, answered: answered, review: review)
        }

        // The question shown: its text comes right after the tabs, marked with │.
        var index: Int?
        if let line = page.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("│") }) {
            let shown = normalized(String(line.drop { $0 != "│" }.dropFirst()))
            index = questions.indices.first { i in
                let text = normalized(questions[i].text)
                let probe = String(shown.prefix(24))
                return !probe.isEmpty && (text.hasPrefix(probe) || shown.hasPrefix(String(text.prefix(24))))
            }
        }
        let current = index ?? answered.firstIndex(of: false) ?? 0
        // The question's own options come first, however they are worded; the dialog's rows follow.
        let expected = questions.indices.contains(current) ? questions[current].options.count : nil
        var rows: [QuestionDialog.Row] = []
        var cursor: Int?
        var options = 0
        for line in page {
            if let m = rowPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let label = String(line[Range(m.range(at: 4), in: line)!])
                let box = m.range(at: 3).location == NSNotFound ? nil : String(line[Range(m.range(at: 3), in: line)!])
                let checked = box.map { $0 != " " }
                let kind: QuestionDialog.Kind
                if let expected, options < expected { kind = .option(options); options += 1 }
                else if label.hasPrefix("Type something") { kind = .type }
                else if label.hasPrefix("Chat about this") { kind = .chat }
                else { kind = .option(options); options += 1 }
                if m.range(at: 1).location != NSNotFound { cursor = rows.count }
                rows.append(.init(kind: kind, number: Int(line[Range(m.range(at: 2), in: line)!]), checked: checked))
            } else if let m = submitPattern.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                if m.range(at: 1).location != NSNotFound { cursor = rows.count }
                rows.append(.init(kind: .submit, number: nil, checked: nil))
            }
        }
        guard !rows.isEmpty else { return nil }
        return QuestionDialog(page: .question(current), rows: rows, cursor: cursor, answered: answered)
    }

    /// The arrow keys that move the highlight from `cursor` to `row`.
    static func keys(from cursor: Int, to row: Int) -> String {
        row > cursor ? String(repeating: down, count: row - cursor) : String(repeating: up, count: cursor - row)
    }

    private static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
