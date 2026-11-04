import Foundation
import GRDB

/// One stage of an achievement: reached at `goal`, giving `draws` draw chances.
public struct AchievementStage: Sendable, Hashable, Identifiable {
    public let number: Int
    public let goal: Int
    public let draws: Int
    /// When it was unlocked; nil while it has not been.
    public let unlockedAt: String?
    /// Whether the producer has not looked at it yet.
    public let isNew: Bool

    public var id: Int { number }

    public init(number: Int, goal: Int, draws: Int, unlockedAt: String?, isNew: Bool) {
        self.number = number
        self.goal = goal
        self.draws = draws
        self.unlockedAt = unlockedAt
        self.isNew = isNew
    }
}

/// What an achievement counts (upstream `achievements.py`).
public enum AchievementID: String, Sendable, CaseIterable, Hashable, Identifiable {
    case turns
    case callTime = "call_time"
    case gifts
    case tier
    case characters
    case intimateCharacters = "intimate_characters"
    case days
    case draws

    public var id: String { rawValue }

    /// The four of hers, in her panel's order.
    public static let perCharacter: [AchievementID] = [.turns, .callTime, .gifts, .tier]
    /// The four of everyone together, in the play page's order.
    public static let allCharacters: [AchievementID] = [
        .characters, .intimateCharacters, .days, .draws,
    ]

    public var title: String {
        switch self {
        case .turns: "和她说话"
        case .callTime: "和她通话"
        case .gifts: "送她的礼物"
        case .tier: "到过的关系"
        case .characters: "往来过的角色"
        case .intimateCharacters: "到过亲密的角色"
        case .days: "来过的天数"
        case .draws: "抽过的奖"
        }
    }

    public var goals: [Int] {
        switch self {
        case .turns: [10, 100, 300, 1_000, 3_000]
        case .callTime: [10 * 60, 60 * 60, 5 * 60 * 60, 20 * 60 * 60]
        case .gifts: [1, 10, 30, 100]
        case .tier: [1, 2]
        case .characters: [3, 10, 29]
        case .intimateCharacters: [1, 3, 10]
        case .days: [7, 30, 100, 365]
        case .draws: [10, 50, 200, 500]
        }
    }
}

/// One achievement as a panel shows it.
public struct AchievementProgress: Sendable, Hashable, Identifiable {
    public let id: AchievementID
    /// How far it has come: seconds for call time, a rank for the tier reached, else a count.
    public let progress: Double
    public let stages: [AchievementStage]

    public init(id: AchievementID, progress: Double, stages: [AchievementStage]) {
        self.id = id
        self.progress = progress
        self.stages = stages
    }

    public var title: String { id.title }

    public var unlockedCount: Int { stages.filter { $0.unlockedAt != nil }.count }

    public var next: AchievementStage? { stages.first { $0.unlockedAt == nil } }

    public var isNew: Bool { stages.contains(where: \.isNew) }

    /// The progress as the panel writes it, in the achievement's own unit.
    public var progressText: String {
        AchievementText.value(id, progress)
    }

    /// What the next stage asks for; nil once every stage is unlocked.
    public var nextGoalText: String? {
        next.map { AchievementText.value(id, Double($0.goal)) }
    }
}

/// Her four achievements, and whether every stage of all four has been unlocked.
public struct HerAchievements: Sendable, Hashable {
    public let achievements: [AchievementProgress]
    public let completedAt: String?

    public init(achievements: [AchievementProgress], completedAt: String?) {
        self.achievements = achievements
        self.completedAt = completedAt
    }

    public var isComplete: Bool { completedAt != nil }
    public var isNew: Bool { achievements.contains(where: \.isNew) }
}

/// The four achievements of everyone together.
public struct AllAchievements: Sendable, Hashable {
    public let achievements: [AchievementProgress]

    public init(achievements: [AchievementProgress]) {
        self.achievements = achievements
    }

    public var isNew: Bool { achievements.contains(where: \.isNew) }
}

/// A reward an achievement unlocked: draw chances, or a reset card for a character completed.
public struct AchievementReward: Sendable, Hashable {
    public let achievement: AchievementID?
    public let characterID: String?
    public let stage: Int?
    public let draws: Int
    public let resetCards: Int
    public let completedCharacterID: String?

