import Foundation
import XCTest
@testable import EidolonCore

/// The estimate from the producer's records alone (spec #53), after LAPLACE Cycles.
final class CycleEstimateTests: XCTestCase {
    private let today = CalendarDay(year: 2026, month: 10, day: 25)

    private func logged(
        _ gaps: [Int], first: CalendarDay = CalendarDay(year: 2026, month: 1, day: 5), days: Int = 5
    ) -> [CycleRecord] {
        var records: [CycleRecord] = []
        var day = first
        records.append(record(day, days: days))
        for gap in gaps {
            day = day.adding(days: gap)
            records.append(record(day, days: days))
        }
        return records
    }

    private func record(_ day: CalendarDay, days: Int = 5) -> CycleRecord {
        CycleRecord(
            id: UUID().uuidString, characterID: "mano", firstDay: day, days: days,
            recordedAt: "2026-01-01T00:00:00.000000Z"
        )
    }

    private func endingBefore(
        _ records: [CycleRecord], today: CalendarDay? = nil
    ) -> [CycleRecord] {
        let target = today ?? self.today
        let last = records[records.count - 1].firstDay
        let shift = target.adding(days: -10).days(since: last)
        return records.map {
            record($0.firstDay.adding(days: shift), days: $0.days)
        }
    }

    func testWithoutRecordsThereIsNoEstimate() {
        XCTAssertNil(CycleEstimateRules.estimate(records: [], today: today))
    }

