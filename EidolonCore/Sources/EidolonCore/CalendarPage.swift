import Foundation

/// A day as the calendar page writes it: the producer's calendar date, no time zone.
public struct CalendarDay: Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (left: CalendarDay, right: CalendarDay) -> Bool {
        (left.year, left.month, left.day) < (right.year, right.month, right.day)
    }

    public var stamp: String { String(format: "%04d-%02d-%02d", year, month, day) }
}

/// What a calendar day can hold (spec #49): her birthday, the producer's birthday, a Japanese
/// holiday. Schedule joins it when its UI lands.
public enum CalendarKind: String, CaseIterable, Sendable, Hashable {
    case character
    case producer
    case holiday
}

public struct CalendarEvent: Sendable, Hashable, Identifiable {
    public var id: String
    public var day: CalendarDay
    public var kind: CalendarKind
    /// The role's name, the holiday's name, or 「制作人的生日」.
    public var title: String
    public var detail: String?
    /// Her colour, for her birthday's mark.
    public var color: String?

    public init(
        id: String,
        day: CalendarDay,
        kind: CalendarKind,
        title: String,
        detail: String? = nil,
        color: String? = nil
    ) {
        self.id = id
        self.day = day
        self.kind = kind
        self.title = title
        self.detail = detail
        self.color = color
    }
}

/// The calendar page's pure model (spec #49): a month's cells and the events on its days.
/// It never reckons a date itself: the time zone, birthdays and holiday table come in.
public enum CalendarPage {
    public struct Month: Hashable, Sendable {
        public var year: Int
        public var month: Int
        /// Seven columns, Sunday first; nil for the blanks before and after the month.
        public var cells: [CalendarDay?]

        public init(year: Int, month: Int, timeZone: TimeZone) {
            self.year = year
            self.month = month
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let first = calendar.date(from: DateComponents(year: year, month: month, day: 1))!
            let weekday = calendar.component(.weekday, from: first) // 1 = Sunday
            let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
            var cells: [CalendarDay?] = Array(repeating: nil, count: weekday - 1)
            for day in 1...days {
                cells.append(CalendarDay(year: year, month: month, day: day))
            }
            while cells.count % 7 != 0 { cells.append(nil) }
            self.cells = cells
        }

        public var days: [CalendarDay] { cells.compactMap { $0 } }

        public func previous() -> Month {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            var year = self.year
            var month = self.month - 1
            if month < 1 { month = 12; year -= 1 }
            return Month(year: year, month: month, timeZone: calendar.timeZone)
        }

        public func next() -> Month {
            var year = self.year
            var month = self.month + 1
            if month > 12 { month = 1; year += 1 }
            return Month(year: year, month: month, timeZone: TimeZone(secondsFromGMT: 0)!)
        }
    }

    /// The day it is for the producer, whose calendar the page shows.
    public static func today(now: Date, timeZone: TimeZone) -> CalendarDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return CalendarDay(
            year: parts.year ?? 0,
            month: parts.month ?? 1,
            day: parts.day ?? 1
        )
    }

    /// The events in `month`: her birthdays in the order the characters come, then the
    /// producer's, then the holiday on each day. A February 29 birthday falls on February 28
    /// in a year without one, as `TodayPrompt` has it.
    public static func events(
        in month: Month,
        characters: [CharacterConfig],
        producerBirthday: (month: Int, day: Int)?,
        holidays: HolidayTable?
    ) -> [CalendarEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1))!
        let isLeap = calendar.range(of: .day, in: .year, for: first).map { $0.count > 365 } ?? false

        var events: [CalendarEvent] = []
        for day in month.days {
            for character in characters {
                guard let birthday = character.birthday,
                      birthday.month == day.month,
                      birthday.day == day.day || (birthday.month == 2 && birthday.day == 29
                          && day.month == 2 && day.day == 28 && !isLeap)
                else { continue }
                events.append(CalendarEvent(
                    id: "character:\(character.id):\(day.stamp)",
                    day: day,
                    kind: .character,
                    title: character.name,
                    color: character.color
                ))
            }
            if let producerBirthday,
               producerBirthday.month == day.month,
               producerBirthday.day == day.day
                   || (producerBirthday.month == 2 && producerBirthday.day == 29
                       && day.month == 2 && day.day == 28 && !isLeap) {
                events.append(CalendarEvent(
                    id: "producer:\(day.stamp)",
                    day: day,
                    kind: .producer,
                    title: "制作人的生日"
                ))
            }
            if let name = holidays?.name(year: day.year, month: day.month, day: day.day) {
                events.append(CalendarEvent(
                    id: "holiday:\(day.stamp):\(name)",
                    day: day,
                    kind: .holiday,
                    title: name
                ))
            }
        }
        return events
    }
}
