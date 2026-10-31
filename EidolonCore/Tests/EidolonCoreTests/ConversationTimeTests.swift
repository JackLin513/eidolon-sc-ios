import Foundation
import XCTest
@testable import EidolonCore

/// How a conversation writes its days and moments (upstream `messageLines.ts`,
/// `ConversationList.tsx`): 今天 / 昨天 / `M月d日` / `yyyy/M/d`, and `H:mm`.
final class ConversationTimeTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        _ hour: Int = 12, _ minute: Int = 0, _ second: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year, month: month, day: day,
            hour: hour, minute: minute, second: second
        ))!
    }

    func testTodayAndYesterdayAreCalendarDays() {
        let now = date(2026, 10, 31, 0, 30)

        XCTAssertEqual(
            ConversationTime.day(of: date(2026, 10, 31, 0, 1), now: now, calendar: calendar),
            .today
        )
        XCTAssertEqual(
            ConversationTime.day(of: date(2026, 10, 30, 23, 59), now: now, calendar: calendar),
            .yesterday
        )
    }

    /// Anything older is split by year: this year writes month and day, an earlier one the
    /// whole date. A year boundary yesterday is still 昨天.
    func testOlderDaysAreSplitByYear() {
        let now = date(2026, 10, 31)

        XCTAssertEqual(
            ConversationTime.day(of: date(2026, 3, 2), now: now, calendar: calendar),
            .thisYear
        )
        XCTAssertEqual(
            ConversationTime.day(of: date(2025, 10, 30), now: now, calendar: calendar),
            .earlier
        )
        XCTAssertEqual(
            ConversationTime.day(of: date(2026, 1, 1, 9), now: date(2026, 1, 2, 9), calendar: calendar),
            .yesterday
        )
    }

    /// The day pill: 今天, 昨天, then `M月d日` without leading zeros, then the whole date.
    func testDayLabels() {
        let now = date(2026, 10, 31)

        XCTAssertEqual(
            ConversationTime.dayLabel(of: date(2026, 10, 31, 0, 1), now: now, calendar: calendar),
            "今天"
        )
        XCTAssertEqual(
            ConversationTime.dayLabel(of: date(2026, 10, 30, 23, 59), now: now, calendar: calendar),
            "昨天"
        )
        XCTAssertEqual(
            ConversationTime.dayLabel(of: date(2026, 8, 9, 8, 49), now: now, calendar: calendar),
            "8月9日"
        )
        XCTAssertEqual(
            ConversationTime.dayLabel(of: date(2024, 8, 9), now: now, calendar: calendar),
            "2024/8/9"
        )
        XCTAssertEqual(
            ConversationTime.dayLabel(of: date(2025, 12, 31, 23, 59), now: date(2026, 1, 2), calendar: calendar),
            "2025/12/31"
        )
        XCTAssertEqual(
            ConversationTime.dayLabel(of: date(2026, 10, 31, 0, 1), now: date(2026, 10, 31, 23, 59), calendar: calendar),
            "今天"
        )
    }

    /// A moment of the day: 24 hours, hour unpadded, minute padded.
    func testMomentsAreWrittenAsHoursAndMinutes() {
        XCTAssertEqual(ConversationTime.clock(of: date(2026, 10, 31, 8, 49), calendar: calendar), "8:49")
        XCTAssertEqual(ConversationTime.clock(of: date(2026, 10, 31, 0, 5), calendar: calendar), "0:05")
        XCTAssertEqual(ConversationTime.clock(of: date(2026, 10, 31, 23, 59), calendar: calendar), "23:59")
    }

    /// Two instants on the same calendar day — the rule a day pill is inserted by.
    func testSameDayIsByCalendarDay() {
        XCTAssertTrue(ConversationTime.isSameDay(
            date(2026, 10, 31, 0, 1), date(2026, 10, 31, 23, 59), calendar: calendar
        ))
        XCTAssertFalse(ConversationTime.isSameDay(
            date(2026, 10, 30, 23, 59), date(2026, 10, 31, 0, 1), calendar: calendar
        ))
    }

    /// The transcript's day pills: the first line always gets one, the lines after it only
    /// when the calendar day changes — including across a year boundary.
    func testDayPillsMarkTheFirstLineAndEachNewDay() {
        let now = date(2026, 1, 2, 12)
        let instants = [
            date(2025, 12, 31, 23, 59),
            date(2026, 1, 1, 0, 1),
            date(2026, 1, 1, 23, 59),
            date(2026, 1, 2, 0, 5),
        ]

        XCTAssertEqual(
            ConversationTime.dayPills(for: instants, now: now, calendar: calendar),
            ["2025/12/31", "昨天", nil, "今天"]
        )
        XCTAssertTrue(ConversationTime.dayPills(for: [], now: now, calendar: calendar).isEmpty)
    }

    /// The conversation list's recent-activity label: today's moment, 昨天, then month/day,
    /// then the whole date.
    func testListTime() {
        let now = date(2026, 10, 31)

        XCTAssertEqual(
            ConversationTime.listTime(of: date(2026, 10, 31, 8, 49), now: now, calendar: calendar),
            "8:49"
        )
        XCTAssertEqual(
            ConversationTime.listTime(of: date(2026, 10, 30, 23, 59), now: now, calendar: calendar),
            "昨天"
        )
        XCTAssertEqual(
            ConversationTime.listTime(of: date(2026, 8, 9), now: now, calendar: calendar),
            "8月9日"
        )
        XCTAssertEqual(
            ConversationTime.listTime(of: date(2024, 8, 9), now: now, calendar: calendar),
            "2024/8/9"
        )
        XCTAssertEqual(
            ConversationTime.listTime(
                of: date(2026, 10, 31, 0, 1),
                now: date(2026, 10, 31, 23, 59),
                calendar: calendar
            ),
            "0:01"
        )
        XCTAssertEqual(
            ConversationTime.listTime(
                of: date(2026, 10, 31, 23, 59),
                now: date(2026, 11, 1, 0, 1),
                calendar: calendar
            ),
            "昨天"
        )
    }
}
