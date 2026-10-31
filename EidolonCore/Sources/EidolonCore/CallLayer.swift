import Foundation

/// Whether the shell draws a call, and how (spec #46, upstream ADR-0018): the call layer
/// stays mounted over the pages while the call lasts, either open over them or folded away
/// with only its bar showing. The rules live here so the app only calls them.
public enum CallLayer: Sendable, Hashable {
    /// No call at all: no layer, no bar.
    case absent
    /// The layer covers the page it was dialled from.
    case expanded
    /// The layer is folded off the page; its bar is showing.
    case collapsed

    /// A new call starts open, sliding up from the bottom of the page.
    public static let dialing: CallLayer = .expanded

    /// The same call connecting leaves the layer as the producer left it: folded stays
    /// folded, open stays open. A call that appears without a dial opens.
    public func connected() -> CallLayer {
        self == .absent ? .expanded : self
    }

    /// However the call ended, the end card must be seen.
    public func ended() -> CallLayer {
        .expanded
    }

    /// Folding away is only for a call under way.
    public func collapsing(live: Bool) -> CallLayer {
        live ? .collapsed : self
    }

    /// Unfolding is only for a call under way that is folded.
    public func expanding(live: Bool) -> CallLayer {
        live && self == .collapsed ? .expanded : self
    }

    /// The bar is drawn only while a call is under way and folded.
    public func showsBar(live: Bool) -> Bool {
        live && self == .collapsed
    }
}
