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
        .environment(\.barOrientation, BarOrientation())
    }
}

/// Asks the app to turn for the bar, and back when it is left.
struct BarOrientation: Sendable {
    @MainActor func landscape() { EidolonIOSApp.orientation(.landscape) }
    @MainActor func portrait() { EidolonIOSApp.orientation(.portrait) }
}

extension EnvironmentValues {
    @Entry var barOrientation = BarOrientation()
}

extension EidolonIOSApp {
    /// The app is upright everywhere but the bar: its 640×360 screen wants a phone held
    /// sideways, so the bar asks for landscape and puts it back when it is left.
    static func orientation(_ orientation: UIInterfaceOrientationMask) {
        AppDelegate.orientation = orientation
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static var orientation = UIInterfaceOrientationMask.portrait

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
            NotificationCenter.default.post(name: MomentsNotifications.openMoments, object: nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientation
    }
}
