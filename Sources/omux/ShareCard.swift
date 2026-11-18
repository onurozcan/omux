import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A picture of the day's or the week's figures, made to be posted: the same look whatever the
/// theme, with omux.app in its corner.
struct ShareCard: View {
    enum Span: String, CaseIterable, Identifiable {
        case day, week
        var id: String { rawValue }
        var label: String { self == .day ? "Today" : "This week" }
    }

    let stats: HomeStats
    let span: Span
    /// Project names are left off unless asked for: a card goes to strangers.
    var projects = false

    /// 16:9, the shape X (Twitter) shows a single picture in without cropping it; rendered at
    /// 1600×900. The type is large because a phone shows the card at about half this size.
    static let size = CGSize(width: 640, height: 360)
    static let scale: CGFloat = 2.5
    private static let accent = Color(red: 0.133, green: 0.827, blue: 0.933)
    private static let ink = Color(red: 0.902, green: 0.902, blue: 0.902)
    private static let muted = Color(red: 0.612, green: 0.612, blue: 0.639)

    private var figures: [(value: String, label: String)] {
        switch span {
        case .day:
            let today = stats.today
            let earlier = stats.days.dropLast()
            let usual = earlier.isEmpty ? 0 : earlier.reduce(0) { $0 + $1.tokens } / earlier.count
            let change = usual > 0 ? Int((Double(today.tokens - usual) / Double(usual) * 100).rounded()) : nil
            return [("\(today.prompts)", "prompts"),
                    (HomeStats.compact(today.tokens), "tokens written"),
                    ("\(today.conversations)", today.conversations == 1 ? "conversation" : "conversations"),
                    (change.map { ($0 >= 0 ? "+" : "−") + "\(abs($0))%" } ?? "–", "vs. my usual day")]
        case .week:
            let active = stats.days.filter { $0.prompts > 0 }.count
            let busiest = stats.days.max { $0.tokens < $1.tokens }
            return [("\(stats.weekPrompts)", "prompts"),
                    (HomeStats.compact(stats.weekTokens), "tokens written"),
                    ("\(active)/\(stats.days.count)", "days active"),
                    (busiest.flatMap { $0.tokens > 0 ? $0.date.formatted(.dateTime.weekday(.abbreviated)) : nil } ?? "–", "busiest day")]
        }
    }

    private var models: [HomeStats.Model] { span == .day ? stats.todayModels : stats.weekModels }
    /// "Fable 5.2 71% · Opus 5.5 22% · GPT-5.6 7%": the models that wrote, by their share.
    private var modelLine: String {
        let all = max(models.reduce(0) { $0 + $1.tokens }, 1)
        return models.prefix(3).map { "\($0.name) \(max(1, $0.tokens * 100 / all))%" }.joined(separator: "  ·  ")
    }

    private var dates: String {
        switch span {
        case .day: return stats.today.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        case .week:
            guard let first = stats.days.first?.date, let last = stats.days.last?.date else { return "" }
            return "\(first.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
    }

    /// The bar that carries the colour: today on a day card, the busiest day on a week card.
    private func lit(_ day: HomeStats.Day) -> Bool {
        switch span {
        case .day: return day.id == stats.days.last?.id
        case .week: return day.tokens > 0 && day.id == stats.days.max { $0.tokens < $1.tokens }?.id
        }
    }

    var body: some View {
        let top = max(stats.days.map(\.tokens).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text((span == .day ? "My day with " : "My week with ") + HomeStats.agents(of: models))
                    .font(.system(size: 23, weight: .semibold)).foregroundStyle(Self.ink)
                Spacer()
                Text(dates).font(.system(size: 14)).foregroundStyle(Self.muted)
            }
            HStack(alignment: .top, spacing: 0) {
                ForEach(figures, id: \.label) { figure in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(figure.value).font(.system(size: 46, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(Self.ink).lineLimit(1).minimumScaleFactor(0.6)
                        Text(figure.label).font(.system(size: 14.5)).foregroundStyle(Self.muted).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 16)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(stats.days) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(lit(day) ? AnyShapeStyle(LinearGradient(colors: [Self.accent, Self.accent.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                                           : AnyShapeStyle(Color.white.opacity(0.14)))
                            .frame(height: max(3, 82 * CGFloat(day.tokens) / CGFloat(top)))
                        Text(day.date.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 13, weight: lit(day) ? .semibold : .regular))
                            .foregroundStyle(lit(day) ? Self.ink : Self.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.top, 10)
            HStack(alignment: .bottom, spacing: 7) {
                VStack(alignment: .leading, spacing: 2) {
                    if projects, !stats.projects.isEmpty {
                        Text("Most active: " + stats.projects.prefix(3).map(\.name).joined(separator: ", "))
                    }
                    if !models.isEmpty { Text(modelLine) }
                }
                .font(.system(size: 13.5)).foregroundStyle(Self.muted).lineLimit(1)
                Spacer(minLength: 12)
                Image(nsImage: NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 22, height: 22)
                Text("omux.app").font(.system(size: 16, weight: .semibold)).foregroundStyle(Self.ink.opacity(0.9))
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 22)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                LinearGradient(colors: [Color(red: 0.094, green: 0.094, blue: 0.11), Color(red: 0.047, green: 0.047, blue: 0.055)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [Self.accent.opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 420)
            }
        }
        .environment(\.colorScheme, .dark)
    }

    /// The card as a picture, at twice its size so it stays sharp when posted.
    @MainActor static func image(stats: HomeStats, span: Span, projects: Bool) -> NSImage? {
        let renderer = ImageRenderer(content: ShareCard(stats: stats, span: span, projects: projects))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSImage(cgImage: cg, size: size)
    }

    @MainActor static func png(stats: HomeStats, span: Span, projects: Bool) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(stats: stats, span: span, projects: projects))
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

/// The popover behind Home's share button: the card as it will look, and what to do with it.
struct ShareCardPanel: View {
    let stats: HomeStats
    @State private var span = ShareCard.Span.day
    @AppStorage("shareCardProjects") private var projects = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Not a segmented picker: under a neutral accent its chosen segment is the darker one.
            HStack(spacing: 2) {
                ForEach(ShareCard.Span.allCases) { choice in
                    Button { span = choice } label: {
                        Text(choice.label).font(.system(size: 12, weight: span == choice ? .semibold : .regular))
                            .foregroundStyle(span == choice ? .primary : .secondary)
                            .frame(maxWidth: .infinity).frame(height: 24)
                            .background(.primary.opacity(span == choice ? 0.14 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            ShareCard(stats: stats, span: span, projects: projects)
                .scaleEffect(0.75, anchor: .topLeading)
                .frame(width: ShareCard.size.width * 0.75, height: ShareCard.size.height * 0.75, alignment: .topLeading)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.primary.opacity(0.12)))
            HStack(spacing: 10) {
                Toggle("Project names", isOn: $projects).toggleStyle(.checkbox)
                    .help("Names the three most active projects on the card. Off, the card carries figures only.")
                Spacer()
                Button(copied ? "Copied" : "Copy Image") { copy() }
                Button("Save…") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: ShareCard.size.width * 0.75 + 28)
    }

    private func copy() {
        guard let image = ShareCard.image(stats: stats, span: span, projects: projects) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.6)); copied = false }
    }

    private func save() {
        guard let data = ShareCard.png(stats: stats, span: span, projects: projects) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "omux-\(span == .day ? "day" : "week")-\(Date().formatted(.iso8601.year().month().day())).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}
