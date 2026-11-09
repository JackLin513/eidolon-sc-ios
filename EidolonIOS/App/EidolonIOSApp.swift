import SwiftUI
import UIKit
import UserNotifications

@main
struct EidolonIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        MomentsBackground.register()
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// A tap on 「她发了新动态」 opens the moments tab; the page itself loads the posts.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.userInfo["tab"] as? String == "moments"
        else { return }
        await MainActor.run {
            MomentsNotifications.pendingOpen = true
            NotificationCenter.default.post(name: MomentsNotifications.openMoments, object: nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

}
