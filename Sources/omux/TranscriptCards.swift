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

    var body: some View {
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

/// A question Claude Code asked, with its options as buttons. Its prompt takes a number to
/// pick and Return to submit.
struct QuestionCard: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let question: Question

    var body: some View {
        Card(color: Palette.needs, title: "Question") {
            Text(question.text).font(.system(size: 12)).textSelection(.enabled)
            HStack(spacing: 8) {
                ForEach(Array(question.options.prefix(6).enumerated()), id: \.offset) { index, option in
                    if index == 0 {
                        Button(option) { pick(index) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(option) { pick(index) }.buttonStyle(.bordered)
                    }
                }
                Text(question.multi ? "pick more in the terminal" : "or type an answer below").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private func pick(_ index: Int) {
        store.sendKeys("\(index + 1)", to: tabID)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { store.sendKeys("\r", to: tabID) }
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
                Card(color: Palette.working, title: text.contains(ClaudeScreen.switchModel) ? ClaudeScreen.switchModel : ClaudeScreen.changeEffort) {
                    HStack(spacing: 8) {
                        Button("Yes, switch") { store.sendKeys("\r", to: tabID) }.buttonStyle(.borderedProminent)
                        Button("No, go back") { store.sendKeys("\u{1b}", to: tabID) }.buttonStyle(.bordered)
                        Text("The conversation is cached for the current setting; switching re-reads the history.").foregroundStyle(.secondary)
                    }
                    .controlSize(.small)
                    .font(.system(size: 11))
                }
            } else if text.localizedCaseInsensitiveContains(ClaudeScreen.trustFolder) {
                Card(color: Palette.working, title: "Claude Code asks whether to trust this folder") {
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
                Card(color: Palette.working, title: "Starting · answer in the terminal if it asks something") {
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
