import CoreGraphics
import SwiftUI

/// The three presentations S2.2 uses. Width comes from the container, never the screen.
enum ResponsiveWidthBand: Equatable {
    case compact
    case medium
    case wide
}

/// What one drag sample means for the roster column. `visibleWidth` is what the finger
/// sees while dragging; `settledWidth` is where it goes on release.
struct RosterDragResult: Equatable {
    let visibleWidth: CGFloat
    let settledWidth: CGFloat
    let willCollapse: Bool
}

/// Pure layout decisions shared by the shell and the tests. All of them take the
/// container's width, never the screen's.
enum ResponsiveLayout {
    /// Below this it is the phone layout: bottom tabs and a pushed chat.
    static let mediumMinWidth: CGFloat = 650
    /// Above this the roster and the chat sit side by side.
    static let wideMinWidth: CGFloat = 960

    // MARK: Left rail

    static let railMinWidth: CGFloat = 88
    static let railDefaultWidth: CGFloat = 165
    static let railMaxWidth: CGFloat = 240
    /// Below this the rail shows icons + the E monogram; at or above it, labels return.
    static let railLabelThreshold: CGFloat = 150

    // MARK: Roster / chat columns

    static let rosterMinWidth: CGFloat = 280
    static let rosterDefaultWidth: CGFloat = 320
    static let rosterMaxWidth: CGFloat = 460
    static let chatMinWidth: CGFloat = 420
    /// The layout width reserved for the vertical handle / active line between columns.
    static let splitterLayoutWidth: CGFloat = 12

    // MARK: Drag feel

    /// Once the roster is narrower than its minimum, this much continued travel must be
    /// crossed before release actually collapses it.
    static let rosterCollapseOvershoot: CGFloat = 36
    /// In the rubber-band zone the visible width moves only a little per point.
    static let rosterRubberBandFactor: CGFloat = 0.14

    // MARK: Drag chrome

    static let activeLineWidth: CGFloat = 2
    static let handlePillWidth: CGFloat = 4
    static let handlePillHeight: CGFloat = 44
    static let handleHitSize: CGFloat = 44
    static let dragBlurRadius: CGFloat = 14
    static let dragFeedbackDuration: TimeInterval = 0.12
    static let railHitWidth: CGFloat = 12

    // MARK: Titles / filters

    /// Shared horizontal anchor for a pad page title, measured from the page content's
    /// leading edge (i.e. after the rail).
    static let pageTitleLeading: CGFloat = 20
    /// Shared top anchor measured from the page content's top safe area.
    static let pageTitleTop: CGFloat = 12
    static let filterButtonWidth: CGFloat = 44
    static let filterTrailingInset: CGFloat = 64

    /// Cards and the settings detail may use more of an iPad's width than a text column.
    static let wideMaxWidth: CGFloat = 1000

    /// The settings category column inside the S2.1/S2.2 rail shell.
    static let settingsSidebarWidth: CGFloat = 250

    // MARK: Width bands

    static func band(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> ResponsiveWidthBand {
        guard sizeClass == .regular else { return .compact }
        if width < mediumMinWidth { return .compact }
        if width <= wideMinWidth { return .medium }
        return .wide
    }

    // MARK: Left rail

    static func clampedRailWidth(_ raw: CGFloat) -> CGFloat {
        min(max(raw, railMinWidth), railMaxWidth)
    }

    static func railShowsLabels(width: CGFloat) -> Bool {
        width >= railLabelThreshold
    }

    // MARK: Roster safe zones

    /// The safe range for the roster, after the rail and divider have taken their space.
    /// The chat's minimum width is the other constraint; the default cap is 460.
    static func rosterBounds(availableWidth: CGFloat) -> ClosedRange<CGFloat> {
        let availableForRoster = availableWidth - splitterLayoutWidth - chatMinWidth
        let upper = min(rosterMaxWidth, availableForRoster)
        guard upper > rosterMinWidth else { return rosterMinWidth...rosterMinWidth }
        return rosterMinWidth...upper
    }

    /// Resolve one drag sample. In the safe range the finger wins; below the minimum the
    /// visible width only creeps (rubber band), and only a selected chat can cross the
    /// 36pt overshoot to a real collapse on release.
    static func resolveRosterDrag(
        rawWidth: CGFloat,
        availableWidth: CGFloat,
        hasSelection: Bool
    ) -> RosterDragResult {
        let bounds = rosterBounds(availableWidth: availableWidth)
        if rawWidth >= bounds.lowerBound {
            let visible = min(rawWidth, bounds.upperBound)
            return RosterDragResult(
                visibleWidth: visible,
                settledWidth: visible,
                willCollapse: false
            )
        }

        let overshoot = bounds.lowerBound - rawWidth
        if hasSelection, overshoot >= rosterCollapseOvershoot {
            // Stay on the safe boundary while the finger has crossed the collapse
            // threshold; release is what actually collapses the roster.
            return RosterDragResult(
                visibleWidth: bounds.lowerBound,
                settledWidth: 0,
                willCollapse: true
            )
        }

        let visible = bounds.lowerBound - overshoot * rosterRubberBandFactor
        return RosterDragResult(
            visibleWidth: visible,
            settledWidth: bounds.lowerBound,
            willCollapse: false
        )
    }

    /// Clamp a remembered width when the rail resized or the window rotated.
    static func clampedRosterWidth(
        _ width: CGFloat,
        availableWidth: CGFloat,
        hasSelection: Bool
    ) -> CGFloat {
        if width <= 0 {
            return hasSelection ? 0 : rosterMinWidth
        }
        let bounds = rosterBounds(availableWidth: availableWidth)
        return min(max(width, bounds.lowerBound), bounds.upperBound)
    }

    // MARK: Titles

    // MARK: Generic

    /// How far the folded call layer sits below its container. The layer paints past the
    /// safe area, so its travel is the container plus both insets.
    static func callCollapsedOffset(containerHeight: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        containerHeight + safeTop + safeBottom
    }
}
