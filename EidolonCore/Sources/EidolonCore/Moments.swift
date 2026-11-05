import Foundation
import GRDB

// MARK: - Settings

public enum MomentMapProvider: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case apple
    case google
    case osm
    case amap

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .apple: "Apple 地图"
        case .google: "Google 地图"
        case .osm: "OpenStreetMap"
        case .amap: "高德地图"
        }
    }

    /// The map link for a coordinate; no key is needed for any of them.
    public func url(name: String, latitude: Double, longitude: Double) -> URL? {
        let query = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        switch self {
        case .apple:
            return URL(string: "https://maps.apple.com/?q=\(query)&ll=\(latitude),\(longitude)")
        case .google:
            return URL(string: "https://www.google.com/maps/search/?api=1&query=\(latitude),\(longitude)")
        case .osm:
            return URL(string: "https://www.openstreetmap.org/?mlat=\(latitude)&mlon=\(longitude)#map=17/\(latitude)/\(longitude)")
        case .amap:
            return URL(string: "https://uri.amap.com/marker?position=\(longitude),\(latitude)&name=\(query)")
        }
    }
}

/// The moments settings, kept as JSON in `app_state` (spec #98). Missing keys take the
/// defaults, so a library written by an older build still loads.
public struct MomentsSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var dailyPosts: Int
    public var dailyReplies: Int
    public var mapProvider: MomentMapProvider
    public var notifications: Bool
    public var debugAdultImages: Bool

    public static let `default` = MomentsSettings(
        enabled: false,
        dailyPosts: 3,
        dailyReplies: 10,
        mapProvider: .apple,
        notifications: true,
        debugAdultImages: false
    )

    public init(
        enabled: Bool = false,
        dailyPosts: Int = 3,
        dailyReplies: Int = 10,
        mapProvider: MomentMapProvider = .apple,
        notifications: Bool = true,
        debugAdultImages: Bool = false
    ) {
        self.enabled = enabled
        self.dailyPosts = max(1, dailyPosts)
        self.dailyReplies = max(0, dailyReplies)
        self.mapProvider = mapProvider
        self.notifications = notifications
        self.debugAdultImages = debugAdultImages
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, dailyPosts, dailyReplies, mapProvider, notifications, debugAdultImages
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MomentsSettings.default
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        dailyPosts = max(
            1, try container.decodeIfPresent(Int.self, forKey: .dailyPosts) ?? defaults.dailyPosts
        )
        dailyReplies = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .dailyReplies) ?? defaults.dailyReplies
        )
        mapProvider = try container.decodeIfPresent(MomentMapProvider.self, forKey: .mapProvider)
            ?? defaults.mapProvider
        notifications = try container.decodeIfPresent(Bool.self, forKey: .notifications)
            ?? defaults.notifications
        debugAdultImages = try container.decodeIfPresent(Bool.self, forKey: .debugAdultImages)
            ?? defaults.debugAdultImages
    }
}

// MARK: - Content

/// The place a post keeps, copied when it is written: changing the bundle later does not
/// rewrite a post that already went out.
public struct MomentPlaceSnapshot: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var area: String
    public var lat: Double
    public var lon: Double

    public init(id: String, name: String, area: String, lat: Double, lon: Double) {
        self.id = id
        self.name = name
        self.area = area
        self.lat = lat
        self.lon = lon
    }
}

/// The weather at the moment the post went out, in seven kinds and whole degrees.
public struct MomentWeather: Codable, Sendable, Hashable {
    public enum Kind: Int, Codable, Sendable, CaseIterable, Hashable {
        case clear = 0
        case partlyCloudy = 1
        case overcast = 2
        case fog = 3
        case rain = 4
        case snow = 5
        case thunder = 6

        public var title: String {
            switch self {
            case .clear: "晴"
            case .partlyCloudy: "多云"
            case .overcast: "阴"
            case .fog: "雾"
            case .rain: "雨"
            case .snow: "雪"
            case .thunder: "雷"
            }
        }

        public var symbol: String {
            switch self {
            case .clear: "sun.max.fill"
            case .partlyCloudy: "cloud.sun.fill"
            case .overcast: "cloud.fill"
            case .fog: "cloud.fog.fill"
            case .rain: "cloud.rain.fill"
            case .snow: "cloud.snow.fill"
            case .thunder: "cloud.bolt.rain.fill"
            }
        }

        /// Rain, snow and thunder keep her indoors.
        public var isWet: Bool { self == .rain || self == .snow || self == .thunder }

        /// WMO codes, as Open-Meteo reports them.
        static func from(wmo code: Int) -> Kind {
            switch code {
            case 0, 1: return .clear
            case 2: return .partlyCloudy
            case 3: return .overcast
            case 45, 48: return .fog
            case 51...67, 80...82: return .rain
            case 71...77, 85, 86: return .snow
            case 95...99: return .thunder
            default: return .overcast
            }
        }
    }

    public var kind: Kind
    public var temperature: Int

    public init(kind: Kind, temperature: Int) {
        self.kind = kind
        self.temperature = temperature
    }
}

public protocol MomentWeatherProviding: Sendable {
    /// The Tokyo weather at `date`; nil when it cannot be had, in which case the post
    /// simply shows none.
    func weather(at date: Date) async -> MomentWeather?
}

// MARK: - Records

public struct MomentImageRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var file: String
    public var width: Int
    public var height: Int
    public var composition: String
    public var tag: String
    public var note: String?
}

public struct MomentReactionRecord: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case like
        case comment
    }

    public var id: String
    public var characterID: String
    public var kind: Kind
    public var ja: String?
    public var zh: String?
    public var revealAt: Date
}

public struct MomentCommentRecord: Sendable, Hashable {
    public var text: String
    public var createdAt: Date
    public var replyRevealAt: Date?
    public var replyJA: String?
    public var replyZH: String?
    public var replyAt: Date?

    public var revealedReply: (ja: String, zh: String)? {
        guard replyAt != nil, let replyJA, let replyZH else { return nil }
        return (replyJA, replyZH)
    }
}

/// One post as the timeline shows it: what has been revealed by `now`, never what has not.
public struct MomentPost: Sendable, Hashable, Identifiable {
    public var id: String
    public var characterID: String
    public var ja: String
    public var zh: String
    public var planDay: String
    public var revealAt: Date
    public var createdAt: Date
    public var place: MomentPlaceSnapshot?
    public var weather: MomentWeather?
    public var image: MomentImageRecord?
    public var reactions: [MomentReactionRecord]
    public var liked: Bool
    public var comment: MomentCommentRecord?
}

/// What one run did, for the app's notification and for tests.
public struct MomentsRun: Sendable, Hashable {
    public var newPosts: [String] = []
    public var newReplies: [String] = []
    public var generated: Int = 0
    public var failed: Int = 0

    public init() {}
}

// MARK: - Reading and writing

extension Eidolon {
    static let momentTokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current
    static let momentSettingsKey = "moments.settings"
    static let momentRetention: TimeInterval = 30 * 24 * 3600

