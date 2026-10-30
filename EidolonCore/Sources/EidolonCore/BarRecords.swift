import Foundation
import GRDB

/// One of the bar's visits done, as it is kept (GLOSSARY.md「光顾」; ADR-0021, upstream's
/// `visit_records`): who came, when she came in and left, why and about what, each order,
/// whether she got drunk, and whether the visit was rewarded. Nothing of what was said.
public struct VisitRecord: Sendable, Hashable {
    public var id: Int64
    public var characterID: String
    public var enteredAt: Date
    public var leftAt: Date
    /// The device's day she came in on, `yyyy-MM-dd`.
    public var enteredOn: String
    public var reason: String
    public var topic: String
    /// Each order, as it was served.
    public var orders: [Had]
    public var drunk: Bool
    /// Whether the visit was the day's first rewarded.
    public var rewarded: Bool

    public init(
        id: Int64,
        characterID: String,
        enteredAt: Date,
        leftAt: Date,
        enteredOn: String,
        reason: String,
        topic: String,
        orders: [Had],
        drunk: Bool,
        rewarded: Bool
    ) {
        self.id = id
        self.characterID = characterID
        self.enteredAt = enteredAt
        self.leftAt = leftAt
        self.enteredOn = enteredOn
        self.reason = reason
        self.topic = topic
        self.orders = orders
        self.drunk = drunk
        self.rewarded = rewarded
    }
}

/// What is read of a user's visits done before one comes in (upstream `_Before`): whether
/// one was done on the day, and how many with anyone.
public struct BarBefore: Sendable, Hashable {
    public var doneToday: Bool
    public var visitsDone: Int

    public init(doneToday: Bool, visitsDone: Int) {
        self.doneToday = doneToday
        self.visitsDone = visitsDone
    }
}

/// What is read of her visits with the user before she comes in (upstream `_Hers`): what
/// she remembers of the last, and the reasons and topics of the latest
/// `BarVisits.recentVisits`, which she is not to come in on again.
public struct BarHistory: Sendable, Hashable {
    public var remembered: BarPrompt.Remembered
    public var reasons: [String]
    public var topics: [String]

    public init(
        remembered: BarPrompt.Remembered = .init(), reasons: [String] = [], topics: [String] = []
    ) {
        self.remembered = remembered
        self.reasons = reasons
        self.topics = topics
    }
}

/// The bar's records in the user library (schema 8, `bar_visits`), and what is read of
/// them before a visit, in it and after it.
enum BarRecords {
    // MARK: - Reading

    /// The visits done with anyone, oldest first.
    static func all(_ db: Database) throws -> [VisitRecord] {
        try Row.fetchAll(db, sql: "SELECT * FROM bar_visits ORDER BY id").map(record)
    }

