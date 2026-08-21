import Foundation
import UserNotifications

/// Local notifications, fired once per crossing rather than once per poll.
///
/// Requires the app to be launched from an installed bundle via Launch Services. A
/// bundle identifier whose first authorization request comes from a bare binary run
/// outside a bundle is denied permanently, and no amount of re-asking recovers it.
public final class Notifier {
    private let center = UNUserNotificationCenter.current()
    private var fired: Set<String>
    private let lock = NSLock()

    public init() {
        fired = Set(JSONStore.load([String].self, from: Paths.notifiedFile) ?? [])
    }

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

    /// Posts only the first time this key crosses. The key should include the window's
    /// reset time so the same window re-arms after it turns over.
    public func postOnce(key: String, title: String, body: String) {
        lock.lock()
        let alreadyFired = fired.contains(key)
        if !alreadyFired {
            fired.insert(key)
            // Bounded so a long-lived install does not accumulate keys forever; the
            // oldest crossings are the least interesting.
            if fired.count > 500 { fired = Set(fired.suffix(250)) }
        }
        let snapshot = Array(fired)
        lock.unlock()
        guard !alreadyFired else { return }
        JSONStore.save(snapshot, to: Paths.notifiedFile)
        post(title: title, body: body)
    }

    /// Clears a crossing so it can fire again, used when a window resets.
    public func rearm(keyPrefix: String) {
        lock.lock()
        let before = fired.count
        fired = fired.filter { !$0.hasPrefix(keyPrefix) }
        let snapshot = Array(fired)
        let changed = before != fired.count
        lock.unlock()
        if changed { JSONStore.save(snapshot, to: Paths.notifiedFile) }
    }
}
