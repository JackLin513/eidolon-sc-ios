import Foundation

/// What a cycle-page day can be marked with (spec #53).
public enum CycleMarkKind: Sendable, Hashable, CaseIterable {
    case period
    case premenstrual
    case recorded
}

/// The cycle page's month marks, worked out from the producer's records and the estimate;
/// her true cycle is not read.
public enum CycleCalendar {
    /// The marks of each day of `month`, only for days in it.
    public static func marks(
        in month: CalendarPage.Month, records: [CycleRecord], estimate: CycleEstimate?
    ) -> [CalendarDay: Set<CycleMarkKind>] {
        var marks: [CalendarDay: Set<CycleMarkKind>] = [:]
        for record in records {
            for offset in 0..<record.days {
                add(.recorded, to: record.firstDay.adding(days: offset), in: month, marks: &marks)
            }
        }
        for period in estimate?.periods ?? [] {
            for offset in 0..<period.days {
                add(.period, to: period.firstDay.adding(days: offset), in: month, marks: &marks)
            }
            for offset in 1...CycleEstimateRules.premenstrual {
                add(
                    .premenstrual, to: period.firstDay.adding(days: -offset),
                    in: month, marks: &marks
                )
            }
        }
        return marks
    }

    /// Whether `month` is the last month the estimate reaches or before it.
    public static func canShowNext(
        after month: CalendarPage.Month, estimate: CycleEstimate?
    ) -> Bool {
        guard let estimate, let last = estimate.periods.last else { return false }
        let lastDay = last.firstDay.adding(days: last.days - 1)
        let this = (month.year, month.month)
        let end = (lastDay.year, lastDay.month)
        return this < end
    }

    private static func add(
        _ kind: CycleMarkKind, to day: CalendarDay, in month: CalendarPage.Month,
        marks: inout [CalendarDay: Set<CycleMarkKind>]
    ) {
        guard day.year == month.year, day.month == month.month else { return }
        marks[day, default: []].insert(kind)
    }
}
