import SwiftUI

/// Settings › Migration: brings a Muxy setup's projects and settings over to omux.
struct MigrationSettings: View {
    @EnvironmentObject var store: Store
    /// What each Muxy folder holds, with what it would add; nil until first looked at.
    @State private var sources: [Looked]?
    @State private var chosen = ""
    @State private var projects = true
    @State private var settings = true
    @State private var result: String?

    /// A source as read, and how its projects sort against omux's at the time.
    private struct Looked {
        let found: MuxyMigration.Found
        let plan: MuxyMigration.Plan
        var id: String { found.source.id }
    }

    private var current: Looked? { sources?.first { $0.id == chosen } }

    var body: some View {
        Form {
            Section("Muxy") {
                if let sources {
                    if sources.isEmpty {
                        Text("No Muxy setup was found on this Mac.").foregroundStyle(.secondary)
                    }
                    ForEach(sources, id: \.id) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.found.source.name)
                            Text(summary(source)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if sources.count > 1 {
                        Picker("Bring over from", selection: $chosen) {
                            ForEach(sources, id: \.id) { Text($0.found.source.name).tag($0.id) }
                        }
                    }
                } else {
                    Text("Looking for Muxy…").foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Look Again") { Task { await look() } }.controlSize(.small)
                }
            }
            if let current {
                Section {
                    Toggle("Projects", isOn: $projects)
                    Toggle("Settings", isOn: $settings)
                    HStack {
                        if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Migrate from Muxy") { migrate(current.found) }
                            .disabled(!(projects && !current.plan.add.isEmpty) && !(settings && current.found.settings.count > 0))
                    }
                    Text("Each project comes over with its name, folder, picture and whether it is pinned, and so do Muxy's terminal font and size, notification sound, where links open and whether to ask before quitting. Muxy's themes, key bindings, open tabs and worktree checkouts stay behind. Muxy's own files are not changed.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .task { await look() }
        .onChange(of: chosen) { _, _ in result = nil }
    }

    /// Reads every Muxy folder off the main thread: desktop-state.json can run to megabytes,
    /// and sorting the projects looks at each one's folder on disk.
    private func look() async {
        let existing = store.groups
        let looked = await Task.detached(priority: .userInitiated) {
            MuxyMigration.sources().compactMap(MuxyMigration.read).map {
                Looked(found: $0, plan: MuxyMigration.plan($0.projects, existing: existing))
            }
        }.value
        sources = looked
        if !looked.contains(where: { $0.id == chosen }) { chosen = looked.first?.id ?? "" }
    }

    private func migrate(_ found: MuxyMigration.Found) {
        var added = 0, applied = 0
        if projects {
            let plan = MuxyMigration.plan(found.projects, existing: store.groups)
            let groups = MuxyMigration.groups(for: plan.add) { ProjectIcons.squarePNG(from: $0).flatMap(ProjectIcons.save) }
            store.importGroups(groups)
            added = groups.count
        }
        if settings {
            applied = MuxyMigration.apply(found.settings)
            // The main window's font watch does this too; here it doesn't wait on that window.
            store.applyAppearance()
        }
        let parts = [added > 0 ? count(added, "project") : nil, applied > 0 ? count(applied, "setting") : nil].compactMap { $0 }
        result = parts.isEmpty ? "There was nothing new to bring over." : "Added \(parts.joined(separator: " and "))."
        Task { await look() }
    }

    /// "4 projects to add, 2 already in omux, 1 folder gone, 3 settings."
    private func summary(_ source: Looked) -> String {
        var parts = ["\(count(source.plan.add.count, "project")) to add"]
        if source.plan.alreadyThere > 0 { parts.append("\(source.plan.alreadyThere) already in omux") }
        if source.plan.missingFolder > 0 { parts.append("\(count(source.plan.missingFolder, "folder")) gone") }
        parts.append(count(source.found.settings.count, "setting"))
        return parts.joined(separator: ", ") + "."
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
