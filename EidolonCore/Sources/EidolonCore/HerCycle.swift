import CryptoKit
import Foundation
import GRDB

/// Where her cycle has her on a day (GLOSSARY.md「周期」): in her period, premenstrual, or
/// neither. Derived from her seed and the day alone, as upstream `her_cycle`; every constant
/// is frozen, so a stored seed always tells the same story.
public struct HerPeriod: Sendable, Hashable {
    public var day: Int
    public var length: Int
    public var firstDay: CalendarDay

    public init(day: Int, length: Int, firstDay: CalendarDay) {
        self.day = day
        self.length = length
        self.firstDay = firstDay
    }
}

public struct Premenstrual: Sendable, Hashable {
    public var daysLeft: Int

    public init(daysLeft: Int) {
        self.daysLeft = daysLeft
    }
}

public enum HerCycleDay: Sendable, Hashable {
    case period(HerPeriod)
    case premenstrual(Premenstrual)
}

/// What is drawn once for her from her seed.
public struct CycleRhythm: Sendable, Hashable {
    public var baseCycle: Int
    public var basePeriod: Int
    public var premenstrualDays: Int
    public var offset: Int

    public init(baseCycle: Int, basePeriod: Int, premenstrualDays: Int, offset: Int) {
        self.baseCycle = baseCycle
        self.basePeriod = basePeriod
        self.premenstrualDays = premenstrualDays
        self.offset = offset
    }
}

public enum HerCycle {
    /// Where her first cycle (the 0th) is counted back from. Frozen.
    public static let epoch = CalendarDay(year: 2026, month: 1, day: 1)
    public static let adultAge = 18
    public static let shortestPeriod = 3
    public static let longestPeriod = 8
    public static let shortestCycle = 21
    public static let longestCycle = 40
    public static let premenstrualChoices = [3, 4, 5]

    private static let baseCycles = [
        (25, 3), (26, 6), (27, 12), (28, 20), (29, 20),
        (30, 14), (31, 10), (32, 7), (33, 5), (34, 3),
    ]
    private static let basePeriods = [(4, 20), (5, 40), (6, 28), (7, 12)]
    private static let periodStrays = [(-1, 25), (0, 50), (1, 25)]
    private static let adultStrays = [
        (-3, 5), (-2, 10), (-1, 20), (0, 30), (1, 20), (2, 10), (3, 5),
    ]
    private static let youngStrays = [
        (-5, 3), (-4, 5), (-3, 7), (-2, 10), (-1, 15), (0, 20),
        (1, 15), (2, 10), (3, 7), (4, 5), (5, 3),
    ]

    /// A missing or invalid age is an adult's. Under 18, her cycles stray more.
    public static func isUnder18(_ age: Int?) -> Bool {
        guard let age else { return false }
        return age > 0 && age < adultAge
    }

    /// What her seed draws once.
    public static func rhythm(seed: Data) -> CycleRhythm {
        let baseCycle = weighted(seed, "base cycle", 0, baseCycles)
        return CycleRhythm(
            baseCycle: baseCycle,
            basePeriod: weighted(seed, "base period", 0, basePeriods),
            premenstrualDays: premenstrualChoices[
                Int(number(seed, "premenstrual", 0) % UInt64(premenstrualChoices.count))
            ],
            offset: Int(number(seed, "offset", 0) % UInt64(baseCycle))
        )
    }

    /// Where her cycle has her on `day`; nil in her other days.
    public static func day(seed: Data, under18: Bool, on day: CalendarDay) -> HerCycleDay? {
        let drawn = rhythm(seed: seed)
        var first = epoch.adding(days: -drawn.offset)
        var k = 0
        while day < first {
            k -= 1
            first = first.adding(days: -length(seed, under18: under18, drawn: drawn, k: k))
        }
        while true {
            let length = length(seed, under18: under18, drawn: drawn, k: k)
            let period = period(seed, drawn: drawn, k: k)
            let into = day.days(since: first)
            if into < period {
                return .period(HerPeriod(day: into + 1, length: period, firstDay: first))
            }
            if into < length {
                let daysLeft = length - into
                guard daysLeft <= drawn.premenstrualDays else { return nil }
                return .premenstrual(Premenstrual(daysLeft: daysLeft))
            }
            first = first.adding(days: length)
            k += 1
        }
    }

    /// The cycle lengths of her next `count` cycles from the one `day` is in, for tests and
    /// the records page later.
    public static func cycles(
        seed: Data, under18: Bool, from day: CalendarDay = epoch, count: Int
    ) -> [(firstDay: CalendarDay, length: Int, period: Int)] {
        let drawn = rhythm(seed: seed)
        var first = epoch.adding(days: -drawn.offset)
        var k = 0
        while day < first {
            k -= 1
            first = first.adding(days: -length(seed, under18: under18, drawn: drawn, k: k))
        }
        return (0..<count).map { step in
            let cycle = (
                firstDay: first,
                length: length(seed, under18: under18, drawn: drawn, k: k + step),
                period: period(seed, drawn: drawn, k: k + step)
            )
            first = first.adding(days: cycle.length)
            return cycle
        }
    }

    private static func length(
        _ seed: Data, under18: Bool, drawn: CycleRhythm, k: Int
    ) -> Int {
        let strays = under18 ? youngStrays : adultStrays
        let length = drawn.baseCycle + weighted(seed, "cycle", k, strays)
        return min(max(length, shortestCycle), longestCycle)
    }

    private static func period(_ seed: Data, drawn: CycleRhythm, k: Int) -> Int {
        let period = drawn.basePeriod + weighted(seed, "period", k, periodStrays)
        return min(max(period, shortestPeriod), longestPeriod)
    }

