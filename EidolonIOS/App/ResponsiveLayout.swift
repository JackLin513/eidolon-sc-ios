import CoreGraphics

/// Pure layout decisions shared by the shell and the tests. All of them take the
/// container's width, never the screen's.
enum ResponsiveLayout {
    /// Regular-width conversations get the roster + chat split; below this they are one
    /// navigation stack. 760pt keeps an iPad mini in landscape split and a 1/2 split on
    /// the 13-inch iPad on the two-column side.
    static let conversationSplitMinWidth: CGFloat = 760

    /// Settings, moments and play stay single-column; this only stops text fields and
    /// cards from stretching across a 13-inch window.
    static let readingMaxWidth: CGFloat = 680

    static func conversationColumns(width: CGFloat) -> Int {
        width >= conversationSplitMinWidth ? 2 : 1
    }

    static func contentWidth(container: CGFloat) -> CGFloat {
        min(max(container, 0), readingMaxWidth)
    }

    /// How far the folded call layer sits below its container. The layer paints past the
    /// safe area, so its travel is the container plus both insets.
    static func callCollapsedOffset(containerHeight: CGFloat, safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        containerHeight + safeTop + safeBottom
    }
}
