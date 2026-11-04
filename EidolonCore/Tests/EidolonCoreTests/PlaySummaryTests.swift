import Foundation
import XCTest
@testable import EidolonCore

/// The play page's five cards and their status lines (spec #94).
final class PlaySummaryTests: XCTestCase {
    private var root: URL!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonPlaySummary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installed() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(
            bundleAt: try Fixture.makeBundle(in: root, options: .init(includeGifts: true))
        )
        return eidolon
    }

    /// A week already drawn, with one job in it and none placed.
    private func insertWeek(
        _ eidolon: Eidolon, week: CalendarDay, jobs: [(id: String, name: String)]
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
                        ) VALUES (?, ?, 'mano', ?, ?, '说明。', 'practice', 1, NULL)
                        """,
                    arguments: [
                        "\(week.stamp):\(job.id)", week.stamp, job.id, job.name,
                    ]
                )
            }
        }
    }

    private func noon(_ day: String) -> Date {
        ISO8601DateFormatter().date(from: "\(day)T03:00:00Z")! // noon JST
    }

    private func card(_ summary: PlaySummary, _ kind: PlayCardKind) -> PlayCardStatus? {
        summary.cards.first { $0.kind == kind }
    }

    func testTheCardsComeInTheUpstreamOrder() async throws {
        let eidolon = try await installed()
        let now = noon("2026-11-03")
        let summary = try await eidolon.playSummary(now: now, timeZone: tokyo)

        XCTAssertEqual(
            summary.cards.map(\.kind),
            [.gifts, .achievements, .calendar, .cycles, .bar]
        )
        XCTAssertEqual(
            summary.cards.map(\.title),
            ["礼物", "成就", "日历", "她的周期", "酒吧"]
        )
    }

    func testTheGiftCardCountsDrawsBackpackAndCards() async throws {
        let eidolon = try await installed()
        let now = noon("2026-11-03")
        try await eidolon.debugSetGiftBalance(draws: 3, resetCards: 1, now: now)
        try await eidolon.debugSetGiftBackpack(["cake": 2])

        let summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        let gifts = try XCTUnwrap(card(summary, .gifts))
        XCTAssertEqual(gifts.status, "还有 3 次抽奖 · 背包 2 件 · 重置卡 1 张")
        XCTAssertFalse(gifts.isNew)
    }

    func testTheAchievementCardCountsUnseenAndUnlockedStages() async throws {
        let eidolon = try await installed()
        let now = noon("2026-11-03")
        try await eidolon.debugSetGiftBackpack(["cake": 1])

        var summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        var achievements = try XCTUnwrap(card(summary, .achievements))
        XCTAssertEqual(achievements.status, "已解锁 0 个阶段")
        XCTAssertFalse(achievements.isNew)

        _ = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
        summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        achievements = try XCTUnwrap(card(summary, .achievements))
        XCTAssertEqual(achievements.status, "1 个新解锁")
        XCTAssertTrue(achievements.isNew)

        try await eidolon.markAchievementsSeen(characterID: nil)
        summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        achievements = try XCTUnwrap(card(summary, .achievements))
        XCTAssertEqual(achievements.status, "已解锁 1 个阶段")
        XCTAssertFalse(achievements.isNew)
    }

    func testTheCalendarCardFindsTheNextEvent() async throws {
        let eidolon = try await installed()

        let later = try await eidolon.playSummary(now: noon("2026-11-03"), timeZone: tokyo)
        let next = try XCTUnwrap(card(later, .calendar))
        XCTAssertEqual(next.status, "下一个：3月4日 風野灯織的生日")

        let today = try await eidolon.playSummary(now: noon("2026-04-25"), timeZone: tokyo)
        let now = try XCTUnwrap(card(today, .calendar))
        XCTAssertEqual(now.status, "今天：櫻木真乃的生日")
    }

    func testTheCalendarCardFindsAHolidayAsTheNextEvent() async throws {
        let eidolon = try await installed()
        let summary = try await eidolon.playSummary(now: noon("2025-12-31"), timeZone: tokyo)
        let calendar = try XCTUnwrap(card(summary, .calendar))
        XCTAssertEqual(calendar.status, "下一个：1月1日 元日")
    }

    func testTheCalendarCardShowsPendingJobs() async throws {
        let eidolon = try await installed()
        let week = CalendarDay(year: 2026, month: 11, day: 2)
        try await insertWeek(
            eidolon, week: week, jobs: [(id: "vocal", name: "声乐课")]
        )
        try await insertWeek(eidolon, week: week.adding(days: 7), jobs: [])

        let summary = try await eidolon.playSummary(now: noon("2026-11-03"), timeZone: tokyo)
        let calendar = try XCTUnwrap(card(summary, .calendar))
        XCTAssertTrue(calendar.status.hasPrefix("本周还有 1 项工作待排"), calendar.status)
    }

    func testTheCycleCardSummarizesRecordsAndGoesAwayWhenOff() async throws {
        let eidolon = try await installed()
        let now = noon("2026-11-03")

        var summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        var cycles = try XCTUnwrap(card(summary, .cycles))
        XCTAssertEqual(cycles.status, "还没有记录。只记最近一次经期的第一天和天数，就会开始推算。")

        _ = try await eidolon.addCycleRecord(
            characterID: "mano",
            firstDay: CalendarDay(year: 2026, month: 10, day: 20),
            days: 5,
            now: now,
            timeZone: tokyo
        )
        summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        cycles = try XCTUnwrap(card(summary, .cycles))
        XCTAssertEqual(cycles.status, "记过 1 位 · 最近 櫻木真乃 10月20日")

        try await eidolon.setCycleEnabled(false)
        summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        XCTAssertNil(card(summary, .cycles))
    }

    func testTheCycleCardPicksTheNewestRecordAcrossCharacters() async throws {
        let eidolon = try await installed()
        let now = noon("2026-11-03")
        _ = try await eidolon.addCycleRecord(
            characterID: "mano",
            firstDay: CalendarDay(year: 2026, month: 10, day: 20),
            days: 5, now: now, timeZone: tokyo
        )
        _ = try await eidolon.addCycleRecord(
            characterID: "hiori",
            firstDay: CalendarDay(year: 2026, month: 11, day: 1),
            days: 4, now: now, timeZone: tokyo
        )

        let summary = try await eidolon.playSummary(now: now, timeZone: tokyo)
        let cycles = try XCTUnwrap(card(summary, .cycles))
        XCTAssertEqual(cycles.status, "记过 2 位 · 最近 風野灯織 11月1日")
    }

    func testTheBarCardSaysThePackageIsMissing() async throws {
        let eidolon = try await installed()
        let summary = try await eidolon.playSummary(now: noon("2026-11-03"), timeZone: tokyo)
        let bar = try XCTUnwrap(card(summary, .bar))
        XCTAssertEqual(bar.status, "还没有导入酒吧素材包，进设置导入")
    }
}
