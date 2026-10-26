import EidolonCore
import UIKit

/// The one way the app draws her (ADR-0017): the call screen and the outfit preview know
/// only this seam. It loads an outfit, tells her how to look, pauses and resumes, and
/// reports what an outfit can play. The iOS implementation is a local `WKWebView`; a Metal
/// one would replace only that adapter.
@MainActor
protocol StandRenderer: AnyObject {
    /// The view to lay out. It draws her on a transparent background and takes no touches.
    var view: UIView { get }

    /// One outfit is loaded and the camera is set: what she can play, and her range.
    var onLoaded: ((StandPose.Report) -> Void)? { get set }
    /// Nothing can be drawn: no runtime, a page that failed, or unreadable outfit files.
    var onFailure: ((StandRenderFailure) -> Void)? { get set }

    /// Load one outfit, replacing the one she is wearing.
    func load(_ outfit: StandOutfit)
    /// What to play from now on.
    func direct(_ pose: StandPose)
    /// Stop drawing while the app is not in the foreground.
    func setPaused(_ paused: Bool)
    /// The size the view is laid out at, in points; the camera frames her for it.
    func setViewportSize(_ size: CGSize)
}

/// Why there is no stand to draw. Losing her is never fatal: the call goes on without a
/// stand (spec「退化」).
enum StandRenderFailure: Error, Equatable {
    /// The local page could not be loaded.
    case page(String)
    /// The Spine runtime is missing or cannot draw here.
    case runtime(String)
    /// Her outfit's files are missing or unreadable.
    case outfit(String)
}
