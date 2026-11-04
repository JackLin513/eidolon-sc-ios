import Foundation
import GRDB

/// The range the stats page sums over (spec #96; upstream `Range`), today the last day.
public enum StatsRange: String, Codable, Sendable, CaseIterable, Hashable {
    case thirtyDays = "30d"
    case year = "1y"
    case all

    public var title: String {
        switch self {
        case .thirtyDays: "近 30 天"
        case .year: "近一年"
        case .all: "全部"
        }
    }

    var days: Int? {
        switch self {
        case .thirtyDays: 30
        case .year: 365
        case .all: nil
        }
    }
}

public struct StatsHeatmapDay: Sendable, Hashable, Identifiable {
    public var day: CalendarDay
    public var count: Int

    public var id: String { day.stamp }
}

public struct StatsAffinityGroup: Sendable, Hashable, Identifiable {
    public var tier: AffinityTier
    public var characterIDs: [String]

    public var id: String { tier.rawValue }
}

public struct StatsAchievements: Sendable, Hashable {
    /// How many stages are unlocked, as the achievements keep them.
    public var stages: Int
    /// How many characters have every stage.
    public var completedCharacters: Int

    public init(stages: Int, completedCharacters: Int) {
        self.stages = stages
        self.completedCharacters = completedCharacters
    }
}

public struct StatsCharacterSummary: Sendable, Hashable, Identifiable {
    public var characterID: String
    public var turns: Int
    public var callSeconds: Double
    public var daysKnown: Int

    public var id: String { characterID }
}

public struct StatsGiftKind: Sendable, Hashable, Identifiable {
    public var giftID: String
    public var given: Int
    public var liked: Int

    public var id: String { giftID }
}

public struct StatsGiftSummary: Sendable, Hashable {
    public var given: Int
    public var liked: Int
    public var mostCharacterID: String?
    public var mostGiven: Int
    /// The gifts given in the range, most often first.
    public var kinds: [StatsGiftKind]

    public init(
        given: Int, liked: Int, mostCharacterID: String?, mostGiven: Int,
        kinds: [StatsGiftKind] = []
    ) {
        self.given = given
        self.liked = liked
        self.mostCharacterID = mostCharacterID
        self.mostGiven = mostGiven
        self.kinds = kinds
    }
}

/// What changes with the range (spec #96; upstream `in_range`).
public struct StatsRangeSummary: Sendable, Hashable {
    public var range: StatsRange
    public var turns: Int
    /// How many contacts at each hour, 0–23, in the producer's zone.
    public var byHour: [Int]
    public var calls: Int
    public var callSeconds: Double
    public var gifts: StatsGiftSummary
    /// Every character with anything still left, in the idols' order.
    public var characters: [StatsCharacterSummary]
}

/// What the stats page reads in one go (spec #96). Dates and hours are the producer's.
public struct StatsSummary: Sendable, Hashable {
    /// Days since the first thing still left, counting its day as the first; 0 when
    /// nothing is left.
    public var daysKnown: Int
    /// Days in a row the producer came, up to today or yesterday while today is not one.
    public var currentVisitStreak: Int
    public var longestVisitStreak: Int
    /// The whole weeks before this one, from a Monday, and this week up to today.
    public var heatmap: [StatsHeatmapDay]
    /// Every character by her current tier, cold to intimate, in the idols' order.
    public var affinity: [StatsAffinityGroup]
    public var achievements: StatsAchievements
    public var range: StatsRangeSummary
    /// Whether any turn or gift is still left; when false the page shows one empty line.
    public var hasContacts: Bool
}

extension Eidolon {
    private struct ContactRow {
        var characterID: String
        var at: Date
        var kind: String
        var liked: Bool
        var giftID: String?
    }

    private struct CallRow {
        var characterID: String
        var at: Date
        var seconds: Double
    }