    private static func weighted(
        _ seed: Data, _ what: String, _ k: Int, _ weights: [(Int, Int)]
    ) -> Int {
        var point = Int(number(seed, what, k) % 100)
        for (value, weight) in weights {
            if point < weight { return value }
            point -= weight
        }
        return weights[weights.count - 1].0
    }

    /// SHA-256 of the seed and what is drawn, its first eight bytes big-endian. Frozen.
    private static func number(_ seed: Data, _ what: String, _ k: Int) -> UInt64 {
        var message = seed
        message.append(Data("\n\(what)\n\(k)".utf8))
        let digest = SHA256.hash(data: message)
        var value: UInt64 = 0
        for byte in digest.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value
    }

    /// A new 32-byte seed, kept for this character on this device.
    static func newSeed() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

/// What she is told of where her cycle has her (upstream `cycles.cycle_lines`): how she feels,
/// then how she keeps it to herself; nothing on her other days.
public enum CyclePrompt {
    static let periodEarly = "你今天身体很不舒服：浑身没力气，说话比平时少、慢，偶尔会走神。"
        + "身上可能发冷、腰酸、身子发沉、只想窝着不动，喝点热的会好些。"
    static let periodLate = "你这几天身体还有点虚：比平时容易累，不太想出门，不过已经比前两天好多了。"
    static let premenstrualFar = "你这几天心情有点起伏：比平时敏感，小事也容易在意。"
    static let premenstrualNear = "你这两天特别容易烦躁、委屈，小事也会在意很久，自己也说不清为什么心情不好；"
        + "身上也可能有点发胀、睡不踏实。"
    static let unsaid = "这是你自己身体的事，你不会说出经期、月经、生理期这些词，也不提出血、卫生用品这类细节；"
        + "只让状态自然地流露在语气和小事里。制作人问起时，照你的性格含糊带过（比如说有点累、没睡好）。"
    static let askedInPeriod = "制作人直接问到是不是那几天时，照你的性格决定认不认：可以含糊地认下，也可以岔开，"
        + "或者嫌他问得太直接；认的话也用你自己的说法，不说出那个词，也不细讲。"
    static let askedBefore = "那几天还没到，只是快了；制作人直接问到时，照你的性格决定怎么应：可以含糊地说快了，"
        + "也可以岔开，或者嫌他问得太直接；不说出那个词，也不细讲。"
    static let stillHerself = "不舒服不是冲制作人发火的理由，也不拿它要挟或讨好处；工作照常，人设里的规则照旧。"
        + "身上的不适一次最多顺口带出一样，换着说，不要每次都提同一样，也不逐条描述身体。"

    public static func lines(_ day: HerCycleDay?) -> [String] {
        switch day {
        case let .period(period):
            let feeling = period.day <= 2 ? periodEarly : periodLate
            return [feeling, unsaid + askedInPeriod + stillHerself]
        case let .premenstrual(premenstrual):
            let feeling = premenstrual.daysLeft <= 2 ? premenstrualNear : premenstrualFar
            return [feeling, unsaid + askedBefore + stillHerself]
        case nil:
            return []
        }
    }
}

// MARK: - Her seed and switch in the user library

extension Eidolon {
    /// Whether cycles are on for this device; on until switched off.
    public func cycleEnabled() throws -> Bool {
        try userQueue.read { db in
            let off = try Int.fetchOne(
                db, sql: "SELECT enabled FROM cycle_settings WHERE id = 1"
            )
            return off != 0
        }
    }

    /// Switches cycles for every character on this device. Off only hides the lines; her
    /// cycle goes on from the same seed.
    public func setCycleEnabled(_ on: Bool) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO cycle_settings(id, enabled) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET enabled = excluded.enabled
                    """,
                arguments: [on]
            )
        }
    }

    /// Her seed, made and kept the first time it is needed; nil for a character the bundle
    /// no longer has.
    public func cycleSeed(characterID: String) throws -> Data? {
        guard try characters().contains(where: { $0.id == characterID }) else { return nil }
        return try userQueue.write { db in
            if let seed = try Data.fetchOne(
                db, sql: "SELECT seed FROM cycle_seeds WHERE character_id = ?",
                arguments: [characterID]
            ) {
                return seed
            }
            let seed = HerCycle.newSeed()
            try db.execute(
                sql: "INSERT INTO cycle_seeds(character_id, seed) VALUES (?, ?)",
                arguments: [characterID, seed]
            )
            return seed
        }
    }

    /// Where her cycle has her now for the producer's day, or nil when cycles are off or
    /// she is in neither.
    public func herCycle(
        characterID: String, now: Date = Date(), timeZone: TimeZone
    ) throws -> HerCycleDay? {
        guard try cycleEnabled() else { return nil }
        let characters = try characters()
        guard let character = characters.first(where: { $0.id == characterID }) else {
            return nil
        }
        guard let seed = try cycleSeed(characterID: characterID) else { return nil }
        let age = character.raw["age"]?.intValue
        let day = CalendarPage.today(now: now, timeZone: timeZone)
        return HerCycle.day(
            seed: seed, under18: HerCycle.isUnder18(age), on: day
        )
    }

    /// What her prompt is told of her cycle; none when cycles are off or on her other days.
    public func cycleLines(
        characterID: String, now: Date = Date(), timeZone: TimeZone
    ) throws -> [String] {
        CyclePrompt.lines(try herCycle(characterID: characterID, now: now, timeZone: timeZone))
    }
}
