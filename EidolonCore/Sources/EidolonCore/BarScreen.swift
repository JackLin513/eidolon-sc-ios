import Foundation

/// How the bar's screen is drawn and where (`.scratch/bar-room` spec「画框和缩放」; upstream
/// `lib/barScreen.ts`): the original's 640×360 logical screen, scaled into what is left of the
/// viewport once the safe area and the call bar across the top are taken away.
///
/// With a mouse it is the largest whole multiple that fits, so the pixels stay crisp, and a
/// fraction only when not even 1× fits; with a finger it is the largest fraction that fits,
/// drawn pixelated. The iPhone has no 「全屏横过来」 button: it cannot lock the screen's
/// orientation, and the bar is played upright on it anyway.
public enum BarScreen {
    /// The logical screen, in the original's pixels.
    public static let width = 640
    public static let height = 360

    /// Whether the screen is under a mouse or a finger.
    public enum Pointer: String, Sendable, Hashable {
        case fine, coarse
    }

    /// The safe area around the viewport.
    public struct Insets: Sendable, Hashable {
        public var top: Double
        public var right: Double
        public var bottom: Double
        public var left: Double

        public static let none = Insets(top: 0, right: 0, bottom: 0, left: 0)

        public init(top: Double, right: Double, bottom: Double, left: Double) {
            self.top = top
            self.right = right
            self.bottom = bottom
            self.left = left
        }
    }

    /// The viewport, its safe-area insets, how tall the call bar across its top is (0 when
    /// there is none) and the pointer.
    public struct Viewport: Sendable, Hashable {
        public var width: Double
        public var height: Double
        public var insets: Insets
        public var callBar: Double
        public var pointer: Pointer

        public init(
            width: Double, height: Double, insets: Insets = .none, callBar: Double = 0,
            pointer: Pointer
        ) {
            self.width = width
            self.height = height
            self.insets = insets
            self.callBar = callBar
            self.pointer = pointer
        }
    }

    /// The screen's scale, and its top-left corner from the top-left of the block under the
    /// call bar, centred in what is left of it.
    public struct Placement: Sendable, Hashable {
        public var scale: Double
        public var left: Double
        public var top: Double

        public init(scale: Double, left: Double, top: Double) {
            self.scale = scale
            self.left = left
            self.top = top
        }

        /// Where a point of the viewport under the screen falls on the logical screen: the
        /// inverse of the scale and the offset. A finger reports its points in the viewport's
        /// own coordinates, but everything the bar draws and every box it tests a drop against
        /// is in the screen's 640×360.
        public func screenX(_ x: Double) -> Double {
            guard scale > 0 else { return 0 }
            return (x - left) / scale
        }

        public func screenY(_ y: Double) -> Double {
            guard scale > 0 else { return 0 }
            return (y - top) / scale
        }
    }

    public static func placement(_ viewport: Viewport) -> Placement {
        let top = max(viewport.insets.top - viewport.callBar, 0)
        let freeWidth = max(viewport.width - viewport.insets.left - viewport.insets.right, 0)
        let freeHeight = max(
            viewport.height - viewport.callBar - top - viewport.insets.bottom, 0
        )
        let fits = min(freeWidth / Double(width), freeHeight / Double(height))
        let scale = viewport.pointer == .fine && fits >= 1 ? fits.rounded(.down) : fits
        return Placement(
            scale: scale,
            left: viewport.insets.left + ((freeWidth - Double(width) * scale) / 2).rounded(.down),
            top: top + ((freeHeight - Double(height) * scale) / 2).rounded(.down)
        )
    }
}