    func testFromOneRecordItIsTwentyEightAndFiveDaysRoughly() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: [record(CalendarDay(year: 2026, month: 10, day: 20), days: 4)],
            today: today
        ))
        XCTAssertEqual(found.cycle, 28)
        XCTAssertEqual(found.period, 5)
        XCTAssertEqual(found.reasons, [.once])
        XCTAssertEqual(found.periods[0], EstimatedPeriod(
            firstDay: CalendarDay(year: 2026, month: 11, day: 17), days: 5
        ))
        XCTAssertNil(found.offBy)
    }

    func testOneRecordLongerThanFiveDaysKeepsItsDays() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: [record(CalendarDay(year: 2026, month: 10, day: 20), days: 7)],
            today: today
        ))
        XCTAssertEqual(found.period, 7)
    }

    func testRegularRecordsTakeTheLatestEightGapsAndSixPeriodsMedian() throws {
        let gaps = [22, 22, 22, 30, 30, 30, 30, 31, 31, 31, 31]
        let days = [3, 3, 3, 3, 3, 3, 4, 6, 6, 5, 7, 6]
        let records = zip(endingBefore(logged(gaps)), days).map {
            record($0.0.firstDay, days: $0.1)
        }
        let found = try XCTUnwrap(CycleEstimateRules.estimate(records: records, today: today))
        XCTAssertEqual(found.cycle, 31)
        XCTAssertEqual(found.period, 6)
        XCTAssertEqual(found.reasons, [])
    }

    func testHowFarOffEachEndedCycleWas() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([30, 28, 32])), today: today
        ))
        XCTAssertEqual(found.offBy, 2.3)
    }

    func testHowFarOffNeedsTwoCompared() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([30])), today: today
        ))
        XCTAssertNil(found.offBy)
    }

    func testHowFarOffLeavesOutOutOfBoundsAndMissedGaps() throws {
        let beyond = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([30, 70, 29, 29])), today: today
        ))
        let missed = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([30, 50, 30])), today: today
        ))
        XCTAssertEqual(beyond.offBy, 1.3)
        XCTAssertEqual(missed.offBy, 1.0)
    }

    func testGapsOutOfBoundsAreSetAsideAsMissed() throws {
        let shorter = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([29, 10, 30])), today: today
        ))
        let longer = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([29, 65, 30])), today: today
        ))
        XCTAssertEqual(shorter.cycle, 30)
        XCTAssertEqual(shorter.reasons, [.missed])
        XCTAssertEqual(longer.cycle, 30)
        XCTAssertEqual(longer.reasons, [.missed])
    }

    func testAGapOnePointSixTimesTheShortestIsSetAside() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([28, 56, 29])), today: today
        ))
        XCTAssertEqual(found.cycle, 29)
        XCTAssertEqual(found.reasons, [.missed])
    }

    func testTheShortestGapIsTakenAsTwentyTwoAtLeast() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([16, 30, 31])), today: today
        ))
        XCTAssertEqual(found.cycle, 30)
        XCTAssertEqual(found.reasons, [.irregular])
    }

    func testOneOrTwoLongGapsAloneAreFoldedIntoTypicalCycles() throws {
        func cycle(_ gaps: [Int]) throws -> (Int, [CycleReason]) {
            let found = try XCTUnwrap(CycleEstimateRules.estimate(
                records: endingBefore(logged(gaps)), today: today
            ))
            return (found.cycle, found.reasons)
        }
        XCTAssertEqual(try cycle([56]).0, 28)
        XCTAssertEqual(try cycle([56]).1, [.missed])
        XCTAssertEqual(try cycle([50]).0, 25)
        XCTAssertEqual(try cycle([50]).1, [.missed])
        XCTAssertEqual(try cycle([50, 56]).0, 27)
        XCTAssertEqual(try cycle([50, 56]).1, [.missed])
    }

    func testEveryGapSetAsideIsTwentyEightAsMissed() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([84])), today: today
        ))
        XCTAssertEqual(found.cycle, 28)
        XCTAssertEqual(found.period, 5)
        XCTAssertEqual(found.reasons, [.missed])
    }

    func testFromAThirdLongGapHerCycleIsTakenToBeLong() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([50, 50, 50])), today: today
        ))
        XCTAssertEqual(found.cycle, 50)
        XCTAssertEqual(found.reasons, [])
    }

    func testGapsMoreThanSevenDaysApartAreIrregular() throws {
        let seven = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([26, 33])), today: today
        ))
        let eight = try XCTUnwrap(CycleEstimateRules.estimate(
            records: endingBefore(logged([26, 34])), today: today
        ))
        XCTAssertEqual(seven.reasons, [])
        XCTAssertEqual(eight.reasons, [.irregular])
    }

    func testPastTheNextFirstDayItMayNotBeWrittenDownAndStaysThere() throws {
        let only = record(CalendarDay(year: 2026, month: 9, day: 27))
        let onTheDay = try XCTUnwrap(CycleEstimateRules.estimate(
            records: [only], today: CalendarDay(year: 2026, month: 10, day: 25)
        ))
        let past = try XCTUnwrap(CycleEstimateRules.estimate(
            records: [only], today: CalendarDay(year: 2026, month: 10, day: 26)
        ))
        XCTAssertEqual(onTheDay.reasons, [.once])
        XCTAssertEqual(past.reasons, [.once, .late])
        XCTAssertEqual(past.periods[0], EstimatedPeriod(
            firstDay: CalendarDay(year: 2026, month: 10, day: 25), days: 5
        ))
    }

    func testThreePeriodsAreEstimatedACycleApart() throws {
        let found = try XCTUnwrap(CycleEstimateRules.estimate(
            records: logged([30], first: CalendarDay(year: 2026, month: 9, day: 1), days: 4),
            today: today
        ))
        XCTAssertEqual(found.periods, [
            EstimatedPeriod(firstDay: CalendarDay(year: 2026, month: 10, day: 31), days: 4),
            EstimatedPeriod(firstDay: CalendarDay(year: 2026, month: 11, day: 30), days: 4),
            EstimatedPeriod(firstDay: CalendarDay(year: 2026, month: 12, day: 30), days: 4),
        ])
    }

    func testWhereTodayIs() throws {
        let records = logged([30], first: CalendarDay(year: 2026, month: 9, day: 1), days: 4)
        func whereOn(_ day: CalendarDay) throws -> CycleToday? {
            try XCTUnwrap(CycleEstimateRules.estimate(records: records, today: day)).today
        }
        XCTAssertEqual(try whereOn(CalendarDay(year: 2026, month: 10, day: 3)), .recorded(day: 3))
        XCTAssertNil(try whereOn(CalendarDay(year: 2026, month: 10, day: 25)))
        XCTAssertEqual(try whereOn(CalendarDay(year: 2026, month: 10, day: 26)), .premenstrual)
        XCTAssertEqual(try whereOn(CalendarDay(year: 2026, month: 10, day: 30)), .premenstrual)
        XCTAssertEqual(try whereOn(CalendarDay(year: 2026, month: 11, day: 3)), .estimated)
        XCTAssertNil(try whereOn(CalendarDay(year: 2026, month: 11, day: 4)))
        XCTAssertEqual(try whereOn(CalendarDay(year: 2026, month: 11, day: 25)), .premenstrual)
    }
}
