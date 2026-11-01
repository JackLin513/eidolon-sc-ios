import Foundation
import XCTest
@testable import EidolonCore

/// The system-calendar export (spec #56): what should be there, and how a sync reconciles
/// it with what the calendar already holds.
final class CalendarExportTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let week = CalendarDay(year: 2026, month: 11, day: 2)

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func job(_ id: String, name: String, length: Int) -> WeeklyJob {
        WeeklyJob(
            id: "\(week.stamp):\(id)", week: week, characterID: "mano",
            listedID: id, name: name, note: "认真做。", category: .practice,
            length: length, slots: nil
        )
    }

    private func source() -> CalendarExportSource {
        let mano = job("vocal", name: "声乐课", length: 2)
        let placement = SchedulePlacement(
            week: week, jobID: mano.id, characterID: "mano", day: 1, slot: 1,
            savedAt: "2026-11-01T00:00:00.000000Z"
        )
        return CalendarExportSource(
            characters: [
                CalendarExportCharacter(
                    id: "mano", name: "櫻木真乃", birthday: Birthday(month: 2, day: 29)
                ),
                CalendarExportCharacter(
                    id: "hiori", name: "風野灯織", birthday: Birthday(month: 4, day: 25)
                ),
            ],
            producerBirthday: Birthday(month: 2, day: 11),
            jobs: [
                CalendarExportJob(job: mano, placement: placement, characterName: "櫻木真乃"),
            ],
            timeZone: tokyo
        )
    }

    private func components(_ date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        return calendar.dateComponents([.year, .month, .day, .hour], from: date)
    }

    // MARK: - What should be in the calendar

    func testBirthdaysAndSavedJobsBecomeEvents() throws {
        let events = CalendarExportBuilder.events(from: source())
        XCTAssertEqual(events.count, 4)

        let mano = try XCTUnwrap(events.first { $0.marker == "eidolon://export/birthday/character/mano" })
        XCTAssertEqual(mano.title, "櫻木真乃 生日")
        XCTAssertTrue(mano.isAllDay)
        XCTAssertTrue(mano.repeatsYearly)
        XCTAssertEqual(components(mano.start), DateComponents(year: 2024, month: 2, day: 29, hour: 0))
        XCTAssertEqual(components(mano.end), DateComponents(year: 2024, month: 3, day: 1, hour: 0))

        let producer = try XCTUnwrap(events.first { $0.marker == "eidolon://export/birthday/producer" })
        XCTAssertEqual(producer.title, "制作人的生日")
        XCTAssertTrue(producer.isAllDay)
        XCTAssertTrue(producer.repeatsYearly)

        let work = try XCTUnwrap(
            events.first { $0.marker == "eidolon://export/schedule/\(week.stamp):vocal" }
        )
        XCTAssertEqual(work.title, "櫻木真乃 · 声乐课")
        XCTAssertEqual(work.notes, "认真做。\n\n制作人排的工作")
        XCTAssertFalse(work.isAllDay)
        XCTAssertFalse(work.repeatsYearly)
        XCTAssertEqual(components(work.start), DateComponents(year: 2026, month: 11, day: 3, hour: 12))
        XCTAssertEqual(components(work.end), DateComponents(year: 2026, month: 11, day: 4, hour: 0))
    }

    // MARK: - Reconciling

    func testAnEmptyCalendarCreatesEveryEvent() {
        let expected = CalendarExportBuilder.events(from: source())
        let plan = CalendarExportPlanner.plan(expected: expected, existing: [])
        XCTAssertEqual(plan.creates, expected)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    func testUnchangedEventsAreLeftAlone() {
        let expected = CalendarExportBuilder.events(from: source())
        let existing = expected.enumerated().map {
            CalendarExportStoredEvent(id: "event-\($0.offset)", event: $0.element)
        }
        let plan = CalendarExportPlanner.plan(expected: expected, existing: existing)
        XCTAssertTrue(plan.creates.isEmpty)
        XCTAssertTrue(plan.updates.isEmpty)
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    func testChangedEventsAreUpdatedAndMissingOnesCreated() {
        var expected = CalendarExportBuilder.events(from: source())
        var existing = expected.map { CalendarExportStoredEvent(id: $0.marker, event: $0) }
        existing[0].event.title = "被改过的生日"
        expected[1].title = "新的标题"
        existing.remove(at: 1)

        let plan = CalendarExportPlanner.plan(expected: expected, existing: existing)
        XCTAssertEqual(plan.updates.map(\.id), [expected[0].marker])
        XCTAssertEqual(plan.creates.map(\.marker), [expected[1].marker])
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    func testOnlyMarkedEventsAreDeletedAndUnmarkedOnesAreLeftAlone() {
        let all = CalendarExportBuilder.events(from: source())
        let removed = try! XCTUnwrap(all.last)
        let expected = Array(all.dropLast())
        let stray = CalendarExportEvent(
            marker: "eidolon://export/schedule/gone", title: "没了", notes: "",
            start: date("2026-11-02T00:00:00Z"), end: date("2026-11-02T01:00:00Z"),
            isAllDay: false, repeatsYearly: false
        )
        let mine = CalendarExportEvent(
            marker: "", title: "我自己的事件", notes: "",
            start: date("2026-11-02T00:00:00Z"), end: date("2026-11-02T01:00:00Z"),
            isAllDay: false, repeatsYearly: false
        )
        let existing = expected.map { CalendarExportStoredEvent(id: $0.marker, event: $0) }
            + [CalendarExportStoredEvent(id: "stray", event: stray)]
            + [CalendarExportStoredEvent(id: "mine", event: mine)]
        let plan = CalendarExportPlanner.plan(expected: all, existing: existing)
        XCTAssertEqual(plan.deletes, ["stray"])
        XCTAssertEqual(plan.creates.map(\.marker), [removed.marker])
    }

    func testAllDayEventsCompareByMonthAndDayNotTheCalendarsNormalizedDates() {
        let expected = CalendarExportBuilder.events(from: source())
        let birthday = expected[0]
        var normalized = birthday
        normalized.start = normalized.start.addingTimeInterval(12 * 3600)
        normalized.end = normalized.start.addingTimeInterval(86_399)
        let existing = [CalendarExportStoredEvent(id: "birthday", event: normalized)]
        let plan = CalendarExportPlanner.plan(expected: [birthday], existing: existing)
        XCTAssertTrue(plan.updates.isEmpty)

        var moved = normalized
        moved.allDayKey = "03-01"
        let movedPlan = CalendarExportPlanner.plan(
            expected: [birthday],
            existing: [CalendarExportStoredEvent(id: "birthday", event: moved)]
        )
        XCTAssertEqual(movedPlan.updates.map(\.id), ["birthday"])
    }

    func testDuplicateMarkedEventsLeaveOnlyOne() {
        let expected = CalendarExportBuilder.events(from: source())
        let first = CalendarExportStoredEvent(id: "first", event: expected[0])
        let duplicate = CalendarExportStoredEvent(id: "duplicate", event: expected[0])
        let existing = [first, duplicate]
            + expected.dropFirst().map { CalendarExportStoredEvent(id: $0.marker, event: $0) }
        let plan = CalendarExportPlanner.plan(expected: expected, existing: existing)
        XCTAssertEqual(plan.deletes, ["duplicate"])
        XCTAssertTrue(plan.creates.isEmpty)
    }
}

/// A calendar in memory: what the synchronizer is tested against instead of EventKit.
private actor FakeCalendarStore: CalendarExportStore {
    private var events: [String: CalendarExportEvent] = [:]
    private var nextID = 1
    var failNextFetch = false
    var failNextCreate = false

    func storedEvents(for expected: [CalendarExportEvent]) async throws -> [CalendarExportStoredEvent] {
        if failNextFetch {
            failNextFetch = false
            throw FakeError.denied
        }
        return events.sorted { $0.key < $1.key }.map {
            CalendarExportStoredEvent(id: $0.key, event: $0.value)
        }
    }

    func create(_ event: CalendarExportEvent) async throws {
        if failNextCreate {
            failNextCreate = false
            throw FakeError.denied
        }
        let id = "event-\(nextID)"
        nextID += 1
        events[id] = event
    }

    func update(id: String, to event: CalendarExportEvent) async throws {
        events[id] = event
    }

    func delete(id: String) async throws {
        events[id] = nil
    }

    func addRogue(marker: String, title: String) {
        events["rogue"] = CalendarExportEvent(
            marker: marker, title: title, notes: "",
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600),
            isAllDay: false, repeatsYearly: false
        )
    }

    func addUnmarked() {
        events["mine"] = CalendarExportEvent(
            marker: "", title: "我自己的事件", notes: "",
            start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600),
            isAllDay: false, repeatsYearly: false
        )
    }

    func changeTitle(ofMarker marker: String) {
        for (id, event) in events where event.marker == marker {
            var changed = event
            changed.title = "被改过"
            events[id] = changed
        }
    }

    func remove(marker: String) {
        events = events.filter { $0.value.marker != marker }
    }

    func failNextFetchOnce() { failNextFetch = true }

    func failNextCreateOnce() { failNextCreate = true }

    func count() -> Int { events.count }

    func all() -> [CalendarExportEvent] { Array(events.values) }

    enum FakeError: Error { case denied }
}

