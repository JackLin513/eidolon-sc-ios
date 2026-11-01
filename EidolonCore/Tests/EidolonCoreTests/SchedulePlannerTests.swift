import Foundation
import XCTest
@testable import EidolonCore

/// The week's board as the page changes it (spec #51): cells, cards, drafts and refusals.
final class SchedulePlannerTests: XCTestCase {
    private let week = CalendarDay(year: 2026, month: 11, day: 2)
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let now = ISO8601DateFormatter().date(from: "2026-11-02T00:00:00Z")! // 09:00 JST

    private func job(
        _ id: String, name: String = "工作", length: Int = 1, slots: [ScheduleSlot]? = nil,
        week: CalendarDay? = nil
    ) -> WeeklyJob {
        let week = week ?? self.week
        return WeeklyJob(
            id: "\(week.stamp):\(id)", week: week, characterID: "mano", listedID: id,
            name: name, note: "说明。", category: .practice, length: length, slots: slots
        )
    }

    private func planner(
        jobs: [WeeklyJob], placements: [SchedulePlacement] = [],
        drafts: [PlacementInput] = [], selected: String? = nil,
        reasons: [String: String] = [:], boardWeek: CalendarDay? = nil,
        now: Date? = nil
    ) -> SchedulePlanner {
        let board = ScheduleBoard(
            week: boardWeek ?? week, isCurrent: true, jobs: jobs, placements: placements
        )
        return SchedulePlanner(
            board: board, now: now ?? self.now, timeZone: tokyo, thisWeek: week,
            drafts: drafts, selectedJobID: selected, reasons: reasons
        )
    }

    private func placement(
        _ job: WeeklyJob, day: Int, slot: Int, week: CalendarDay? = nil
    ) -> SchedulePlacement {
        SchedulePlacement(
            week: week ?? self.week, jobID: job.id, characterID: "mano", day: day, slot: slot,
            savedAt: "2026-11-01T00:00:00.000000Z"
        )
    }

    // MARK: - Cells

    func testCellsArePastNowOrToComeAndSavedOnesStay() {
        let saved = job("saved", name: "已排")
        let plan = planner(jobs: [saved], placements: [placement(saved, day: 0, slot: 0)])
        XCTAssertEqual(
            plan.cell(day: 0, slot: 0).state,
            .saved(day: 0, slot: 0, job: saved)
        )
        XCTAssertEqual(plan.cell(day: 0, slot: 1).state, .empty)
        XCTAssertEqual(plan.cell(day: 1, slot: 0).state, .empty)
        let empty = planner(jobs: [])
        XCTAssertEqual(empty.cell(day: 0, slot: 0).state, .now)
        XCTAssertEqual(empty.cell(day: 0, slot: 1).state, .empty)
    }

    func testTheSelectedJobMarksTheCellsItCannotStartIn() {
        let long = job("long", length: 2)
        let plan = planner(jobs: [long], selected: long.id)
        // The morning is under way; the afternoon takes both it and the evening, but a
        // two-slot job starting in the evening would pass midnight.
        XCTAssertEqual(plan.cell(day: 0, slot: 1).state, .empty)
        XCTAssertEqual(plan.cell(day: 0, slot: 2).state, .cannot)
        XCTAssertEqual(plan.cell(day: 1, slot: 0).state, .empty)
        XCTAssertEqual(plan.cell(day: 1, slot: 1).state, .empty)
        let available = plan.availableCells().map { [$0.day, $0.slot] }
        XCTAssertEqual(available.count, 13)
        XCTAssertEqual(available.first, [0, 1])
        XCTAssertFalse(available.contains([0, 2]))
    }

    func testAJobInItsSlotsOnly() {
        let morning = job("morning", slots: [.morning])
        let plan = planner(jobs: [morning], selected: morning.id)
        XCTAssertEqual(plan.cell(day: 1, slot: 1).state, .cannot)
        XCTAssertEqual(plan.cell(day: 1, slot: 0).state, .empty)
    }

    // MARK: - Pending and free cells (spec #59)

    func testFreeCellCountCountsFutureCellsWithoutAnOccupant() {
        let plan = planner(jobs: [])
        // Monday morning is under way at 09:00 JST; the other twenty cells are to come.
        XCTAssertEqual(plan.freeCellCount, 20)

        let saved = job("saved", length: 2)
        let withSaved = planner(jobs: [saved], placements: [placement(saved, day: 1, slot: 0)])
        XCTAssertEqual(withSaved.freeCellCount, 18)
    }

