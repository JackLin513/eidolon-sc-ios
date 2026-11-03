import Foundation
import GRDB

/// The numbers gifts go by, kept with affinity's as upstream keeps them in `affinity.py`.
public enum GiftRules {
    public static let drawsPerDay = AffinityRules.drawsPerDay
    public static let maxDraws = AffinityRules.maxDraws
    public static let dayTimeZone = AffinityRules.dayZone
    public static let resetCardPercent = AffinityRules.resetCardPercent
    public static let commonPercent = AffinityRules.commonPercent
    public static let uncommonPercent = AffinityRules.uncommonPercent
    public static let rarePercent = AffinityRules.rarePercent
    /// The identifier a reset card is shown under; not a gift.
    public static let resetCardID = "reset_card"
    /// How much a gift raises affinity by its rarity (upstream `GIFT_STEPS`).
    public static func step(_ rarity: GiftRarity) -> Double {
        switch rarity {
        case .common: 0.3
        case .uncommon: 0.5
        case .rare: 0.7
        }
    }
    public static let likedStep = 0.3
    public static let warmStep = 0.3
    public static let cooldownStep = 3.0

    /// The Beijing day `now` is in, as the balance keeps it (`yyyy-MM-dd`).
    public static func day(_ now: Date) -> String {
        Eidolon.isoDay(now, in: dayTimeZone)
    }

    /// When the next day's chances are given: the next Beijing midnight.
    public static func nextRefill(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = dayTimeZone
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? now.addingTimeInterval(86_400)
    }

    /// Whole Beijing days from one stored day to another; never negative.
    static func days(from start: String, to end: String) -> Int {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let first = formatter.date(from: start),
              let last = formatter.date(from: end)
        else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return max(0, calendar.dateComponents([.day], from: first, to: last).day ?? 0)
    }
}

/// The source a draw's numbers come from. The app uses `SystemGiftRandom`; tests pass a
/// scripted one, so an odds boundary can be drawn on purpose.
public protocol GiftRandom: Sendable {
    /// A number from 0 up to, not including, `bound`.
    func int(below bound: Int) -> Int
}

public struct SystemGiftRandom: GiftRandom {
    public init() {}

    public func int(below bound: Int) -> Int {
        precondition(bound > 0, "a random bound must be positive")
        return Int.random(in: 0..<bound)
    }
}

/// The numbers from a seed, the same sequence each launch, for a debug draw whose result
/// can be looked at twice (spec #73). Locked because draws may come from more than one
/// task, though the actor serializes them today.
public final class SeededGiftRandom: GiftRandom, @unchecked Sendable {
    private var state: UInt64
    private let lock = NSLock()

    public init(seed: UInt64) {
        state = seed
    }

