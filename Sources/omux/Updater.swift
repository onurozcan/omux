import Sparkle
import SwiftUI

/// Sparkle updates: a daily check of the appcast on omux.app, and Help › Check for Updates….
/// Only runs from an app bundle; `swift run` has no Info.plist for Sparkle to read.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController
    let isAvailable: Bool
    @Published private(set) var canCheck = false
    /// Mirrors Sparkle's own settings, which it keeps in omux's user defaults. Sparkle can change
    /// them too, e.g. from the "Automatically download and install" box in its update window.
    @Published var automaticallyChecks = false {
        didSet { if updater.automaticallyChecksForUpdates != automaticallyChecks { updater.automaticallyChecksForUpdates = automaticallyChecks } }
    }
    @Published var automaticallyDownloads = false {
        didSet { if updater.automaticallyDownloadsUpdates != automaticallyDownloads { updater.automaticallyDownloadsUpdates = automaticallyDownloads } }
    }
    @Published private(set) var allowsAutomaticDownloads = false
    @Published private(set) var lastCheck: Date?
    private var observations: [NSKeyValueObservation] = []

    var updater: SPUUpdater { controller.updater }

    private init() {
        isAvailable = Bundle.main.bundleURL.pathExtension == "app"
        controller = SPUStandardUpdaterController(startingUpdater: isAvailable, updaterDelegate: nil, userDriverDelegate: nil)
        // A check that finishes makes checking possible again, so that's when the date moves.
        observations.append(updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor in self?.canCheck = value; self?.refreshLastCheck() }
        })
        observations.append(updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.automaticallyChecksForUpdates
            Task { @MainActor in if self?.automaticallyChecks != value { self?.automaticallyChecks = value } }
        })
        observations.append(updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.automaticallyDownloadsUpdates
            Task { @MainActor in if self?.automaticallyDownloads != value { self?.automaticallyDownloads = value } }
        })
        observations.append(updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.allowsAutomaticUpdates
            Task { @MainActor in self?.allowsAutomaticDownloads = value }
        })
    }

    func check() { controller.checkForUpdates(nil) }

    func refreshLastCheck() { lastCheck = updater.lastUpdateCheckDate }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.check() }
            .disabled(!updater.canCheck)
    }
}

/// Settings › Updates.
struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
            Toggle("Download and install updates automatically", isOn: $updater.automaticallyDownloads)
                .disabled(!updater.automaticallyChecks || !updater.allowsAutomaticDownloads)
            Text("Downloaded updates are installed when you quit omux, so running sessions aren't interrupted.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text(lastCheckText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                CheckForUpdatesButton()
            }
        }
        .disabled(!updater.isAvailable)
        .onAppear { updater.refreshLastCheck() }
    }

    private var lastCheckText: String {
        guard updater.isAvailable else { return "Updates work in the app bundle, not from swift run." }
        guard let date = updater.lastCheck else { return "Not checked yet." }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }
}