    func testFreeCellCountFollowsDraftsAndDoesNotFollowTheSelectedCard() {
        let first = job("a", length: 2)
        let second = job("b")
        var plan = planner(jobs: [first, second])
        plan.select(first.id)
        XCTAssertEqual(plan.freeCellCount, 20, "selecting a card does not take a cell")
        XCTAssertTrue(plan.tap(day: 1, slot: 0))
        XCTAssertEqual(plan.freeCellCount, 18, "a two-slot draft takes two cells")
        plan.removeDraft(jobID: first.id)
        XCTAssertEqual(plan.freeCellCount, 20)
    }

    func testAJobWithNoRoomAnywhereStaysPending() {
        let next = week.adding(days: 7)
        let extra = job("extra", week: next)
        let fills = (0..<7).map { day in
            job("fill\(day)", length: 3, week: next)
        }
        let plan = planner(
            jobs: [extra] + fills,
            placements: fills.enumerated().map { index, job in
                placement(job, day: index, slot: 0, week: next)
            },
            selected: extra.id,
            boardWeek: next
        )
        XCTAssertEqual(plan.freeCellCount, 0)
        XCTAssertEqual(plan.pendingCount, 1)
        XCTAssertTrue(plan.availableCells().isEmpty)
    }

    func testPendingExpiresTonightOnlyOnThisLocalSunday() {
        let sunday = ISO8601DateFormatter().date(from: "2026-11-08T00:00:00Z")! // 09:00 JST
        XCTAssertTrue(planner(jobs: [], now: sunday).pendingExpiresTonight)
        XCTAssertFalse(planner(jobs: []).pendingExpiresTonight)
        XCTAssertFalse(
            planner(jobs: [], boardWeek: week.adding(days: 7), now: sunday)
                .pendingExpiresTonight
        )
    }

    // MARK: - Drafts

    func testTapPlacesTheSelectedCardAndTappingTheDraftTakesItBack() {
        var plan = planner(jobs: [job("a")])
        plan.select(plan.board.jobs[0].id)
        XCTAssertTrue(plan.tap(day: 1, slot: 0))
        XCTAssertEqual(plan.drafts, [PlacementInput(jobID: plan.board.jobs[0].id, day: 1, slot: 0)])
        XCTAssertEqual(
            plan.cell(day: 1, slot: 0).state,
            .draft(day: 1, slot: 0, job: plan.board.jobs[0])
        )
        XCTAssertNil(plan.selectedJobID)
        XCTAssertTrue(plan.tap(day: 1, slot: 0))
        XCTAssertTrue(plan.drafts.isEmpty)
    }

    func testADraftCannotOverlapAnother() {
        let first = job("a")
        let second = job("b", length: 2)
        var plan = planner(jobs: [first, second])
        plan.select(first.id)
        XCTAssertTrue(plan.tap(day: 1, slot: 1))
        plan.select(second.id)
        XCTAssertFalse(plan.tap(day: 1, slot: 0))
        XCTAssertEqual(plan.drafts.count, 1)
    }

    func testASavedJobCannotBeMovedAndIsNotPending() {
        let saved = job("a", name: "已排")
        var plan = planner(jobs: [saved], placements: [placement(saved, day: 1, slot: 0)])
        XCTAssertFalse(plan.tap(day: 1, slot: 0))
        XCTAssertTrue(plan.drafts.isEmpty)
        XCTAssertEqual(plan.pendingCount, 0)
        XCTAssertEqual(plan.cards.first?.placement, .saved(day: 1, slot: 0))
    }

    func testPendingCountFallsAsCardsAreDrafted() {
        let plan = planner(jobs: [job("a"), job("b")])
        XCTAssertEqual(plan.pendingCount, 2)
        var withDraft = plan
        withDraft.select(withDraft.board.jobs[0].id)
        withDraft.tap(day: 1, slot: 0)
        XCTAssertEqual(withDraft.pendingCount, 1)
    }

    // MARK: - Saving

