import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// Gifts given, reset cards, achievements and their rewards (spec #63, #66–#72).
final class AchievementTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonAchievements-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(
            bundleAt: try Fixture.makeBundle(in: root, options: .init(includeGifts: true))
        )
        return eidolon
    }

    private func noon(_ day: String = "2026-03-04") throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = GiftRules.dayTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: "\(day) 12:00"))
    }

    private func addGift(_ id: String, count: Int, on eidolon: Eidolon) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO gift_backpack(gift_id, count) VALUES (?, ?)
                    ON CONFLICT(gift_id) DO UPDATE SET count = count + excluded.count
                    """,
                arguments: [id, count]
            )
        }
    }

    private func setAffinity(
        _ character: String,
        value: Double,
        cooling: Bool = false,
        on eidolon: Eidolon,
        at now: Date
    ) async throws {
        try await eidolon.userQueue.write { db in
            try Eidolon.writeAffinity(
                db,
                characterID: character,
                value: value,
                cooling: cooling,
                updatedAt: Eidolon.timestamp(now),
                gainedToday: 0,
                gainedOn: nil
            )
        }
    }

    private func balance(_ eidolon: Eidolon) async throws -> (draws: Int, cards: Int) {
        try await eidolon.userQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT draws, reset_cards FROM gift_balances WHERE id = 1"
            )
            return (row?["draws"] ?? 0, row?["reset_cards"] ?? 0)
        }
    }

    func testGivingAGiftTakesItRaisesAffinityAndWritesAnEvent() async throws {
        let eidolon = try await installedEidolon()
        try await addGift("cake", count: 1, on: eidolon)
        let now = try noon()

        let given = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
        XCTAssertEqual(given.gift.name, "蛋糕")
        XCTAssertEqual(given.remaining, 0)
        XCTAssertFalse(given.change?.tierChanged ?? true)
        XCTAssertFalse(given.stillCooling)
        let affinity = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(affinity.value, 50.3, accuracy: 0.0001)

        let events = try await eidolon.conversationEvents(conversationID: given.conversationID)
        XCTAssertEqual(events.last?.kind, "gift")
        XCTAssertEqual(events.last?.giftID, "cake")
        XCTAssertEqual(events.last?.liked, false)
        XCTAssertNotNil(events.last?.affinity)

        let hers = try await eidolon.herAchievements(characterID: "mano")
        XCTAssertEqual(hers.achievements.first { $0.id == .gifts }?.unlockedCount, 1)
        let after = try await balance(eidolon)
        XCTAssertEqual(after.draws, GiftRules.drawsPerDay + 1)

        do {
            _ = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
            XCTFail("the last one was already given")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .noSuchGift)
        }
    }

    func testALikedGiftRaisesMoreAndTheEventSaysSo() async throws {
        let eidolon = try await installedEidolon()
        try await addGift("black-tea", count: 1, on: eidolon)
        let now = try noon()
        let given = try await eidolon.giveGift(giftID: "black-tea", characterID: "mano", now: now)
        let affinity = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(affinity.value, 50.6, accuracy: 0.0001)
        let events = try await eidolon.conversationEvents(conversationID: given.conversationID)
        XCTAssertEqual(events.last?.liked, true)
    }

    func testTheGiftNarrationIsExactAndAsksHerToRespondOnce() async throws {
        let eidolon = try await installedEidolon()
        try await addGift("black-tea", count: 1, on: eidolon)
        let now = try noon()
        let given = try await eidolon.giveGift(
            giftID: "black-tea", characterID: "mano", now: now
        )
        let record = try await eidolon.promptRecord(
            conversationID: given.conversationID,
            turns: 20,
            timeZone: AffinityRules.dayZone
        )
        XCTAssertEqual(
            record.trailingNarration,
            "（制作人送给你一份红茶。这是你喜欢的东西。）\n"
                + "（先回应制作人说的话，再在合适的时候用你自己的方式回应收到的礼物，一次就够。）\n"
        )
    }

    func testGiftsInACooldownRaiseByThreeAndThawAtTen() async throws {
        let eidolon = try await installedEidolon()
        try await addGift("cake", count: 4, on: eidolon)
        let now = try noon()
        try await setAffinity("mano", value: 0, cooling: true, on: eidolon, at: now)
        var last: GiftGiven?
        for _ in 0..<4 {
            last = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
        }
        let affinity = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(affinity.value, 12, accuracy: 0.0001)
        XCTAssertFalse(affinity.cooling)
        XCTAssertEqual(last?.change?.thawed, true)
    }

    func testAGiftAfterAnEndedConversationStartsAnother() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        let stamp = Eidolon.timestamp(now)
        let old = try await eidolon.createConversation(characterID: "mano", now: now)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET ended_at = ? WHERE id = ?",
                arguments: [stamp, old]
            )
        }
        try await addGift("cake", count: 1, on: eidolon)
        let given = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
        XCTAssertNotEqual(given.conversationID, old)
        let current = try await eidolon.currentConversationID("mano")
        XCTAssertEqual(current, given.conversationID)
    }

    func testAResetCardBringsEveryoneBelowTrustBack() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        try await setAffinity("mano", value: 12, cooling: true, on: eidolon, at: now)
        try await setAffinity("hiori", value: 70, on: eidolon, at: now)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO gift_balances(id, draws, given_on, reset_cards)
                    VALUES (1, 0, ?, 1)
                    ON CONFLICT(id) DO UPDATE SET reset_cards = 1
                    """,
                arguments: [GiftRules.day(now)]
            )
        }
        let targets = try await eidolon.resetCardTargets(now: now)
        XCTAssertEqual(targets.map(\.characterID), ["mano"])

        let use = try await eidolon.useResetCard(now: now)
        XCTAssertEqual(use.restored.map(\.characterID), ["mano"])
        XCTAssertEqual(use.resetCardsLeft, 0)
        let mano = try await eidolon.debugAffinity(characterID: "mano", now: now)
        let hiori = try await eidolon.debugAffinity(characterID: "hiori", now: now)
        XCTAssertEqual(mano.value, 50)
        XCTAssertFalse(mano.cooling)
        XCTAssertEqual(hiori.value, 70)
        let events = try await eidolon.conversationEventsForAll()
        XCTAssertTrue(events.isEmpty)
    }

    func testTheBackfillCountsWhatWasAlreadyRecorded() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        try await eidolon.userQueue.write { db in
            let conversation = UUID().uuidString
            try Eidolon.insertConversation(
                db, id: conversation, characterID: "mano", createdAt: Eidolon.timestamp(now)
            )
            for index in 0..<10 {
                try db.execute(
                    sql: "INSERT INTO messages(id, conversation_id, role, text, created_at) VALUES (?, ?, 'user', ?, ?)",
                    arguments: [
                        UUID().uuidString, conversation, "line \(index)",
                        Eidolon.timestamp(now.addingTimeInterval(Double(index))),
                    ]
                )
            }
            try db.execute(
                sql: "INSERT INTO call_ends(conversation_id, character_id, ended_at, duration_s) VALUES (?, 'mano', ?, 600)",
                arguments: [conversation, Eidolon.timestamp(now)]
            )
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(conversation_id, kind, created_at, gift_id, liked)
                    VALUES (?, 'gift', ?, 'cake', 0)
                    """,
                arguments: [conversation, Eidolon.timestamp(now)]
            )
            // A second conversation counts towards the same character: the backfill must
            // add both up rather than pick one conversation per character.
            let other = UUID().uuidString
            try Eidolon.insertConversation(
                db, id: other, characterID: "mano", createdAt: Eidolon.timestamp(now)
            )
            for index in 0..<4 {
                try db.execute(
                    sql: "INSERT INTO messages(id, conversation_id, role, text, created_at) VALUES (?, ?, 'user', ?, ?)",
                    arguments: [
                        UUID().uuidString, other, "other \(index)",
                        Eidolon.timestamp(now.addingTimeInterval(Double(index))),
                    ]
                )
            }
        }

        let summary = try await eidolon.launchAchievements(now: now)
        XCTAssertEqual(summary?.stages, 3)
        XCTAssertEqual(summary?.draws, 3)
        let hers = try await eidolon.herAchievements(characterID: "mano")
        XCTAssertEqual(hers.achievements.first { $0.id == .turns }?.progress, 14)
        XCTAssertEqual(hers.achievements.first { $0.id == .turns }?.unlockedCount, 1)
        XCTAssertEqual(hers.achievements.first { $0.id == .callTime }?.unlockedCount, 1)
        XCTAssertEqual(hers.achievements.first { $0.id == .gifts }?.unlockedCount, 1)
        let again = try await eidolon.launchAchievements(now: now)
        XCTAssertNil(again)
    }

    func testDrawingCountsTowardsTheDrawAchievement() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO gift_balances(id, draws, given_on, reset_cards)
                    VALUES (1, 10, ?, 0) ON CONFLICT(id) DO UPDATE SET draws = 10
                    """,
                arguments: [GiftRules.day(now)]
            )
        }
        let draw = try await eidolon.drawGifts(
            all: true,
            random: ScriptedGiftRandom((0..<10).flatMap { _ in [10, 0] }),
            at: now
        )
        XCTAssertFalse(draw.rewards.isEmpty)
        let all = try await eidolon.allAchievements()
        XCTAssertEqual(all.achievements.first { $0.id == .draws }?.unlockedCount, 1)
    }

    func testTheBarGivesOneDrawOnly() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        let first = try await eidolon.userQueue.write { db in
            try GiftStore.creditBarDraw(db, key: "bar:\(GiftRules.day(now))", at: now)
        }
        let second = try await eidolon.userQueue.write { db in
            try GiftStore.creditBarDraw(db, key: "bar:\(GiftRules.day(now))", at: now)
        }
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        let after = try await balance(eidolon)
        XCTAssertEqual(after.draws, GiftRules.drawsPerDay + 1)
    }
    func testAWarmGiftRaisesMore() {
        let warm = Gift(
            id: "hot-cocoa", name: "热可可", category: .drink, rarity: .common, warm: true
        )
        XCTAssertEqual(
            warm.coolingStep(affinityCooling: false, liked: false, warmed: true),
            0.6,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            warm.coolingStep(affinityCooling: false, liked: false, warmed: false),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            warm.coolingStep(affinityCooling: false, liked: true, warmed: true),
            0.9,
            accuracy: 0.0001
        )
    }

    func testCompletingHerGivesOneResetCardOnlyOnce() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        try await eidolon.userQueue.write { db in
            for (achievement, count) in [
                ("turns", 3_000.0), ("call_time", 72_000.0), ("tier", 2.0), ("gifts", 99.0),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO achievement_progress(achievement, character_id, count)
                        VALUES (?, 'mano', ?)
                        """,
                    arguments: [achievement, count]
                )
            }
        }
        try await addGift("cake", count: 2, on: eidolon)

        let given = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
        XCTAssertTrue(
            given.rewards.contains { $0.resetCards == 1 && $0.completedCharacterID == "mano" }
        )
        let hers = try await eidolon.herAchievements(characterID: "mano")
        XCTAssertTrue(hers.isComplete)
        let firstCards = try await balance(eidolon).cards
        XCTAssertEqual(firstCards, 1)

        let again = try await eidolon.giveGift(
            giftID: "cake", characterID: "mano", now: now.addingTimeInterval(1)
        )
        XCTAssertFalse(again.rewards.contains { $0.resetCards > 0 })
        let cardsAfter = try await balance(eidolon).cards
        XCTAssertEqual(cardsAfter, 1)
    }

    func testThePlayDotIsClearedByEitherPageNotByHerPanel() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        try await addGift("cake", count: 3, on: eidolon)
        let before = try await eidolon.achievementBadge()
        XCTAssertFalse(before)

        _ = try await eidolon.giveGift(giftID: "cake", characterID: "mano", now: now)
        let unlocked = try await eidolon.achievementBadge()
        XCTAssertTrue(unlocked)

        try await eidolon.markPlaySeen(now: now.addingTimeInterval(1))
        let cleared = try await eidolon.achievementBadge()
        XCTAssertFalse(cleared)

        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE achievement_progress SET count = 9
                    WHERE achievement = 'gifts' AND character_id = 'mano'
                    """
            )
        }
        _ = try await eidolon.giveGift(
            giftID: "cake", characterID: "mano", now: now.addingTimeInterval(2)
        )
        let unlockedAgain = try await eidolon.achievementBadge()
        XCTAssertTrue(unlockedAgain)

        // Her panel's per-character mark is its own; the play dot waits for the play page.
        try await eidolon.markAchievementsSeen(characterID: "mano")
        let afterHerPanel = try await eidolon.achievementBadge()
        XCTAssertTrue(afterHerPanel)
        try await eidolon.markPlaySeen(now: now.addingTimeInterval(3))
        let clearedAgain = try await eidolon.achievementBadge()
        XCTAssertFalse(clearedAgain)
    }

    func testTheGiftPanelListsTheConversationListsOrder() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon()
        try await addGift("cake", count: 2, on: eidolon)
        _ = try await eidolon.giveGift(
            giftID: "cake", characterID: "mano", now: now.addingTimeInterval(-60)
        )
        _ = try await eidolon.giveGift(giftID: "cake", characterID: "hiori", now: now)

        let recipients = try await eidolon.giftRecipients(now: now)
        XCTAssertEqual(Array(recipients.map(\.characterID).prefix(2)), ["hiori", "mano"])
    }

    func testTheToastKeepsBothRewardsFromOneAction() {
        XCTAssertEqual(
            AchievementReward.toast(for: [
                AchievementReward(stage: 1, draws: 1),
                AchievementReward(resetCards: 1, completedCharacterID: "mano"),
            ]),
            "成就，抽奖 +1，重置卡 +1"
        )
        XCTAssertNil(AchievementReward.toast(for: []))
    }

}

private extension Eidolon {
    /// Every event in the library, for tests that only need to know none was written.
    func conversationEventsForAll() async throws -> [ConversationEventRecord] {
        try await userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT id, kind, created_at, gift_id, liked, affinity FROM conversation_events"
            ).map(Eidolon.eventRecord)
        }
    }
}
