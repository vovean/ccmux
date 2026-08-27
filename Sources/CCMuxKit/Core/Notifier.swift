import CCMuxCore
import Foundation
import UserNotifications

/// Local notifications, fired once per crossing rather than once per poll.
///
/// Requires the app to be launched from an installed bundle via Launch Services. A
/// bundle identifier whose first authorization request comes from a bare binary run
/// outside a bundle is denied permanently, and no amount of re-asking recovers it.
public final class Notifier {
    /// Lazy: `UNUserNotificationCenter.current()` traps when there is no app bundle, so
    /// touching it must wait until something actually posts.
    private lazy var center = UNUserNotificationCenter.current()
    private let crossings = CrossingLog()

    public init() {}

    public enum Authorization: Equatable {
        case granted
        case notDetermined
        /// Recoverable: the app is listed in System Settings › Notifications and the
        /// switch can be turned back on. A prompt that is dismissed — or killed while
        /// still on screen — lands here, and re-asking will not bring it back.
        case denied
    }

    /// Asks only when the answer is still unknown, so a launch never re-logs a denial
    /// the user has already been told about.
    public func requestAuthorizationIfNeeded() async -> Authorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return .granted
        case .denied:
            Log.warn("notifications are disabled for ccmux; enable them in "
                     + "System Settings › Notifications")
            return .denied
        case .notDetermined:
            break
        @unknown default:
            return .notDetermined
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            if !granted {
                Log.warn("notification authorization was declined")
            }
            return granted ? .granted : .denied
        } catch {
            Log.warn("notification authorization failed: \(error.localizedDescription)")
            return .denied
        }
    }

    public func post(title: String, body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            if let error {
                Log.warn("could not post notification: \(error.localizedDescription)")
            }
        }
    }

    /// Posts only the first time this key crosses. The key includes the window's reset
    /// time, so the same window re-arms by itself once it turns over.
    public func postOnce(key: String, title: String, body: String) {
        guard crossings.claim(key) else { return }
        post(title: title, body: body)
    }
}
