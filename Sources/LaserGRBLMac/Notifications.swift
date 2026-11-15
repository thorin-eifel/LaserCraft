import AppKit
import UserNotifications
import LaserGRBLCore

/// macOS notifications (Notification Center) for the end of a job.
/// Only available when running as a real app bundle; the permission is asked for when the first job starts.
enum Notifier {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private static let delegate = Delegate()

    /// Lets banners show even while the app is in front (the person may be looking at the machine, not the window).
    static func activate() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = delegate
    }

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private final class Delegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner])
        }
    }
}

/// Short system sounds for the main moments (connection, countdown, job, errors).
enum Sounds {
    enum Kind: String, CaseIterable {
        case connected = "Ping"          // connection established
        case connectionFailed = "Basso"  // connection failed
        case tick = "Tink"               // one second of the safety countdown
        case go = "Pop"                  // countdown over, the start button is released
        case started = "Submarine"       // job started
        case finished = "Hero"           // job finished
        case error = "Funk"              // something went wrong (Grbl error, restart, lost connection)
        case alarm = "Sosumi"            // machine alarm
    }

    static var enabled: Bool { UserDefaults.standard.object(forKey: "soundOnFinish") as? Bool ?? true }
    static var volume: Float { Float(UserDefaults.standard.object(forKey: "soundVolume") as? Double ?? 0.7) }

    /// Plays one of the macOS system sounds at the chosen volume (overlapping sounds are fine).
    static func play(_ kind: Kind, force: Bool = false) {
        guard force || enabled else { return }
        let path = "/System/Library/Sounds/\(kind.rawValue).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: NSSound.Name(kind.rawValue)) else { return }
        sound.volume = volume
        sound.play()
    }
}
