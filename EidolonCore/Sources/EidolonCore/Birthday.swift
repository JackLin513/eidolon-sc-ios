import Foundation

/// A birthday as the content bundle carries it: month and day in upstream's `"MM-DD"`
/// form. February 29 counts as a day of the year, so it is kept as written.
public struct Birthday: Sendable, Hashable {
    public var month: Int
    public var day: Int

    public init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }

    /// Reads `"MM-DD"`; nil unless it is a day some year has.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0].count == 2,
              parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let month = Int(parts[0]),
              let day = Int(parts[1]),
              (1...12).contains(month),
              (1...Birthday.daysInMonth[month - 1]).contains(day)
        else { return nil }
        self.init(month: month, day: day)
    }

    public var text: String {
        String(format: "%02d-%02d", month, day)
    }

    /// The days each month has in a year that has February 29, as upstream reckons them.
    private static let daysInMonth = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
}
