import EidolonCore
import UserNotifications

/// The two local notifications moments may send (spec #98): only when the background task
/// itself made something new, never for a foreground catch-up, and never with the words of
/// the post in them.
enum MomentsNotifications {
    static let openMoments = Notification.Name("eidolon.moments.open")
    /// Set when a notification is tapped while the app is not yet showing its tabs: a
    /// cold launch has no one listening to `openMoments` yet.
    @MainActor static var pendingOpen = false

    static func requestAuthorizationIfNeeded(moments: MomentsSettings) {
        guard moments.enabled, moments.notifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(posts: Int, replies: Int) {
        guard posts > 0 || replies > 0 else { return }
        let content = UNMutableNotificationContent()
        if posts > 0, replies > 0 {
            content.title = "她发了新动态"
            content.body = "她回复了你的评论"
        } else if posts > 0 {
            content.title = "她发了新动态"
        } else {
            content.title = "她回复了你的评论"
        }
        content.sound = .default
        content.userInfo = ["tab": "moments"]
        let request = UNNotificationRequest(
            identifier: "moments-\(UUID().uuidString)", content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
