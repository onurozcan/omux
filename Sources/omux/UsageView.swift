import SwiftUI

/// One compact line of Claude limits: `5h 1%  Week 32%  Fable 35%`, each with a
/// hairline bar. Hovering a limit swaps its text for the reset time.
struct UsageView: View {
    @EnvironmentObject var store: Store
    @StateObject private var monitor = UsageMonitor()
    @ObservedObject private var codex = CodexManager.shared
    @State private var hovered: String?
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0

    /// Codex sessions show Codex's limits; every other session shows Claude's, as before.
    private var isCodex: Bool { store.selectedProvider == .codex }
    private var limits: [UsageMonitor.Limit] { isCodex ? codex.limits : monitor.limits }

    var body: some View {
        HStack(spacing: 10) {
            if isCodex {
                Text(codex.plan.map { "Codex \($0.replacingOccurrences(of: "_", with: " ").capitalized)" } ?? "Codex")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if limits.isEmpty {
                Button {
                    if isCodex { Task { await codex.refreshUsage() } } else { monitor.refresh() }
                } label: {
                    Text(isCodex ? codex.usageError ?? "Codex usage…" : monitor.error ?? "Claude usage…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isCodex ? codex.usageError ?? "" : monitor.detail ?? "")
            }
            ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hovered == limit.id ? limit.resetText : "\(limit.label) \(limit.percent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(hovered == limit.id ? .primary : limit.percent >= 90 ? Palette.error : limit.percent >= 70 ? Palette.needs : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.primary.opacity(0.08))
                            Capsule().fill(limit.tint)
                                .frame(width: max(2, geo.size.width * CGFloat(min(limit.percent, 100)) / 100))
                        }
                    }
                    .frame(height: 3)
                }
                .onHover { hovered = $0 ? limit.id : nil }
                .help(limit.resetText)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear { monitor.start() }
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
}