    func testARefusedDraftStaysWithItsReasonAndSavedOnesLeave() {
        let a = job("a")
        let b = job("b")
        let inputs = [
            PlacementInput(jobID: a.id, day: 1, slot: 0),
            PlacementInput(jobID: b.id, day: 2, slot: 0),
        ]
        var plan = planner(jobs: [a, b], drafts: inputs)
        XCTAssertEqual(plan.drafts.count, 2)

        plan.apply(ScheduleSave(
            saved: [inputs[0]],
            refused: [RefusedPlacement(input: inputs[1], reason: "格子里有别的工作")]
        ))
        XCTAssertEqual(plan.drafts, [inputs[1]])
        XCTAssertEqual(plan.reasons[b.id], "格子里有别的工作")
        XCTAssertNil(plan.reasons[a.id])
    }

    // MARK: - Calendar

    func testTheCalendarShowsSavedAndDraftedJobs() {
        let saved = job("a", name: "声乐课")
        let draft = job("b", name: "舞蹈课", length: 2)
        let character = CharacterConfig(id: "mano", name: "櫻木真乃", nameZh: "樱木真乃")
        let board = ScheduleBoard(
            week: week, isCurrent: true, jobs: [saved, draft],
            placements: [placement(saved, day: 1, slot: 0)]
        )
        let entries = ScheduleCalendar.entries(
            character: character, board: board,
            drafts: [PlacementInput(jobID: draft.id, day: 3, slot: 1)]
        )
        XCTAssertEqual(entries.map(\.jobName), ["声乐课", "舞蹈课"])
        XCTAssertEqual(entries.map(\.day), [
            CalendarDay(year: 2026, month: 11, day: 3),
            CalendarDay(year: 2026, month: 11, day: 5),
        ])
        XCTAssertEqual(entries.map(\.draft), [false, true])
        XCTAssertEqual(entries[1].slotsName, "下午到晚上")
        XCTAssertEqual(entries[0].id, "schedule:\(saved.id)")
        XCTAssertEqual(entries[1].id, "draft:\(draft.id)")

        let month = CalendarPage.Month(year: 2026, month: 11, timeZone: tokyo)
        let events = CalendarPage.events(
            in: month, characters: [character], producerBirthday: nil, holidays: nil,
            schedule: entries
        )
        XCTAssertEqual(events.filter { $0.kind == .schedule }.map(\.title), ["声乐课", "舞蹈课"])
        XCTAssertEqual(
            events.first { $0.kind == .schedule }?.detail, "樱木真乃 · 上午"
        )
    }

    func testSeveralJobsOnADayAreCountedListedAndFiltered() {
        let one = job("a", name: "声乐课")
        let two = job("b", name: "舞蹈课")
        let character = CharacterConfig(id: "mano", name: "櫻木真乃")
        let day = CalendarDay(year: 2026, month: 11, day: 3)
        let entries = [
            ScheduleCalendar.entry(
                character: character, job: one, day: day, slot: 0, draft: false
            ),
            ScheduleCalendar.entry(
                character: character, job: two, day: day, slot: 1, draft: true
            ),
        ]
        let month = CalendarPage.Month(year: 2026, month: 11, timeZone: tokyo)
        let events = CalendarPage.events(
            in: month, characters: [character], producerBirthday: nil, holidays: nil,
            schedule: entries
        ).filter { $0.kind == .schedule }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.map(\.day), [day, day])
        XCTAssertEqual(events.map(\.title), ["声乐课", "舞蹈课"])
        XCTAssertTrue(events[1].detail?.contains("（草稿）") == true)
    }

    func testTheBookKeepsDraftsAndReasonsTogether() {
        let key = ScheduleDraftKey(characterID: "mano", week: week)
        let input = PlacementInput(jobID: "\(week.stamp):a", day: 1, slot: 0)
        var book = ScheduleDraftBook()
        XCTAssertTrue(book.drafts(for: key).isEmpty)
        book.set(drafts: [input], reasons: [input.jobID: "已经过了"], for: key)
        XCTAssertEqual(book.drafts(for: key), [input])
        XCTAssertEqual(book.reasons(for: key)[input.jobID], "已经过了")
        book.set(drafts: [], reasons: [:], for: key)
        XCTAssertTrue(book.drafts(for: key).isEmpty)
        XCTAssertTrue(book.reasons(for: key).isEmpty)
    }
}
