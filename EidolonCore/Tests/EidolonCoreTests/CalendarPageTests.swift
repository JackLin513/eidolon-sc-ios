import XCTest
@testable import EidolonCore

/// The calendar page's months and events (spec #49).
final class CalendarPageTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func character(_ id: String, _ name: String, _ birthday: String, color: String? = nil) -> CharacterConfig {
        CharacterConfig(id: id, name: name, color: color, birthday: Birthday(birthday))
    }

    func testAMonthStartsWithTheWeekdayAndHoldsEveryDay() {
        let february = CalendarPage.Month(year: 2026, month: 2, timeZone: tokyo)
        XCTAssertEqual(february.days.count, 28)
        XCTAssertEqual(february.cells.count % 7, 0)
        // 2026-02-01 is a Sunday: no blanks before it.
        XCTAssertEqual(february.cells.first, CalendarDay(year: 2026, month: 2, day: 1))
        let march = CalendarPage.Month(year: 2026, month: 3, timeZone: tokyo)
        XCTAssertEqual(march.days.count, 31)
        XCTAssertEqual(march.cells.first, CalendarDay(year: 2026, month: 3, day: 1))
    }

    func testLeapFebruaryHasTwentyNineDays() {
        XCTAssertEqual(CalendarPage.Month(year: 2024, month: 2, timeZone: tokyo).days.count, 29)
        XCTAssertEqual(CalendarPage.Month(year: 2023, month: 2, timeZone: tokyo).days.count, 28)
    }

    func testMonthsGoAcrossTheYear() {
        let december = CalendarPage.Month(year: 2026, month: 12, timeZone: tokyo)
        XCTAssertEqual(december.next().year, 2027)
        XCTAssertEqual(december.next().month, 1)
        let january = CalendarPage.Month(year: 2026, month: 1, timeZone: tokyo)
        XCTAssertEqual(january.previous().year, 2025)
        XCTAssertEqual(january.previous().month, 12)
    }

    func testHerBirthdayTheProducersAndAHolidayAreEventsOnTheirDays() throws {
        let holidays = HolidayTable(names: ["2026-02-11": "建国記念の日"])
        let month = CalendarPage.Month(year: 2026, month: 2, timeZone: tokyo)
        let events = CalendarPage.events(
            in: month,
            characters: [character("mano", "樱木真乃", "02-11", color: "#f00")],
            producerBirthday: (2, 11),
            holidays: holidays
        )
        XCTAssertEqual(events.map(\.kind), [.character, .producer, .holiday])
        XCTAssertEqual(events.map(\.title), ["樱木真乃", "制作人的生日", "建国記念の日"])
        XCTAssertTrue(events.allSatisfy { $0.day == CalendarDay(year: 2026, month: 2, day: 11) })
        XCTAssertEqual(events.first?.color, "#f00")
    }

    func testFebruaryTwentyNineFallsOnTheTwentyEighthWithoutOne() {
        let character = character("leap", "闰日", "02-29")
        let leap = CalendarPage.Month(year: 2024, month: 2, timeZone: tokyo)
        let ordinary = CalendarPage.Month(year: 2026, month: 2, timeZone: tokyo)
        let leapEvent = CalendarPage.events(
            in: leap, characters: [character], producerBirthday: (2, 29), holidays: nil
        )
        XCTAssertEqual(leapEvent.map(\.day.day), [29, 29])
        let ordinaryEvent = CalendarPage.events(
            in: ordinary, characters: [character], producerBirthday: (2, 29), holidays: nil
        )
        XCTAssertEqual(ordinaryEvent.map(\.day.day), [28, 28])
        XCTAssertEqual(ordinaryEvent.map(\.kind), [.character, .producer])
    }

    func testAMonthWithNothingIsEmpty() {
        let month = CalendarPage.Month(year: 2026, month: 7, timeZone: tokyo)
        XCTAssertTrue(CalendarPage.events(
            in: month,
            characters: [character("mano", "樱木真乃", "04-25")],
            producerBirthday: nil,
            holidays: HolidayTable(names: [:])
        ).isEmpty)
    }

    func testTodayIsTheProducersCalendarDay() {
        // 2026-02-11 23:30 UTC is already February 12 in Tokyo.
        let now = Date(timeIntervalSince1970: 1_770_852_600)
        XCTAssertEqual(
            CalendarPage.today(now: now, timeZone: tokyo),
            CalendarDay(year: 2026, month: 2, day: 12)
        )
        XCTAssertEqual(
            CalendarPage.today(now: now, timeZone: TimeZone(secondsFromGMT: 0)!),
            CalendarDay(year: 2026, month: 2, day: 11)
        )
    }
}
