#if canImport(UnityFramework)
import Foundation
import UIKit
import UnityFramework

/// The app's single embedded Unity player (ADR-0034). Swift only sees this seam: start it,
/// take its view, pause it, and send the stand's small string messages. The 3D adapter
/// exists only in the 3D scheme; the default build never imports UnityFramework.
@MainActor
final class UnityRuntime {
    static let shared = UnityRuntime()

    static let eventName = Notification.Name("EidolonStandEvent")
    static let eventKey = "json"
    static let contentFolderName = "Unity3DContent"
    static let hostObject = "EidolonStandHost"

    private(set) var rootView: UIView?
    private(set) var lastEvent: String?
    var onEvent: ((String) -> Void)?

    private var started = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: Self.eventName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let json = notification.userInfo?[Self.eventKey] as? String else { return }
            MainActor.assumeIsolated {
                self?.lastEvent = json
                self?.onEvent?(json)
            }
        }
    }

    /// The 3D content directory, when the app was built with one.
    nonisolated static var contentRoot: URL? {
        Bundle.main.url(forResource: contentFolderName, withExtension: nil)
    }

    /// Whether this build can offer 3D at all: the content folder is present and the
    /// framework is embedded. The framework is loaded lazily in `start()`.
    var isAvailable: Bool {
        guard Self.contentRoot != nil else { return false }
        let path = Bundle.main.privateFrameworksURL?
            .appendingPathComponent("UnityFramework.framework").path
        return path.map { FileManager.default.fileExists(atPath: $0) } ?? false
    }

    func start() -> UIView? {
        if let rootView { return rootView }
        guard let framework = EidolonUnityLoadFramework() else { return nil }
        if !started {
            started = true
            EidolonUnityStart(framework)
        }
        // Keep the player's own window below ours, or it takes every touch.
        EidolonUnityDetachWindow(framework)
        rootView = EidolonUnityRootView(framework)
        return rootView
    }

    func send(_ method: String, _ message: String) {
        guard let framework = EidolonUnityLoadFramework() else { return }
        framework.sendMessageToGO(withName: Self.hostObject, functionName: method, message: message)
    }

    func setPaused(_ paused: Bool) {
        EidolonUnityLoadFramework()?.pause(paused)
    }
}

/// The optional 3D runtime. It is registered only when the 3D scheme compiles
/// UnityFramework in; without a `model3d` package `makeRenderer` still returns a renderer,
/// which fails with `contentMissing` so the page falls back to 2D.
@MainActor
final class UnityPresentationRuntime: PresentationRuntime {
    let runtimeID = RuntimeID.unityUaaL
    let capabilities = RuntimeCapabilities.unity3D
    var isAvailable: Bool { UnityRuntime.shared.isAvailable }

    func makeRenderer(_ assets: RuntimeAssets) throws -> any CharacterRenderer {
        UnityCharacterRenderer(assets: assets)
    }

    func setPausedAll(_ paused: Bool) {
        UnityRuntime.shared.setPaused(paused)
    }
}
#endif
