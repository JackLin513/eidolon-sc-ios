import CoreGraphics
import EidolonCore
import SwiftUI

/// The three presentations S2.2 uses. Width comes from the container, never the screen.
enum ResponsiveWidthBand: Equatable {
    case compact
    case medium
    case wide
}


/// How the call layer is presented by the S2.2 shell. Width alone is not enough: a
/// wide conversation page keeps the roster visible, so the call only takes the chat
/// column; any other wide page takes the content area to the right of the rail.
enum CallPresentation: Equatable {
    case fullScreen
    case page
    case conversationPane
    /// A narrow, tall conversation pane is laid out like a phone call sheet: same
    /// knees framing and phone-like character scale, not the desktop waist framing.
    case phonePane

    var isPane: Bool { self != .fullScreen }

    /// The desktop pane frames her to the waist; a full-screen or phone-shaped pane
    /// frames to the knees. 3D full-bleed is reported by its renderer and overrides this.
    var standFraming: StandFraming {
        switch self {
        case .page, .conversationPane: .waist
        case .fullScreen: .knees
        case .phonePane: .full
        }
    }

    /// Her stage height in a viewport. The phone pane also caps by width: a tall, narrow
    /// Air portrait pane must not turn a 1024px atlas into a giant close-up.
    func standHeight(in viewport: CGSize, isCompactPhone: Bool) -> CGFloat {
        switch self {
        case .page, .conversationPane:
            return viewport.height * 0.92
        case .phonePane:
            // A tall portrait pane can hold her whole body at the same width; do not
            // waste the upper half on a knees crop.
            return viewport.height * 0.92
        case .fullScreen:
            return viewport.height * (isCompactPhone ? 0.80 : 0.70)
        }
    }
}