    public init(
        achievement: AchievementID? = nil,
        characterID: String? = nil,
        stage: Int? = nil,
        draws: Int = 0,
        resetCards: Int = 0,
        completedCharacterID: String? = nil
    ) {
        self.achievement = achievement
        self.characterID = characterID
        self.stage = stage
        self.draws = draws
        self.resetCards = resetCards
        self.completedCharacterID = completedCharacterID
    }

    /// The toast after one action, with everything it unlocked: `成就，抽奖 +2`,
    /// `重置卡 +1`, or both when the last stage also completed her.
    public static func toast(for rewards: [AchievementReward]) -> String? {
        let draws = rewards.reduce(0) { $0 + $1.draws }
        let cards = rewards.reduce(0) { $0 + $1.resetCards }
        switch (draws > 0, cards > 0) {
        case (true, true): return "成就，抽奖 +\(draws)，重置卡 +\(cards)"
        case (true, false): return "成就，抽奖 +\(draws)"
        case (false, true): return "重置卡 +\(cards)"
        case (false, false): return nil
        }
    }
}

/// What on the play page has something the producer has not looked at yet: a stage on
/// the achievements page or a reward on the gift page.
public struct PlayBadges: Sendable, Hashable {
    public let achievements: Bool
    public let gifts: Bool

    public init(achievements: Bool, gifts: Bool) {
        self.achievements = achievements
        self.gifts = gifts
    }

    public var any: Bool { achievements || gifts }
}

/// What the one-time backfill found and awarded.
public struct AchievementLaunchSummary: Sendable, Hashable {
    public let stages: Int
    public let draws: Int
    public let resetCards: Int

    public init(stages: Int, draws: Int, resetCards: Int) {
        self.stages = stages
        self.draws = draws
        self.resetCards = resetCards
    }
}

/// The numbers as the panel writes them, never her affinity itself.
enum AchievementText {
    static func value(_ id: AchievementID, _ number: Double) -> String {
        switch id {
        case .callTime:
            duration(Int(number.rounded()))
        case .tier:
            switch Int(number.rounded()) {
            case 1: "亲近"
            case 2: "亲密"
            default: "还没有到"
            }
        case .turns: "\(Int(number)) 回合"
        case .gifts: "\(Int(number)) 件"
        case .characters, .intimateCharacters: "\(Int(number)) 位"
        case .days: "\(Int(number)) 天"
        case .draws: "\(Int(number)) 次"
        }
    }

    static func duration(_ seconds: Int) -> String {
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分钟"
        }
        if seconds >= 60 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }
}

/// How achievements are kept and unlocked, in the transaction the action they count is
/// written in (upstream `achievements.keep`, `launch`).
enum AchievementStore {
    static let all = ""

    // MARK: - Keeping an action

    /// Keeps what an action counted and unlocks the stages it reached, crediting their
    /// rewards in the same transaction.
    static func keep(
        _ db: Database,
        characterID: String? = nil,
        now: Date,
        today: String,
        turns: Int = 0,
        gifts: Int = 0,
        callTime: Double = 0,
        draws: Int = 0,
        tier: AffinityTier? = nil
    ) throws -> [AchievementReward] {
        if let characterID, turns > 0 {
            try add(db, "turns", characterID, Double(turns))
        }
        if let characterID, gifts > 0 {
            try add(db, "gifts", characterID, Double(gifts))
        }
        if let characterID, callTime > 0 {
            try add(db, "call_time", characterID, callTime)
        }
        if draws > 0 {
            try add(db, "draws", all, Double(draws))
        }
        if let characterID, let tier, let rank = tierRank(tier) {
            try db.execute(
                sql: """
                    INSERT INTO achievement_progress(achievement, character_id, count)
                    VALUES ('tier', ?, ?)
                    ON CONFLICT(achievement, character_id) DO UPDATE SET
                        count = MAX(count, excluded.count)
                    """,
                arguments: [characterID, rank]
            )
        }
        if characterID != nil, turns > 0 || gifts > 0 {
            try db.execute(
                sql: """
                    INSERT INTO achievement_progress(achievement, character_id, count, last_day)
                    VALUES ('days', ?, 1, ?)
                    ON CONFLICT(achievement, character_id) DO UPDATE SET
                        count = count + 1, last_day = excluded.last_day
                    WHERE last_day IS NULL OR last_day < excluded.last_day
                    """,
                arguments: [all, today]
            )
        }
        return try unlock(db, characterID: characterID, now: now)
    }

