import Foundation

/// The app's three first-level pages (spec #64). The conversation page shows the roster
/// and her chats, the play page holds the bar and the coming gift and achievement pages,
/// and settings is a page of its own instead of a sheet.
enum MainTab: Hashable {
    case conversation
    case play
    case settings
}

/// A page inside the play tab's stack (spec #64). The pages themselves arrive in later
/// tickets; the route already lives here so another tab can open one.
enum PlayRoute: Hashable {
    case gifts
    case achievements
}
