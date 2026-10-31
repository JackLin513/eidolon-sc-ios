import Foundation

/// How a conversation writes its days and moments (upstream `messageLines.ts`,
/// `ConversationList.tsx`).
public enum ConversationTime {
    /// Which day an instant belongs to, seen from now.
    public enum Day: Equatable {
        case today
        case yesterday
        case thisYear
        case earlier
    }

    /// 今天 / 昨天 by calendar day — not by a 24-hour distance.
    public static func day(
        of instant: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> Day {
        let day = calendar.startOfDay(for: instant)
        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return .earlier
        }
        if day >= today { return .today }
        if day == yesterday { return .yesterday }
        let year = calendar.component(.year, from: instant)
        let thisYear = calendar.component(.year, from: now)
        return year == thisYear ? .thisYear : .earlier
    }

    /// The pill a day gets in the transcript: 今天, 昨天, `M月d日`, `yyyy/M/d`.
    public static func dayLabel(
        of instant: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        switch day(of: instant, now: now, calendar: calendar) {
        case .today:
            return "今天"
        case .yesterday:
            return "昨天"
        case .thisYear:
            let month = calendar.component(.month, from: instant)
            let day = calendar.component(.day, from: instant)
            return "\(month)月\(day)日"
        case .earlier:
            let year = calendar.component(.year, from: instant)
            let month = calendar.component(.month, from: instant)
            let day = calendar.component(.day, from: instant)
            return "\(year)/\(month)/\(day)"
        }
    }

    /// The moment beside a message: `H:mm`, 24 hours.
    public static func clock(of instant: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: instant)
        let minute = calendar.component(.minute, from: instant)
        return "\(hour):" + String(format: "%02d", minute)
    }

    /// Whether two instants fall on the same calendar day.
    public static func isSameDay(
        _ first: Date,
        _ second: Date,
        calendar: Calendar = .current
    ) -> Bool {
        calendar.isDate(first, inSameDayAs: second)
    }

    /// The day pill for each line of a conversation, in order: the first line always gets
    /// one, and after that only a change of calendar day does.
    public static func dayPills(
        for instants: [Date],
        now: Date,
        calendar: Calendar = .current
    ) -> [String?] {
        var previous: Date?
        return instants.map { instant in
            defer { previous = instant }
            guard let last = previous, isSameDay(last, instant, calendar: calendar) else {
                return dayLabel(of: instant, now: now, calendar: calendar)
            }
            return nil
        }
    }

    /// How the conversation list writes the last time it heard from someone: today's moment,
    /// then 昨天, then the same labels a day pill uses.
    public static func listTime(
        of instant: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        switch day(of: instant, now: now, calendar: calendar) {
        case .today:
            return clock(of: instant, calendar: calendar)
        case .yesterday:
            return "昨天"
        case .thisYear, .earlier:
            return dayLabel(of: instant, now: now, calendar: calendar)
        }
    }
}

public enum ConversationTranscript {
    /// One line of the transcript, in the database's order.
    public struct Row: Sendable, Hashable, Identifiable {
        public var line: ConversationLine
        /// The day pill to draw above this line; nil while the pill above is still up.
        public var day: String?
        /// The line's moment, `H:mm`.
        public var clock: String
        /// This line opens its bubble group: it gets her avatar and name.
        public var first: Bool
        /// This line closes its bubble group: the time goes beside it.
        public var last: Bool
        /// The affinity change to show under this line, if it made one (spec #38).
        public var cue: AffinityChange?

        public var id: String { line.id }
    }

    public static func rows(
        of record: [ConversationLine],
        now: Date,
        calendar: Calendar = .current,
        splitsAfter: (ConversationLine) -> Bool = { _ in false }
    ) -> [Row] {
        let instants = record.map { Eidolon.parseTimestamp($0.createdAt) ?? now }
        let days = ConversationTime.dayPills(for: instants, now: now, calendar: calendar)
        return record.indices.map { index in
            let line = record[index]
            let first = index == 0 || breaks(
                between: record[index - 1], and: line, at: index,
                instants: instants, calendar: calendar, splitsAfter: splitsAfter
            )
            let last = index == record.count - 1 || breaks(
                between: line, and: record[index + 1], at: index + 1,
                instants: instants, calendar: calendar, splitsAfter: splitsAfter
            )
            let cue: AffinityChange?
            if case let .message(message) = line {
                cue = message.affinityChange
            } else {
                cue = nil
            }
            return Row(
                line: line,
                day: days[index],
                clock: ConversationTime.clock(of: instants[index], calendar: calendar),
                first: first,
                last: last,
                cue: cue
            )
        }
    }

    /// Whether the boundary that starts the line at `index` is a group break. The first and
    /// last of a group are the same boundary seen from either side.
    private static func breaks(
        between previous: ConversationLine,
        and next: ConversationLine,
        at index: Int,
        instants: [Date],
        calendar: Calendar,
        splitsAfter: (ConversationLine) -> Bool
    ) -> Bool {
        // An event is not a person: it is never in a group, and splits both sides.
        if case .event = previous { return true }
        if case .event = next { return true }
        return !ConversationTime.isSameDay(instants[index - 1], instants[index], calendar: calendar)
            || side(of: previous) != side(of: next)
            || splitsAfter(previous)
            || reachesOut(next)
    }

    private enum Side {
        case her
        case producer
    }

    /// Who a line is from. Reach-outs are hers.
    private static func side(of line: ConversationLine) -> Side? {
        switch line {
        case let .message(message): message.role == "user" ? .producer : .her
        case .event: nil
        }
    }

    private static func reachesOut(_ line: ConversationLine) -> Bool {
        guard case let .message(message) = line else { return false }
        return message.isReachOut
    }
}