    private static func add(
        _ db: Database,
        _ achievement: String,
        _ characterID: String,
        _ count: Double
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO achievement_progress(achievement, character_id, count)
                VALUES (?, ?, ?)
                ON CONFLICT(achievement, character_id) DO UPDATE SET
                    count = count + excluded.count
                """,
            arguments: [achievement, characterID, count]
        )
    }

    private static func tierRank(_ tier: AffinityTier) -> Int? {
        switch tier {
        case .close: 1
        case .intimate: 2
        default: nil
        }
    }

    // MARK: - Unlocking

    static func unlock(
        _ db: Database,
        characterID: String?,
        now: Date
    ) throws -> [AchievementReward] {
        let stamp = Eidolon.timestamp(now)
        let counts = try progressCounts(db)
        var rewards: [AchievementReward] = []
        func value(_ id: AchievementID, _ character: String) -> Double {
            counts[ProgressKey(achievement: id.rawValue, character: character)] ?? 0
        }
        func unlockStages(_ id: AchievementID, character: String, progress: Double) throws {
            for (number, goal) in id.goals.enumerated() where progress >= Double(goal) {
                let stage = number + 1
                try db.execute(
                    sql: """
                        INSERT INTO achievement_stages
                            (achievement, character_id, stage, unlocked_at)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT DO NOTHING
                        """,
                    arguments: [id.rawValue, character, stage, stamp]
                )
                guard db.changesCount > 0 else { continue }
                let key = "achievement:\(id.rawValue):\(character):\(stage)"
                if try GiftStore.creditReward(db, key: key, draws: stage, resetCards: 0, at: now) {
                    rewards.append(AchievementReward(
                        achievement: id,
                        characterID: character == all ? nil : character,
                        stage: stage,
                        draws: stage
                    ))
                }
            }
        }

        if let characterID {
            for id in AchievementID.perCharacter {
                try unlockStages(id, character: characterID, progress: value(id, characterID))
            }
        }
        for id in AchievementID.allCharacters {
            try unlockStages(id, character: all, progress: allValue(id, counts))
        }

        if let characterID {
            let total = AchievementID.perCharacter.reduce(0) { $0 + $1.goals.count }
            let unlocked = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM achievement_stages
                    WHERE character_id = ? AND achievement IN
                        (\(AchievementID.perCharacter.map { "'\($0.rawValue)'" }.joined(separator: ",")))
                    """,
                arguments: [characterID]
            ) ?? 0
            if unlocked >= total {
                try db.execute(
                    sql: """
                        INSERT INTO achievement_progress(achievement, character_id, count)
                        VALUES ('complete', ?, 1)
                        ON CONFLICT DO NOTHING
                        """,
                    arguments: [characterID]
                )
                let inserted = db.changesCount > 0
                if inserted {
                    let key = "achievement_complete:\(characterID)"
                    if try GiftStore.creditReward(db, key: key, draws: 0, resetCards: 1, at: now) {
                        rewards.append(AchievementReward(
                            resetCards: 1,
                            completedCharacterID: characterID
                        ))
                    }
                }
            }
        }
        return rewards
    }

    /// One row of `achievement_progress`: what it counts and whose progress it is. The
    /// all-characters achievements use `all` as their character.
    struct ProgressKey: Hashable {
        let achievement: String
        let character: String
    }

    private static func progressCounts(_ db: Database) throws -> [ProgressKey: Double] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT achievement, character_id, count FROM achievement_progress"
        )
        var counts: [ProgressKey: Double] = [:]
        for row in rows {
            let key = ProgressKey(achievement: row["achievement"], character: row["character_id"])
            counts[key] = row["count"]
        }
        return counts
    }

    private static func allValue(_ id: AchievementID, _ counts: [ProgressKey: Double]) -> Double {
        switch id {
        case .characters:
            Double(counts.filter {
                $0.key.achievement == AchievementID.turns.rawValue
                    && $0.key.character != all && $0.value >= 1
            }.count)
        case .intimateCharacters:
            Double(counts.filter {
                $0.key.achievement == AchievementID.tier.rawValue
                    && $0.key.character != all && $0.value >= 2
            }.count)
        default:
            counts[ProgressKey(achievement: id.rawValue, character: all)] ?? 0
        }
    }

    // MARK: - Backfill

    /// The one-time backfill: what was recorded before achievements existed, and the
    /// rewards for the stages it reaches. nil once it has been done.
    static func launch(_ db: Database, now: Date) throws -> AchievementLaunchSummary? {
        let done = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM achievements_launched"
        ) ?? 0
        guard done == 0 else { return nil }
        try db.execute(
            sql: """
                INSERT INTO achievements_launched(id, launched_at, notice_seen)
                VALUES (1, ?, 1)
                """,
            arguments: [Eidolon.timestamp(now)]
        )

        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT c.character_id,
                    (SELECT COUNT(*) FROM messages m
                     JOIN conversations mc ON mc.id = m.conversation_id
                     WHERE mc.character_id = c.character_id AND m.role = 'user') AS turns,
                    (SELECT COUNT(*) FROM conversation_events e
                     JOIN conversations ec ON ec.id = e.conversation_id
                     WHERE ec.character_id = c.character_id AND e.kind = 'gift') AS gifts,
                    (SELECT COALESCE(SUM(k.duration_s), 0) FROM call_ends k
                     JOIN conversations kc ON kc.id = k.conversation_id
                     WHERE kc.character_id = c.character_id) AS call_time
                FROM (SELECT DISTINCT character_id FROM conversations) c
                """
        )
        for row in rows {
            let character: String = row["character_id"]
            try upsertProgress(db, "turns", character, row["turns"])
            try upsertProgress(db, "gifts", character, row["gifts"])
            try upsertProgress(db, "call_time", character, row["call_time"])
        }

        let tiers = try Row.fetchAll(
            db,
            sql: """
                SELECT c.character_id, m.affinity AS tier FROM messages m
                JOIN conversations c ON c.id = m.conversation_id
                WHERE m.affinity IS NOT NULL
                UNION ALL
                SELECT c.character_id, e.affinity FROM conversation_events e
                JOIN conversations c ON c.id = e.conversation_id
                WHERE e.kind = 'gift' AND e.affinity IS NOT NULL
                UNION ALL
                SELECT character_id, NULL FROM affinities WHERE value >= ?
                """,
            arguments: [AffinityTier.close.start]
        )
        var ranks: [String: Int] = [:]
        for row in tiers {
            let character: String = row["character_id"]
            var rank = 0
            if let raw: String = row["tier"], let tier = AffinityTier(rawValue: raw) {
                rank = tierRank(tier) ?? 0
            } else if let raw: String = row["tier"],
                      let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let name = object["tier"] as? String,
                      let tier = AffinityTier(rawValue: name) {
                rank = tierRank(tier) ?? 0
            }
            ranks[character] = max(ranks[character] ?? 0, rank)
        }
        // The current affinity was added as NULL above; read its value separately for
        // characters already at close or better.
        let current = try Row.fetchAll(
            db, sql: "SELECT character_id, value FROM affinities WHERE value >= ?",
            arguments: [AffinityTier.close.start]
        )
        for row in current {
            let character: String = row["character_id"]
            ranks[character] = max(ranks[character] ?? 0, tierRank(AffinityTier.of(row["value"])) ?? 0)
        }
        for (character, rank) in ranks where rank > 0 {
            try db.execute(
                sql: """
                    INSERT INTO achievement_progress(achievement, character_id, count)
                    VALUES ('tier', ?, ?)
                    ON CONFLICT(achievement, character_id) DO UPDATE SET
                        count = MAX(count, excluded.count)
                    """,
                arguments: [character, rank]
            )
        }

        var days: Set<String> = []
        let stamps = try String.fetchAll(
            db,
            sql: """
                SELECT m.created_at FROM messages m
                JOIN conversations c ON c.id = m.conversation_id WHERE m.role = 'user'
                UNION ALL
                SELECT e.created_at FROM conversation_events e
                JOIN conversations c ON c.id = e.conversation_id WHERE e.kind = 'gift'
                """
        )
        for stamp in stamps {
            if let at = Eidolon.parseTimestamp(stamp) {
                days.insert(Eidolon.isoDay(at, in: AffinityRules.dayZone))
            }
        }
        if !days.isEmpty {
            let ordered = days.sorted()
            try db.execute(
                sql: """
                    INSERT INTO achievement_progress(achievement, character_id, count, last_day)
                    VALUES ('days', ?, ?, ?)
                    ON CONFLICT(achievement, character_id) DO UPDATE SET
                        count = MAX(count, excluded.count),
                        last_day = MAX(last_day, excluded.last_day)
                    """,
                arguments: [all, ordered.count, ordered.last]
            )
        }

        var rewards: [AchievementReward] = []
        let characters = Set(rows.map { $0["character_id"] as String })
        for character in characters {
            rewards += try unlock(db, characterID: character, now: now)
        }
        rewards += try unlock(db, characterID: nil, now: now)

        let stages = rewards.filter { $0.stage != nil }.count
        let draws = rewards.reduce(0) { $0 + $1.draws }
        let cards = rewards.reduce(0) { $0 + $1.resetCards }
        guard stages > 0 || draws > 0 || cards > 0 else { return nil }
        try db.execute(
            sql: """
                UPDATE achievements_launched SET
                    notice_seen = 0, notice_stages = ?, notice_draws = ?, notice_reset_cards = ?
                WHERE id = 1
                """,
            arguments: [stages, draws, cards]
        )
        return AchievementLaunchSummary(stages: stages, draws: draws, resetCards: cards)
    }

    private static func upsertProgress(
        _ db: Database, _ achievement: String, _ character: String, _ count: Double
    ) throws {
        guard count > 0 else { return }
        try db.execute(
            sql: """
                INSERT INTO achievement_progress(achievement, character_id, count)
                VALUES (?, ?, ?)
                ON CONFLICT(achievement, character_id) DO UPDATE SET
                    count = MAX(count, excluded.count)
                """,
            arguments: [achievement, character, count]
        )
    }

    // MARK: - Reading

    static func hers(_ db: Database, characterID: String) throws -> HerAchievements {
        let counts = try progressCounts(db)
        let stages = try stageRows(db, characterID: characterID)
        let achievements = AchievementID.perCharacter.map { id in
            AchievementProgress(
                id: id,
                progress: counts[ProgressKey(achievement: id.rawValue, character: characterID)] ?? 0,
                stages: stageList(id, stages[id.rawValue] ?? [:])
            )
        }
        let complete = counts[ProgressKey(achievement: "complete", character: characterID)] != nil
        let completedAt = complete
            ? achievements.flatMap(\.stages).compactMap(\.unlockedAt).max()
            : nil
        return HerAchievements(achievements: achievements, completedAt: completedAt)
    }

    static func allAchievements(_ db: Database) throws -> AllAchievements {
        let counts = try progressCounts(db)
        let stages = try stageRows(db, characterID: all)
        let achievements = AchievementID.allCharacters.map { id in
            AchievementProgress(
                id: id,
                progress: allValue(id, counts),
                stages: stageList(id, stages[id.rawValue] ?? [:])
            )
        }
        return AllAchievements(achievements: achievements)
    }

    private static func stageRows(
        _ db: Database, characterID: String
    ) throws -> [String: [Int: (String, Bool)]] {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT achievement, stage, unlocked_at, seen FROM achievement_stages
                WHERE character_id = ?
                """,
            arguments: [characterID]
        )
        var stages: [String: [Int: (String, Bool)]] = [:]
        for row in rows {
            stages[row["achievement"], default: [:]][row["stage"]] = (
                row["unlocked_at"], (row["seen"] as Int) == 1
            )
        }
        return stages
    }

    private static func stageList(
        _ id: AchievementID, _ unlocked: [Int: (String, Bool)]
    ) -> [AchievementStage] {
        id.goals.enumerated().map { index, goal in
            let number = index + 1
            let row = unlocked[number]
            return AchievementStage(
                number: number,
                goal: goal,
                draws: number,
                unlockedAt: row?.0,
                isNew: row.map { !$0.1 } ?? false
            )
        }
    }

    static func markSeen(_ db: Database, characterID: String?) throws {
        if let characterID {
            try db.execute(
                sql: "UPDATE achievement_stages SET seen = 1 WHERE character_id = ?",
                arguments: [characterID]
            )
        } else {
            // The play page's achievements card covers every scope: opening it acknowledges
            // the per-character stages too, or its dot would never go.
            try db.execute(sql: "UPDATE achievement_stages SET seen = 1")
        }
    }

    static func markRewardsSeen(_ db: Database) throws {
        try db.execute(sql: "UPDATE gift_rewards SET seen = 1")
    }

    static func badges(_ db: Database) throws -> PlayBadges {
        let stages = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM achievement_stages WHERE seen = 0"
        ) ?? 0
        let rewards = try Int.fetchOne(
            db, sql: "SELECT COUNT(*) FROM gift_rewards WHERE seen = 0"
        ) ?? 0
        return PlayBadges(achievements: stages > 0, gifts: rewards > 0)
    }

    /// Whether anything was unlocked or paid since the play tab was last cleared.
    static func hasNew(_ db: Database) throws -> Bool {
        let seenAt = try String.fetchOne(
            db, sql: "SELECT seen_at FROM achievement_play_seen WHERE id = 1"
        ) ?? ""
        let stages = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM achievement_stages WHERE unlocked_at > ?",
            arguments: [seenAt]
        ) ?? 0
        let rewards = try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM gift_rewards WHERE rewarded_at > ?",
            arguments: [seenAt]
        ) ?? 0
        return stages > 0 || rewards > 0
    }

    /// Clears the play tab's dot: the producer has seen the achievements page or the gift
    /// page.
    static func markPlaySeen(_ db: Database, at now: Date) throws {
        try db.execute(
            sql: """
                INSERT INTO achievement_play_seen(id, seen_at) VALUES (1, ?)
                ON CONFLICT(id) DO UPDATE SET seen_at = excluded.seen_at
                """,
            arguments: [Eidolon.timestamp(now)]
        )
    }

    static func launchSummary(_ db: Database) throws -> AchievementLaunchSummary? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT notice_seen, notice_stages, notice_draws, notice_reset_cards
                FROM achievements_launched WHERE id = 1
                """
        ), (row["notice_seen"] as Int) == 0 else { return nil }
        return AchievementLaunchSummary(
            stages: row["notice_stages"],
            draws: row["notice_draws"],
            resetCards: row["notice_reset_cards"]
        )
    }

    static func markLaunchSeen(_ db: Database) throws {
        try db.execute(sql: "UPDATE achievements_launched SET notice_seen = 1 WHERE id = 1")
    }
}

extension Eidolon {
    /// Her four achievements with the producer, and whether all their stages are unlocked.
    public func herAchievements(characterID: String) throws -> HerAchievements {
        try userQueue.read { db in
            try AchievementStore.hers(db, characterID: characterID)
        }
    }

    /// The four achievements of everyone together.
    public func allAchievements() throws -> AllAchievements {
        try userQueue.read { db in
            try AchievementStore.allAchievements(db)
        }
    }

    /// Marks what a panel has been looked at: her stages, or those of everyone together
    /// (`nil`), never the other's.
    public func markAchievementsSeen(characterID: String?) throws {
        try userQueue.write { db in
            try AchievementStore.markSeen(db, characterID: characterID)
        }
    }

    /// Marks the rewards the gift page shows as looked at, clearing the play tab's dot.
    public func markGiftRewardsSeen() throws {
        try userQueue.write { db in
            try AchievementStore.markRewardsSeen(db)
        }
    }

    /// Whether the play tab should show its dot: a new stage or a new reward.
    public func achievementBadge() throws -> Bool {
        try userQueue.read { db in
            try AchievementStore.hasNew(db)
        }
    }

    /// Which play card has something new: a stage (achievements) or a reward (gifts).
    public func playBadges() throws -> PlayBadges {
        try userQueue.read { db in
            try AchievementStore.badges(db)
        }
    }

    /// Clears the play tab's dot after the achievements page or the gift page was opened.
    public func markPlaySeen(now: Date = Date()) throws {
        try userQueue.write { db in
            try AchievementStore.markPlaySeen(db, at: now)
        }
    }

    /// The one-time backfill, done on the first launch after achievements arrive; nil if it
    /// has been done, or if nothing was unlocked.
    public func launchAchievements(now: Date = Date()) throws -> AchievementLaunchSummary? {
        try userQueue.write { db in
            try AchievementStore.launch(db, now: now)
        }
    }

    /// The launch summary still to show once; nil after it was seen.
    public func achievementLaunchSummary() throws -> AchievementLaunchSummary? {
        try userQueue.read { db in
            try AchievementStore.launchSummary(db)
        }
    }

    public func markAchievementLaunchSeen() throws {
        try userQueue.write { db in
            try AchievementStore.markLaunchSeen(db)
        }
    }
}
