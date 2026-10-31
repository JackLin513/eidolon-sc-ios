import Foundation
import XCTest
@testable import EidolonCore

/// The producer's records of her periods and the cycle page's marks (spec #53).
final class CycleRecordsTests: XCTestCase {
    private var root: URL!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-03T03:00:00Z")! // noon JST

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCycleRecords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installed() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    private func day(_ month: Int, _ day: Int, year: Int = 2026) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    func testRecordsAreAddedReadChangedAndDeleted() async throws {
        let eidolon = try await installed()
        let first = try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: day(10, 20), days: 5, now: now, timeZone: tokyo
        )
        XCTAssertEqual(first.days, 5)
        XCTAssertEqual(first.firstDay, day(10, 20))
        var records = try await eidolon.cycleRecords(characterID: "mano")
        XCTAssertEqual(records.map(\.firstDay), [day(10, 20)])

        let changed = try await eidolon.changeCycleRecord(
            id: first.id, firstDay: day(10, 18), days: 4,
            now: now.addingTimeInterval(60), timeZone: tokyo
        )
        XCTAssertEqual(changed.firstDay, day(10, 18))
        XCTAssertEqual(changed.days, 4)
        XCTAssertEqual(changed.recordedAt, first.recordedAt, "creation time is kept")
        XCTAssertNotEqual(changed.updatedAt, first.updatedAt)
        records = try await eidolon.cycleRecords(characterID: "mano")
        XCTAssertEqual(records.map(\.days), [4])

        try await eidolon.deleteCycleRecord(id: first.id)
        let empty = try await eidolon.cycleRecords(characterID: "mano")
        XCTAssertTrue(empty.isEmpty)
    }

    func testRecordsRefuseFutureOutOfBoundsAndOverlap() async throws {
        let eidolon = try await installed()
        let first = try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: day(10, 20), days: 5, now: now, timeZone: tokyo
        )

        do {
            _ = try await eidolon.addCycleRecord(
                characterID: "mano", firstDay: day(11, 4), days: 5,
                now: now, timeZone: tokyo
            )
            XCTFail("future")
        } catch {
            XCTAssertEqual(error as? CycleRecordError, .future)
        }
        for days in [2, 9] {
            do {
                _ = try await eidolon.addCycleRecord(
                    characterID: "mano", firstDay: day(9, 1), days: days,
                    now: now, timeZone: tokyo
                )
                XCTFail("days")
            } catch {
                XCTAssertEqual(error as? CycleRecordError, .days)
            }
        }
        do {
            _ = try await eidolon.addCycleRecord(
                characterID: "mano", firstDay: day(10, 24), days: 3,
                now: now, timeZone: tokyo
            )
            XCTFail("overlap")
        } catch {
            XCTAssertEqual(error as? CycleRecordError, .overlap(day(10, 20)))
        }
        // The day after one ends does not overlap.
        let next = try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: day(10, 25), days: 3, now: now, timeZone: tokyo
        )
        XCTAssertEqual(next.firstDay, day(10, 25))
        // Changing a record does not count as overlapping itself.
        _ = try await eidolon.changeCycleRecord(
            id: first.id, firstDay: day(10, 19), days: 5, now: now, timeZone: tokyo
        )
    }

    func testRecordsAreForEachCharacterAloneAndNeedACharacter() async throws {
        let eidolon = try await installed()
        _ = try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: day(10, 20), days: 5, now: now, timeZone: tokyo
        )
        let hiori = try await eidolon.cycleRecords(characterID: "hiori")
        XCTAssertTrue(hiori.isEmpty)
        do {
            _ = try await eidolon.addCycleRecord(
                characterID: "nobody", firstDay: day(10, 20), days: 5,
                now: now, timeZone: tokyo
            )
            XCTFail("character")
        } catch {
            XCTAssertEqual(error as? CycleRecordError, .noSuchCharacter)
        }
    }

    func testTheEstimateIsWorkedOutFromTheRecords() async throws {
        let eidolon = try await installed()
        _ = try await eidolon.addCycleRecord(
            characterID: "mano", firstDay: day(9, 27), days: 5, now: now, timeZone: tokyo
        )
        let estimate = try await eidolon.cycleEstimate(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertEqual(estimate?.cycle, 28)
        XCTAssertEqual(estimate?.period, 5)
        XCTAssertEqual(estimate?.reasons, [.once, .late])
    }

    func testMonthMarksShowRecordsEstimatedPeriodsAndPremenstrualDays() {
        let month = CalendarPage.Month(year: 2026, month: 11, timeZone: tokyo)
        let record = CycleRecord(
            id: "a", characterID: "mano", firstDay: day(10, 30), days: 4,
            recordedAt: "2026-10-30T00:00:00.000000Z"
        )
        let estimate = CycleEstimate(
            cycle: 28, period: 5, reasons: [], periods: [
                EstimatedPeriod(firstDay: day(11, 27), days: 5),
            ], offBy: nil, today: nil
        )
        let marks = CycleCalendar.marks(in: month, records: [record], estimate: estimate)
        XCTAssertNil(marks[day(10, 30)], "October is another month")
        let october = CalendarPage.Month(year: 2026, month: 10, timeZone: tokyo)
        let octoberMarks = CycleCalendar.marks(in: october, records: [record], estimate: estimate)
        XCTAssertEqual(octoberMarks[day(10, 30)], [.recorded])
        XCTAssertEqual(octoberMarks[day(10, 31)], [.recorded])
        XCTAssertNil(octoberMarks[day(11, 1)], "the record ended on October 31")
        XCTAssertEqual(marks[day(11, 22)], [.premenstrual])
        XCTAssertEqual(marks[day(11, 26)], [.premenstrual])
        XCTAssertEqual(marks[day(11, 27)], [.period])
        XCTAssertEqual(marks[day(12, 1)], nil, "outside the month")
        // December is still within the estimate; after its last period it is not.
        let november = CalendarPage.Month(year: 2026, month: 11, timeZone: tokyo)
        XCTAssertTrue(CycleCalendar.canShowNext(after: november, estimate: estimate))
        let december = CalendarPage.Month(year: 2026, month: 12, timeZone: tokyo)
        XCTAssertFalse(CycleCalendar.canShowNext(after: december, estimate: estimate))
        XCTAssertFalse(CycleCalendar.canShowNext(after: november, estimate: nil))
    }

    func testMarksCrossMonthAndYearAndLeapDay() {
        let february = CalendarPage.Month(year: 2028, month: 2, timeZone: tokyo)
        let record = CycleRecord(
            id: "a", characterID: "mano", firstDay: day(2, 27, year: 2028), days: 4,
            recordedAt: "2028-02-27T00:00:00.000000Z"
        )
        let marks = CycleCalendar.marks(in: february, records: [record], estimate: nil)
        XCTAssertEqual(marks[day(2, 27, year: 2028)], [.recorded])
        XCTAssertEqual(marks[day(2, 29, year: 2028)], [.recorded])
        XCTAssertNil(marks[day(3, 1, year: 2028)], "March is another month")
        let march = CalendarPage.Month(year: 2028, month: 3, timeZone: tokyo)
        let marchMarks = CycleCalendar.marks(in: march, records: [record], estimate: nil)
        XCTAssertEqual(marchMarks[day(3, 1, year: 2028)], [.recorded])
        XCTAssertNil(marchMarks[day(3, 2, year: 2028)])
    }
}