    public func momentsSettings() throws -> MomentsSettings {
        let stored: String? = try userQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [Self.momentSettingsKey]
            )
        }
        guard let stored, let data = stored.data(using: .utf8) else { return .default }
        return (try? JSONDecoder().decode(MomentsSettings.self, from: data)) ?? .default
    }

    public func setMomentsSettings(_ settings: MomentsSettings) throws {
        let previous = (try? momentsSettings()) ?? .default
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state(key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [Self.momentSettingsKey, text]
            )
            // Turning it back on today plans the rest of the day again: `planned_day`
            // alone would otherwise make the switch look like it did nothing.
            if settings.enabled && !previous.enabled {
                try db.execute(sql: "UPDATE moment_state SET planned_day = NULL WHERE id = 1")
            }
        }
    }

    /// The posts revealed by `now`, newest first, with only the reactions that have come
    /// out, the producer's like and comment, and her reply once it has.
    public func momentsTimeline(now: Date = Date()) throws -> [MomentPost] {
        let stamp = Self.timestamp(now)
        return try userQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM moment_posts WHERE reveal_at <= ? ORDER BY reveal_at DESC",
                arguments: [stamp]
            )
            let images = try Row.fetchAll(
                db, sql: "SELECT * FROM moment_images"
            ).reduce(into: [String: MomentImageRecord]()) { result, row in
                result[row["post_id"]] = MomentImageRecord(
                    id: row["id"], file: row["file"], width: row["width"], height: row["height"],
                    composition: row["composition"], tag: row["tag"], note: row["note"]
                )
            }
            let reactions = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM moment_reactions WHERE reveal_at <= ?
                    ORDER BY reveal_at ASC, position ASC
                    """,
                arguments: [stamp]
            ).reduce(into: [String: [MomentReactionRecord]]()) { result, row in
                result[row["post_id"], default: []].append(MomentReactionRecord(
                    id: row["id"], characterID: row["character_id"],
                    kind: MomentReactionRecord.Kind(rawValue: row["kind"]) ?? .like,
                    ja: row["ja"], zh: row["zh"],
                    revealAt: Self.parseTimestamp(row["reveal_at"]) ?? now
                ))
            }
            let likes = Set(try String.fetchAll(db, sql: "SELECT post_id FROM moment_likes"))
            let comments = try Row.fetchAll(db, sql: "SELECT * FROM moment_comments")
                .reduce(into: [String: MomentCommentRecord]()) { result, row in
                    result[row["post_id"]] = MomentCommentRecord(
                        text: row["text"],
                        createdAt: Self.parseTimestamp(row["created_at"]) ?? now,
                        replyRevealAt: (row["reply_reveal_at"] as String?).flatMap(Self.parseTimestamp),
                        replyJA: row["reply_ja"], replyZH: row["reply_zh"],
                        replyAt: (row["reply_at"] as String?).flatMap(Self.parseTimestamp)
                    )
                }
            return rows.map { row in
                let id: String = row["id"]
                return MomentPost(
                    id: id,
                    characterID: row["character_id"],
                    ja: row["ja"],
                    zh: row["zh"],
                    planDay: row["plan_day"],
                    revealAt: Self.parseTimestamp(row["reveal_at"]) ?? now,
                    createdAt: Self.parseTimestamp(row["created_at"]) ?? now,
                    place: (row["place_id"] as String?).map {
                        MomentPlaceSnapshot(
                            id: $0, name: row["place_name"] ?? "",
                            area: row["place_area"] ?? "",
                            lat: row["place_lat"] ?? 0, lon: row["place_lon"] ?? 0
                        )
                    },
                    weather: (row["weather_code"] as Int?).map {
                        MomentWeather(
                            kind: MomentWeather.Kind(rawValue: $0) ?? .overcast,
                            temperature: row["weather_temperature"] ?? 0
                        )
                    },
                    image: images[id],
                    reactions: reactions[id] ?? [],
                    liked: likes.contains(id),
                    comment: comments[id]
                )
            }
        }
    }

    /// Whether anything new is waiting: a post or her reply after the last time the page
    /// was opened. The other idols' reactions do not count.
    public func momentsBadge(now: Date = Date()) throws -> Bool {
        let stamp = Self.timestamp(now)
        return try userQueue.read { db in
            let opened = try String.fetchOne(
                db, sql: "SELECT last_opened_at FROM moment_state WHERE id = 1"
            )
            if let opened {
                let posts = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM moment_posts WHERE reveal_at > ? AND reveal_at <= ?",
                    arguments: [opened, stamp]
                ) ?? 0
                if posts > 0 { return true }
                let replies = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM moment_comments
                        WHERE reply_at IS NOT NULL AND reply_at > ? AND reply_at <= ?
                        """,
                    arguments: [opened, stamp]
                ) ?? 0
                return replies > 0
            }
            return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM moment_posts") ?? 0) > 0
        }
    }

    public func markMomentsOpened(now: Date = Date()) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_state(id, last_opened_at) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET last_opened_at = excluded.last_opened_at
                    """,
                arguments: [Self.timestamp(now)]
            )
        }
    }

    @discardableResult
    public func likeMoment(_ postID: String, now: Date = Date()) throws -> Bool {
        guard try momentPostExists(postID) else { return false }
        try userQueue.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO moment_likes(post_id, created_at) VALUES (?, ?)",
                arguments: [postID, Self.timestamp(now)]
            )
        }
        return true
    }

    @discardableResult
    public func unlikeMoment(_ postID: String) throws -> Bool {
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM moment_likes WHERE post_id = ?", arguments: [postID])
            return db.changesCount > 0
        }
    }

    /// Leaves one comment on a post. Only one may exist at a time and it cannot be edited;
    /// her reply is scheduled by the affinity she has right now. False when the post is
    /// gone, a comment already exists, or the text is not 1–140 characters.
    @discardableResult
    public func commentMoment(
        _ postID: String, text: String, now: Date = Date(), seed: UInt64? = nil
    ) throws -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let count = trimmed.count
        guard (1...140).contains(count) else { return false }
        guard try momentPostExists(postID) else { return false }
        let characterID: String? = try userQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT character_id FROM moment_posts WHERE id = ?", arguments: [postID]
            )
        }
        guard let characterID else { return false }
        let affinity = try readAffinity(characterID: characterID, now: now)
        let tier = affinity.tier
        var reveal: Date?
        if tier != .cold, tier != .distant, affinity.cooldownUntil == nil {
            var random = SeededRandom(seed: seed.map(String.init) ?? "\(postID)-\(now.timeIntervalSince1970)")
            let (low, high): (Int, Int) = switch tier {
            case .intimate: (5, 30)
            case .close: (15, 60)
            default: (30, 120)
            }
            let minutes = low + random.below(high - low + 1)
            reveal = now.addingTimeInterval(TimeInterval(minutes * 60))
        }
        return try userQueue.write { db in
            let existing = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM moment_comments WHERE post_id = ?", arguments: [postID]
            ) ?? 0
            guard existing == 0 else { return false }
            try db.execute(
                sql: """
                    INSERT INTO moment_comments(post_id, text, created_at, reply_reveal_at)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [postID, trimmed, Self.timestamp(now), reveal.map(Self.timestamp)]
            )
            return true
        }
    }

    /// Deletes the producer's comment and, with it, a reply that had already come out;
    /// one that had not comes to nothing.
    @discardableResult
    public func deleteMomentComment(_ postID: String) throws -> Bool {
        try userQueue.write { db in
            try db.execute(
                sql: "DELETE FROM moment_comments WHERE post_id = ?", arguments: [postID]
            )
            return db.changesCount > 0
        }
    }

    func momentPostExists(_ postID: String) throws -> Bool {
        try userQueue.read { db in
            (try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM moment_posts WHERE id = ?", arguments: [postID]
            ) ?? 0) > 0
        }
    }
}

// MARK: - Running

public struct MomentsProviders: Sendable {
    public var chat: any ChatProvider
    public var photo: PhotoTurnContext?
    public var weather: (any MomentWeatherProviding)?
    public var gptImage: (any GPTImageGenerating)?
    public var gptSettings: GPTImageSettings?
    /// The app's own switches for the debug R picture (spec #98): adult mode, debug mode,
    /// and the moments setting that opts in.
    public var adultMode: Bool
    public var debugMode: Bool

    public init(
        chat: any ChatProvider,
        photo: PhotoTurnContext? = nil,
        weather: (any MomentWeatherProviding)? = nil,
        gptImage: (any GPTImageGenerating)? = nil,
        gptSettings: GPTImageSettings? = nil,
        adultMode: Bool = false,
        debugMode: Bool = false
    ) {
        self.chat = chat
        self.photo = photo
        self.weather = weather
        self.gptImage = gptImage
        self.gptSettings = gptSettings
        self.adultMode = adultMode
        self.debugMode = debugMode
    }
}

