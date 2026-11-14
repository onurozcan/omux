import AppKit
import OmuxCore
import OmuxHostKit
import SwiftUI

/// Where a machine is typed or picked: the ones used before and the names in ~/.ssh/config
/// are a click away, and anything ssh takes can still be typed.
struct MachineField: View {
    @Binding var host: String
    @ObservedObject private var machines = RemoteMachines.shared

    var body: some View {
        HStack(spacing: 6) {
            TextField("Machine", text: $host, prompt: Text("devbox, or me@10.0.0.5"))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
            let choices = machines.suggestions
            if !choices.isEmpty {
                Menu {
                    ForEach(choices, id: \.self) { name in Button(name) { host = name } }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Machines you've used, and the names in ~/.ssh/config")
            }
        }
    }
}

/// What a look at a machine found, a line for each thing that matters before a session starts
/// there. Says what is wrong in words, and what is merely missing as a warning.
struct MachineCheck: View {
    let host: String
    let folder: String?
    let provider: SessionProvider
    @ObservedObject private var machines = RemoteMachines.shared

    var body: some View {
        let state = machines.state(of: host)
        VStack(alignment: .leading, spacing: 5) {
            switch state {
            case .unknown:
                EmptyView()
            case .checking:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking at \(host)…").foregroundStyle(.secondary) }
            case .unreachable(let why):
                line(.bad, why)
            case .reachable(let report):
                line(.good, "Reached \(host): \(report.system)")
                if !report.supported {
                    line(.bad, "omux can't run sessions on \(report.system) yet. Linux on Intel or ARM works; Windows through WSL.")
                } else if report.hostVersion != nil {
                    line(.good, report.running.isEmpty ? "omux is set up there" : "omux is set up there, with \(report.running.count) session\(report.running.count == 1 ? "" : "s") running")
                } else {
                    line(.note, "omux will set itself up there when the first session opens")
                }
                if provider == .claude {
                    report.claude ? line(.good, "Claude Code is installed there")
                                  : line(.warn, "Claude Code wasn't found there. Install it on \(host) and sign in before starting a session.")
                }
                if let exists = report.folderExists {
                    exists ? line(.good, "The folder is there") : line(.bad, "No folder \(folder ?? "") on \(host)")
                }
            }
        }
        .font(.caption)
    }

    private enum Mark { case good, warn, bad, note }

    private func line(_ mark: Mark, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch mark {
            case .good: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.done)
            case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.needs)
            case .bad: Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.error)
            case .note: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
            }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Whether what was found stands in the way of a session there.
    static func blocks(_ state: MachineState) -> Bool {
        switch state {
        case .unreachable: return true
        case .reachable(let report): return !report.supported || report.folderExists == false
        default: return false
        }
    }
}

