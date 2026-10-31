import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// The weekly schedule (spec #50): drawing a week's jobs, placing them, what she is told,
/// the affinity a done job raises, and why she comes to the bar after one.
final class ScheduleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonSchedule-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text)!
    }

    private func installed(includeJobs: Bool = false) async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.includeJobs = includeJobs
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root, options: options))
        return eidolon
    }

    /// A job list that can give eight idols a week of 24–27 slots.
    private func drawingJobs() -> [ListedJob] {
        (0..<48).map { index in
            ListedJob(
                id: "job-\(index)",
                name: "工作 \(index)",
                note: "做点什么。",
                category: .practice,
                length: index < 32 ? 1 : 2
            )
        }
    }

    /// Four rounds' worth, so each week takes eight of them.
    private let idols = (0..<32).map { "idol-\($0)" }

    // MARK: - Weeks and drawing

    /// A week is the one Beijing is in, from Monday.
    func testTheWeekIsTheOneBeijingIsIn() {
        XCTAssertEqual(
            ScheduleRules.week(of: date("2026-11-01T15:59:00Z")),
            CalendarDay(year: 2026, month: 10, day: 26)
        )
        XCTAssertEqual(
            ScheduleRules.week(of: date("2026-11-01T16:30:00Z")),
            CalendarDay(year: 2026, month: 11, day: 2)
        )
    }

    func testAWeekIsDrawnWithinTheRulesAndDoesNotChange() throws {
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        let first = try ScheduleRules.drawWeek(week: week, idols: idols, jobs: drawingJobs())
        let again = try ScheduleRules.drawWeek(week: week, idols: idols, jobs: drawingJobs())
        XCTAssertEqual(first.map { [$0.characterID, $0.job.id] }, again.map { [$0.characterID, $0.job.id] })

        let total = first.reduce(0) { $0 + $1.job.length }
        XCTAssertTrue((24...27).contains(total), "total: \(total)")
        XCTAssertEqual(Set(first.map(\.job.id)).count, first.count, "no job twice")
        // One group of four weeks has this week's idols: eight of the thirty-two.
        let ofTheWeek = Set(first.map(\.characterID))
        XCTAssertEqual(ofTheWeek.count, 8)
        XCTAssertTrue(ofTheWeek.isSubset(of: Set(idols)))
        for idol in ofTheWeek {
            let count = first.filter { $0.characterID == idol }.count
            XCTAssertTrue((2...3).contains(count), "\(idol): \(count)")
        }
    }

    // MARK: - Time in a day

    func testASlotIsPastUnderWayOrToComeWhereTheProducerIs() {
        let thisWeek = CalendarDay(year: 2026, month: 11, day: 2)
        let local = date("2026-11-02T09:00:00Z") // 18:00 JST
        XCTAssertEqual(
            ScheduleRules.timeOf(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek, day: 0, slot: 1
            ),
            .past
        )
        XCTAssertEqual(
            ScheduleRules.timeOf(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek, day: 0, slot: 2
            ),
            .now
        )
        XCTAssertEqual(
            ScheduleRules.timeOf(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek, day: 1, slot: 0
            ),
            .future
        )
        XCTAssertEqual(
            ScheduleRules.timeOf(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek.adding(days: -7), day: 0, slot: 0
            ),
            .past
        )
    }

    func testAJobIsDoneAsItsLastSlotEnds() {
        let thisWeek = CalendarDay(year: 2026, month: 11, day: 2)
        let local = date("2026-11-02T03:00:00Z") // 12:00 JST, the afternoon begun
        XCTAssertTrue(
            ScheduleRules.isDone(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek, day: 0, slot: 0, length: 1
            )
        )
        XCTAssertFalse(
            ScheduleRules.isDone(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek, day: 0, slot: 0, length: 3
            )
        )
        XCTAssertFalse(
            ScheduleRules.isDone(
                local: local, timeZone: tokyo, thisWeek: thisWeek,
                week: thisWeek, day: 0, slot: 1, length: 1
            )
        )
    }

    // MARK: - What she is told

    func testHerJobsAreToldWithTheirDaySlotsAndWhetherDone() {
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        let done = WeeklyJob(
            id: "\(week.stamp):vocal", week: week, characterID: "mano", listedID: "vocal",
            name: "声乐课", note: "跟老师练发声。", category: .practice, length: 1, slots: nil
        )
        let underWay = WeeklyJob(
            id: "\(week.stamp):dance", week: week, characterID: "mano", listedID: "dance",
            name: "舞蹈课", note: "抠新编舞。", category: .practice, length: 1, slots: nil
        )
        let schedule = HerSchedule(
            local: date("2026-11-03T04:00:00Z"), // 13:00 JST Tuesday
            timeZone: tokyo,
            thisWeek: week,
            jobs: [
                HerJob(job: done, week: week, day: 0, slot: 0),
                HerJob(job: underWay, week: week, day: 1, slot: 1),
            ]
        )
        let lines = SchedulePrompt.lines(schedule)
        XCTAssertEqual(lines.first, SchedulePrompt.herJobs)
        XCTAssertEqual(lines.last, SchedulePrompt.about)
        XCTAssertTrue(
            lines.contains("周一（昨天）上午：声乐课——跟老师练发声。（做完了）"), "\(lines)"
        )
        XCTAssertTrue(
            lines.contains {
                $0.hasPrefix("现在（下午 12–18 点）你正在舞蹈课：抠新编舞。")
            },
            "\(lines)"
        )
    }

    // MARK: - Saving

    private func insertWeek(
        _ eidolon: Eidolon, week: CalendarDay,
        jobs: [(id: String, name: String, length: Int, slots: [ScheduleSlot]?)]
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO schedule_weeks(week, drawn_at) VALUES (?, ?)",
                arguments: [week.stamp, "2026-11-01T00:00:00.000000Z"]
            )
            for job in jobs {
                try db.execute(
                    sql: """
                        INSERT INTO weekly_jobs(
                            id, week, character_id, listed_id, name, note, category, length, slots
                        ) VALUES (?, ?, 'mano', ?, ?, '说明。', 'practice', ?, ?)
                        """,
                    arguments: [
                        "\(week.stamp):\(job.id)", week.stamp, job.id, job.name, job.length,
                        job.slots.map { $0.map { String($0.rawValue) }.joined(separator: ",") },
                    ]
                )
            }
        }
    }

    func testSavingRefusesWhatCannotBePlacedAndSaysWhy() async throws {
        let eidolon = try await installed()
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        try await insertWeek(eidolon, week: week, jobs: [
            ("vocal", "声乐课", 1, nil),
            ("dance", "舞蹈课", 1, nil),
            ("whole", "外景", 3, nil),
            ("morning", "早课", 1, [.morning]),
        ])
        let now = date("2026-11-02T00:00:00Z") // 09:00 JST Monday, the morning under way

        let save = try await eidolon.saveSchedule(
            characterID: "mano", week: week,
            placements: [
                PlacementInput(jobID: "\(week.stamp):vocal", day: 1, slot: 0),
                PlacementInput(jobID: "\(week.stamp):vocal", day: 2, slot: 0),
                PlacementInput(jobID: "\(week.stamp):dance", day: 1, slot: 0),
                PlacementInput(jobID: "\(week.stamp):whole", day: 1, slot: 1),
                PlacementInput(jobID: "\(week.stamp):morning", day: 1, slot: 2),
                PlacementInput(jobID: "\(week.stamp):missing", day: 1, slot: 0),
            ],
            now: now, timeZone: tokyo
        )
        XCTAssertEqual(save.saved, [PlacementInput(jobID: "\(week.stamp):vocal", day: 1, slot: 0)])
        XCTAssertEqual(save.refused.map(\.reason), [
            "这项工作已经保存过了",
            "格子里有别的工作",
            "一整天的工作只能从上午排",
            "只能排在上午",
            "这项工作不在这一周",
        ])
    }

    func testTheMorningUnderWayCannotBeSaved() async throws {
        let eidolon = try await installed()
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        try await insertWeek(eidolon, week: week, jobs: [("vocal", "声乐课", 1, nil)])
        let now = date("2026-11-02T00:00:00Z") // 09:00 JST
        let save = try await eidolon.saveSchedule(
            characterID: "mano", week: week,
            placements: [PlacementInput(jobID: "\(week.stamp):vocal", day: 0, slot: 0)],
            now: now, timeZone: tokyo
        )
        XCTAssertEqual(save.refused.map(\.reason), ["正在进行"])
    }

    func testAWeekThatIsNotThisOrTheNextIsNotSaved() async throws {
        let eidolon = try await installed()
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        try await insertWeek(eidolon, week: week, jobs: [("vocal", "声乐课", 1, nil)])
        let save = try await eidolon.saveSchedule(
            characterID: "mano", week: week,
            placements: [PlacementInput(jobID: "\(week.stamp):vocal", day: 1, slot: 0)],
            now: date("2026-11-20T00:00:00Z"), timeZone: tokyo
        )
        XCTAssertEqual(save.refused.map(\.reason), ["这一周不能排"])
    }

    // MARK: - Done jobs

    /// A done job raises her affinity once, as the schedule is read (upstream
    /// `Affinities.job_done`), and is why she may come to the bar.
    func testADoneJobRaisesAffinityOnceAndIsTodaysReasonAtTheBar() async throws {
        let eidolon = try await installed()
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        let next = week.adding(days: 7)
        try await insertWeek(eidolon, week: week, jobs: [("vocal", "声乐课", 1, nil)])
        try await insertWeek(eidolon, week: next, jobs: [])
        let now = date("2026-11-03T03:00:00Z") // 12:00 JST Tuesday, the morning done
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO schedule_placements(
                        week, job_id, character_id, day, slot, saved_at
                    ) VALUES (?, ?, 'mano', 1, 0, ?)
                    """,
                arguments: [week.stamp, "\(week.stamp):vocal", "2026-11-02T00:00:00.000000Z"]
            )
        }

        let before = try await eidolon.readAffinity(characterID: "mano", now: now).value
        let schedule = try await eidolon.schedule(characterID: "mano", now: now, timeZone: tokyo)
        XCTAssertEqual(schedule.doneToday()?.name, "声乐课")
        let after = try await eidolon.readAffinity(characterID: "mano", now: now).value
        XCTAssertEqual(after, before + 0.5, accuracy: 0.0001)
        let lines = try await eidolon.scheduleLines(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertTrue(lines.contains { $0.contains("声乐课") && $0.contains("做完了") })

        _ = try await eidolon.schedule(characterID: "mano", now: now, timeZone: tokyo)
        let again = try await eidolon.readAffinity(characterID: "mano", now: now).value
        XCTAssertEqual(again, after, accuracy: 0.0001)

        let localNow = now
        let zone = tokyo
        let job = try await eidolon.userQueue.read { db in
            try ScheduleStore.doneTodayJob(
                db, characterID: "mano", now: localNow, timeZone: zone
            )
        }
        XCTAssertEqual(job?.name, "声乐课")
    }

    // MARK: - The bundle and the bar

    func testTheJobListIsReadFromTheBundle() async throws {
        let eidolon = try await installed(includeJobs: true)
        let jobs = try await eidolon.jobList()
        XCTAssertEqual(jobs.map(\.id), ["vocal-lesson", "photos", "day-off"])
        XCTAssertEqual(jobs[1].slots, [.morning])
        XCTAssertEqual(jobs[2].length, 3)
    }

    func testABrokenJobListIsRefused() throws {
        XCTAssertThrowsError(try Eidolon.validateJobs([
            ListedJob(id: "a", name: "一", note: "一", category: .practice, length: 4),
        ]))
        XCTAssertThrowsError(try Eidolon.validateJobs([
            ListedJob(id: "a", name: "一", note: "一", category: .practice, length: 1),
            ListedJob(id: "a", name: "二", note: "二", category: .practice, length: 1),
        ]))
    }

    func testAJobOfHersDoneTodayIsWhySheComesToTheBar() {
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        let job = WeeklyJob(
            id: "\(week.stamp):vocal", week: week, characterID: "mano", listedID: "vocal",
            name: "声乐课", note: "跟老师练发声。", category: .practice, length: 1, slots: nil
        )
        let character = CharacterConfig(id: "mano", name: "櫻木真乃")
        let visits = BarVisits(
            reasons: [BarReason(id: "late", note: "路过", mood: .tired)], topics: []
        )
        let withJob = BarRoom.reason(
            character, visits, job: job, recent: [], { _ in 0 }
        )
        XCTAssertEqual(withJob.id, "声乐课")
        XCTAssertTrue(withJob.job)
        XCTAssertNil(withJob.mood)
        let listed = BarRoom.reason(
            character, visits, job: job, recent: [], { _ in 1 }
        )
        XCTAssertEqual(listed.id, "late")
        XCTAssertFalse(listed.job)
    }

    func testTheBarSaysSheCameAfterHerJob() {
        let line = BarPrompt.reasonLine(
            VisitReason(id: "声乐课", note: "跟老师练发声。", job: true)
        )
        XCTAssertEqual(
            line,
            "你今天完成了制作人排给你的工作「声乐课」（跟老师练发声。），"
                + "收工以后来了店里。心情按你做这项工作的样子来定。"
        )
        XCTAssertEqual(
            BarPrompt.reasonLine(VisitReason(id: "late", note: "路过", mood: .tired)),
            "你今晚来的缘由：路过进门时的心情：疲惫。"
        )
    }
}
