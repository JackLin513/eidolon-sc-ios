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
            return GiftDraw(results: results, drawsLeft: left, resetCards: resetCards)
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