/// Picks a folder on another machine, the way the open panel does on this one.
struct RemoteFolderBrowser: View {
    let host: String
    @Binding var folder: String
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var names: [String] = []
    @State private var problem: String?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { open((path as NSString).deletingLastPathComponent) } label: { Image(systemName: "chevron.up") }
                    .disabled(path == "/" || path.isEmpty)
                    .help("The folder above")
                Text(path.isEmpty ? host : path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(10)
            Divider()
            if let problem {
                Text(problem).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if names.isEmpty, !loading {
                Text("No folders in here").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(names, id: \.self) { name in
                    Button { open(path == "/" ? "/" + name : path + "/" + name) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(name).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Text("On \(host)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose This Folder") { folder = path; dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(path.isEmpty || problem != nil)
            }
            .padding(10)
        }
        .frame(width: 420, height: 380)
        .task { open(folder.isEmpty ? "~" : folder) }
    }

    private func open(_ target: String) {
        loading = true
        Task {
            let result = await RemoteMachines.folders(on: host, in: target)
            loading = false
            switch result {
            case .success(let listing):
                path = listing.path; names = listing.names; problem = nil
            case .failure(let failure):
                // A folder that isn't there, typed by hand: start from home instead of a dead end.
                if path.isEmpty, target != "~" { open("~") } else { problem = failure.text }
            }
        }
    }
}

/// A folder on a machine: typed, or browsed for.
struct RemoteFolderField: View {
    let host: String
    @Binding var folder: String
    @State private var browsing = false

    var body: some View {
        HStack {
            TextField("Folder", text: $folder, prompt: Text("~/code/app, a folder on that machine"))
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
            Button("Browse…") { browsing = true }
                .disabled(!RemoteMachines.isValid(host))
                .popover(isPresented: $browsing) { RemoteFolderBrowser(host: host, folder: $folder) }
        }
    }
}

/// A project on another machine, made in one go: where, which folder, which agent, with a
/// look at the machine before anything is created.
struct RemoteProjectSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var machines = RemoteMachines.shared
    @State private var name = ""
    @State private var host = ""
    @State private var folder = ""
    @State private var provider = SessionProvider.claude

    private var machine: String { host.trimmingCharacters(in: .whitespaces) }
    private var valid: Bool { RemoteMachines.isValid(machine) }
    private var shownName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty { return typed }
        let last = (folder.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        return last.isEmpty || last == "~" ? machine : last
    }

    var body: some View {
        Form {
            Section {
                MachineField(host: $host)
                RemoteFolderField(host: machine, folder: $folder)
                TextField("Name", text: $name, prompt: Text(shownName.isEmpty ? "Project" : shownName))
                Picker("New sessions", selection: $provider) {
                    Text(SessionProvider.claude.label).tag(SessionProvider.claude)
                    Text(SessionProvider.codex.label).tag(SessionProvider.codex)
                    Text(SessionProvider.shell.label).tag(SessionProvider.shell)
                }
            } header: {
                Text("New Remote Project").font(.headline)
            } footer: {
                Text("Sessions run on that machine over SSH and keep running there when omux is closed. Enter how you reach it with ssh: a name from ~/.ssh/config, or user@address.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if valid, machines.state(of: machine) != .unknown {
                Section { MachineCheck(host: machine, folder: folder.isEmpty ? nil : folder, provider: provider) }
            } else if !machine.isEmpty, !valid {
                Section { Text("A machine is one word, such as devbox or me@10.0.0.5.").font(.caption).foregroundStyle(Palette.error) }
            }
            HStack {
                Button("Test") { test() }.disabled(!valid || machines.state(of: machine) == .checking)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || machines.state(of: machine) == .checking)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            // Asked for with a machine named, as /remote devbox ~/code/app does: have a look at once.
            (host, folder) = store.remoteDraft
            store.remoteDraft = ("", "")
            if valid { test() }
        }
    }

    private func test() {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        Task { await machines.check(machine, folder: folder.isEmpty ? nil : folder) }
    }

    /// Looks first, unless a look has just been had, and creates the project only when
    /// nothing stands in the way: a typo is caught here, not in a session that won't connect.
    private func create() {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        Task {
            let state = await machines.check(machine, folder: folder.isEmpty ? nil : folder)
            guard !MachineCheck.blocks(state) else { return }
            store.newRemoteGroup(name: shownName, host: machine, directory: folder.isEmpty ? nil : folder, provider: provider)
            dismiss()
        }
    }
}

/// Settings › Machines: every machine projects run on or have run on, how it is, what runs
/// there, and what can be done about it.
struct MachinesSettings: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var machines = RemoteMachines.shared
    @State private var adding = ""
    @State private var removing: String?
    @State private var failure: String?

    private var hosts: [String] {
        var seen: Set<String> = []
        return (store.groups.compactMap { $0.isRemote ? $0.host : nil } + machines.remembered).filter { seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            if hosts.isEmpty {
                Section {
                    Text("No machines yet").font(.headline)
                    Text("A project can run on another machine you reach with ssh: its sessions go on there when omux is closed. Make one with File › New Remote Project…, or add a machine here to look at it first.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(hosts, id: \.self) { host in machine(host) }
            Section("Add a machine") {
                HStack {
                    MachineField(host: $adding)
                    Button("Add") {
                        let host = adding.trimmingCharacters(in: .whitespaces)
                        machines.remember(host)
                        Task { await machines.check(host) }
                        adding = ""
                    }
                    .disabled(!RemoteMachines.isValid(adding.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        .formStyle(.grouped)
        .task { for host in hosts { Task { await machines.check(host, quietly: true) } } }
        .confirmationDialog("Remove omux from \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove omux and Close Its Sessions", role: .destructive) {
                guard let host = removing else { return }
                Task { failure = await machines.removeOmux(from: host) }
            }
        } message: {
            let running = removing.flatMap { machines.state(of: $0).report?.running.count } ?? 0
            Text(running > 0 ? "\(running) session\(running == 1 ? "" : "s") running there will be closed, and the ~/.omux folder deleted. Your projects, their files and Claude Code's conversations stay."
                             : "The ~/.omux folder there is deleted. Your projects, their files and Claude Code's conversations stay. omux sets itself up again the next time a session opens there.")
        }
        .alert("Couldn't remove omux", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    @ViewBuilder
    private func machine(_ host: String) -> some View {
        let state = machines.state(of: host)
        let projects = store.groups.filter { $0.host == host }
        Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(host).font(.system(.body, design: .monospaced)).fontWeight(.medium)
                    summary(state)
                    if !projects.isEmpty {
                        Text("Used by \(projects.map(\.name).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Check") { Task { await machines.check(host) } }.disabled(state == .checking)
            }
            if let report = state.report {
                ForEach(report.sessions, id: \.id) { session in row(session, on: host) }
                HStack {
                    if report.hostVersion != nil {
                        Button("Remove omux from This Machine…", role: .destructive) { removing = host }
                    }
                    Spacer()
                    if projects.isEmpty { Button("Forget") { machines.forget(host) } }
                }
                .controlSize(.small)
            } else if projects.isEmpty {
                HStack { Spacer(); Button("Forget") { machines.forget(host) }.controlSize(.small) }
            }
        }
    }

    @ViewBuilder
    private func summary(_ state: MachineState) -> some View {
        switch state {
        case .unknown: Text("Not looked at yet").font(.caption).foregroundStyle(.secondary)
        case .checking: HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Looking…").font(.caption).foregroundStyle(.secondary) }
        case .unreachable(let why):
            Label(why, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Palette.needs).fixedSize(horizontal: false, vertical: true)
        case .reachable(let report):
            let parts = [report.system,
                         !report.supported ? "not supported yet" : report.hostVersion != nil ? "omux set up" : "omux not set up yet",
                         report.claude ? "Claude Code installed" : "no Claude Code"]
            Label(parts.joined(separator: " · "), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// A session on the machine: one of this omux's, or one something else started there,
    /// such as omux on another Mac, which can be opened here.
    @ViewBuilder
    private func row(_ session: SessionInfo, on host: String) -> some View {
        let mine = UUID(uuidString: session.id).flatMap { store.tab($0) }
        HStack(spacing: 8) {
            Circle().fill(session.exited == nil ? Palette.done : Color.secondary.opacity(0.4)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(mine?.name ?? session.name).lineLimit(1)
                Text([session.directory, session.exited.map { "ended with \($0)" } ?? "running",
                      mine == nil ? "not open in this omux" : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if mine == nil, session.exited == nil, UUID(uuidString: session.id) != nil {
                Button("Open Here") { store.adoptRemoteSession(session, on: host) }
                    .help("Shows this session in a project here; it keeps running on \(host) as it is")
            } else if let mine {
                Button("Show") { store.selectedTabID = mine.id; NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }?.makeKeyAndOrderFront(nil) }
            }
            Button(session.exited == nil ? "Close" : "Clear") {
                if let mine { store.requestClose(mine.id) } else { Task { await machines.close(session: session.id, on: host) } }
            }
        }
        .controlSize(.small)
    }
}

/// The mark beside a remote project's name in the sidebar: the machine, and whether it can be
/// reached right now.
struct MachineBadge: View {
    let host: String
    @ObservedObject private var machines = RemoteMachines.shared

    var body: some View {
        let problem = machines.state(of: host).problem
        HStack(spacing: 3) {
            Image(systemName: problem == nil ? "network" : "exclamationmark.triangle.fill").font(.system(size: 8))
            Text(host).font(.system(size: 9.5, design: .monospaced)).lineLimit(1)
        }
        .foregroundStyle(problem == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Palette.needs))
        .help(problem ?? "Sessions of this project run on \(host)")
    }
}
