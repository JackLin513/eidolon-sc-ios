import CoreGraphics
import SwiftUI

/// Pure layout decisions shared by the shell and the tests. All of them take the
/// container's width, never the screen's.
enum ResponsiveLayout {
    /// Regular-width conversations get the roster + chat split; below this they are one
    /// navigation stack. 760pt keeps an iPad mini in landscape split and a 1/2 split on
    /// the 13-inch iPad on the two-column side.
    static let conversationSplitMinWidth: CGFloat = 700

    /// Settings, moments and play stay single-column; this only stops text fields and
    /// cards from stretching across a 13-inch window.
    static let readingMaxWidth: CGFloat = 680

    static func isSplit(width: CGFloat, sizeClass: UserInterfaceSizeClass?) -> Bool {
        sizeClass == .regular && width >= conversationSplitMinWidth
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