extension Eidolon {
    /// What the app calls on launch, on coming back to the foreground, once a minute in
    /// the foreground, and from the background task (spec #98). There is no timer in here:
    /// every call reads the clock and does whatever is due.
    public func runMomentsDue(
        now: Date = Date(),
        providers: MomentsProviders,
        seed: UInt64 = UInt64.random(in: 0...UInt64.max)
    ) async -> MomentsRun {
        var run = MomentsRun()
        // Expired posts go even while the switch is off: turning moments off keeps the
        // data but does not stop it ageing out.
        try? cleanupMoments(now: now)
        guard let settings = try? momentsSettings(), settings.enabled else { return run }
        var random = SeededRandom(seed: "\(seed)")
        try? ensureMomentsPlans(now: now, settings: settings, random: &random)
        let plans = (try? dueMomentPlans(now: now)) ?? []
        for plan in plans {
            await processMomentPlan(plan, now: now, providers: providers, run: &run, random: &random)
        }
        await processMomentReplies(now: now, settings: settings, providers: providers, run: &run)
        return run
    }

    /// Ages out posts and plans past retention even while the switch is off, so turning
    /// moments off does not freeze the library. Failures are never surfaced.
    public func pruneMoments(now: Date = Date()) {
        try? cleanupMoments(now: now)
    }

    // MARK: Planning

    struct MomentPlanRecord: Sendable {
        var id: String
        var characterID: String
        var planDay: String
        var dueAt: Date
        var kind: MomentPlanKind
        var birthday: Bool
    }

    enum MomentPlanKind: String, Sendable {
        case work
        case daily
    }