    /// The producer's own dealings with the characters (spec #96; upstream `stats.py`).
    /// Only what is still in the conversations counts: a user message or a gift event.
    public func statsSummary(
        range: StatsRange,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> StatsSummary {
        let characters = try characters()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = Self.calendarDay(now, in: timeZone)
        let start = range.days.map { days in
            Self.calendarDay(
                calendar.date(byAdding: .day, value: -(days - 1), to: now) ?? now,
                in: timeZone
            )
        }

        // Affinity recovers with time, so each is read as of now.
        let tiers = try characters.map { character in
            let affinity = try readAffinity(characterID: character.id, now: now)
            return (character.id, affinity.cooling ? AffinityTier.cold : affinity.tier)
        }

        let rows = try userQueue.read { db -> (contacts: [ContactRow], calls: [CallRow], first: Date?, firstByCharacter: [String: Date], achievements: StatsAchievements) in
            let contactRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.character_id AS character_id, m.created_at AS at,
                           'turn' AS kind, 0 AS liked, NULL AS gift_id
                    FROM messages m
                    JOIN conversations c ON c.id = m.conversation_id
                    WHERE m.role = 'user'
                    UNION ALL
                    SELECT c.character_id, e.created_at, 'gift', COALESCE(e.liked, 0), e.gift_id
                    FROM conversation_events e
                    JOIN conversations c ON c.id = e.conversation_id
                    WHERE e.kind = 'gift'
                    """
            ).compactMap { row -> ContactRow? in
                guard let at = Self.parseTimestamp(row["at"]) else { return nil }
                return ContactRow(
                    characterID: row["character_id"], at: at, kind: row["kind"],
                    liked: (row["liked"] as Int) == 1, giftID: row["gift_id"]
                )
            }
            let callRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.character_id AS character_id, k.connected_at AS at,
                           COALESCE(k.duration_s, 0) AS seconds
                    FROM call_ends k
                    JOIN conversations c ON c.id = k.conversation_id
                    WHERE k.connected_at IS NOT NULL
                    """
            ).compactMap { row -> CallRow? in
                guard let at = Self.parseTimestamp(row["at"]) else { return nil }
                return CallRow(
                    characterID: row["character_id"], at: at, seconds: row["seconds"]
                )
            }
            let firstRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT character_id, MIN(at) AS first FROM (
                        SELECT c.character_id AS character_id, m.created_at AS at
                        FROM messages m JOIN conversations c ON c.id = m.conversation_id
                        UNION ALL
                        SELECT c.character_id, e.created_at
                        FROM conversation_events e
                        JOIN conversations c ON c.id = e.conversation_id
                        UNION ALL
                        SELECT c.character_id, k.connected_at
                        FROM call_ends k
                        JOIN conversations c ON c.id = k.conversation_id
                        WHERE k.connected_at IS NOT NULL
                    ) GROUP BY character_id
                    """
            )
            var firstByCharacter: [String: Date] = [:]
            var first: Date?
            for row in firstRows {
                guard let at = Self.parseTimestamp(row["first"]) else { continue }
                firstByCharacter[row["character_id"]] = at
                if first == nil || at < first! { first = at }
            }
            let stages = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM achievement_stages"
            ) ?? 0
            let complete = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM achievement_progress WHERE achievement = 'complete'"
            ) ?? 0
            return (
                contactRows, callRows, first, firstByCharacter,
                StatsAchievements(stages: stages, completedCharacters: complete)
            )
        }

        let contactDays = Set(rows.contacts.map { Self.calendarDay($0.at, in: timeZone) })
        let daysKnown = rows.first.map { max(1, today.days(since: Self.calendarDay($0, in: timeZone)) + 1) } ?? 0
        let visits = Self.visits(contactDays, today: today)

        let heatmapStart = today.adding(days: -(today.weekdayIndex + 7 * 52))
        let countsByDay = Dictionary(grouping: rows.contacts, by: {
            Self.calendarDay($0.at, in: timeZone)
        }).mapValues(\.count)
        var heatmap: [StatsHeatmapDay] = []
        var heatmapDay = heatmapStart
        while heatmapDay <= today {
            heatmap.append(
                StatsHeatmapDay(day: heatmapDay, count: countsByDay[heatmapDay] ?? 0)
            )
            heatmapDay = heatmapDay.adding(days: 1)
        }

        let within = rows.contacts.filter {
            let day = Self.calendarDay($0.at, in: timeZone)
            guard day <= today else { return false }
            return start.map { day >= $0 } ?? true
        }
        let callsWithin = rows.calls.filter {
            let day = Self.calendarDay($0.at, in: timeZone)
            guard day <= today else { return false }
            return start.map { day >= $0 } ?? true
        }

        var byHour = Array(repeating: 0, count: 24)
        for contact in within {
            var zoneCalendar = Calendar(identifier: .gregorian)
            zoneCalendar.timeZone = timeZone
            byHour[zoneCalendar.component(.hour, from: contact.at)] += 1
        }

        let gifts = within.filter { $0.kind == "gift" }
        let giftCounts = Dictionary(grouping: gifts, by: \.characterID).mapValues(\.count)
        let most = giftCounts.values.max() ?? 0
        let mostCharacter = most > 0
            ? characters.map(\.id).first { giftCounts[$0] == most }
            : nil
        let namedGifts: [ContactRow] = gifts.filter { $0.giftID != nil }
        let giftsByName: [String: [ContactRow]] = Dictionary(
            grouping: namedGifts, by: { $0.giftID ?? "" }
        )
        var giftKinds: [StatsGiftKind] = []
        for (giftID, rows) in giftsByName {
            giftKinds.append(
                StatsGiftKind(
                    giftID: giftID, given: rows.count, liked: rows.filter(\.liked).count
                )
            )
        }
        giftKinds.sort {
            $0.given == $1.given ? $0.giftID < $1.giftID : $0.given > $1.given
        }

        let turns = within.filter { $0.kind == "turn" }
        let turnsByCharacter = Dictionary(grouping: turns, by: \.characterID).mapValues(\.count)
        let callSeconds = callsWithin.reduce(into: [String: Double]()) {
            $0[$1.characterID, default: 0] += $1.seconds
        }
        let characterRows = characters.compactMap { character -> StatsCharacterSummary? in
            guard let first = rows.firstByCharacter[character.id] else { return nil }
            return StatsCharacterSummary(
                characterID: character.id,
                turns: turnsByCharacter[character.id] ?? 0,
                callSeconds: callSeconds[character.id] ?? 0,
                daysKnown: max(1, today.days(since: Self.calendarDay(first, in: timeZone)) + 1)
            )
        }

        var groups: [AffinityTier: [String]] = [:]
        for (id, tier) in tiers {
            groups[tier, default: []].append(id)
        }
        let affinity = AffinityTier.allCases.map {
            StatsAffinityGroup(tier: $0, characterIDs: groups[$0] ?? [])
        }

        return StatsSummary(
            daysKnown: daysKnown,
            currentVisitStreak: visits.current,
            longestVisitStreak: visits.longest,
            heatmap: heatmap,
            affinity: affinity,
            achievements: rows.achievements,
            range: StatsRangeSummary(
                range: range,
                turns: turns.count,
                byHour: byHour,
                calls: callsWithin.count,
                callSeconds: callsWithin.reduce(0) { $0 + $1.seconds },
                gifts: StatsGiftSummary(
                    given: gifts.count,
                    liked: gifts.filter(\.liked).count,
                    mostCharacterID: mostCharacter,
                    mostGiven: most,
                    kinds: giftKinds
                ),
                characters: characterRows
            ),
            hasContacts: !rows.contacts.isEmpty
        )
    }

    /// Days in a row the producer came (upstream `visits`): the run up to today, or up to
    /// yesterday while today is not one of them yet, and the longest.
    static func visits(
        _ days: Set<CalendarDay>, today: CalendarDay
    ) -> (current: Int, longest: Int) {
        var longest = 0
        var run = 0
        var previous: CalendarDay?
        for day in days.filter({ $0 <= today }).sorted() {
            run = previous.map { $0.adding(days: 1) == day } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = day
        }
        var current = 0
        var day = days.contains(today) ? today : today.adding(days: -1)
        while days.contains(day) {
            current += 1
            day = day.adding(days: -1)
        }
        return (current, longest)
    }
}
