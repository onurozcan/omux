import SwiftUI

/// One compact line of the selected session's agent limits: `5h 1%  Week 32%  Fable 35%`,
/// each with a hairline bar. Hovering a limit swaps its text for the reset time.
struct UsageView: View {
    @EnvironmentObject var store: Store
    @StateObject private var monitor = UsageMonitor()
    @ObservedObject private var codex = CodexManager.shared
    @ObservedObject private var cursor = CursorManager.shared
    @State private var hovered: String?
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0

    /// Codex and Cursor sessions show their own agent's limits; everything else shows
    /// Claude's, as before.
    private var isCodex: Bool { store.selectedProvider == .codex }
    private var isCursor: Bool { store.selectedProvider == .cursor }
    private var agent: SessionProvider { isCodex ? .codex : isCursor ? .cursor : .claude }

    private var limits: [UsageMonitor.Limit] {
        isCodex ? codex.limits : isCursor ? cursor.limits : monitor.limits
    }

    private var problem: String? {
        isCodex ? codex.usageError : isCursor ? cursor.usageError : monitor.error
    }

    var body: some View {
        HStack(spacing: 10) {
            if isCodex {
                Text(codex.plan.map { "Codex \($0.replacingOccurrences(of: "_", with: " ").capitalized)" } ?? "Codex")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else if isCursor {
                Text("Cursor")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if limits.isEmpty {
                Button {
                    if isCodex { Task { await codex.refreshUsage() } }
                    else if isCursor { Task { await cursor.refreshUsage() } }
                    else { monitor.refresh() }
                } label: {
                    Text(problem ?? "\(agent.agentName) usage…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(isCodex || isCursor ? problem ?? "" : monitor.detail ?? "")
            }
            ForEach(limits) { limit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hovered == limit.id ? limit.resetText : "\(limit.label) \(limit.percent)%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(hovered == limit.id ? .primary : .secondary)
                        .lineLimit(1)
                        .fixedSize()
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(limit.tint)
                                .frame(width: geo.size.width * CGFloat(min(limit.percent, 100)) / 100)
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
        .task(id: isCursor) {
            guard isCursor else { return }
            while !Task.isCancelled {
                await cursor.refreshUsage()
                try? await Task.sleep(for: .seconds(max(usageInterval, 30)))
            }
        }
    }
}
