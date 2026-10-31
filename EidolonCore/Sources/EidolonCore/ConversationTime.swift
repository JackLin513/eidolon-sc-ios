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
