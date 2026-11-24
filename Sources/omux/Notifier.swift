import AppKit
import UserNotifications

/// macOS notifications for sessions you aren't looking at. Clicking one opens its session.
/// Only works when omux runs as an app bundle: the notification center traps in a bare
/// binary (`swift run`), so there it does nothing.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil

    /// Call before launch finishes, so a click on a notification reaches us.
    func activate() {
        center?.delegate = self
    }

    /// The macOS alert sounds, by name, plus "Default".
    nonisolated static let sounds = ["Default", "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]

    /// Plays the sound chosen in Settings. Sound-only notifications are just this.
    func playSound() {
        let name = UserDefaults.standard.string(forKey: Prefs.notifySound) ?? ""
        let sound = NSSound(named: name.isEmpty || name == "Default" ? "Glass" : name) ?? NSSound(named: "Glass")
        sound?.play()
    }

    /// Shows a notification for a session, replacing the one it showed before.
    /// With "sound only" in Settings, plays the sound and shows nothing.
    func post(tabID: UUID, title: String, subtitle: String?, body: String) {
        let soundOnly = UserDefaults.standard.string(forKey: Prefs.notifyStyle) == "sound"
        let customSound = (UserDefaults.standard.string(forKey: Prefs.notifySound) ?? "").isEmpty == false
            && UserDefaults.standard.string(forKey: Prefs.notifySound) != "Default"
        if soundOnly || customSound { playSound() }
        guard let center, !soundOnly else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        // A custom sound is played above, as the notification can't play system sounds by name.
        content.sound = customSound ? nil : .default
        content.threadIdentifier = tabID.uuidString
        content.userInfo = ["tabID": tabID.uuidString]
        let request = UNNotificationRequest(identifier: tabID.uuidString, content: content, trigger: nil)
        Task {
            guard await isAuthorized(center) else { return }
            try? await center.add(request)
        }
    }

    /// Removes a session's notification from Notification Center once you've seen the session.
    func clear(tabID: UUID) {
        center?.removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        return await center.notificationSettings().authorizationStatus
    }

    /// Asks now, for the welcome sheet. Returns the resulting status.
    func requestAuthorization() async -> UNAuthorizationStatus {
        guard let center else { return .denied }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission the first time there is something to show, not at launch.
    private func isAuthorized(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// omux only posts for sessions you aren't watching, so show them even while it's in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["tabID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await MainActor.run { Store.shared.reveal(id) }
    }
}
