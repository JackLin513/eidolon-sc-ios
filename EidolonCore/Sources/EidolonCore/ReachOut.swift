import Foundation
import GRDB

/// Something she says first after a while apart (GLOSSARY.md「搭话」), kept until the
/// producer opens the conversation. It is not one of her turns, but it reads as hers.
public struct ReachOutRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var conversationID: String
    public var segments: [ReplySegment]
    public var seen: Bool
    public var createdAt: String
}

public enum ReachOutCadence: Sendable, Hashable {
    /// After the producer's set number of hours, whatever her tier.
    case fixed(hours: Double)
    /// After a time drawn from her tier's range (upstream `INTERVALS`).
    case byTier
}

public enum ReachOutRules {
    /// How long after the last thing said she may reach out, when the producer has not
    /// set a number (ADR-0009).
    public static let defaultHours: Double = 6

    /// How long after the last contact she reaches out, by her tier: the closer, the
    /// sooner. None in the tiers she does not reach out in (upstream `INTERVALS`).
    static let intervals: [AffinityTier: (low: Double, high: Double)] = [
        .intimate: (3, 6),
        .close: (8, 16),
        .trust: (20, 36),
    ]

    /// How many places in a tier's range her time may be drawn at, evenly apart (upstream
    /// `PLACES`).
    static let places = 1000

    /// How many times she may reach out in a day, over every character (upstream
    /// `DEFAULT_REACH_OUTS_PER_DAY`).
    static let perDay = 3

    /// How long after the last contact she may still reach out (upstream `WINDOW`).
    static let window: TimeInterval = 7 * 86_400

    /// When in the producer's day she does not reach out: from the first to the second
    /// (upstream `NIGHT`). A time that falls there is put off to the morning, which in a
    /// foreground-only app means the next time the app is opened after it.
    static let nightStartHour = 22
    static let nightEndHour = 8

    /// The tiers she reaches out in: trust and above. Cold and distant are not
    /// (upstream `INTERVALS`).
    static func reachesOut(_ tier: AffinityTier) -> Bool {
        intervals[tier] != nil
    }

    /// Where in the tier's range her time is, in [0, 1): one of a thousand evenly spaced
    /// places (upstream `PLACES`), taken from the conversation and the contact, so that
    /// the same stretch of absence keeps the same time without a table of its own.
    static func place(conversationID: String, contact: Date) -> Double {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in "\(conversationID)|\(Eidolon.timestamp(contact))".utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % UInt64(places)) / Double(places)
    }

    /// How long after `contact` she reaches out in `tier`, or nil in the tiers she does
    /// not reach out in.
    static func interval(
        tier: AffinityTier,
        conversationID: String,
        contact: Date
    ) -> TimeInterval? {
        guard let range = intervals[tier] else { return nil }
        let hours = range.low
            + (range.high - range.low) * place(conversationID: conversationID, contact: contact)
        return hours * 3600
    }

    /// Whether `moment` falls in the night of `timeZone`.
    static func isNight(_ moment: Date, in timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let hour = calendar.component(.hour, from: moment)
        return hour >= nightStartHour || hour < nightEndHour
    }

    /// Added where what retrieval found would go, as upstream tells her how to reach out
    /// (upstream `REACH_OUT_RULES`), word for word.
    static let rules = """
        # 先开口
        制作人这会儿没在和你说话，你想先给他发几句。
        - 由头你自己挑：先接着你们最近聊过的事，或者他最近的近况；其次是你这周的工作（如果有）；再其次才是现在的时间、他的生日。
        - 别人的生日、节假日、往年今天的演出不拿来当由头；组合伙伴的生日可以顺口提一句。
        - 不要只发一句空的问候，比如「早安」「在吗」「想你了」，要有具体想说的事。
        - 写一到两段。
        - 别和你前几次先开口时用一样的开头、一样的由头。
        - 说到你自己那边：日程里有的就说日程里的；没有的话只说练习、拍摄、事务所的工作这类平常的事，或者世界设定里快到的 live 和新歌，已经过去的只当回忆说，先对照现在的年份；不要编具体的剧情，也不要说别的偶像做了什么。
        - 不发照片，也不说要给他发照片、要给他打电话。
        - 让他好接话，但不必用问句结尾。
        """

    /// The same rules, with her recent moments offered as a reason to reach out when
    /// there are any (spec #98). Without moments the text is exactly the constant above.
    static func rules(withMoments: Bool) -> String {
        guard withMoments else { return rules }
        return rules.replacingOccurrences(
            of: "再其次才是现在的时间、他的生日。",
            with: "再其次是你最近发的朋友圈（如果有）；最后才是现在的时间、他的生日。"
        )
    }

    /// Where the producer's words would be, so the prompt ends with the user as a turn does.
    static let wantsToReachOut = "（制作人这会儿没在和你说话。你想先给他发几句。）"
}