    /// How many visits were done, with anyone.
    static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bar_visits") ?? 0
    }

    /// Whether a visit done came in on `day` (the device's, `yyyy-MM-dd`).
    static func doneOn(_ db: Database, day: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: "SELECT EXISTS (SELECT 1 FROM bar_visits WHERE entered_on = ?)",
            arguments: [day]
        ) ?? false
    }

    /// Whether one was done on `today`, and how many with anyone.
    static func before(_ db: Database, today: String) throws -> BarBefore {
        BarBefore(doneToday: try doneOn(db, day: today), visitsDone: try count(db))
    }

    /// What she remembers of her visits with the user before this one, and the reasons and
    /// topics of the latest `BarVisits.recentVisits` of them, latest first.
    static func history(_ db: Database, characterID: String) throws -> BarHistory {
        let visits = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM bar_visits WHERE character_id = ?",
            arguments: [characterID]
        ) ?? 0
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM bar_visits WHERE character_id = ?
                ORDER BY id DESC LIMIT ?
                """,
            arguments: [characterID, BarVisits.recentVisits]
        )
        guard let first = rows.first else { return BarHistory() }
        let last = try record(first)
        return BarHistory(
            remembered: BarPrompt.Remembered(
                visits: visits, lastLeftAt: last.leftAt,
                lastOrders: last.orders, lastDrunk: last.drunk
            ),
            reasons: rows.map { $0["reason"] },
            topics: rows.map { $0["topic"] }
        )
    }

    // MARK: - Writing

    /// One visit written down: its row's identifier.
    @discardableResult
    static func insert(
        _ db: Database,
        characterID: String,
        enteredAt: Date,
        leftAt: Date,
        enteredOn: String,
        reason: String,
        topic: String,
        servings: [Serving],
        drunk: Bool,
        rewarded: Bool
    ) throws -> Int64 {
        let orders = servings.map {
            Had(
                target: $0.order.target.id, phrasing: $0.order.phrasing,
                served: $0.served.drink.id, big: $0.served.big, tier: $0.tier
            )
        }
        try db.execute(
            sql: """
                INSERT INTO bar_visits(character_id, entered_at, left_at, entered_on, reason,
                                       topic, orders, drunk, rewarded)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [
                characterID, Eidolon.timestamp(enteredAt), Eidolon.timestamp(leftAt), enteredOn,
                reason, topic, try Self.ordersJSON(orders), drunk ? 1 : 0, rewarded ? 1 : 0,
            ]
        )
        return db.lastInsertedRowID
    }

    /// The visit written down, done `now`, and rewarded if `rewarding` and it is the user's
    /// first done of the day it came in on: what it was rewarded with, or nil (upstream
    /// `Bar._write_down`).
    ///
    /// Upstream gives a draw and keeps it within the day's most; the app has no gifts or draws
    /// (ADR-0021), so the reward is her affinity alone and the row says it was rewarded.
    static func writeDown(
        _ visit: BarVisit, leftAt now: Date, day: String, rewarding: Bool,
        catalog: DrinkCatalog, _ db: Database
    ) throws -> Reward? {
        var reward: Reward?
        if rewarding, try doneOn(db, day: day) == false {
            let step = AffinityRules.visitDone(try visit.servings.map { serving in
                (serving.tier, try BarRules.hasBest(serving.order, visit.character, catalog))
            })
            reward = Reward(affinityUp: try raiseAffinity(
                visit.character.id, by: step, at: now, db
            ))
        }
        try insert(
            db, characterID: visit.character.id, enteredAt: visit.enteredAt, leftAt: now,
            enteredOn: day, reason: visit.reason.id, topic: visit.topic.id,
            servings: visit.servings, drunk: visit.drunk, rewarded: reward != nil
        )
        return reward
    }

    /// Forgets every visit done, and what was looked up for them. What was said was never
    /// kept; her affinity stays as it is.
    static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM bar_visits")
        try db.execute(sql: "DELETE FROM app_state WHERE key LIKE 'bar.facts.%'")
    }

    // MARK: - Rewarding

    /// Raises her affinity by `step`, in a cooldown too, as a gift does (upstream
    /// `Affinities._raise`): beyond the day's gains, and out of a cooldown only at the thaw
    /// line. Whether it rose: not if it was as high as it goes.
    private static func raiseAffinity(
        _ characterID: String, by step: Double, at now: Date, _ db: Database
    ) throws -> Bool {
        let before = try Eidolon.readAffinity(db, characterID: characterID, now: now)
        let after = before.stepped(max(step, 0)).recovered(now: now)
        try db.execute(
            sql: """
                INSERT INTO affinities(character_id, value, updated_at, cooling, gained_today,
                                       gained_on)
                VALUES (?, ?, ?, ?, 0, NULL)
                ON CONFLICT(character_id) DO UPDATE SET
                    value = excluded.value, updated_at = excluded.updated_at,
                    cooling = excluded.cooling
                """,
            arguments: [characterID, after.value, Eidolon.timestamp(now), after.cooling ? 1 : 0]
        )
        return after.value > before.value
    }

    // MARK: - Private

    private static func record(_ row: Row) throws -> VisitRecord {
        let entered = Eidolon.parseTimestamp(row["entered_at"]) ?? Date(timeIntervalSince1970: 0)
        let left = Eidolon.parseTimestamp(row["left_at"]) ?? entered
        return VisitRecord(
            id: row["id"],
            characterID: row["character_id"],
            enteredAt: entered,
            leftAt: left,
            enteredOn: row["entered_on"],
            reason: row["reason"],
            topic: row["topic"],
            orders: try decodeOrders(row["orders"]),
            drunk: (row["drunk"] as Int) == 1,
            rewarded: (row["rewarded"] as Int) == 1
        )
    }

    private struct OrderJSON: Codable {
        var target: String
        var phrasing: Phrasing
        var served: String
        var big: Bool
        var tier: Tier
    }

    private static func ordersJSON(_ orders: [Had]) throws -> String {
        let encoded = orders.map {
            OrderJSON(
                target: $0.target, phrasing: $0.phrasing, served: $0.served, big: $0.big,
                tier: $0.tier
            )
        }
        return String(decoding: try! JSONEncoder().encode(encoded), as: UTF8.self)
    }

    private static func decodeOrders(_ text: String) throws -> [Had] {
        try JSONDecoder().decode([OrderJSON].self, from: Data(text.utf8)).map {
            Had(target: $0.target, phrasing: $0.phrasing, served: $0.served, big: $0.big, tier: $0.tier)
        }
    }

    /// `yyyy-MM-dd` of the device's day `moment` falls on, as the records key it.
    static func day(_ moment: Date, in timeZone: TimeZone = .current) -> String {
        BarDates.day(of: moment, in: timeZone)
    }
}