/// The four resting places of the folded-call capsule.
enum CallCapsuleCorner: CaseIterable, Equatable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
    /// Side-edge anchors (S2.3 addendum Q3-C): no top/bottom midpoint.
    case leading
    case trailing
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
    /// Distance from the seam to the hit area's leading edge; the visible pill is
    /// therefore a few points to the right of the boundary rather than on top of it.
    static let handleLineGap: CGFloat = 8

    /// Offset for the 44pt split-handle hit frame. The gray pill's centre sits
    /// `handleLineGap` right of the roster seam in both states; when the roster is
    /// collapsed the hit frame may extend a little into the rail so the pill does not
    /// jump inward to the hit-frame centre.
    static func splitHandleOffset(listWidth: CGFloat) -> CGFloat {
        listWidth + handleLineGap - handleHitSize / 2
    }
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

    // MARK: Call presentation

    static func callPresentation(
        band: ResponsiveWidthBand,
        onConversation: Bool
    ) -> CallPresentation {
        guard band == .wide else { return .fullScreen }
        return onConversation ? .conversationPane : .page
    }

    /// A conversation pane narrower than a phone-ish aspect is laid out as a phone
    /// sheet instead of a desktop pane.
    static func resolvePaneCallPresentation(
        _ presentation: CallPresentation,
        paneSize: CGSize,
        containerSize: CGSize
    ) -> CallPresentation {
        // The pane size comes from a preference that can still be the previous
        // orientation for one layout pass. Resolve against the current window too:
        // a landscape window is never a phone pane, even if the stale pane looks tall.
        guard presentation == .conversationPane,
              paneSize.height > 0,
              containerSize.height > containerSize.width,
              paneSize.width / paneSize.height < 0.55
        else { return presentation }
        return .phonePane
    }

    // MARK: Folded-call capsule

    static let callCapsuleMargin: CGFloat = 16
    /// The folded capsule rests above her chat composer; on a phone it also clears the
    /// bottom tab bar.
    static let callCapsuleConversationClearance: CGFloat = 104
    static let callCapsuleCompactClearance: CGFloat = 52

    /// The resting centre of the capsule in its container, inside the safe area.
    static func callCapsuleCenter(
        corner: CallCapsuleCorner,
        size: CGSize,
        container: CGSize,
        safeInsets: EdgeInsets,
        margin: CGFloat = callCapsuleMargin,
        extraBottom: CGFloat = 0
    ) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let minX = safeInsets.leading + margin + halfW
        let maxX = max(minX, container.width - safeInsets.trailing - margin - halfW)
        let minY = safeInsets.top + margin + halfH
        let maxY = max(minY, container.height - safeInsets.bottom - margin - halfH - extraBottom)
        let x: CGFloat = switch corner {
        case .topLeading, .bottomLeading, .leading: minX
        case .topTrailing, .bottomTrailing, .trailing: maxX
        }
        let y: CGFloat = switch corner {
        case .topLeading, .topTrailing: minY
        case .bottomLeading, .bottomTrailing: maxY
        case .leading, .trailing: min(max(container.height / 2, minY), maxY)
        }
        return CGPoint(x: x, y: y)
    }

    /// A free vertical position on a left/right edge; Q3-C allows any y, not just the
    /// midpoint or the three corner-ish slots the discrete anchors produced.
    static func callCapsuleSideCenter(
        side: CallCapsuleCorner,
        y: CGFloat,
        size: CGSize,
        container: CGSize,
        safeInsets: EdgeInsets,
        margin: CGFloat = callCapsuleMargin,
        extraBottom: CGFloat = 0
    ) -> CGPoint {
        let center = callCapsuleCenter(
            corner: side,
            size: size,
            container: container,
            safeInsets: safeInsets,
            margin: margin,
            extraBottom: extraBottom
        )
        let halfH = size.height / 2
        let minY = safeInsets.top + margin + halfH
        let maxY = max(minY, container.height - safeInsets.bottom - margin - halfH - extraBottom)
        return CGPoint(x: center.x, y: min(max(y, minY), maxY))
    }

    /// The four corners, without the side anchors: used when a drag is not close enough
    /// to a screen edge to dock.
    static func callCapsuleCornerOnly(
        for center: CGPoint,
        size: CGSize,
        container: CGSize,
        safeInsets: EdgeInsets,
        margin: CGFloat = callCapsuleMargin,
        extraBottom: CGFloat = 0
    ) -> CallCapsuleCorner {
        [.topLeading, .topTrailing, .bottomLeading, .bottomTrailing].min { lhs, rhs in
            let l = callCapsuleCenter(
                corner: lhs, size: size, container: container,
                safeInsets: safeInsets, margin: margin, extraBottom: extraBottom
            )
            let r = callCapsuleCenter(
                corner: rhs, size: size, container: container,
                safeInsets: safeInsets, margin: margin, extraBottom: extraBottom
            )
            let ld = pow(l.x - center.x, 2) + pow(l.y - center.y, 2)
            let rd = pow(r.x - center.x, 2) + pow(r.y - center.y, 2)
            return ld < rd
        } ?? .bottomTrailing
    }

    /// Keep a dragged capsule inside the safe area while the finger is down.
    static func clampedCallCapsuleCenter(
        _ center: CGPoint,
        size: CGSize,
        container: CGSize,
        safeInsets: EdgeInsets,
        margin: CGFloat = callCapsuleMargin,
        extraBottom: CGFloat = 0
    ) -> CGPoint {
        let halfW = size.width / 2
        let halfH = size.height / 2
        let minX = safeInsets.leading + margin + halfW
        let maxX = max(minX, container.width - safeInsets.trailing - margin - halfW)
        let minY = safeInsets.top + margin + halfH
        let maxY = max(minY, container.height - safeInsets.bottom - margin - halfH - extraBottom)
        return CGPoint(x: min(max(center.x, minX), maxX), y: min(max(center.y, minY), maxY))
    }

    /// The corner the capsule settles into after a drag: nearest by squared distance.
    static func callCapsuleCorner(
        for center: CGPoint,
        size: CGSize,
        container: CGSize,
        safeInsets: EdgeInsets,
        margin: CGFloat = callCapsuleMargin,
        extraBottom: CGFloat = 0
    ) -> CallCapsuleCorner {
        CallCapsuleCorner.allCases.min { lhs, rhs in
            let l = callCapsuleCenter(
                corner: lhs, size: size, container: container,
                safeInsets: safeInsets, margin: margin, extraBottom: extraBottom
            )
            let r = callCapsuleCenter(
                corner: rhs, size: size, container: container,
                safeInsets: safeInsets, margin: margin, extraBottom: extraBottom
            )
            let ld = pow(l.x - center.x, 2) + pow(l.y - center.y, 2)
            let rd = pow(r.x - center.x, 2) + pow(r.y - center.y, 2)
            return ld < rd
        } ?? .bottomTrailing
    }
}