    func ensureMomentsPlans(
        now: Date, settings: MomentsSettings, random: inout SeededRandom
    ) throws {
        let day = Self.isoDay(now, in: Self.momentTokyo)
        let planned: String? = try userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT planned_day FROM moment_state WHERE id = 1")
        }
        guard planned != day else { return }
        // Plans older than yesterday are not caught up (spec #98); a work plan may run
        // past midnight and still belongs to its own day.
        try userQueue.write { db in
            try db.execute(
                sql: "DELETE FROM moment_plans WHERE plan_day < ?",
                arguments: [Self.isoDay(now.addingTimeInterval(-24 * 3600), in: Self.momentTokyo)]
            )
        }
        let characters = try characters()
        let ids = try momentActiveCharacterIDs(now: now)
        // Posts already out or planned today, so a new one keeps an hour clear of them.
        var reserved = try momentReservedDues(now: now)
        let postedToday = try momentPostCounts(day: day)
        var remaining = max(0, settings.dailyPosts - postedToday.values.reduce(0, +))
        var candidates: [(CharacterConfig, Affinity, Bool)] = []
        for character in characters where ids.contains(character.id) {
            if let count = postedToday[character.id], count > 0 { continue }
            let affinity = try readAffinity(characterID: character.id, now: now)
            guard Self.momentAllowsMoments(affinity),
                  try momentHasHadATurn(character.id)
            else { continue }
            let birthday = Self.isMomentBirthday(character.birthday, now: now)
            let chance: Int = switch (birthday, affinity.tier) {
            case (true, _): 100
            case (_, .intimate): 80
            case (_, .close): 50
            default: 25
            }
            guard random.below(100) < chance else { continue }
            candidates.append((character, affinity, birthday))
        }
        // A birthday is forced, so it is planned first and never dropped by the daily cap.
        random.shuffle(&candidates)
        candidates = candidates.filter(\.2) + candidates.filter { !$0.2 }
        for (character, _, birthday) in candidates {
            guard remaining > 0 else { break }
            let work = try momentTodaysWork(characterID: character.id, now: now)
            let kind: MomentPlanKind
            var due: Date
            if let work, !work.isEmpty {
                kind = .work
                let lastEnd = work.map(\.end).max() ?? now
                let delay = TimeInterval((30 + random.below(91)) * 60)
                due = max(now.addingTimeInterval(30 * 60), lastEnd.addingTimeInterval(delay))
            } else if let slot = momentDailyDue(now: now, random: &random) {
                kind = .daily
                due = slot
            } else if birthday {
                kind = .daily
                due = now.addingTimeInterval(5 * 60)
            } else {
                continue
            }
            // Same-day posts stay at least an hour apart (spec #98). A birthday may move
            // later instead of losing its day; anyone else simply waits for tomorrow.
            var tries = 0
            while !reserved.allSatisfy({ abs($0.timeIntervalSince(due)) >= 3600 }), tries < 6 {
                guard birthday else { break }
                due = due.addingTimeInterval(3600)
                tries += 1
            }
            guard reserved.allSatisfy({ abs($0.timeIntervalSince(due)) >= 3600 }) else { continue }
            reserved.append(due)
            try insertMomentPlan(
                characterID: character.id, planDay: day, dueAt: due, kind: kind,
                birthday: birthday, now: now
            )
            remaining -= 1
        }
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_state(id, planned_day) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET planned_day = excluded.planned_day
                    """,
                arguments: [day]
            )
        }
    }

    /// When today's posts and plans land (Tokyo's day), for the one-hour spacing rule.
    func momentReservedDues(now: Date) throws -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.momentTokyo
        let start = calendar.startOfDay(for: now)
        let end = start.addingTimeInterval(24 * 3600)
        return try userQueue.read { db in
            let posts = try String.fetchAll(
                db,
                sql: "SELECT reveal_at FROM moment_posts WHERE reveal_at >= ? AND reveal_at < ?",
                arguments: [Self.timestamp(start), Self.timestamp(end)]
            )
            let plans = try String.fetchAll(
                db,
                sql: "SELECT due_at FROM moment_plans WHERE due_at >= ? AND due_at < ?",
                arguments: [Self.timestamp(start), Self.timestamp(end)]
            )
            return (posts + plans).compactMap(Self.parseTimestamp)
        }
    }

    func insertMomentPlan(
        characterID: String, planDay: String, dueAt: Date, kind: MomentPlanKind,
        birthday: Bool, now: Date
    ) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_plans(id, character_id, plan_day, due_at, kind, birthday, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    UUID().uuidString, characterID, planDay, Self.timestamp(dueAt),
                    kind.rawValue, birthday ? 1 : 0, Self.timestamp(now),
                ]
            )
        }
    }

    /// Her jobs today and when each ends (Tokyo clock), if she has any.
    func momentTodaysWork(
        characterID: String, now: Date
    ) throws -> [(job: WeeklyJob, end: Date)]? {
        // The day of the post is Tokyo's, but when a job ends is the producer's clock
        // (spec #98): the schedule board is theirs.
        let zone = (try? producerProfile())?.timezone.flatMap(TimeZone.init(identifier:))
            ?? Self.momentTokyo
        let her = try schedule(characterID: characterID, now: now, timeZone: zone)
        let today = her.localDay.weekdayIndex
        let jobs = her.jobs.filter { $0.week == her.thisWeek && $0.day == today }
        guard !jobs.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: now)
        return jobs.map { job in
            let endHour = 6 + (job.slot + job.job.length) * 6
            return (job.job, start.addingTimeInterval(TimeInterval(endHour * 3600)))
        }
    }

    /// A random moment left today in one of the daily windows, weighted toward the evening.
    func momentDailyDue(now: Date, random: inout SeededRandom) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.momentTokyo
        let start = calendar.startOfDay(for: now)
        let windows: [(Int, Int, Int)] = [(7, 9, 2), (12, 13, 2), (18, 24, 4), (0, 2, 1)]
        var choices: [(Date, Int)] = []
        for (from, to, weight) in windows {
            let begin = start.addingTimeInterval(TimeInterval(from * 3600))
            let end = start.addingTimeInterval(TimeInterval(to * 3600))
            let earliest = max(begin, now.addingTimeInterval(5 * 60))
            guard end.timeIntervalSince(earliest) > 60 else { continue }
            let span = Int(end.timeIntervalSince(earliest))
            let moment = earliest.addingTimeInterval(TimeInterval(random.below(span)))
            choices.append((moment, weight))
        }
        guard !choices.isEmpty else { return nil }
        let total = choices.reduce(0) { $0 + $1.1 }
        var pick = random.below(total)
        for (date, weight) in choices {
            if pick < weight { return date }
            pick -= weight
        }
        return choices.last?.0
    }

    func dueMomentPlans(now: Date) throws -> [MomentPlanRecord] {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM moment_plans WHERE due_at <= ? ORDER BY due_at ASC",
                arguments: [Self.timestamp(now)]
            ).map { row in
                MomentPlanRecord(
                    id: row["id"], characterID: row["character_id"], planDay: row["plan_day"],
                    dueAt: Self.parseTimestamp(row["due_at"]) ?? now,
                    kind: MomentPlanKind(rawValue: row["kind"]) ?? .daily,
                    birthday: (row["birthday"] as Int) == 1
                )
            }
        }
    }

    func deleteMomentPlan(_ id: String) throws {
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM moment_plans WHERE id = ?", arguments: [id])
        }
    }

    func pushMomentPlan(_ id: String, to date: Date) throws {
        try userQueue.write { db in
            try db.execute(
                sql: "UPDATE moment_plans SET due_at = ? WHERE id = ?",
                arguments: [Self.timestamp(date), id]
            )
        }
    }

    // MARK: Eligibility

    /// Who was spoken to or called within seven days: the moments pool (spec #98).
    func momentActiveCharacterIDs(now: Date) throws -> Set<String> {
        let cutoff = Self.timestamp(now.addingTimeInterval(-7 * 24 * 3600))
        return try userQueue.read { db in
            var ids = Set(try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT c.character_id FROM messages m
                    JOIN conversations c ON c.id = m.conversation_id
                    WHERE m.role = 'user' AND m.created_at >= ?
                    """,
                arguments: [cutoff]
            ))
            if try db.tableExists("call_ends") {
                ids.formUnion(try String.fetchAll(
                    db,
                    sql: """
                        SELECT DISTINCT character_id FROM call_ends
                        WHERE connected_at IS NOT NULL AND connected_at >= ?
                        """,
                    arguments: [cutoff]
                ))
            }
            return ids
        }
    }

    func momentHasHadATurn(_ characterID: String) throws -> Bool {
        try userQueue.read { db in
            (try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM messages m
                    JOIN conversations c ON c.id = m.conversation_id
                    WHERE c.character_id = ? AND m.role = 'user'
                    """,
                arguments: [characterID]
            ) ?? 0) > 0
        }
    }

    func momentPostCounts(day: String) throws -> [String: Int] {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT character_id, COUNT(*) AS n FROM moment_posts WHERE plan_day = ? GROUP BY character_id",
                arguments: [day]
            ).reduce(into: [:]) { result, row in result[row["character_id"]] = row["n"] }
        }
    }

    /// Close enough to post and reply: trust or higher, and not cooling off.
    static func momentAllowsMoments(_ affinity: Affinity) -> Bool {
        switch affinity.tier {
        case .trust, .close, .intimate: affinity.cooldownUntil == nil
        default: false
        }
    }

    static func isMomentBirthday(_ birthday: Birthday?, now: Date) -> Bool {
        guard let birthday else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = momentTokyo
        let parts = calendar.dateComponents([.month, .day], from: now)
        return parts.month == birthday.month && parts.day == birthday.day
    }
}

// MARK: - Making a post

extension Eidolon {
    struct MomentDraft {
        var ja: String
        var zh: String
        var placeID: String?
        var likes: [String]
        var comments: [(from: String, ja: String, zh: String)]
        var image: MomentImageDraft?
    }

    func processMomentPlan(
        _ plan: MomentPlanRecord,
        now: Date,
        providers: MomentsProviders,
        run: inout MomentsRun,
        random: inout SeededRandom
    ) async {
        // A plan that is pushed to later stays; everything else is done with.
        var completed = true
        defer { if completed { try? deleteMomentPlan(plan.id) } }
        guard let settingsNow = try? momentsSettings(), settingsNow.enabled else { return }
        guard let character = try? characters().first(where: { $0.id == plan.characterID }) else {
            return
        }
        let affinity = (try? readAffinity(characterID: plan.characterID, now: now))
            ?? .fresh(at: now)
        guard Self.momentAllowsMoments(affinity) else { return }
        let today = Self.isoDay(now, in: Self.momentTokyo)
        if plan.planDay != today, plan.kind != .work { return }
        let counts = (try? momentPostCounts(day: plan.planDay)) ?? [:]
        guard (counts[character.id] ?? 0) == 0 else { return }
        guard counts.values.reduce(0, +) < settingsNow.dailyPosts else { return }

        var work: [(job: WeeklyJob, end: Date)]? = nil
        if plan.kind == .work {
            let todays: [(job: WeeklyJob, end: Date)]? =
                (try? momentTodaysWork(characterID: character.id, now: now)) ?? nil
            let done = (todays ?? []).filter { $0.end <= now }
            guard !done.isEmpty else {
                // The work is not finished at its time: push it a little, and give up once
                // its day is long past.
                if now.timeIntervalSince(plan.dueAt) < 24 * 3600 {
                    try? pushMomentPlan(plan.id, to: now.addingTimeInterval(30 * 60))
                    completed = false
                }
                return
            }
            work = done
        }

        let id = await generateMomentPost(
            characterID: character.id, planDay: plan.planDay, birthday: plan.birthday,
            work: work, now: now, settings: settingsNow, providers: providers,
            random: &random
        )
        if let id {
            run.newPosts.append(id)
            run.generated += 1
        } else {
            run.failed += 1
        }
    }

    func generateMomentPost(
        characterID: String,
        planDay: String,
        birthday: Bool,
        work: [(job: WeeklyJob, end: Date)]?,
        now: Date,
        settings: MomentsSettings,
        providers: MomentsProviders,
        random: inout SeededRandom
    ) async -> String? {
        guard let character = try? characters().first(where: { $0.id == characterID }) else {
            return nil
        }
        let world = try? loadWorld()
        let producer = (try? producerProfile()) ?? .default
        let characters = (try? characters()) ?? []
        let todayLines = TodayPrompt.lines(
            now: now, character: character, characters: characters,
            unitMates: world?.unitMates(of: character.name) ?? [],
            herLives: world?.livesOf(character.name) ?? [],
            holidays: try? holidayTable()
        )
        let weather = await providers.weather?.weather(at: now)
        let candidates = (try? momentPlaceCandidates(
            character: character, work: work, now: now, todayLines: todayLines,
            wet: weather?.kind.isWet ?? false, random: &random
        )) ?? []
        let circle = momentCircle(
            character: character, characters: characters,
            birthday: birthday, now: now, random: &random
        )
        let seeds = work.map { jobs in
            jobs.map { "\($0.job.name)：\($0.job.note)" }
        } ?? momentSeeds(character: character, random: &random)
        let memories = momentMemories(characterID: character.id)
        let recent = (try? momentRecentPosts(characterID: character.id, limit: 5)) ?? []
        let allowedCompositions = momentAllowedCompositions(providers: providers)
        let wantImage = !allowedCompositions.isEmpty && random.below(3) < 2
        let compositions = wantImage ? allowedCompositions : []
        let prompt = (try? momentPostPrompt(
            character: character, world: world, producer: producer, now: now,
            todayLines: todayLines, weather: weather, seeds: seeds, memories: memories,
            recent: recent, circle: circle, places: candidates,
            compositions: compositions, work: work != nil
        )) ?? []
        guard !prompt.isEmpty else { return nil }

        let answer = await momentChatAnswer(prompt, providers: providers)
        let draft = answer.failure == nil ? Self.parseMomentDraft(answer.raw) : nil
        let failure = answer.failure ?? (draft == nil ? "朋友圈格式不对" : nil)
        await recordChatCall(
            provider: providers.chat, operation: .moment, prompts: [prompt],
            output: answer.raw, latency: answer.latency, error: failure,
            conversationID: nil, at: now
        )
        guard let draft else { return nil }

        var place: Place?
        if let placeID = draft.placeID,
           let chosen = candidates.first(where: { $0.id == placeID }) {
            place = chosen
        }
        let postID = UUID().uuidString
        let snapshot = place.map {
            MomentPlaceSnapshot(
                id: $0.id, name: $0.name, area: $0.area,
                lat: $0.latitude, lon: $0.longitude
            )
        }
        try? await userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO moment_posts(
                        id, character_id, ja, zh, plan_day, reveal_at, created_at,
                        place_id, place_name, place_area, place_lat, place_lon,
                        weather_code, weather_temperature
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    postID, character.id, draft.ja, draft.zh, planDay,
                    Self.timestamp(now), Self.timestamp(now),
                    snapshot?.id, snapshot?.name, snapshot?.area, snapshot?.lat, snapshot?.lon,
                    weather.map { $0.kind.rawValue }, weather?.temperature,
                ]
            )
        }
        if let image = draft.image, compositions.contains(image.composition) {
            _ = await makeMomentImage(
                postID: postID, draft: image, character: character, characters: characters,
                now: now, settings: settings, providers: providers
            )
        }
        insertMomentReactions(
            postID: postID, draft: draft, circle: circle, birthday: birthday,
            now: now, random: &random
        )
        return postID
    }

    func insertMomentReactions(
        postID: String, draft: MomentDraft, circle: [CharacterConfig],
        birthday: Bool, now: Date, random: inout SeededRandom
    ) {
        let byID = Dictionary(uniqueKeysWithValues: circle.map { ($0.id, $0) })
        let byName = Dictionary(uniqueKeysWithValues: circle.map { ($0.name, $0) })
        // The people standing in a group picture were there too, so they like it.
        let group = draft.image?.composition == .group ? draft.image?.with ?? [] : []
        let likes = Array((draft.likes + group).prefix(birthday ? 10 : 6))
        let comments = Array(draft.comments.prefix(birthday ? 6 : 3))
        var position = 0
        var seen = Set<String>()
        try? userQueue.write { db in
            for raw in likes {
                guard let character = byID[raw] ?? byName[raw],
                      seen.insert(character.id).inserted
                else { continue }
                let minutes = 5 + random.below(176)
                try db.execute(
                    sql: """
                        INSERT INTO moment_reactions(
                            id, post_id, character_id, kind, ja, zh, position, reveal_at
                        ) VALUES (?, ?, ?, 'like', NULL, NULL, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, postID, character.id, position,
                        Self.timestamp(now.addingTimeInterval(TimeInterval(minutes * 60))),
                    ]
                )
                position += 1
            }
            for comment in comments {
                guard let character = byID[comment.from] ?? byName[comment.from],
                      seen.insert(character.id).inserted
                else { continue }
                let minutes = 15 + random.below(346)
                try db.execute(
                    sql: """
                        INSERT INTO moment_reactions(
                            id, post_id, character_id, kind, ja, zh, position, reveal_at
                        ) VALUES (?, ?, ?, 'comment', ?, ?, ?, ?)
                        """,
                    arguments: [
                        UUID().uuidString, postID, character.id, comment.ja, comment.zh,
                        position,
                        Self.timestamp(now.addingTimeInterval(TimeInterval(minutes * 60))),
                    ]
                )
                position += 1
            }
        }
    }

    // MARK: Places

    static func momentSeason(_ now: Date) -> PlaceSeason {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = momentTokyo
        let month = calendar.component(.month, from: now)
        switch month {
        case 3...5: return .spring
        case 6...8: return .summer
        case 9...11: return .autumn
        default: return .winter
        }
    }

    static func momentSlot(_ now: Date) -> PlaceSlot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = momentTokyo
        let hour = calendar.component(.hour, from: now)
        if hour >= 5, hour < 12 { return .morning }
        if hour >= 12, hour < 18 { return .afternoon }
        return .evening
    }

    func momentPlaceCandidates(
        character: CharacterConfig,
        work: [(job: WeeklyJob, end: Date)]?,
        now: Date,
        todayLines: [String],
        wet: Bool,
        random: inout SeededRandom
    ) throws -> [Place] {
        let all = try (places()?.places ?? [])
        guard !all.isEmpty else { return [] }
        let used = try momentRecentlyUsedPlaces(now: now)
        var categories: Set<String>? = nil
        if let work, !work.isEmpty {
            let listed = (try? jobList()) ?? []
            let byID = Dictionary(uniqueKeysWithValues: listed.map { ($0.id, $0) })
            // Only the categories today's work puts her in; a job that names none leaves
            // the post without a place rather than a random one.
            categories = Set(work.compactMap { byID[$0.job.listedID]?.places }.flatMap { $0 })
        }
        let season = Self.momentSeason(now)
        let slot = Self.momentSlot(now)
        var pool: [(Place, Int)] = []
        for place in all {
            if used.contains(place.id) { continue }
            if let categories, !categories.contains(place.category.rawValue) { continue }
            if !place.seasons.isEmpty, !place.seasons.contains(season) {
                continue
            }
            if !place.slots.isEmpty, !place.slots.contains(slot) { continue }
            if wet, !place.category.isIndoor { continue }
            if place.category == .venue, work == nil,
               !todayLines.contains(where: {
                   $0.contains("站上") || $0.contains("演出") || $0.contains("ライブ")
               }) {
                continue
            }
            var weight = 1
            if character.placeLikes.contains(place.category.rawValue) { weight += 3 }
            if place.idols.contains(character.id) { weight += 3 }
            pool.append((place, weight))
        }
        var picked: [Place] = []
        while picked.count < 4, !pool.isEmpty {
            let total = pool.reduce(0) { $0 + $1.1 }
            var pick = random.below(total)
            var index = 0
            for (offset, entry) in pool.enumerated() {
                if pick < entry.1 { index = offset; break }
                pick -= entry.1
            }
            picked.append(pool.remove(at: index).0)
        }
        return picked
    }

    func momentRecentlyUsedPlaces(now: Date) throws -> Set<String> {
        let cutoff = Self.timestamp(now.addingTimeInterval(-30 * 24 * 3600))
        return try userQueue.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT place_id FROM moment_posts WHERE place_id IS NOT NULL AND reveal_at >= ?",
                arguments: [cutoff]
            ))
        }
    }

    // MARK: Circle, seeds, memories

    func momentCircle(
        character: CharacterConfig, characters: [CharacterConfig],
        birthday: Bool, now: Date, random: inout SeededRandom
    ) -> [CharacterConfig] {
        let target = birthday ? 8 + random.below(3) : 4 + random.below(3)
        var mates: [CharacterConfig] = []
        var others: [CharacterConfig] = []
        for other in characters where other.id != character.id {
            if let herUnit = character.unit, other.unit == herUnit {
                mates.append(other)
            } else {
                others.append(other)
            }
        }
        random.shuffle(&mates)
        random.shuffle(&others)

        var circle: [CharacterConfig] = []
        var chosen = Set<String>()
        func add(_ people: [CharacterConfig]) {
            for person in people where circle.count < target && chosen.insert(person.id).inserted {
                circle.append(person)
            }
        }
        // Birthday first, then the people her own facts name in 人物关系, then her unit.
        add(mates.filter { Self.isMomentBirthday($0.birthday, now: now) })
        add(momentRelatedCharacters(character, characters: characters))
        add(mates)
        // One from another unit now and then, so the circle does not close in on itself.
        if circle.count < target, !others.isEmpty, random.below(100) < 40 {
            add([others.removeFirst()])
        }
        add(others.filter { $0.photoTag != nil })
        return circle
    }

    /// Other characters her facts name under 人物关系: the people she would naturally
    /// bring into a moment even when they are in another unit.
    func momentRelatedCharacters(
        _ character: CharacterConfig, characters: [CharacterConfig]
    ) -> [CharacterConfig] {
        guard let facts = character.facts,
              let text = try? String(
                contentsOf: location.contentDirectory.appendingPathComponent(facts),
                encoding: .utf8
              )
        else { return [] }
        var inRelations = false
        var lines: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inRelations = line.contains("人物关系") || line.contains("关系")
                continue
            }
            guard inRelations, !line.isEmpty else { continue }
            lines.append(line)
        }
        let relations = lines.joined(separator: "\n")
        guard !relations.isEmpty else { return [] }
        return characters.filter {
            $0.id != character.id && relations.contains($0.name)
        }
    }

    func momentSeeds(character: CharacterConfig, random: inout SeededRandom) -> [String] {
        guard let facts = character.facts,
              let text = try? String(
                contentsOf: location.contentDirectory.appendingPathComponent(facts),
                encoding: .utf8
              )
        else { return [] }
        var lines: [String] = []
        var skip = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                skip = line.contains("人物关系") || line.contains("关系")
                continue
            }
            guard !skip, !line.isEmpty else { continue }
            lines.append(line)
        }
        random.shuffle(&lines)
        return Array(lines.prefix(3))
    }

    func momentMemories(characterID: String) -> [String] {
        ((try? memories()) ?? [])
            .filter { $0.holds && $0.sourceCharacterID == characterID }
            .suffix(5)
            .map(\.text)
    }

    func momentRecentPosts(characterID: String, limit: Int) throws -> [String] {
        try userQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT ja, reveal_at, (SELECT note FROM moment_images i WHERE i.post_id = p.id)
                        AS note
                    FROM moment_posts p WHERE character_id = ?
                    ORDER BY reveal_at DESC LIMIT ?
                    """,
                arguments: [characterID, limit]
            )
            return rows.map { row in
                let ja: String = row["ja"]
                let note: String? = row["note"]
                return note.map { "\(ja)（配图：\($0)）" } ?? ja
            }
        }
    }
}

// MARK: - The prompt

extension Eidolon {
    func momentSheet(_ character: CharacterConfig) -> String {
        guard let path = character.sheet else { return "" }
        return CharacterSheet.read(
            characterID: character.id, sheetPath: path,
            in: location.contentDirectory
        ) ?? ""
    }

    func momentPostPrompt(
        character: CharacterConfig,
        world: WorldSetting?,
        producer: ProducerProfile,
        now: Date,
        todayLines: [String],
        weather: MomentWeather?,
        seeds: [String],
        memories: [String],
        recent: [String],
        circle: [CharacterConfig],
        places: [Place],
        compositions: [MomentComposition] = [],
        work: Bool = false
    ) throws -> [PromptMessage] {
        var shared = [momentSheet(character)]
        if let birthday = character.birthday {
            shared.append(TodayPrompt.herBirthday(birthday))
        }
        if let world {
            shared.append(world.prompt(name: character.name, today: Self.isoDay(now, in: Self.momentTokyo)))
        }
        shared.append(Self.momentFormat(
            places: places, circle: circle,
            birthday: Self.isMomentBirthday(character.birthday, now: now),
            compositions: compositions
        ))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.momentTokyo
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[((parts.weekday ?? 1) + 5) % 7]
        var context = [
            "# 此刻（朋友圈）",
            "现在是 \(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日（星期\(weekday)）\(clock)（东京）。",
        ]
        if let weather {
            context.append("东京此刻的天气：\(weather.kind.title)，\(weather.temperature)℃。")
        }
        if !todayLines.isEmpty {
            context.append("今天：\n" + todayLines.joined(separator: "\n"))
        }
        let affinity = try? readAffinity(characterID: character.id, now: now)
        let affinityLines = AffinityPrompt.lines(
            tier: affinity?.tier ?? .trust, judged: nil, parting: nil, warning: nil,
            shielded: false
        )
        context.append(contentsOf: affinityLines)
        if !seeds.isEmpty {
            context.append("# 可以写进这条动态的事\n" + seeds.map { "- \($0)" }.joined(separator: "\n"))
        }
        if work {
            context.append("# 这条动态\n写今天做完的工作，把几件事串起来，不要只写最后一件。")
        }
        if !memories.isEmpty {
            context.append("# 你记得的事\n" + memories.map { "- \($0)" }.joined(separator: "\n"))
        }
        if !recent.isEmpty {
            context.append(
                "# 你最近发的朋友圈（不要重复这些内容）\n"
                    + recent.map { "- \($0)" }.joined(separator: "\n")
            )
        }
        if !circle.isEmpty {
            context.append(
                "# 这条动态的圈子\n"
                    + circle.map { "\($0.id)（\($0.name)）" }.joined(separator: "、")
            )
        }
        if !places.isEmpty {
            context.append(
                "# 地点候选\n"
                    + places.map { "\($0.id)｜\($0.name)（\($0.area)）：\($0.note)" }
                    .joined(separator: "\n")
            )
        }

        return [
            PromptMessage(.system, shared.joined(separator: "\n\n")),
            PromptMessage(.system, producer.prompt),
            PromptMessage(.system, context.joined(separator: "\n\n")),
            PromptMessage(.user, "（你想发一条朋友圈。）"),
        ]
    }

    static func momentFormat(
        places: [Place], circle: [CharacterConfig], birthday: Bool,
        compositions: [MomentComposition] = []
    ) -> String {
        var format = """
            # 朋友圈写法
            你在发今天的一条朋友圈，不是回复消息，不是公告，也不是台词。只输出下面这些标签，
            标签外不要写任何文字：
            <post><ja>日语正文</ja><zh>中文字幕</zh></post>
            """
        if !places.isEmpty {
            format += "\n<place>从地点候选里选一个 id，或 none</place>"
        }
        if !circle.isEmpty {
            format += """

                <likes>赞了这条的人，用逗号隔开，只能从圈子里选</likes>
                <comment from="圈子里的人"><ja>…</ja><zh>…</zh></comment>
                """
        }
        format += """


            正文 1–3 句日语，像随手发的，不写 # 话题、不 @ 任何人、不带语气提示；
            中文字幕只翻译正文。一条动态只写一次，不要写照片标签。
            """
        if !compositions.isEmpty {
            format += """

                <image>
                composition: 从这次允许的构图里选一个
                shot: other
                framing: upper body
                with: none
                place: 英文 tag，地点、室内外、光线
                outfit: 英文 tag
                action: 英文 tag
                note: 中文一句，写画面里发生的事
                </image>
                这次可以用的构图：\(compositions.map(\.title).joined(separator: "、"))。
                大约三分之二的动态带一张配图；不想配图就不写 <image>。
                风景、食物、物品的画面里不能有人；合照的 with 写 1–2 位圈子成员的 id。
                """
        }
        if birthday {
            format += "\n今天是你的生日：这一天评论区会比平时热闹，赞和评论都可以多一些。"
        }
        return format
    }

    static func parseMomentDraft(_ raw: String) -> MomentDraft? {
        func slice(_ text: String, _ tag: String) -> String? {
            guard let open = text.range(of: "<\(tag)>"),
                  let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex)
            else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var body = raw
        var post: String? = nil
        if let open = raw.range(of: "<post>"),
           let close = raw.range(of: "</post>", range: open.upperBound..<raw.endIndex) {
            post = String(raw[open.upperBound..<close.lowerBound])
        }
        if let post { body = post }
        guard let ja = slice(body, "ja"), !ja.isEmpty,
              let zh = slice(body, "zh"), !zh.isEmpty
        else { return nil }
        let placeID = slice(raw, "place").flatMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.lowercased() == "none" ? nil : trimmed
        }
        let likes = (slice(raw, "likes") ?? "")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "、", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var comments: [(from: String, ja: String, zh: String)] = []
        if let regex = try? NSRegularExpression(
            pattern: "<comment\\s+from=\"([^\"]+)\"[^>]*>(.*?)</comment>",
            options: [.dotMatchesLineSeparators]
        ) {
            let text = raw as NSString
            let matches = regex.matches(in: raw, range: NSRange(location: 0, length: text.length))
            for match in matches {
                guard match.numberOfRanges > 2 else { continue }
                let from = text.substring(with: match.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let inside = text.substring(with: match.range(at: 2))
                guard let commentJA = slice(inside, "ja"), !commentJA.isEmpty,
                      let commentZH = slice(inside, "zh"), !commentZH.isEmpty
                else { continue }
                comments.append((from, commentJA, commentZH))
            }
        }
        var image: MomentImageDraft?
        if let open = raw.range(of: "<image>"),
           let close = raw.range(of: "</image>", range: open.upperBound..<raw.endIndex) {
            image = MomentImageDraft(text: String(raw[open.upperBound..<close.lowerBound]))
        }
        return MomentDraft(
            ja: ja, zh: zh, placeID: placeID, likes: likes, comments: comments,
            image: image
        )
    }
}

// MARK: - Her reply to the producer

extension Eidolon {
    func processMomentReplies(
        now: Date,
        settings: MomentsSettings,
        providers: MomentsProviders,
        run: inout MomentsRun
    ) async {
        guard settings.enabled, settings.dailyReplies > 0 else { return }
        let targets = (try? momentDueReplies(now: now)) ?? []
        for target in targets {
            guard let character = try? characters().first(where: { $0.id == target.characterID })
            else { continue }
            let affinity = (try? readAffinity(characterID: character.id, now: now))
                ?? .fresh(at: now)
            guard Self.momentAllowsMoments(affinity),
                  (try? momentRepliesToday(now: now)) ?? 0 < settings.dailyReplies
            else { continue }
            let reply = await generateMomentReply(
                target, character: character, now: now, providers: providers
            )
            if let reply {
                try? await userQueue.write { db in
                    try db.execute(
                        sql: """
                            UPDATE moment_comments
                            SET reply_ja = ?, reply_zh = ?, reply_at = ?
                            WHERE post_id = ? AND reply_at IS NULL
                            """,
                        arguments: [reply.ja, reply.zh, Self.timestamp(now), target.postID]
                    )
                }
                run.newReplies.append(target.postID)
                run.generated += 1
            } else {
                // A failed reply does not count and is not retried.
                try? await userQueue.write { db in
                    try db.execute(
                        sql: "UPDATE moment_comments SET reply_reveal_at = NULL WHERE post_id = ?",
                        arguments: [target.postID]
                    )
                }
                run.failed += 1
            }
        }
    }

    /// One streamed answer from the chat model, timed, for both posts and replies.
    struct MomentChatAnswer {
        var raw: String
        var failure: String?
        var latency: TimeInterval
    }

    func momentChatAnswer(
        _ prompt: [PromptMessage], providers: MomentsProviders
    ) async -> MomentChatAnswer {
        let started = Date()
        var raw = ""
        var failure: String?
        do {
            for try await delta in providers.chat.stream(messages: prompt) {
                raw += delta
            }
        } catch {
            failure = error.localizedDescription
        }
        return MomentChatAnswer(
            raw: raw, failure: failure, latency: Date().timeIntervalSince(started)
        )
    }

    struct MomentReplyTarget {
        var postID: String
        var characterID: String
        var ja: String
        var zh: String
        var imageNote: String?
        var liked: Bool
        var comment: String
        var idolComments: [(name: String, ja: String, zh: String)]
    }

    func momentDueReplies(now: Date) throws -> [MomentReplyTarget] {
        let stamp = Self.timestamp(now)
        let rows = try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT c.post_id, c.text, p.character_id, p.ja, p.zh,
                        (SELECT note FROM moment_images i WHERE i.post_id = p.id) AS image_note,
                        EXISTS(SELECT 1 FROM moment_likes l WHERE l.post_id = p.id) AS liked
                    FROM moment_comments c
                    JOIN moment_posts p ON p.id = c.post_id
                    WHERE c.reply_reveal_at IS NOT NULL AND c.reply_at IS NULL
                        AND c.reply_reveal_at <= ? AND p.reveal_at <= ?
                    """,
                arguments: [stamp, stamp]
            )
        }
        let names = Dictionary(
            uniqueKeysWithValues: ((try? characters()) ?? []).map { ($0.id, $0.name) }
        )
        return rows.map { row in
            let postID: String = row["post_id"]
            let idolComments = (try? userQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT character_id, ja, zh FROM moment_reactions
                        WHERE post_id = ? AND kind = 'comment' AND reveal_at <= ?
                        ORDER BY reveal_at ASC
                        """,
                    arguments: [postID, stamp]
                ).compactMap { reaction -> (String, String, String)? in
                    guard let ja: String = reaction["ja"], let zh: String = reaction["zh"]
                    else { return nil }
                    return (names[reaction["character_id"]] ?? reaction["character_id"], ja, zh)
                }
            }) ?? []
            return MomentReplyTarget(
                postID: postID, characterID: row["character_id"], ja: row["ja"],
                zh: row["zh"], imageNote: row["image_note"],
                liked: (row["liked"] as Int) == 1, comment: row["text"],
                idolComments: idolComments
            )
        }
    }

    func momentRepliesToday(now: Date) throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.momentTokyo
        let start = calendar.startOfDay(for: now)
        let end = start.addingTimeInterval(24 * 3600)
        return try userQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM moment_comments
                    WHERE reply_at IS NOT NULL AND reply_at >= ? AND reply_at < ?
                    """,
                arguments: [Self.timestamp(start), Self.timestamp(end)]
            ) ?? 0
        }
    }

    func generateMomentReply(
        _ target: MomentReplyTarget, character: CharacterConfig, now: Date,
        providers: MomentsProviders
    ) async -> (ja: String, zh: String)? {
        let producer = (try? producerProfile()) ?? .default
        let world = try? loadWorld()
        let characters = (try? characters()) ?? []
        let todayLines = TodayPrompt.lines(
            now: now, character: character, characters: characters,
            unitMates: world?.unitMates(of: character.name) ?? [],
            herLives: world?.livesOf(character.name) ?? [],
            holidays: try? holidayTable()
        )
        let weather = await providers.weather?.weather(at: now)
        var shared = [momentSheet(character)]
        if let birthday = character.birthday {
            shared.append(TodayPrompt.herBirthday(birthday))
        }
        if let world {
            shared.append(world.prompt(name: character.name, today: Self.isoDay(now, in: Self.momentTokyo)))
        }
        shared.append("""
            # 回评论
            你在自己的朋友圈下面回复制作人的评论。只输出一对标签：
            <ja>日语</ja><zh>中文字幕</zh>
            一两句口语，评论区口吻；不发照片，不带语气提示，不写 # 或 @。
            """)
        // What is going on right now colors the reply as much as it colors a post.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.momentTokyo
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        let weekday = weekdays[((parts.weekday ?? 1) + 5) % 7]
        var context = [
            "# 此刻（朋友圈评论区）",
            "现在是 \(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日（星期\(weekday)）\(clock)（东京）。",
        ]
        if let weather {
            context.append("东京此刻的天气：\(weather.kind.title)，\(weather.temperature)℃。")
        }
        if !todayLines.isEmpty {
            context.append("今天：\n" + todayLines.joined(separator: "\n"))
        }
        let affinity = (try? readAffinity(characterID: character.id, now: now))
            ?? .fresh(at: now)
        context.append(contentsOf: AffinityPrompt.lines(
            tier: affinity.tier, judged: nil, parting: nil, warning: nil, shielded: false
        ))
        if let cycle = try? cycleLines(
            characterID: character.id, now: now, timeZone: Self.momentTokyo
        ), !cycle.isEmpty {
            context.append(contentsOf: cycle)
        }
        context.append("# 这条动态")
        context.append(target.ja)
        if let note = target.imageNote, !note.isEmpty {
            context.append("（配图：\(note)）")
        }
        if !target.idolComments.isEmpty {
            context.append(
                "# 已经露出的偶像评论\n"
                    + target.idolComments.map { "\($0.name)：\($0.ja)（\($0.zh)）" }
                    .joined(separator: "\n")
            )
        }
        context.append("# 制作人")
        context.append(target.liked ? "他赞了这条动态。" : "他没有赞这条动态。")
        context.append("他评论：「\(target.comment)」")
        if let turns = try? momentRecentTurns(characterID: character.id, limit: 6),
           !turns.isEmpty {
            context.append("# 你们最近说的话\n" + turns.joined(separator: "\n"))
        }
        let prompt = [
            PromptMessage(.system, shared.joined(separator: "\n\n")),
            PromptMessage(.system, producer.prompt),
            PromptMessage(.system, context.joined(separator: "\n\n")),
            PromptMessage(.user, "（你在朋友圈回复制作人的评论。）"),
        ]
        let answer = await momentChatAnswer(prompt, providers: providers)
        let pair = answer.failure == nil ? Self.parseMomentReply(answer.raw) : nil
        let failure = answer.failure ?? (pair == nil ? "回复格式不对" : nil)
        await recordChatCall(
            provider: providers.chat, operation: .momentReply, prompts: [prompt],
            output: answer.raw, latency: answer.latency, error: failure,
            conversationID: nil, at: now
        )
        return pair
    }

    static func parseMomentReply(_ raw: String) -> (ja: String, zh: String)? {
        func slice(_ tag: String) -> String? {
            guard let open = raw.range(of: "<\(tag)>"),
                  let close = raw.range(of: "</\(tag)>", range: open.upperBound..<raw.endIndex)
            else { return nil }
            let text = String(raw[open.upperBound..<close.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        guard let ja = slice("ja"), let zh = slice("zh") else { return nil }
        return (ja, zh)
    }

    func momentRecentTurns(characterID: String, limit: Int) throws -> [String] {
        guard let conversationID = try currentConversationID(characterID) else { return [] }
        return try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT role, text, blocks, segments FROM messages
                    WHERE conversation_id = ? ORDER BY created_at DESC LIMIT ?
                    """,
                arguments: [conversationID, limit]
            ).reversed().map { row in
                let role: String = row["role"]
                if role == "user" {
                    return "制作人：\(row["text"] ?? "")"
                }
                let blocks = Self.decodeBlocks(row["blocks"]) ?? []
                if !blocks.isEmpty {
                    return "她：" + blocks.map { block in
                        switch block {
                        case let .line(line): line.ja
                        case let .scene(scene): "（\(scene)）"
                        }
                    }.joined()
                }
                return "她：" + Self.decodeSegments(row["segments"]).map(\.ja).joined()
            }
        }
    }
}

// MARK: - Cleanup

extension Eidolon {
    /// Drops posts past 30 days with everything on them, and the pictures of vanished
    /// posts. Failures are the caller's to ignore: cleanup never blocks a launch.
    func cleanupMoments(now: Date) throws {
        let cutoff = Self.timestamp(now.addingTimeInterval(-Self.momentRetention))
        // A few hundred at a time, so a first cleanup on an old library never holds the
        // database for long.
        while true {
            let batch = try userQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT p.id, i.file FROM moment_posts p
                        LEFT JOIN moment_images i ON i.post_id = p.id
                        WHERE p.reveal_at < ? LIMIT 200
                        """,
                    arguments: [cutoff]
                )
            }
            guard !batch.isEmpty else { break }
            let ids = Array(Set(batch.map { $0["id"] as String }))
            let files = batch.compactMap { $0["file"] as String? }
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
            try userQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM moment_posts WHERE id IN (\(marks))",
                    arguments: StatementArguments(ids)
                )
            }
            for file in files {
                try? FileManager.default.removeItem(
                    at: location.userDirectory.appendingPathComponent(file)
                )
            }
        }
        try userQueue.write { db in
            try db.execute(
                sql: "DELETE FROM moment_plans WHERE plan_day < ?",
                arguments: [Self.isoDay(now.addingTimeInterval(-24 * 3600), in: Self.momentTokyo)]
            )
        }
        try removeOrphanMomentImages()
    }

    func removeOrphanMomentImages() throws {
        let directory = location.userDirectory.appendingPathComponent("images/moments")
        let known = Set(try userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT file FROM moment_images")
        })
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            let relative = "images/moments/" + file.lastPathComponent
            if !known.contains(relative) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

