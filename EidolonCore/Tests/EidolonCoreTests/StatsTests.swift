import Foundation
import XCTest
@testable import EidolonCore

/// The stats page's read model (spec #96), following upstream `stats.py`.
final class StatsTests: XCTestCase {
    private var root: URL!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonStats-\(UUID().uuidString)", isDirectory: true)
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

    private func date(_ stamp: String) -> Date {
        Eidolon.parseTimestamp(stamp)!
    }

    private func noon(_ day: String) -> Date {
        date("\(day)T03:00:00Z") // noon JST
    }

    private func conversation(
        _ eidolon: Eidolon, id: String, character: String = "mano",
        at stamp: String = "2026-11-01T03:00:00Z"
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO conversations(id, character_id, created_at) VALUES (?, ?, ?)",
                arguments: [id, character, stamp]
            )
        }
    }

    private func message(
        _ eidolon: Eidolon, conversation: String, role: String = "user",
        at stamp: String
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES (?, ?, ?, '话', ?)
                    """,
                arguments: [UUID().uuidString, conversation, role, stamp]
            )
        }
    }

    private func gift(
        _ eidolon: Eidolon, conversation: String, id: String,
        liked: Bool, at stamp: String
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(
                        conversation_id, kind, created_at, gift_id, liked
                    ) VALUES (?, 'gift', ?, ?, ?)
                    """,
                arguments: [conversation, stamp, id, liked ? 1 : 0]
            )
        }
    }

    private func call(
        _ eidolon: Eidolon, conversation: String, character: String = "mano",
        connectedAt stamp: String, seconds: Double
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO call_ends(
                        conversation_id, character_id, ended_at, connected_at, duration_s
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [conversation, character, stamp, stamp, seconds]
            )
        }
    }

    private func achievement(
        _ eidolon: Eidolon, character: String = "mano", stage: Int
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO achievement_stages(
                        achievement, character_id, stage, unlocked_at
                    ) VALUES ('turns', ?, ?, ?)
                    """,
                arguments: [character, stage, "2026-11-01T03:00:00Z"]
            )
        }
    }

    private func affinity(
        _ eidolon: Eidolon, character: String, value: Double,
        cooling: Bool = false, at stamp: String = "2026-11-05T03:00:00Z"
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES (?, ?, ?, ?, 0, NULL)
                    """,
                arguments: [character, value, cooling ? 1 : 0, stamp]
            )
        }
    }

    func testContactsHeatmapAndVisitStreak() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        for day in ["2026-11-03", "2026-11-04", "2026-11-05"] {
            try await message(eidolon, conversation: "c1", at: "\(day)T03:00:00Z")
        }
        // One day earlier in the run, before a gap.
        try await message(eidolon, conversation: "c1", at: "2026-10-30T03:00:00Z")

        let now = noon("2026-11-05")
        let stats = try await eidolon.statsSummary(range: .all, now: now, timeZone: tokyo)

        XCTAssertTrue(stats.hasContacts)
        XCTAssertEqual(stats.daysKnown, 7) // Oct 30 through Nov 5, counting the first
        XCTAssertEqual(stats.currentVisitStreak, 3)
        XCTAssertEqual(stats.longestVisitStreak, 3)
        XCTAssertEqual(stats.range.turns, 4)
        XCTAssertEqual(stats.range.byHour[12], 4) // noon JST
        XCTAssertEqual(stats.heatmap.last?.day, CalendarDay(year: 2026, month: 11, day: 5))
        XCTAssertEqual(stats.heatmap.last?.count, 1)
        XCTAssertEqual(stats.heatmap.first?.day.weekdayIndex, 0)
        XCTAssertEqual(stats.heatmap.first?.day, CalendarDay(year: 2026, month: 10, day: 26))
        XCTAssertEqual(stats.heatmap.count, 11) // Oct 26 through Nov 5
    }

    func testTheHeatmapFollowsTheRangeAndStartsOnAMonday() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        try await message(eidolon, conversation: "c1", at: "2026-11-05T03:00:00Z")
        let now = noon("2026-11-05")

        let month = try await eidolon.statsSummary(
            range: .thirtyDays, now: now, timeZone: tokyo
        )
        XCTAssertEqual(month.heatmap.first?.day, CalendarDay(year: 2026, month: 10, day: 5))
        XCTAssertEqual(month.heatmap.last?.day, CalendarDay(year: 2026, month: 11, day: 5))
        XCTAssertEqual(month.heatmap.count, 32)
        XCTAssertEqual(month.heatmap.first?.day.weekdayIndex, 0)

        let year = try await eidolon.statsSummary(range: .year, now: now, timeZone: tokyo)
        XCTAssertEqual(
            year.heatmap.count,
            52 * 7 + CalendarDay(year: 2026, month: 11, day: 5).weekdayIndex + 1
        )
        XCTAssertEqual(year.heatmap.first?.day.weekdayIndex, 0)

        let all = try await eidolon.statsSummary(range: .all, now: now, timeZone: tokyo)
        XCTAssertEqual(all.heatmap.first?.day, CalendarDay(year: 2026, month: 11, day: 2))
        XCTAssertEqual(all.heatmap.count, 4)
    }

    func testTheRangeTakesWholeDaysAndOnlyConnectedCalls() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        try await message(eidolon, conversation: "c1", at: "2026-11-05T03:00:00Z")
        try await message(eidolon, conversation: "c1", at: "2026-08-01T03:00:00Z")
        try await call(eidolon, conversation: "c1", connectedAt: "2026-11-04T03:00:00Z", seconds: 60)
        try await call(eidolon, conversation: "c1", connectedAt: "2026-08-01T03:00:00Z", seconds: 30)

        let now = noon("2026-11-05")
        let recent = try await eidolon.statsSummary(range: .thirtyDays, now: now, timeZone: tokyo)
        XCTAssertEqual(recent.range.turns, 1)
        XCTAssertEqual(recent.range.calls, 1)
        XCTAssertEqual(recent.range.callSeconds, 60)

        let all = try await eidolon.statsSummary(range: .all, now: now, timeZone: tokyo)
        XCTAssertEqual(all.range.turns, 2)
        XCTAssertEqual(all.range.calls, 2)
        XCTAssertEqual(all.range.callSeconds, 90)
    }

    func testTheProducersTimeZoneMovesTheDayAndHour() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        // 2026-11-04 16:00 UTC is 2026-11-05 01:00 in Tokyo and 12:00 in New York.
        try await message(eidolon, conversation: "c1", at: "2026-11-04T16:00:00Z")
        let now = noon("2026-11-05")
        let tokyoStats = try await eidolon.statsSummary(range: .all, now: now, timeZone: tokyo)
        XCTAssertEqual(tokyoStats.range.byHour[1], 1)
        XCTAssertEqual(
            tokyoStats.heatmap.first { $0.day == CalendarDay(year: 2026, month: 11, day: 5) }?.count,
            1
        )
        let utc = try await eidolon.statsSummary(range: .all, now: now, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(utc.range.byHour[16], 1)
    }

    func testDeletingAConversationRemovesItsTurnsButNotTheAchievements() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        try await message(eidolon, conversation: "c1", at: "2026-11-05T03:00:00Z")
        try await achievement(eidolon, stage: 1)
        var stats = try await eidolon.statsSummary(range: .all, now: noon("2026-11-05"), timeZone: tokyo)
        XCTAssertEqual(stats.range.turns, 1)
        XCTAssertEqual(stats.achievements.stages, 1)

        try await eidolon.userQueue.write { db in
            try db.execute(sql: "DELETE FROM conversations WHERE id = 'c1'")
        }
        stats = try await eidolon.statsSummary(range: .all, now: noon("2026-11-05"), timeZone: tokyo)
        XCTAssertEqual(stats.range.turns, 0)
        XCTAssertFalse(stats.hasContacts)
        XCTAssertEqual(stats.achievements.stages, 1)
    }

    func testGiftsCountLikedAndTheMostGivenCharacterInIdolOrder() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        try await conversation(eidolon, id: "c2", character: "hiori")
        try await gift(eidolon, conversation: "c1", id: "cake", liked: true, at: "2026-11-05T03:00:00Z")
        try await gift(eidolon, conversation: "c1", id: "cake", liked: false, at: "2026-11-05T04:00:00Z")
        try await gift(eidolon, conversation: "c2", id: "flower", liked: true, at: "2026-11-05T05:00:00Z")

        let stats = try await eidolon.statsSummary(range: .all, now: noon("2026-11-05"), timeZone: tokyo)
        XCTAssertEqual(stats.range.gifts.given, 3)
        XCTAssertEqual(stats.range.gifts.liked, 2)
        XCTAssertEqual(stats.range.gifts.mostGiven, 2)
        XCTAssertEqual(stats.range.gifts.mostCharacterID, "mano")
        XCTAssertEqual(stats.range.gifts.kinds.map(\.giftID), ["cake", "flower"])
        XCTAssertEqual(stats.range.gifts.kinds[0].liked, 1)
        XCTAssertEqual(stats.range.turns, 0)
    }

    func testAffinityGroupsAreByTierAndCoolingIsCold() async throws {
        let eidolon = try await installed()
        try await affinity(eidolon, character: "mano", value: 90)
        try await affinity(eidolon, character: "hiori", value: 10, cooling: true)
        let stats = try await eidolon.statsSummary(range: .all, now: noon("2026-11-05"), timeZone: tokyo)
        XCTAssertEqual(
            stats.affinity.first { $0.tier == .intimate }?.characterIDs, ["mano"]
        )
        XCTAssertEqual(
            stats.affinity.first { $0.tier == .cold }?.characterIDs, ["hiori"]
        )
    }

    func testCharactersAreInIdolOrderWithTheirOwnDaysAndCalls() async throws {
        let eidolon = try await installed()
        try await conversation(eidolon, id: "c1")
        try await conversation(eidolon, id: "c2", character: "hiori")
        try await message(eidolon, conversation: "c1", at: "2026-11-05T03:00:00Z")
        try await message(eidolon, conversation: "c2", at: "2026-11-03T03:00:00Z")
        try await call(eidolon, conversation: "c2", character: "hiori",
                       connectedAt: "2026-11-05T03:00:00Z", seconds: 120)

        let stats = try await eidolon.statsSummary(range: .all, now: noon("2026-11-05"), timeZone: tokyo)
        XCTAssertEqual(stats.range.characters.map(\.characterID), ["mano", "hiori"])
        XCTAssertEqual(stats.range.characters[0].turns, 1)
        XCTAssertEqual(stats.range.characters[0].daysKnown, 1)
        XCTAssertEqual(stats.range.characters[1].turns, 1)
        XCTAssertEqual(stats.range.characters[1].callSeconds, 120)
        XCTAssertEqual(stats.range.characters[1].daysKnown, 3)
    }

    func testNothingLeftIsAnEmptyState() async throws {
        let eidolon = try await installed()
        let stats = try await eidolon.statsSummary(range: .all, now: noon("2026-11-05"), timeZone: tokyo)
        XCTAssertFalse(stats.hasContacts)
        XCTAssertEqual(stats.daysKnown, 0)
        XCTAssertEqual(stats.currentVisitStreak, 0)
        XCTAssertTrue(stats.range.characters.isEmpty)
    }
}
