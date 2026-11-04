import Foundation

/// The app's four first-level pages (spec #64, #94). The conversation page shows the roster
/// and her chats, moments is the placeholder for what she posts, the play page holds the
/// five cards (gifts, achievements, calendar, her cycles, the bar), and settings is a page
/// of its own instead of a sheet.
enum MainTab: Hashable {
    case conversation
    case moments
    case play
    case settings
}

/// A page inside the play tab's stack (spec #64). The pages themselves arrive in later
/// tickets; the route already lives here so another tab can open one.
enum PlayRoute: Hashable {
    case gifts
    case achievements
    case calendar
    /// Her week's schedule, the page the chat's 「她的日程」 opens.
    case schedule(characterID: String?)
    case cycles
}
