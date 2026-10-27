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

public enum ReachOutRules {
    /// How long after the last thing said she may reach out (ADR-0009); the app lets the
    /// producer change it.
    public static let defaultHours: Double = 6

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

    /// Where the producer's words would be, so the prompt ends with the user as a turn does.
    static let wantsToReachOut = "（制作人这会儿没在和你说话。你想先给他发几句。）"
}

extension Eidolon {
    /// Whether she reaches out now, and if so, what she says: only in the conversation in
    /// progress, only once the producer has been away longer than `hours`, and only once
    /// per stretch of absence.
    @discardableResult
    public func reachOutIfDue(
        characterID: String,
        provider: any ChatProvider,
        embedder: (any EmbeddingProvider)? = nil,
        reranker: (any RerankProvider)? = nil,
        hours: Double = ReachOutRules.defaultHours,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> ReachOutRecord? {
        guard let conversationID = try currentConversationID(characterID) else { return nil }
        guard try !isEnded(conversationID: conversationID) else { return nil }
        let affinity = try readAffinity(characterID: characterID, now: now)
        guard !affinity.cooling else { return nil }
        guard let contact = try lastContact(conversationID: conversationID) else { return nil }
        guard now.timeIntervalSince(contact) > hours * 3600 else { return nil }
        guard try !reachedOut(since: contact, conversationID: conversationID) else { return nil }

        let characters = try characters()
        guard let character = characters.first(where: { $0.id == characterID }) else {
            return nil
        }
        let world = try loadWorld()
        let producer = try producerProfile()
        let zone = producer.timezone.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let reading = try promptRecord(conversationID: conversationID, turns: 20, timeZone: zone)
        let todayLines = TodayPrompt.lines(
            now: now,
            character: character,
            characters: characters,
            unitMates: world?.unitMates(of: character.name) ?? [],
            herLives: world?.livesOf(character.name) ?? [],
            holidays: try? holidayTable()
        )
        let nowText = NowPrompt.text(
            now: now,
            timeZone: zone,
            talking: .apart,
            affinityLines: AffinityPrompt.lines(tier: affinity.tier, judged: nil),
            lastContact: contact,
            birthday: producer.birthday,
            todayLines: todayLines
        )
        let memories = await reachingOutMemories(
            characterID: characterID,
            query: Self.lastTurnQuery(reading.allMessages),
            embedder: embedder,
            reranker: reranker,
            now: now,
            timeZone: zone
        )
        let nowSection = ([nowText, memories, ReachOutRules.rules]
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
        for try await chunk in provider.stream(messages: prompt) {
            try Task.checkCancellation()
            _ = parser.feed(chunk)
        }
        _ = parser.finish()
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