    public func int(below bound: Int) -> Int {
        precondition(bound > 0, "a random bound must be positive")
        lock.lock()
        defer { lock.unlock() }
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// One gift in the backpack and how many of it the producer has.
public struct GiftStack: Sendable, Hashable, Identifiable {
    public var gift: Gift
    public var count: Int

    public var id: String { gift.id }

    public init(gift: Gift, count: Int) {
        self.gift = gift
        self.count = count
    }
}

/// What the gift page shows: the chances and cards the producer has and the backpack in
/// catalog order.
public struct GiftState: Sendable, Hashable {
    /// The installed bundle is older than gifts; the page says so and drawing is off.
    public let catalogMissing: Bool
    public let draws: Int
    public let maxDraws: Int
    public let resetCards: Int
    public let backpack: [GiftStack]
    public let nextRefill: Date

    public init(
        catalogMissing: Bool,
        draws: Int,
        maxDraws: Int,
        resetCards: Int,
        backpack: [GiftStack],
        nextRefill: Date
    ) {
        self.catalogMissing = catalogMissing
        self.draws = draws
        self.maxDraws = maxDraws
        self.resetCards = resetCards
        self.backpack = backpack
        self.nextRefill = nextRefill
    }
}

/// What one chance gave: a gift or a reset card.
public enum GiftDrawResult: Sendable, Hashable {
    case gift(Gift)
    case resetCard

    public var gift: Gift? {
        if case let .gift(gift) = self { return gift }
        return nil
    }
}

/// What drawing did: what each chance gave, in draw order, and what is left.
public struct GiftDraw: Sendable, Hashable {
    public let results: [GiftDrawResult]
    public let drawsLeft: Int
    public let resetCards: Int
    public let rewards: [AchievementReward]

    public init(
        results: [GiftDrawResult],
        drawsLeft: Int,
        resetCards: Int,
        rewards: [AchievementReward] = []
    ) {
        self.results = results
        self.drawsLeft = drawsLeft
        self.resetCards = resetCards
        self.rewards = rewards
    }
}

extension Eidolon {
    // MARK: - Reading

    /// The installed bundle's gift catalog, or nil when it was exported before gifts.
    public func giftCatalog() throws -> GiftCatalog? {
        try requireContent()
        return try GiftCatalog.load(in: location.contentDirectory)
    }

    /// The gift page's state, having been given the chances due today first. A bundle
    /// without a catalog still has a balance, so the page can say that the catalog is
    /// missing without hiding the chances the producer already has.
    public func giftState(at now: Date = Date()) throws -> GiftState {
        let catalog = try giftCatalog()
        return try userQueue.write { db in
            try Self.giveDueGiftDraws(db, at: now)
            let row = try Row.fetchOne(
                db,
                sql: "SELECT draws, reset_cards FROM gift_balances WHERE id = 1"
            )
            let draws: Int = row?["draws"] ?? 0
            let resetCards: Int = row?["reset_cards"] ?? 0

            var backpack: [GiftStack] = []
            if let catalog {
                for gift in catalog.gifts {
                    let count = try Int.fetchOne(
                        db,
                        sql: "SELECT count FROM gift_backpack WHERE gift_id = ?",
                        arguments: [gift.id]
                    ) ?? 0
                    if count > 0 {
                        backpack.append(GiftStack(gift: gift, count: count))
                    }
                }
            }

            return GiftState(
                catalogMissing: catalog == nil,
                draws: draws,
                maxDraws: GiftRules.maxDraws,
                resetCards: resetCards,
                backpack: backpack,
                nextRefill: GiftRules.nextRefill(after: now)
            )
        }
    }

    // MARK: - Drawing

    /// Draws once, or every chance the producer has when `all`, having been given the
    /// chances due today. Each chance is a reset card or a gift of one rarity, any of that
    /// rarity's gifts not retired as likely as another; drawn gifts stack in the backpack.
    public func drawGifts(
        all: Bool = false,
        random: any GiftRandom = SystemGiftRandom(),
        at now: Date = Date()
    ) throws -> GiftDraw {
        guard let catalog = try giftCatalog() else {
            throw EidolonError.giftCatalogMissing
        }
        return try userQueue.write { db in
            try Self.giveDueGiftDraws(db, at: now)
            let draws = try Int.fetchOne(
                db,
                sql: "SELECT draws FROM gift_balances WHERE id = 1"
            ) ?? 0
            guard draws > 0 else { throw EidolonError.noDraws }

            let count = all ? draws : 1
            var results: [GiftDrawResult] = []
            var gainedCards = 0
            for _ in 0..<count {
                let result = try Self.drawOne(from: catalog, random: random)
                switch result {
                case let .gift(gift):
                    try db.execute(
                        sql: """
                            INSERT INTO gift_backpack (gift_id, count) VALUES (?, 1)
                            ON CONFLICT (gift_id) DO UPDATE SET count = count + 1
                            """,
                        arguments: [gift.id]
                    )
                case .resetCard:
                    gainedCards += 1
                }
                results.append(result)
            }

            let left = draws - count
            try db.execute(
                sql: """
                    UPDATE gift_balances
                    SET draws = ?, reset_cards = reset_cards + ?
                    WHERE id = 1
                    """,
                arguments: [left, gainedCards]
            )
            let resetCards = try Int.fetchOne(
                db,
                sql: "SELECT reset_cards FROM gift_balances WHERE id = 1"
            ) ?? 0
            let rewards = try AchievementStore.keep(
                db,
                now: now,
                today: GiftRules.day(now),
                draws: count
            )
            return GiftDraw(
                results: results,
                drawsLeft: left,
                resetCards: resetCards,
                rewards: rewards
            )
        }
    }

    // MARK: - Art

    /// A gift's illustration in the installed bundle; nil when it has none, and the page
    /// falls back to a symbol.
    public nonisolated func giftArtURL(for giftID: String) -> URL? {
        let url = location.contentDirectory.appendingPathComponent("gifts/\(giftID).webp")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public nonisolated func resetCardArtURL() -> URL? {
        let url = location.contentDirectory.appendingPathComponent("gifts/reset-card.webp")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Balance

    /// Gives the chances due by `today` (upstream `_give`): the new producer's on their
    /// first read, else one for each day since they were last given, up to the most kept.
    /// A balance already over the most (from an achievement) is never brought down.
    static func giveDueGiftDraws(_ db: Database, at now: Date) throws {
        let today = GiftRules.day(now)
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT draws, given_on FROM gift_balances WHERE id = 1"
        ) else {
            try db.execute(
                sql: """
                    INSERT INTO gift_balances (id, draws, given_on, reset_cards)
                    VALUES (1, ?, ?, 0)
                    """,
                arguments: [GiftRules.drawsPerDay, today]
            )
            return
        }
        let draws: Int = row["draws"]
        let givenOn: String = row["given_on"]
        guard !givenOn.isEmpty else {
            // A balance from a build that never stamped its day: give today's chances,
            // without taking back any the achievements gave over the cap.
            try db.execute(
                sql: "UPDATE gift_balances SET draws = ?, given_on = ? WHERE id = 1",
                arguments: [
                    max(draws, min(draws + GiftRules.drawsPerDay, GiftRules.maxDraws)),
                    today,
                ]
            )
            return
        }
        guard today > givenOn else { return }
        let due = GiftRules.days(from: givenOn, to: today) * GiftRules.drawsPerDay
        let kept = max(draws, min(draws + due, GiftRules.maxDraws))
        try db.execute(
            sql: "UPDATE gift_balances SET draws = ?, given_on = ? WHERE id = 1",
            arguments: [kept, today]
        )
    }

    /// What one chance gives (upstream `_draw_one`): a reset card, or a gift not retired of
    /// the rarity the number falls in, any of that rarity's as likely as another.
    static func drawOne(from catalog: GiftCatalog, random: any GiftRandom) throws -> GiftDrawResult {
        let number = random.int(below: 100)
        guard (0..<100).contains(number) else {
            throw EidolonError.invalidBundle("抽奖随机源越界")
        }
        let uptoReset = GiftRules.resetCardPercent
        let uptoCommon = uptoReset + GiftRules.commonPercent
        let uptoUncommon = uptoCommon + GiftRules.uncommonPercent
        let uptoRare = uptoUncommon + GiftRules.rarePercent
        if number < uptoReset { return .resetCard }
        let rarity: GiftRarity
        if number < uptoCommon {
            rarity = .common
        } else if number < uptoUncommon {
            rarity = .uncommon
        } else if number < uptoRare {
            rarity = .rare
        } else {
            throw EidolonError.invalidBundle("抽奖概率之和不等于 100")
        }
        let pool = catalog.drawable(rarity)
        guard !pool.isEmpty else {
            throw EidolonError.invalidBundle(
                "礼物目录里稀有度 \(rarity.rawValue) 没有一件没下架的礼物，这一档抽不出东西"
            )
        }
        let index = random.int(below: pool.count)
        guard (0..<pool.count).contains(index) else {
            throw EidolonError.invalidBundle("抽奖随机源越界")
        }
        return .gift(pool[index])
    }
}

/// One character the gift page may give to, with how she feels now, never what she likes.
public struct GiftRecipient: Sendable, Hashable, Identifiable {
    public var characterID: String
    public var name: String
    public var tier: AffinityTier
    public var cooling: Bool

    public var id: String { characterID }
}

/// What giving a gift did: where it was recorded, how it changed her, and what is left.
public struct GiftGiven: Sendable, Hashable {
    public var gift: Gift
    public var characterID: String
    public var conversationID: String
    public var tier: AffinityTier
    /// Nil when nothing changed to show.
    public var change: AffinityChange?
    public var stillCooling: Bool
    public var remaining: Int
    public var rewards: [AchievementReward]
}

/// A character a reset card would bring back below trust, as the confirmation lists her.
public struct ResetCardTarget: Sendable, Hashable, Identifiable {
    public var characterID: String
    public var name: String
    public var tier: AffinityTier
    public var cooling: Bool

    public var id: String { characterID }
}

/// How the gift is written wherever it is spoken of: her chat, the roster's preview, and
/// the list of conversations.
public enum GiftText {
    public static func given(characterName: String, giftName: String?) -> String {
        "你送给\(characterName)一份\(giftName ?? "礼物")"
    }
}

/// What using a reset card did: who came back, and how many cards are left.
public struct ResetCardUse: Sendable, Hashable {
    public var restored: [ResetCardTarget]
    public var resetCardsLeft: Int
}

extension Eidolon {
    /// The characters the gift page lists, in the conversation list's order, with her tier
    /// and whether she is cooling; never her liked gifts.
    public func giftRecipients(now: Date = Date()) throws -> [GiftRecipient] {
        let ordered = ConversationOrder.byRecency(
            try characters(), latest: try latestActivities()
        )
        return try ordered.map { character in
            let status = try affinityStatus(characterID: character.id, now: now)
            return GiftRecipient(
                characterID: character.id,
                name: character.name,
                tier: status.tier,
                cooling: status.cooling
            )
        }
    }

    /// Gives the character one of the gift: taken from the backpack, raising her affinity
    /// as upstream `gifts.give` does, recorded as a `gift` conversation event, and counted
    /// towards the achievements, all in one transaction.
    public func giveGift(
        giftID: String,
        characterID: String,
        now: Date = Date()
    ) throws -> GiftGiven {
        guard let catalog = try giftCatalog() else { throw EidolonError.giftCatalogMissing }
        guard let gift = catalog.gift(id: giftID) else { throw EidolonError.noSuchGift }
        let characters = try characters()
        guard let character = characters.first(where: { $0.id == characterID }) else {
            throw EidolonError.invalidContent("找不到角色 \(characterID)")
        }
        let timeZone = try producerTimeZone()
        let warmed = try warms(gift, characterID: characterID, now: now, timeZone: timeZone)
        let liked = character.likedGifts.contains(giftID)
        return try userQueue.write { db in
            try db.execute(
                sql: "UPDATE gift_backpack SET count = count - 1 WHERE gift_id = ? AND count > 0",
                arguments: [giftID]
            )
            guard db.changesCount > 0 else { throw EidolonError.noSuchGift }
            let remaining = try Int.fetchOne(
                db,
                sql: "SELECT count FROM gift_backpack WHERE gift_id = ?",
                arguments: [giftID]
            ) ?? 0

            let before = try Self.readAffinity(db, characterID: characterID, now: now)
            let step = gift.coolingStep(
                affinityCooling: before.cooling,
                liked: liked,
                warmed: warmed
            )
            let after = before.raised(step, at: now)
            let change: AffinityChange?
            if before.cooling, !after.cooling {
                change = AffinityChange(
                    up: true,
                    tierChanged: after.tier != before.tier,
                    tier: after.tier,
                    cooldown: false,
                    thawed: true
                )
            } else if !after.cooling, after.value != before.value {
                change = AffinityChange(
                    up: after.value > before.value,
                    tierChanged: after.tier != before.tier,
                    tier: after.tier,
                    cooldown: after.cooling && !before.cooling
                )
            } else {
                change = nil
            }
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES (?, ?, ?, ?, 0, NULL)
                    ON CONFLICT(character_id) DO UPDATE SET
                        value = excluded.value, cooling = excluded.cooling,
                        updated_at = excluded.updated_at
                    """,
                arguments: [characterID, after.value, after.cooling ? 1 : 0, Self.timestamp(now)]
            )

            let conversationID: String
            let current = try Self.currentConversationID(db, characterID: characterID)
            let ended: String? = try current.flatMap {
                try String.fetchOne(
                    db,
                    sql: "SELECT ended_at FROM conversations WHERE id = ?",
                    arguments: [$0]
                )
            }
            if let current, ended == nil {
                conversationID = current
            } else {
                conversationID = UUID().uuidString
                try Self.insertConversation(
                    db,
                    id: conversationID,
                    characterID: characterID,
                    createdAt: Self.timestamp(now)
                )
            }
            let affinityJSON = change.flatMap { try? JSONEncoder().encode($0) }
                .map { String(decoding: $0, as: UTF8.self) }
            try db.execute(
                sql: """
                    INSERT INTO conversation_events
                        (conversation_id, kind, created_at, gift_id, liked, affinity)
                    VALUES (?, 'gift', ?, ?, ?, ?)
                    """,
                arguments: [
                    conversationID, Self.timestamp(now), giftID, liked ? 1 : 0, affinityJSON,
                ]
            )
            let rewards = try AchievementStore.keep(
                db,
                characterID: characterID,
                now: now,
                today: GiftRules.day(now),
                gifts: 1,
                tier: after.tier
            )
            return GiftGiven(
                gift: gift,
                characterID: characterID,
                conversationID: conversationID,
                tier: after.tier,
                change: change,
                stillCooling: after.cooling,
                remaining: remaining,
                rewards: rewards
            )
        }
    }

    /// Who a reset card would bring back now, in roster order, below trust and cooling or not.
    public func resetCardTargets(now: Date = Date()) throws -> [ResetCardTarget] {
        try characters().compactMap { character in
            let status = try affinityStatus(characterID: character.id, now: now)
            guard status.tier.start < AffinityTier.trust.start else { return nil }
            return ResetCardTarget(
                characterID: character.id,
                name: character.name,
                tier: status.tier,
                cooling: status.cooling
            )
        }
    }

    /// Uses one reset card, bringing every character below trust back to 50 and out of any
    /// cooldown, in one transaction; no one to bring back or no card leaves it unspent.
    public func useResetCard(now: Date = Date()) throws -> ResetCardUse {
        let characters = try characters()
        return try userQueue.write { db in
            let cards = try Int.fetchOne(
                db, sql: "SELECT reset_cards FROM gift_balances WHERE id = 1"
            ) ?? 0
            guard cards > 0 else { throw EidolonError.noResetCards }
            var restored: [ResetCardTarget] = []
            for character in characters {
                let affinity = try Self.readAffinity(
                    db, characterID: character.id, now: now
                )
                guard affinity.tier.start < AffinityTier.trust.start else { continue }
                restored.append(ResetCardTarget(
                    characterID: character.id,
                    name: character.name,
                    tier: affinity.tier,
                    cooling: affinity.cooling
                ))
                try db.execute(
                    sql: """
                        UPDATE affinities SET value = ?, updated_at = ?, cooling = 0
                        WHERE character_id = ?
                        """,
                    arguments: [AffinityRules.normal, Self.timestamp(now), character.id]
                )
            }
            guard !restored.isEmpty else { throw EidolonError.noOneToReset }
            try db.execute(
                sql: "UPDATE gift_balances SET reset_cards = reset_cards - 1 WHERE id = 1"
            )
            return ResetCardUse(restored: restored, resetCardsLeft: cards - 1)
        }
    }

    private func warms(
        _ gift: Gift,
        characterID: String,
        now: Date,
        timeZone: TimeZone
    ) throws -> Bool {
        guard gift.warm else { return false }
        return try herCycle(
            characterID: characterID,
            now: now,
            timeZone: timeZone
        ) != nil
    }

    private func producerTimeZone() throws -> TimeZone {
        try producerProfile().timezone.flatMap(TimeZone.init(identifier:)) ?? .current
    }
}

extension Gift {
    /// How much giving this gift raises her affinity: `COOLDOWN_GIFT_STEP` in a cooldown,
    /// else rarity plus liking and warmth (upstream `_gift_step`).
    func coolingStep(affinityCooling: Bool, liked: Bool, warmed: Bool) -> Double {
        if affinityCooling { return GiftRules.cooldownStep }
        return GiftRules.step(rarity) + (liked ? GiftRules.likedStep : 0)
            + (warmed ? GiftRules.warmStep : 0)
    }
}

/// The gift claiming rules shared by giving, achievements and the bar's draw.
enum GiftStore {
    /// Gives a reward once by its key: draw chances, over the day's cap, and reset cards.
    /// Whether it was given now.
    static func creditReward(
        _ db: Database,
        key: String,
        draws: Int,
        resetCards: Int,
        at now: Date
    ) throws -> Bool {
        try Eidolon.giveDueGiftDraws(db, at: now)
        try db.execute(
            sql: """
                INSERT INTO gift_rewards(key, draws, reset_cards, rewarded_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT DO NOTHING
                """,
            arguments: [key, draws, resetCards, Eidolon.timestamp(now)]
        )
        guard db.changesCount > 0 else { return false }
        try db.execute(
            sql: """
                UPDATE gift_balances
                SET draws = draws + ?, reset_cards = reset_cards + ?
                WHERE id = 1
                """,
            arguments: [draws, resetCards]
        )
        return true
    }

    /// The bar's first visit done gives one draw, held to the day's most: only if it was
    /// under the cap when the visit finished, recorded once by its key.
    static func creditBarDraw(_ db: Database, key: String, at now: Date) throws -> Bool {
        try Eidolon.giveDueGiftDraws(db, at: now)
        let draws = try Int.fetchOne(
            db, sql: "SELECT draws FROM gift_balances WHERE id = 1"
        ) ?? 0
        guard draws < GiftRules.maxDraws else { return false }
        return try creditReward(db, key: key, draws: 1, resetCards: 0, at: now)
    }
}
