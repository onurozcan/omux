import SwiftUI

/// Messages shown over the terminal instead of an alert, so they don't stop what the user
/// is doing. Results go away on their own; errors stay until they're dismissed.
@MainActor
final class Notices: ObservableObject {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String
        let isError: Bool
    }

    static let shared = Notices()

    @Published private(set) var list: [Notice] = []

    private let resultLifetime: Duration

    init(resultLifetime: Duration = .seconds(6)) {
        self.resultLifetime = resultLifetime
    }

    func post(_ title: String, detail: String, isError: Bool) {
        let notice = Notice(title: title, detail: detail.trimmingCharacters(in: .whitespacesAndNewlines), isError: isError)
        // The same failure again replaces the first instead of stacking up.
        list.removeAll { $0.title == notice.title && $0.detail == notice.detail }
        list.append(notice)
        AccessibilityNotification.Announcement(title).post()
        guard !isError else { return }
        Task {
            try? await Task.sleep(for: resultLifetime)
            dismiss(notice)
        }
    }

    func dismiss(_ notice: Notice) {
        list.removeAll { $0.id == notice.id }
    }
}

struct NoticeStack: View {
    @ObservedObject private var notices = Notices.shared
    let theme: Theme

    var body: some View {
        VStack(spacing: 6) {
            ForEach(notices.list.suffix(3)) { notice in
                row(notice)
            }
        }
        .frame(maxWidth: 520)
        .padding(10)
    }

    private func row(_ notice: Notices.Notice) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Palette.needs : Color.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title).fontWeight(.medium)
                if !notice.detail.isEmpty {
                    // Git's output can be long, and it's the only copy of it.
                    ScrollView {
                        Text(notice.detail)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 96)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
            Button { notices.dismiss(notice) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(10)
        .background(Color(nsColor: theme.chrome), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(radius: 6, y: 2)
    }
}