extension CalendarExportTests {
    func testSynchronizerCreatesThenLeavesAnUnchangedCalendarAlone() async throws {
        let store = FakeCalendarStore()
        let expected = CalendarExportBuilder.events(from: source())
        let first = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
        XCTAssertEqual(first.creates.count, expected.count)
        var count = await store.count()
        XCTAssertEqual(count, expected.count)

        let second = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
        XCTAssertTrue(second.creates.isEmpty)
        XCTAssertTrue(second.updates.isEmpty)
        XCTAssertTrue(second.deletes.isEmpty)
        count = await store.count()
        XCTAssertEqual(count, expected.count)
    }

    func testSynchronizerRestoresChangedAndDeletedEventsAndDeletesStrays() async throws {
        let store = FakeCalendarStore()
        let expected = CalendarExportBuilder.events(from: source())
        _ = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
        await store.changeTitle(ofMarker: expected[0].marker)
        await store.remove(marker: expected[1].marker)
        await store.addRogue(marker: "eidolon://export/schedule/rogue", title: "多出来的")
        await store.addUnmarked()

        let plan = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
        XCTAssertEqual(plan.updates.count, 1)
        XCTAssertEqual(plan.creates.count, 1)
        XCTAssertEqual(plan.deletes.count, 1)
        let count = await store.count()
        let all = await store.all()
        XCTAssertEqual(count, expected.count + 1)
        XCTAssertTrue(all.contains { $0.title == "我自己的事件" })
        XCTAssertFalse(all.contains { $0.marker == "eidolon://export/schedule/rogue" })
    }

    func testAFailedWriteDoesNotDeleteExistingEvents() async throws {
        let store = FakeCalendarStore()
        let expected = CalendarExportBuilder.events(from: source())
        _ = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
        await store.addRogue(marker: "eidolon://export/schedule/rogue", title: "多出来的")
        await store.remove(marker: expected[0].marker)
        await store.failNextCreateOnce()
        do {
            _ = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
            XCTFail("a failed create did not throw")
        } catch {}
        let all = await store.all()
        XCTAssertTrue(all.contains { $0.marker == "eidolon://export/schedule/rogue" })
        XCTAssertEqual(all.count, expected.count)
    }

    func testAFailedFetchChangesNothing() async throws {
        let store = FakeCalendarStore()
        let expected = CalendarExportBuilder.events(from: source())
        _ = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
        await store.failNextFetchOnce()
        do {
            _ = try await CalendarExportSynchronizer.sync(expected: expected, store: store)
            XCTFail("a denied calendar did not throw")
        } catch {}
        let count = await store.count()
        XCTAssertEqual(count, expected.count)
    }
}