// MARK: - What she remembers of it in a conversation

extension Eidolon {
    /// The 「你最近发的朋友圈」 section for the now prompt: the last three days' posts that
    /// have gone out, at most three, each with the producer's like and comment and her
    /// reply. Empty when moments are off or she has none, so the prompt is unchanged then.
    func momentPromptLines(
        characterID: String, now: Date, timeZone: TimeZone
    ) throws -> [String] {
        let settings = (try? momentsSettings()) ?? .default
        guard settings.enabled else { return [] }
        let cutoff = Self.timestamp(now.addingTimeInterval(-3 * 24 * 3600))
        let stamp = Self.timestamp(now)
        let rows = try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.ja, p.reveal_at,
                        (SELECT note FROM moment_images i WHERE i.post_id = p.id) AS note,
                        EXISTS(SELECT 1 FROM moment_likes l WHERE l.post_id = p.id) AS liked,
                        c.text AS comment, c.reply_ja AS reply, c.reply_at AS reply_at
                    FROM moment_posts p
                    LEFT JOIN moment_comments c ON c.post_id = p.id
                    WHERE p.character_id = ? AND p.reveal_at >= ? AND p.reveal_at <= ?
                    ORDER BY p.reveal_at DESC LIMIT 3
                    """,
                arguments: [characterID, cutoff, stamp]
            )
        }
        guard !rows.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        func when(_ date: Date) -> String {
            let day = calendar.startOfDay(for: date)
            let days = Int(today.timeIntervalSince(day) / 86_400)
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
            let prefix: String = switch days {
            case 0: "今天"
            case 1: "昨天"
            case 2: "前天"
            default:
                {
                    let parts = calendar.dateComponents([.month, .day], from: date)
                    return "\(parts.month ?? 0)月\(parts.day ?? 0)日"
                }()
            }
            return "\(prefix) \(clock)"
        }
        var lines = ["# 你最近发的朋友圈"]
        for row in rows {
            var line = "\(when(Self.parseTimestamp(row["reveal_at"]) ?? now))　\(row["ja"] as String)"
            if let note: String = row["note"], !note.isEmpty {
                line += "（配图：\(note)）"
            }
            let liked = (row["liked"] as Int) == 1
            let comment: String? = row["comment"]
            let reply: String? = row["reply"]
            if let comment, !comment.isEmpty {
                line += liked ? "　制作人赞了；他评论「\(comment)」" : "　他评论「\(comment)」"
                if (row["reply_at"] as String?) != nil, let reply, !reply.isEmpty {
                    line += "，你回了「\(reply)」"
                }
            } else if liked {
                line += "　制作人赞了"
            } else {
                line += "　他还没赞也没评论"
            }
            lines.append(line)
        }
        lines.append(
            "- 可以主动提起；他没赞也没评论时，不要抱怨，也不要追问。"
                + "只有亲密、亲近档可以带一点期待，最多提一次。"
        )
        return lines
    }
}
