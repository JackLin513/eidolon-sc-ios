import EidolonCore
import UIKit

/// Everything a renderer needs to prepare one character on one surface. The 2D adapter
/// reads the outfit; a future 3D adapter reads `model3D`.
struct RuntimeAssets {
    var contentRoot: URL
    var characterID: String
    var outfit: StandOutfit?
    var framing: StandFraming
    var model3D: Model3DCharacter?
    var model3DRoot: URL?

    init(
        contentRoot: URL,
        characterID: String,
        outfit: StandOutfit? = nil,
        framing: StandFraming,
        model3D: Model3DCharacter? = nil,
        model3DRoot: URL? = nil
    ) {
        self.contentRoot = contentRoot
        self.characterID = characterID
        self.outfit = outfit
        self.framing = framing
        self.model3D = model3D
        self.model3DRoot = model3DRoot
    }
}

/// One surface's way of drawing her (ADR-0017/0035). The page knows only this; it never
/// sees WebKit or Unity. `prepare` is followed by `present` once `onReady` reports what
/// the backend can actually do.
@MainActor
protocol CharacterRenderer: AnyObject {
    var runtimeID: RuntimeID { get }
    /// The view to lay out. It draws her on a transparent background and takes no touches.
    var view: UIView { get }

    /// The backend is ready: measured capabilities and where she sits.
    var onReady: ((RuntimeReport) -> Void)? { get set }
    /// Nothing can be drawn; the page falls back and keeps the call going.
    var onFailure: ((RuntimeFailure) -> Void)? { get set }

    func prepare(_ assets: RuntimeAssets)
    /// Replace the outfit without recreating the view (the outfit picker's preview).
    func load(_ outfit: StandOutfit)
    func present(_ frame: PresentationFrame)
    /// The exact at-rest pose the thumbnail bench has always snapshotted.
    func presentCalm()
    func setPaused(_ paused: Bool)
    func setViewport(_ size: CGSize)
    func snapshot() async -> UIImage?
}

extension CharacterRenderer {
    func presentCalm() {
        present(
            PresentationFrame(
                emotion: .calm,
                speaking: false,
                looking: false,
                framing: .full
            )
        )
    }

    /// Backends without a snapshot (for example Unity in S1) return nil; the UI uses a
    /// card/avatar instead.
    func snapshot() async -> UIImage? { nil }
}

/// One engine for the whole process (ADR-0035): create renderers per surface, and pause
/// the engine once when the app leaves the foreground. Unity is a single instance; Spine
/// is not, but both fit this shape.
@MainActor
protocol PresentationRuntime: AnyObject {
    var runtimeID: RuntimeID { get }
    var capabilities: RuntimeCapabilities { get }
    var isAvailable: Bool { get }
    func makeRenderer(_ assets: RuntimeAssets) throws -> any CharacterRenderer
    func setPausedAll(_ paused: Bool)
}

/// The runtimes compiled into this build, resolved by `RuntimeRequirement`. No dynamic
/// loading: the 3D adapter exists only when UnityFramework is linked into the 3D scheme.
@MainActor
final class RuntimeRegistry {
    static let shared = RuntimeRegistry(runtimes: defaultRuntimes())

    private var runtimes: [RuntimeID: any PresentationRuntime]

    init(runtimes: [any PresentationRuntime]) {
        var map: [RuntimeID: any PresentationRuntime] = [:]
        for runtime in runtimes {
            map[runtime.runtimeID] = runtime
        }
        self.runtimes = map
    }

    var available: Set<RuntimeID> {
        Set(runtimes.compactMap { id, runtime in runtime.isAvailable ? id : nil })
    }

    /// The first runtime in the requirement's order that is actually available.
    func runtime(
        for requirement: RuntimeRequirement,
        avoiding: Set<RuntimeID> = []
    ) -> (any PresentationRuntime)? {
        RuntimeResolver.order(requirement)
            .filter { !avoiding.contains($0) }
            .compactMap { runtimes[$0] }
            .first { $0.isAvailable }
    }

    /// A renderer for one surface, or nil when no runtime can draw (the page shows the
    /// avatar).
    func makeRenderer(
        _ requirement: RuntimeRequirement,
        assets: RuntimeAssets,
        avoiding: Set<RuntimeID> = []
    ) -> (any CharacterRenderer)? {
        guard let runtime = runtime(for: requirement, avoiding: avoiding) else { return nil }
        return try? runtime.makeRenderer(assets)
    }

    func setPausedAll(_ paused: Bool) {
        for runtime in runtimes.values {
            runtime.setPausedAll(paused)
        }
    }

    private static func defaultRuntimes() -> [any PresentationRuntime] {
        var runtimes: [any PresentationRuntime] = [
            SpinePresentationRuntime(),
            AvatarPresentationRuntime(),
        ]
        #if canImport(UnityFramework)
        runtimes.append(UnityPresentationRuntime())
        #endif
        return runtimes
    }
}

/// The built-in 2D player: always available; no process-wide pause.
@MainActor
final class SpinePresentationRuntime: PresentationRuntime {
    let runtimeID = RuntimeID.spineWebGL
    let capabilities = RuntimeCapabilities.spine2D
    var isAvailable: Bool { true }

    func makeRenderer(_ assets: RuntimeAssets) throws -> any CharacterRenderer {
        SpineCharacterRenderer(assets: assets)
    }

    func setPausedAll(_ paused: Bool) {}
}

/// The page-level fallback: the avatar is drawn by the view, not by a renderer.
@MainActor
final class AvatarPresentationRuntime: PresentationRuntime {
    let runtimeID = RuntimeID.avatar
    let capabilities = RuntimeCapabilities(
        expressions: [],
        framings: [],
        fullBleed: false,
        outfitSwitch: false,
        snapshot: false,
        lipSync: false,
        gaze: false,
        gesture: false,
        engine: nil
    )
    var isAvailable: Bool { true }

    func makeRenderer(_ assets: RuntimeAssets) throws -> any CharacterRenderer {
        throw RuntimeFailure.unavailable("头像由页面绘制")
    }

    func setPausedAll(_ paused: Bool) {}
}
