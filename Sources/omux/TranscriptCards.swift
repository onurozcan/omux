import SwiftUI

// The native cards the transcript view shows above the compose box when the agent waits:
// a permission with the pending edit, a plan, a question, or a prompt only on the screen.

/// What Claude Code draws on the terminal that omux recognizes, in one place. Taken from
/// Claude Code 2.1.317; a new version that rewords a prompt breaks these, nothing else.
enum ClaudeScreen {
    static let version = "2.1.317"
    static let trustFolder = "trust this folder"
    static let switchModel = "Switch model?"
    static let changeEffort = "Change effort level?"
    /// The permission prompt's second option, when it is a "don't ask again" rather than a "No".
    static let allowForSession = ["don't ask again", "allow all"]
    static let modes: [(String, String)] = [("plan mode", "plan"), ("auto mode", "auto"), ("accept edits", "accept edits"), ("bypass permissions", "bypass")]
    static let modeHint = "shift+tab"
    /// A reply line in the TUI starts with this marker.
    static let reply = "● "
    /// Lines that end a reply: tool results, the prompt box, spinners.
    static let replyEnds = ["⎿", "╭", "╰", "│", "─", "> ", "✻", "✶", "✽", "✢", "·", "⏵", "⏺"]
}

/// Allow or deny the tool the agent is waiting on, with the edit it wants to make.
struct PermissionCard: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var codex = CodexManager.shared
    let tabID: UUID
    let provider: SessionProvider
    let pending: ToolRow?

    var body: some View { WithRuntime(tabID) { _ in sessionBody } }

    /// Drawn again whenever this session's live state changes; see `WithRuntime`.
    @ViewBuilder private var sessionBody: some View {
        let approval = codex.approval(for: tabID)
        let runtime = store.runtime[tabID]
        let detail = approval?.detail
            ?? runtime?.statusDetail.map { $0.replacingOccurrences(of: #"^approve "#, with: "", options: .regularExpression) }
            ?? "The agent is waiting for permission"
        Card(color: Palette.needs, title: "Permission") {
            Text(detail).font(.system(size: 11.5, design: .monospaced)).lineLimit(3).textSelection(.enabled)
            if let pending, pending.old != nil || pending.new != nil, provider == .claude {
                DiffPreview(old: pending.old, new: pending.new)
            }
            HStack(spacing: 8) {
                Button("Allow") { store.answerPermission(tabID, allow: true, codexApproval: approval) }.buttonStyle(.borderedProminent)
                if provider == .claude, secondOptionAllows {
                    Button("Allow for session") { store.sendKeys("2", to: tabID) }.buttonStyle(.bordered)
                        .help("Claude Code's second option: yes, and don't ask again for this during the session")
                }
                Button("Deny") { store.answerPermission(tabID, allow: false, codexApproval: approval) }.buttonStyle(.bordered)
                Text("or tell it what to do instead below").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .controlSize(.small)
            .disabled(approval.map { codex.answering.contains($0) } ?? false)
        }
    }

    /// Only when the prompt's option 2 really is "don't ask again"; on a two-option prompt it would be "No".
    private var secondOptionAllows: Bool {
        let lines = store.screenLines(tabID, count: 24)
        guard let option = lines.first(where: { $0.range(of: #"^\s*(❯\s*)?2\.\s"#, options: .regularExpression) != nil }) else { return false }
        return ClaudeScreen.allowForSession.contains { option.localizedCaseInsensitiveContains($0) }
    }
}

/// A few lines of what an edit removes and adds.
struct DiffPreview: View {
    let old: String?
    let new: String?

    var body: some View {
        let removed = old?.split(separator: "\n", omittingEmptySubsequences: false).prefix(12) ?? []
        let added = new?.split(separator: "\n", omittingEmptySubsequences: false).prefix(12) ?? []
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(removed.enumerated()), id: \.offset) { _, line in
                    Text("- " + line).foregroundStyle(Palette.error).frame(maxWidth: .infinity, alignment: .leading).background(Palette.error.opacity(0.1))
                }
                ForEach(Array(added.enumerated()), id: \.offset) { _, line in
                    Text("+ " + line).foregroundStyle(Palette.done).frame(maxWidth: .infinity, alignment: .leading).background(Palette.done.opacity(0.1))
                }
                if (old?.split(separator: "\n").count ?? 0) > 12 || (new?.split(separator: "\n").count ?? 0) > 12 {
                    Text("…").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(6)
        }
        .frame(maxHeight: 180)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Claude Code's plan, with the approval options its prompt offers:
/// "Yes, and auto-accept edits", "Yes, and manually approve edits", "No, keep planning".
struct PlanCard: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let plan: String

    var body: some View {
        Card(color: Palette.agent, title: "Plan ready") {
            ScrollView {
                MarkdownText(plan).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .frame(maxHeight: 260)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Button("Approve, auto-accept edits") { store.sendKeys("1", to: tabID) }.buttonStyle(.borderedProminent)
                Button("Approve, ask for each edit") { store.sendKeys("2", to: tabID) }.buttonStyle(.bordered)
                Button("Keep planning") { store.sendKeys("3", to: tabID) }.buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
    }
}

/// Claude Code's questions, one at a time as its dialog shows them: a choice list with radio
/// marks for one answer or boxes for several, a field for a typed answer, Chat about this, and
/// the review page at the end. The card reads the dialog off the screen and drives it with the
/// arrow keys and Return, so it always shows the question the terminal is on; a click shows at
/// once and the screen confirms it a moment later.
struct QuestionCard: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let questions: [Question]
    @State private var typed = ""
    /// The option just clicked on a one-answer question, shown picked until the dialog moves on.
    @State private var picked: [Int: Int] = [:]
    /// Boxes just clicked on a many-answer question, by question then option, with the state
    /// they should show; dropped once the screen shows it.
    @State private var toggled: [Int: [Int: Bool]] = [:]
    /// Keys are on their way; clicks before the dialog redraws would land twice.
    @State private var busyUntil = Date.distantPast
    /// The dialog as last read, and the output it was read at: an unchanged screen isn't parsed again.
    @State private var read = DialogRead()

    private final class DialogRead {
        var output: UInt64?
        var questions: [Question] = []
        var dialog: QuestionDialog?
        var known = false
    }

    private var dialogNow: QuestionDialog? {
        let output = store.outputGeneration(tabID)
        if read.known, read.output == output, read.questions == questions { return read.dialog }
        read.dialog = QuestionScreen.parse(store.screenLines(tabID, count: 60), questions: questions)
        read.output = output; read.questions = questions; read.known = true
        return read.dialog
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            let dialog = dialogNow
            Card(color: Palette.needs, title: title(dialog)) {
                if questions.count > 1 { tabs(dialog) }
                switch dialog?.page {
                case .review: review(dialog!)
                case .question(let index) where questions.indices.contains(index): question(index, dialog!)
                default: fallback
                }
            }
            .controlSize(.small)
        }
    }

    private func title(_ dialog: QuestionDialog?) -> String {
        switch dialog?.page {
        case .review: return "Review your answers"
        case .question(let index):
            let mode = questions.indices.contains(index) && questions[index].multi ? "choose any" : "choose one"
            return questions.count > 1 ? "Question \(index + 1) of \(questions.count) · \(mode)" : "Question · \(mode)"
        default: return "Question"
        }
    }

    /// The dialog's tabs: one per question, ticked once answered, the shown one underlined.
    private func tabs(_ dialog: QuestionDialog?) -> some View {
        HStack(spacing: 10) {
            ForEach(questions.indices, id: \.self) { i in
                let answered = dialog.map { $0.answered.indices.contains(i) && $0.answered[i] } ?? false
                let current = dialog?.page == .question(i)
                Label(questions[i].header ?? "Question \(i + 1)", systemImage: answered ? "checkmark.circle.fill" : (current ? "circle.inset.filled" : "circle"))
                    .font(.system(size: 11, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? .primary : .secondary)
            }
            Label("Submit", systemImage: dialog?.page == .review ? "circle.inset.filled" : "circle")
                .font(.system(size: 11, weight: dialog?.page == .review ? .semibold : .regular))
                .foregroundStyle(dialog?.page == .review ? .primary : .secondary)
        }
        .labelStyle(.titleAndIcon)
    }

    @ViewBuilder
    private func question(_ index: Int, _ dialog: QuestionDialog) -> some View {
        let question = questions[index]
        Text(question.text).font(.system(size: 12.5, weight: .medium)).textSelection(.enabled)
        VStack(alignment: .leading, spacing: 2) {
            ForEach(question.options.indices, id: \.self) { i in
                optionRow(i, of: question, at: index, dialog)
            }
        }
        HStack(spacing: 8) {
            if question.multi, let submit = dialog.row(.submit) {
                let any = dialog.rows.contains { $0.checked == true } || (toggled[index]?.values.contains(true) ?? false)
                let label = dialog.rows[submit].label.isEmpty ? "Next" : dialog.rows[submit].label
                if any {
                    Button(label) { choose(submit, dialog) }.buttonStyle(.borderedProminent).help("Confirms the ticked options")
                } else {
                    Button(label) { choose(submit, dialog) }.buttonStyle(.bordered).help("Confirms the ticked options")
                }
            }
            TextField("Type your own answer…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { type(dialog) }
            Button("Send") { type(dialog) }.disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty || dialog.row(.type) == nil)
            Spacer(minLength: 0)
            if let chat = dialog.row(.chat) {
                Button("Chat about this") { choose(chat, dialog) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
                    .help("Tells Claude Code you'd rather talk about these questions; reply below")
            }
        }
    }

    /// One option: a radio mark or a box, the label, its description, and a tint on the row
    /// the dialog's highlight is on.
    private func optionRow(_ i: Int, of question: Question, at index: Int, _ dialog: QuestionDialog) -> some View {
        let row = dialog.row(.option(i))
        let onScreen = row.flatMap { dialog.rows[$0].checked } ?? false
        let wanted = toggled[index]?[i]
        let checked = question.multi ? (wanted ?? onScreen) : picked[index] == i
        let highlighted = row != nil && row == dialog.cursor
        let description = question.descriptions.indices.contains(i) ? question.descriptions[i] : ""
        let mark = question.multi ? (checked ? "checkmark.square.fill" : "square") : (checked ? "largecircle.fill.circle" : "circle")
        return Button {
            guard let row else { return }
            if question.multi {
                toggled[index, default: [:]][i] = !(wanted ?? onScreen)
            } else {
                picked[index] = i
            }
            choose(row, dialog)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: mark)
                    .font(.system(size: 13))
                    .foregroundStyle(checked ? Color.accent : Color.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(question.options[i]).font(.system(size: 12, weight: checked ? .semibold : .regular))
                    if !description.isEmpty {
                        Text(description).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5).padding(.horizontal, 7)
            .background(highlighted ? Color.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(row == nil)
        .onChange(of: onScreen) { _, now in
            // The screen caught up with the click: its state is the truth again.
            if wanted == now { toggled[index]?[i] = nil }
        }
    }

    @ViewBuilder
    private func review(_ dialog: QuestionDialog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(dialog.review.indices, id: \.self) { i in
                let parts = dialog.review[i].components(separatedBy: " → ")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(parts.first ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(parts.dropFirst().joined(separator: " → ")).font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
        .textSelection(.enabled)
        HStack(spacing: 8) {
            if let submit = dialog.row(.submitAnswers) {
                Button("Submit answers") { choose(submit, dialog) }.buttonStyle(.borderedProminent)
            }
            if let cancel = dialog.row(.cancel) {
                Button("Cancel") { choose(cancel, dialog) }.buttonStyle(.bordered)
            }
            Button("Back") { send("\u{1b}[D") }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11))
                .help("The previous question, to change its answer")
        }
    }

    /// The screen doesn't show the dialog's rows: the typed-answer field is open, or the
    /// terminal is mid-redraw. What's typed here goes to the terminal as is.
    @ViewBuilder
    private var fallback: some View {
        if let first = questions.first { Text(first.text).font(.system(size: 12.5, weight: .medium)).textSelection(.enabled) }
        HStack(spacing: 8) {
            TextField("Type your own answer…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .onSubmit { sendTyped() }
            Button("Send") { sendTyped() }.disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("Answer in the terminal, or type here").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// Moves the highlight to the row and presses Return: picks an option, ticks a box, or
    /// takes Next, Submit or Chat about this. Without a highlight to start from, the row's number.
    private func choose(_ row: Int, _ dialog: QuestionDialog) {
        guard Date() >= busyUntil else { return }
        if let cursor = dialog.cursor {
            send(QuestionScreen.keys(from: cursor, to: row), then: QuestionScreen.enter)
        } else if let number = dialog.rows[row].number {
            send("\(number)", then: QuestionScreen.enter)
        }
    }

    /// "Type something", then the text, then Return.
    private func type(_ dialog: QuestionDialog) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let row = dialog.row(.type) else { return }
        choose(row, dialog)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            store.sendKeys(text, to: tabID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.sendKeys(QuestionScreen.enter, to: tabID) }
        }
        typed = ""
    }

    private func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        send(text, then: QuestionScreen.enter)
        typed = ""
    }

    private func send(_ keys: String, then followUp: String? = nil) {
        busyUntil = Date().addingTimeInterval(0.5)
        if !keys.isEmpty { store.sendKeys(keys, to: tabID) }
        if let followUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.sendKeys(followUp, to: tabID) }
        }
    }
}

/// Prompts Claude Code draws on screen without a status record: trusting a new folder, confirming a
/// model or effort switch. Answerable here. While it starts up, the last lines of the screen.
struct ScreenPromptCard: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let starting: Bool

    var body: some View {
        // Often while it starts, when the trust question comes; rarely afterwards.
        TimelineView(.periodic(from: .now, by: starting ? 1 : 3)) { _ in
            let lines = store.screenLines(tabID, count: 14)
            let text = lines.joined(separator: "\n")
            if text.contains(ClaudeScreen.switchModel) || text.contains(ClaudeScreen.changeEffort) {
                Card(color: Color.accent, title: text.contains(ClaudeScreen.switchModel) ? ClaudeScreen.switchModel : ClaudeScreen.changeEffort) {
                    HStack(spacing: 8) {
                        Button("Yes, switch") { store.sendKeys("\r", to: tabID) }.buttonStyle(.borderedProminent)
                        Button("No, go back") { store.sendKeys("\u{1b}", to: tabID) }.buttonStyle(.bordered)
                        Text("The conversation is cached for the current setting; switching re-reads the history.").foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
            } else if text.localizedCaseInsensitiveContains(ClaudeScreen.trustFolder) {
                Card(color: Color.accent, title: "Claude Code asks whether to trust this folder") {
                    HStack(spacing: 8) {
                        Button("Trust folder") {
                            // Its menu starts on "No, exit": move down one row, then confirm.
                            store.sendKeys("\u{1b}[B", to: tabID)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { store.sendKeys("\r", to: tabID) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Exit") { store.sendKeys("\u{1b}", to: tabID) }.buttonStyle(.bordered)
                        Text("Claude Code will be able to read, edit and run files there.").foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
            } else if starting, !lines.isEmpty {
                Card(color: Color.accent, title: "Starting · answer in the terminal if it asks something") {
                    Text(lines.suffix(6).joined(separator: "\n"))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(6)
                }
            }
        }
    }
}

/// The tinted box the cards share.
struct Card<Content: View>: View {
    let color: Color
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PulsingDot(color: color)
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(color.opacity(0.55)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// A dot that breathes, for states that are in progress.
struct PulsingDot: View {
    let color: Color

    var body: some View {
        BreathingDot(color: color, pulsing: true)
            .frame(width: 8, height: 8)
    }
}

// MARK: - Markdown (native, for the plan card)

/// Paragraphs, bullet lists, headings and fenced code blocks, with inline markdown inside them.
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    private enum Segment { case paragraph(String), bullets([String]), heading(String), code(String) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .heading(let line):
                    Text(inline(line)).font(.system(size: 13, weight: .semibold)).padding(.top, 2)
                case .paragraph(let para):
                    Text(inline(para)).font(.system(size: 12)).lineSpacing(3)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                Text(inline(item)).lineSpacing(3)
                            }
                        }
                    }
                    .font(.system(size: 12))
                    .padding(.leading, 4)
                case .code(let code):
                    ScrollView(.horizontal) {
                        Text(code).font(.system(size: 11, design: .monospaced)).padding(10)
                    }
                    .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ string: String) -> AttributedString {
        (try? AttributedString(markdown: string, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(string)
    }

    private var segments: [Segment] {
        var result: [Segment] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
            if !bullets.isEmpty { result.append(.bullets(bullets)); bullets = [] }
        }
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let open = code { result.append(.code(open.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(rawLine); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush()
                result.append(.heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if let item = Self.bullet(line) {
                if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
                bullets.append(item)
            } else if !bullets.isEmpty, rawLine.hasPrefix("  ") {
                bullets[bullets.count - 1] += " " + line
            } else {
                if !bullets.isEmpty { result.append(.bullets(bullets)); bullets = [] }
                paragraph.append(line)
            }
        }
        if let code { result.append(.code(code.joined(separator: "\n"))) }
        flush()
        return result
    }

    private static func bullet(_ line: String) -> String? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") { return String(line.dropFirst(2)) }
        if let range = line.range(of: #"^\d+[.)] "#, options: .regularExpression) { return String(line[range.upperBound...]) }
        return nil
    }
}
