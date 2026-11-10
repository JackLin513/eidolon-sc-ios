import CoreGraphics
import SwiftUI

/// The three presentations S2.1 uses. Width comes from the container, never the screen.
enum ResponsiveWidthBand: Equatable {
    case compact
    case medium
    case wide
}

/// Pure layout decisions shared by the shell and the tests. All of them take the
/// container's width, never the screen's.
enum ResponsiveLayout {
    /// Below this it is the phone layout: bottom tabs and a pushed chat.
    static let mediumMinWidth: CGFloat = 650
    /// Above this the roster and the chat sit side by side.
    static let wideMinWidth: CGFloat = 960

    /// The fixed navigation rail on medium and wide.
    static let railWidth: CGFloat = 165

    /// The wide roster's three resting positions.
    static let rosterCollapsedWidth: CGFloat = 0
    static let rosterStandardWidth: CGFloat = 320
    static let rosterExpandedWidth: CGFloat = 460

    /// The roster keeps this layout width while it is being clipped during a collapse.
    static let rosterMinContentWidth: CGFloat = 280

    /// Settings, moments and play stay single-column; this only stops text fields and
    /// cards from stretching across a 13-inch window.
    static let readingMaxWidth: CGFloat = 680

    /// Cards and the settings detail may use more of an iPad's width than a text column.
    static let wideMaxWidth: CGFloat = 1000

    static func band(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> ResponsiveWidthBand {
        guard sizeClass == .regular else { return .compact }
        if width < mediumMinWidth { return .compact }
        if width <= wideMinWidth { return .medium }
        return .wide
    }

    /// Live width while the gray handle is being dragged.
    static func draggingRosterWidth(start: CGFloat, translation: CGFloat) -> CGFloat {
        min(max(start + translation, rosterCollapsedWidth), rosterExpandedWidth)
    }

    /// The resting width after a drag. The caller passes the width projected through
    /// `predictedEndTranslation`, so a quick fling reaches the next stop.
    static func snapRosterWidth(projectedWidth: CGFloat) -> CGFloat {
        // Midpoints belong to the wider stop, matching the spring's direction of travel.
        if projectedWidth < (rosterCollapsedWidth + rosterStandardWidth) / 2 {
            return rosterCollapsedWidth
        }
        if projectedWidth < (rosterStandardWidth + rosterExpandedWidth) / 2 {
            return rosterStandardWidth
        }
        return rosterExpandedWidth
    }

    /// The content keeps its natural minimum while the visible frame closes; clipping,
    /// not text compression, hides it.
    static func rosterContentWidth(visibleWidth: CGFloat) -> CGFloat {
        max(visibleWidth, rosterMinContentWidth)
    }

    /// Single-column pages stay readable but centred on a wide window.
    static func readingContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: readingMaxWidth)
            .frame(maxWidth: .infinity)
    }

    /// How far the folded call layer sits below its container. The layer paints past the
    /// safe area, so its travel is the container plus both insets.
    static func callCollapsedOffset(containerHeight: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        containerHeight + safeTop + safeBottom
    }
}
