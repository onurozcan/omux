import SwiftUI

/// One compact line of Claude limits: `5h 1%  Week 32%  Fable 35%`, each with a
/// hairline bar. Hovering a limit swaps its text for the reset time.
struct UsageView: View {
    @EnvironmentObject var store: Store
    @StateObject private var monitor = UsageMonitor()
    @ObservedObject private var codex = CodexManager.shared
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0

    /// Codex sessions show Codex's limits; every other session shows Claude's, as before.
    private var isCodex: Bool { (provider ?? store.selectedProvider) == .codex }
    /// Set to show one agent's limits whatever session is selected, as Home does.
    var provider: SessionProvider?
    private var limits: [UsageMonitor.Limit] { isCodex ? codex.limits : monitor.limits }

    /// On the project rail the limits are one small set of nested rings, and lines of text
    /// beside it only while the rail is open; under the session list they are bars.
    var onRail = false
    var railOpen = false

    var body: some View {
        Group {
            if onRail { rings } else { bars }
        }
        .onAppear { if provider != .codex { monitor.start() } }
        .onDisappear { monitor.stop() }
        .onChange(of: usageInterval) { _, seconds in monitor.schedule(every: seconds) }
        .task(id: isCodex) {
            guard isCodex else { return }
            while !Task.isCancelled {
                await codex.refreshUsage()
                try? await Task.sleep(for: .seconds(max(usageInterval, 30)))
            }
        }
    }

    private var summary: String {
        let name = isCodex ? "Codex" : "Claude"
        guard !limits.isEmpty else { return (isCodex ? codex.usageError : monitor.error) ?? "\(name) limits are loading" }
        return name + " limits\n" + limits.map { "\($0.label) \($0.percent)% used" + ($0.resetShort.map { ", resets in \($0)" } ?? "") }.joined(separator: "\n")
    }

    /// One ring a limit, the first outermost, each filled as far as the limit is used.
    private var rings: some View {
        HStack(spacing: 9) {
            ZStack {
                ForEach(Array(limits.prefix(3).enumerated()), id: \.element.id) { index, limit in
                    let inset = CGFloat(index) * 3.5
                    Circle().stroke(.primary.opacity(0.1), lineWidth: 2).padding(inset)
                    Circle().trim(from: 0, to: max(0.03, CGFloat(min(limit.percent, 100)) / 100))
                        .stroke(limit.tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(inset)
                }
                if limits.isEmpty { Circle().stroke(.primary.opacity(0.1), lineWidth: 2) }
            }
            .frame(width: 16, height: 16)
            .padding(7)
            .contentShape(Rectangle())
            .onTapGesture { if isCodex { Task { await codex.refreshUsage() } } else { monitor.refresh() } }
            .help(railOpen ? "" : summary)
            if railOpen {
                VStack(alignment: .leading, spacing: 1) {
                    if limits.isEmpty {
                        Text((isCodex ? codex.usageError : monitor.error) ?? "Loading limits…").foregroundStyle(.secondary)
                    }
                    ForEach(limits.prefix(3)) { limit in
                        HStack(spacing: 5) {
                            Text(limit.label).foregroundStyle(.secondary)
                            Text("\(limit.percent)%")
                                .fontWeight(.medium)
                                .foregroundStyle(limit.percent >= 90 ? Palette.error : limit.percent >= 70 ? Palette.needs : .primary.opacity(0.85))
                            if let reset = limit.resetShort { Text(reset).foregroundStyle(.tertiary) }
                        }
                    }
                }
                .font(.system(size: 10).monospacedDigit())
                .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var bars: some View {
        // The agent's mark, then one line a limit: what it is, how much is used, when it starts over.
        HStack(alignment: .top, spacing: 9) {
            ProviderLogo(provider: isCodex ? .codex : .claude, size: 12)
                .foregroundStyle(.secondary)
                .frame(width: 12, height: 13)
                .help(isCodex ? codex.plan.map { "Codex \($0.replacingOccurrences(of: "_", with: " ").capitalized) limits" } ?? "Codex limits" : "Claude limits")
            VStack(alignment: .leading, spacing: 4) {
                if limits.isEmpty {
                    Button {
                        if isCodex { Task { await codex.refreshUsage() } } else { monitor.refresh() }
                    } label: {
                        Text(isCodex ? codex.usageError ?? "Loading limits…" : monitor.error ?? "Loading limits…")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(height: 13)
                    }
                    .buttonStyle(.plain)
                    .help(isCodex ? codex.usageError ?? "" : monitor.detail ?? "")
                }
                ForEach(limits) { limit in
                    HStack(spacing: 7) {
                        Text(limit.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 34, alignment: .leading)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.08))
                                Capsule().fill(limit.tint)
                                    .frame(width: max(3, geo.size.width * CGFloat(min(limit.percent, 100)) / 100))
                            }
                        }
                        .frame(height: 3)
                        Text("\(limit.percent)%")
                            .fontWeight(.medium)
                            .foregroundStyle(limit.percent >= 90 ? Palette.error : limit.percent >= 70 ? Palette.needs : .primary.opacity(0.85))
                            .frame(width: 28, alignment: .trailing)
                        Text(limit.resetShort ?? "")
                            .foregroundStyle(.tertiary)
                            .frame(width: 38, alignment: .trailing)
                    }
                    .font(.system(size: 10).monospacedDigit())
                    .lineLimit(1)
                    .frame(height: 13)
                    .help("\(limit.percent)% used, \(max(0, 100 - limit.percent))% left. \(limit.resetText)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
