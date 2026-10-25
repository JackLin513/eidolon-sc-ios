import Foundation

/// Japan's holidays as the content bundle's `content/holidays.json` lists them: a Tokyo
/// date (`"YYYY-MM-DD"`) mapped to its Japanese name, exported by the same `holidays`
/// library upstream uses. The app only looks days up; it never reckons the calendar.
public struct HolidayTable: Sendable, Hashable {
    public let names: [String: String]

    public init(names: [String: String]) {
        self.names = names
    }

    public init(data: Data) throws {
        names = try JSONDecoder().decode([String: String].self, from: data)
    }

    public func name(year: Int, month: Int, day: Int) -> String? {
        names[String(format: "%04d-%02d-%02d", year, month, day)]
    }

    /// The name of the holiday `day` is in `timeZone`, if it is one.
    public func name(on day: Date, in timeZone: TimeZone) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day
        else { return nil }
        return name(year: year, month: month, day: dayOfMonth)
    }
}