extension Eidolon {
    /// Whether she reaches out now, and if so, what she says: only in the conversation in
    /// progress, only once the producer has been away for `cadence`, and only once per
    /// stretch of absence, and no more than `ReachOutRules.perDay` times a day.
    @discardableResult
    public func reachOutIfDue(
        characterID: String,
        provider: any ChatProvider,
        embedder: (any EmbeddingProvider)? = nil,
        reranker: (any RerankProvider)? = nil,
        cadence: ReachOutCadence = .fixed(hours: ReachOutRules.defaultHours),
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> ReachOutRecord? {
        guard let conversationID = try currentConversationID(characterID) else { return nil }
        guard try !isEnded(conversationID: conversationID) else { return nil }
        let affinity = try readAffinity(characterID: characterID, now: now)
        guard !affinity.cooling, ReachOutRules.reachesOut(affinity.tier) else { return nil }
        // Their days go by the profile's time zone, when they set one.
        let producer = try producerProfile()
        let zone = producer.timezone.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let recordedEmbedder = embedder.map { RecordingEmbedding(base: $0, eidolon: self) }
        let recordedReranker = reranker.map { RecordingRerank(base: $0, eidolon: self) }
        guard !ReachOutRules.isNight(now, in: zone) else { return nil }
        guard let contact = try lastContact(conversationID: conversationID) else { return nil }
        guard now.timeIntervalSince(contact) <= ReachOutRules.window else { return nil }
        let wait: TimeInterval
        switch cadence {
        case let .fixed(hours):
            wait = hours * 3600
        case .byTier:
            guard let drawn = ReachOutRules.interval(
                tier: affinity.tier,
                conversationID: conversationID,
                contact: contact
            ) else { return nil }
            wait = drawn
        }
        guard now.timeIntervalSince(contact) > wait else { return nil }
        guard try reachedOutToday(in: zone, now: now) < ReachOutRules.perDay else { return nil }
        guard try !reachedOut(since: contact, conversationID: conversationID) else { return nil }

        let characters = try characters()
        guard let character = characters.first(where: { $0.id == characterID }) else {
            return nil
        }
        let world = try loadWorld()
        let reading = try promptRecord(conversationID: conversationID, turns: 20, timeZone: zone)
        let todayLines = TodayPrompt.lines(
            now: now,
            character: character,
            characters: characters,
            unitMates: world?.unitMates(of: character.name) ?? [],
            herLives: world?.livesOf(character.name) ?? [],
            holidays: try? holidayTable()
        )
        let scheduleLines = (try? scheduleLines(
            characterID: characterID, now: now, timeZone: zone
        )) ?? []
        let cycleLines = (try? cycleLines(
            characterID: characterID, now: now, timeZone: zone
        )) ?? []
        let momentLines = (try? momentPromptLines(
            characterID: characterID, now: now, timeZone: zone
        )) ?? []
        let nowText = NowPrompt.text(
            now: now,
            timeZone: zone,
            talking: .apart,
            affinityLines: AffinityPrompt.lines(tier: affinity.tier, judged: nil),
            lastContact: contact,
            birthday: producer.birthday,
            todayLines: todayLines,
            scheduleLines: scheduleLines,
            cycleLines: cycleLines,
            momentsLines: momentLines
        )
        let memories = await reachingOutMemories(
            characterID: characterID,
            query: Self.lastTurnQuery(reading.allMessages),
            embedder: recordedEmbedder,
            reranker: recordedReranker,
            now: now,
            timeZone: zone
        )
        let nowSection = ([nowText, memories, ReachOutRules.rules(withMoments: !momentLines.isEmpty)]
            .compactMap { $0 }
            .joined(separator: "\n\n"))
        let assembler = PromptAssembler(
            bundleDirectory: location.contentDirectory,
            character: character,
            world: world,
            producer: producer,
            today: Self.isoDay(now, in: zone),
            nowSection: nowSection,
            narration: reading.narration,
            currentNarration: reading.trailingNarration
        )
        let prompt = try assembler.prompt(
            history: reading.chatHistory,
            text: ReachOutRules.wantsToReachOut
        )

        var parser = ReplyParser()
        var answer = ""
        let started = Date()
        do {
            for try await chunk in provider.stream(messages: prompt) {
                try Task.checkCancellation()
                answer += chunk
                _ = parser.feed(chunk)
            }
        } catch {
            await recordChatCall(
                provider: provider, operation: .reachOut, prompts: [prompt], output: answer,
                latency: Date().timeIntervalSince(started), error: error.localizedDescription,
                conversationID: conversationID, at: now
            )
            throw error
        }
        _ = parser.finish()
        await recordChatCall(
            provider: provider, operation: .reachOut, prompts: [prompt], output: answer,
            latency: Date().timeIntervalSince(started), error: nil,
            conversationID: conversationID, at: now
        )
        let segments = parser.segments.filter { !($0.ja.isEmpty && $0.zh.isEmpty) }
        guard !segments.isEmpty else { return nil }

        let record = ReachOutRecord(
            id: UUID().uuidString,
            conversationID: conversationID,
            segments: segments,
            seen: false,
            createdAt: Self.timestamp(now)
        )
        try await userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO reach_outs(id, conversation_id, ja, zh, segments, seen, created_at)
                    VALUES (?, ?, ?, ?, ?, 0, ?)
                    """,
                arguments: [
                    record.id, conversationID,
                    segments.map(\.ja).joined(),
                    segments.map(\.zh).joined(),
                    try Self.encodeSegments(segments),
                    record.createdAt,
                ]
            )
        }
        return record
    }

    /// The fewest things she reaches out with: the producer's own words, as people see
    /// the last turn and her answer to it.
    static func lastTurnQuery(_ history: [StoredMessage]) -> String? {
        guard let index = history.lastIndex(where: { $0.role == "user" }) else { return nil }
        let said = history[index].text ?? ""
        let replies = history[(index + 1)...]
            .filter { $0.role == "character" }
            .map { MemoryExtraction.shownText($0) }
        return ([said] + replies).joined(separator: "\n")
    }

    /// The reach-out is the first thing said since the last contact.
    private func reachedOut(since contact: Date, conversationID: String) throws -> Bool {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT created_at FROM reach_outs WHERE conversation_id = ?",
                arguments: [conversationID]
            ).contains { row in
                let stamp: String = row["created_at"]
                return Eidolon.parseTimestamp(stamp).map { $0 >= contact } ?? false
            }
        }
    }

    /// How many times she has reached out today, over every character: the day is the
    /// producer's (upstream `_within_the_day`).
    private func reachedOutToday(in zone: TimeZone, now: Date) throws -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let began = calendar.startOfDay(for: now)
        return try userQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT created_at FROM reach_outs")
                .filter { row in
                    let stamp: String = row["created_at"]
                    guard let at = Eidolon.parseTimestamp(stamp) else { return false }
                    return at >= began
                }
                .count
        }
    }

    /// What she reaches out with: memories told to her that match the last turn, then the
    /// producer's latest news, as a hearsay section (upstream `for_reaching_out`).
    func reachingOutMemories(
        characterID: String,
        query: String?,
        embedder: (any EmbeddingProvider)?,
        reranker: (any RerankProvider)?,
        now: Date,
        timeZone: TimeZone
    ) async -> String? {
        var found: [MemoryRecord] = []
        if let query, let embedder, let vector = try? await embedder.embedQuery(query) {
            let candidates = ((try? await memoryCandidates(
                queryVector: vector,
                limit: RetrievalRules.candidatesPerSource,
                embedder: embedder,
                characterID: characterID
            )) ?? []).filter { $0.sourceCharacterID == characterID }
            if let reranker, !candidates.isEmpty,
               let ranked = try? await reranker.rerank(
                   query: query,
                   documents: candidates.map(\.text)
               ) {
                found = ranked
                    .filter { $0.score >= RetrievalRules.thresholds(for: reranker.model).memories }
                    .prefix(3)
                    .map { candidates[$0.index].record }
            }
        }

        let since = Self.timestamp(now.addingTimeInterval(-14 * 86_400))
        let latest: [MemoryRecord] = (try? await userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_character_id, text, created_at, superseded_by
                    FROM memories
                    WHERE superseded_by IS NULL AND source_character_id = ? AND created_at >= ?
                    ORDER BY created_at DESC LIMIT 5
                    """,
                arguments: [characterID, since]
            ).map { row in
                MemoryRecord(
                    id: row["id"],
                    sourceCharacterID: row["source_character_id"],
                    text: row["text"],
                    createdAt: row["created_at"],
                    supersededBy: row["superseded_by"]
                )
            }
        }) ?? []

        let ids = Set(found.map(\.id))
        let recalled = found + latest.reversed().filter { !ids.contains($0.id) }
        guard !recalled.isEmpty else { return nil }
        return try? await memoriesPrompt(
            recalled,
            characterID: characterID,
            timeZone: timeZone,
            opening: "下面是制作人以前对你说过的事：先是和你们上次聊的可能有关的，再是制作人这两周的近况。"
                + "挑一两件自然地提起，不要逐条复述。"
        )
    }

    /// The producer has opened the conversation: her reach-out is no longer unseen.
    public func markReachOutsSeen(conversationID: String) throws {
        try userQueue.write { db in
            try db.execute(
                sql: "UPDATE reach_outs SET seen = 1 WHERE conversation_id = ? AND seen = 0",
                arguments: [conversationID]
            )
        }
    }
}
