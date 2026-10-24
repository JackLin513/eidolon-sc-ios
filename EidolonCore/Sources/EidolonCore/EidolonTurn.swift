import Foundation
import GRDB

public enum TurnEvent: Sendable {
    case delta(segment: Int, language: ReplyLanguage, text: String)
    /// Her Japanese as it is to be voiced, delivery cues kept (a call voices it per
    /// segment; a text turn ignores it).
    case speechDelta(segment: Int, text: String)
    case finished(TurnRecord)
}

public struct TurnRecord: Sendable, Hashable {
    public var conversationID: String
    public var segments: [ReplySegment]
    /// The reply was cut short because the producer said something else.
    public var stopped: Bool
    public var affinityTier: AffinityTier
    public var cooldownUntil: Date?
    /// She ended the conversation with this turn.
    public var ended: Bool
}

public struct AffinityStatus: Sendable, Hashable {
    public var tier: AffinityTier
    public var cooldownUntil: Date?

    public init(tier: AffinityTier, cooldownUntil: Date? = nil) {
        self.tier = tier
        self.cooldownUntil = cooldownUntil
    }

    public var cooling: Bool { cooldownUntil != nil }
}

public struct ChatMessageRecord: Sendable, Hashable, Identifiable {
    public var id: String
    public var role: String
    public var text: String?
    public var segments: [ReplySegment]
    public var createdAt: String

    public var isFromCharacter: Bool { role == "character" }

    public var japanese: String {
        segments.map(\.ja).joined()
    }

    public var chinese: String {
        segments.map(\.zh).joined()
    }
}

public struct ConversationSnapshot: Sendable, Hashable {
    public var id: String
    public var messages: [ChatMessageRecord]
    public var ended: Bool
}

extension Eidolon {
    /// Sends the producer's line and streams her reply. Persistence happens when the
    /// stream ends, including when it is stopped by the next message.
    public nonisolated func sendTurn(
        characterID: String,
        text: String,
        provider: any ChatProvider,
        judge: (any JudgeProvider)? = nil,
        embedder: (any EmbeddingProvider)? = nil,
        reranker: (any RerankProvider)? = nil,
        historyTurns: Int = 20,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        tracing: TurnTracing = .on,
        talking: NowPrompt.Talking = .typing,
        voicedBy model: String? = nil
    ) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let record = try await self.performTurn(
                        characterID: characterID,
                        text: text,
                        provider: provider,
                        judge: judge,
                        embedder: embedder,
                        reranker: reranker,
                        historyTurns: historyTurns,
                        now: now,
                        timeZone: timeZone,
                        tracing: tracing,
                        talking: talking,
                        voicedBy: model
                    ) { continuation.yield($0) }
                    continuation.yield(.finished(record))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The conversation the next turn will go into, with everything recorded so far; it
    /// may be one she has ended already, which only a new conversation may follow.
    public func currentConversation(characterID: String) throws -> ConversationSnapshot? {
        guard let conversationID = try currentConversationID(characterID) else { return nil }
        return try conversation(id: conversationID)
    }

    /// The newest conversation with her, ended or not: what the app keeps showing after
    /// she ends one, until the next message starts another.
    public func lastConversation(characterID: String) throws -> ConversationSnapshot? {
        let row = try userQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT id, ended_at FROM conversations
                    WHERE character_id = ?
                    ORDER BY created_at DESC, rowid DESC LIMIT 1
                    """,
                arguments: [characterID]
            )
        }
        guard let row else { return nil }
        let id: String = row["id"]
        return ConversationSnapshot(
            id: id,
            messages: try messages(conversationID: id),
            ended: (row["ended_at"] as String?) != nil
        )
    }

    /// What the app shows: the tier, and when a cooldown ends if there is one.
    public func affinityStatus(characterID: String, now: Date = Date()) throws -> AffinityStatus {
        let affinity = try readAffinity(characterID: characterID, now: now)
        return AffinityStatus(tier: affinity.tier, cooldownUntil: affinity.cooldownUntil)
    }

    // MARK: - The turn

    private func performTurn(
        characterID: String,
        text: String,
        provider: any ChatProvider,
        judge: (any JudgeProvider)?,
        embedder: (any EmbeddingProvider)?,
        reranker: (any RerankProvider)?,
        historyTurns: Int,
        now: Date,
        timeZone: TimeZone,
        tracing: TurnTracing,
        talking: NowPrompt.Talking,
        voicedBy model: String?,
        emit: (TurnEvent) -> Void
    ) async throws -> TurnRecord {
        let characters = try characters()
        guard let character = characters.first(where: { $0.id == characterID }) else {
            throw EidolonError.invalidContent("找不到角色 \(characterID)")
        }
        let affinity = try readAffinity(characterID: characterID, now: now)
        if let until = affinity.cooldownUntil {
            throw EidolonError.coolingDown(until)
        }
        // What the producer said last turn is remembered by the time they go on, unless
        // it takes too long.
        await settleMemories()

        let world = try loadWorld()
        let producer = try producerProfile()
        // The producer's days go by the profile's time zone, when they set one.
        let zone = producer.timezone.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let existingConversation = try currentConversationID(characterID)
        if let existingConversation, try isEnded(conversationID: existingConversation) {
            throw EidolonError.conversationEnded
        }
        let history = try existingConversation.map {
            try loadHistory(conversationID: $0, turns: historyTurns)
        } ?? []

        // The judge is advisory (ADR-0005): whatever it says, the turn goes on; failing,
        // the turn looks references up anyway, as upstream does.
        var degradation: [String] = []
        var judgeAnswer: String?
        var verdict: JudgeVerdict?
        if let judge {
            do {
                if let tracingJudge = judge as? any TracingJudgeProvider {
                    let answer = try await tracingJudge.judgedWithRaw(
                        characterName: character.name,
                        history: PromptAssembler.judgeHistory(history),
                        said: text
                    )
                    judgeAnswer = answer.raw
                    verdict = answer.verdict
                } else {
                    verdict = try await judge.judge(
                        characterName: character.name,
                        history: PromptAssembler.judgeHistory(history),
                        said: text
                    )
                }
            } catch {
                if let unreadable = error as? JudgeUnreadable {
                    judgeAnswer = unreadable.raw
                }
                degradation.append(
                    "判断模型失败，本回合不动好感、按资料检索：\(error.localizedDescription)"
                )
            }
        }
        let judged: Judged? = verdict?.affinity
        let need: RetrievalNeed = verdict?.need ?? .references
        let retrieval = RetrievalEngine(
            eidolon: self,
            character: character,
            world: world,
            embedder: embedder,
            reranker: reranker,
            timeZone: zone
        )
        let retrieved = await retrieval.retrieve(history: history, text: text, need: need)

        let cools = try forecastCooling(characterID: characterID, judged: judged, now: now)
        let recent = try existingConversation.map {
            try recentTurns(conversationID: $0)
        } ?? []
        let outOfLineBefore = recent.suffix(AffinityRules.fedUpTurns - 1).filter(\.outOfLine).count
        let hurtBefore = recent.map(\.hurt)
        let ending = ends(
            judged: judged,
            cools: cools,
            outOfLineBefore: outOfLineBefore,
            hurtBefore: hurtBefore
        )
        let warning = warns(
            judged: judged,
            cools: cools,
            outOfLineBefore: outOfLineBefore,
            hurtBefore: hurtBefore
        )
        let affinityLines = AffinityPrompt.lines(
            tier: affinity.tier,
            judged: judged,
            parting: (ending != nil || cools) ? .parts : nil,
            warning: warning ? .parts : nil
        )
        let nowText = NowPrompt.text(
            now: now,
            timeZone: zone,
            talking: talking,
            affinityLines: affinityLines,
            // In a call they are talking right now: no "last time" to tell her.
            lastContact: talking == .inCall
                ? nil
                : try lastContact(conversationID: existingConversation),
            birthday: producer.birthday
        )
        let nowSection = ([nowText, PromptAssembler.cannotSendPhoto, retrieved.memories, retrieved.references]
            .compactMap { $0 }
            .joined(separator: "\n\n"))

        let assembler = PromptAssembler(
            bundleDirectory: location.contentDirectory,
            character: character,
            world: world,
            producer: producer,
            today: Self.isoDay(now, in: zone),
            nowSection: nowSection,
            formatInstructions: ReplyFormatInstructions.forVoice(model: model)
        )
        let messages = try assembler.prompt(history: history, text: text)

        // Each step is shown in the app as it arrives.
        var parser = ReplyParser()
        var stopped = false
        func shown(_ events: [ReplyParserEvent]) {
            for event in events {
                switch event {
                case let .delta(segment, language, text):
                    emit(.delta(segment: segment, language: language, text: text))
                case let .speechDelta(segment, text):
                    emit(.speechDelta(segment: segment, text: text))
                }
            }
        }

        // The tool is offered on every turn retrieval is available, so that what opens
        // each prompt stays the same; the round after a call, and the round after the
        // judge already recalled an episode, are forbidden to call it again.
        let tools = embedder == nil ? [] : [RecallStoryTool.definition]
        let toolProvider = provider as? any ToolChatProvider
        var prompt = messages
        let recalled = retrieved.recalled
        var toolRounds = 0
        var prompts: [[TracedMessage]] = []
        var toolCalls: [String] = []
        var failure: Error?
        do {
            while true {
                prompts.append(prompt.map(TracedMessage.init))
                let forbidden = toolRounds >= 1 || recalled
                var said = ""
                var calls: [ToolCall] = []
                if let toolProvider, !tools.isEmpty {
                    for try await event in toolProvider.stream(
                        messages: prompt,
                        tools: tools,
                        forbidCalls: forbidden
                    ) {
                        try Task.checkCancellation()
                        switch event {
                        case let .text(chunk):
                            said += chunk
                            shown(parser.feed(chunk))
                        case let .toolCalls(made):
                            calls += made
                        }
                    }
                } else {
                    for try await chunk in provider.stream(messages: prompt) {
                        try Task.checkCancellation()
                        said += chunk
                        shown(parser.feed(chunk))
                    }
                }
                shown(parser.finish())

                // A call made when forbidden, or to a tool never offered, is left
                // unanswered; the turn goes on with what she said.
                #if DEBUG
                for call in calls {
                    NSLog("[Eidolon] tool call %@ %@", call.name, call.arguments)
                }
                #endif
                if calls.isEmpty || tools.isEmpty || forbidden { break }
                toolCalls += calls.map { "\($0.name)(\($0.arguments))" }
                prompt.append(PromptMessage(.assistant, said, toolCalls: calls))
                for call in calls {
                    let result = await self.toolResult(call, retrieval: retrieval)
                        + "\n\n" + RecallStoryTool.lastRoundNote
                    prompt.append(PromptMessage(.tool, result, toolCallID: call.id))
                }
                toolRounds += 1
            }
        } catch is CancellationError {
            stopped = true
        } catch let error as URLError where error.code == .cancelled {
            stopped = true
        } catch {
            failure = error
        }

        // What this turn can be gone over by, later: what she was asked, what the judge
        // wrote, what retrieval found and what the fallbacks cost (ADR-0012).
        func recordTrace(_ conversationID: String?, error: String?) {
            guard tracing.enabled else { return }
            var degraded = degradation + retrieved.trace.degradation
            if let error { degraded.append(error) }
            let trace = TurnTrace(
                characterID: characterID,
                prompts: prompts,
                judgeAnswer: judgeAnswer,
                verdict: verdict.map { judged in
                    "level=\(judged.affinity.level) step=\(judged.affinity.step)"
                        + " out_of_line=\(judged.affinity.outOfLine)"
                        + " manipulation=\(judged.affinity.manipulation)"
                        + " retrieval=\(judged.need.rawValue)"
                },
                retrieval: retrieved.trace,
                toolCalls: toolCalls,
                degradation: degraded,
                error: error
            )
            try? writeTrace(
                trace,
                conversationID: conversationID,
                createdAt: Self.timestamp(now),
                tracing: tracing
            )
        }

        if let failure {
            recordTrace(existingConversation, error: "对话模型失败：\(failure.localizedDescription)")
            throw failure
        }
        let segments = parser.segments.filter { !($0.ja.isEmpty && $0.zh.isEmpty) }
        if segments.isEmpty && !stopped {
            recordTrace(existingConversation, error: "她说的话是空的")
            throw ChatProviderError.invalidResponse("她说的话是空的")
        }
        let recorded = try recordTurn(
            conversationID: existingConversation,
            characterID: characterID,
            userText: text,
            segments: segments,
            judged: judged,
            ending: ending,
            now: now
        )
        recordTrace(recorded.conversationID, error: nil)
        // Memory is on with an embedder and a reranker (upstream `_services`): what the
        // producer revealed is written down after the reply, in a task of its own.
        if embedder != nil, reranker != nil,
           let job = try? enqueueMemoryJob(
               conversationID: recorded.conversationID,
               userMessageID: recorded.userMessageID,
               now: now
           ) {
            scheduleMemoryJob(job, provider: provider, embedder: embedder)
        }
        nameConversationIfDue(
            conversationID: recorded.conversationID,
            characterID: characterID,
            provider: provider
        )
        return TurnRecord(
            conversationID: recorded.conversationID,
            segments: segments,
            stopped: stopped,
            affinityTier: recorded.affinity.tier,
            cooldownUntil: recorded.affinity.cooldownUntil,
            ended: ending != nil
        )
    }

    /// What the model reads for the tool it called: the recalled episode, or why not.
    private func toolResult(_ call: ToolCall, retrieval: RetrievalEngine) async -> String {
        guard call.name == RecallStoryTool.name else {
            return "没有 \(call.name) 这个工具。"
        }
        guard let query = call.query else {
            return "调用参数有误：需要 query（要回顾的事，一句概括）。"
        }
        return await retrieval.recallStoryTool(query: query)
    }

    // MARK: - Affinity

    func readAffinity(characterID: String, now: Date) throws -> Affinity {
        try userQueue.read { db in
            try Self.readAffinity(db, characterID: characterID, now: now)
        }
    }

    static func readAffinity(_ db: Database, characterID: String, now: Date) throws -> Affinity {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT value, updated_at, cooling FROM affinities WHERE character_id = ?
                """,
            arguments: [characterID]
        ) else {
            return .fresh(at: now)
        }
        let at = ISO8601DateFormatter().date(from: row["updated_at"]) ?? now
        return Affinity(
            value: row["value"],
            at: at,
            cooling: (row["cooling"] as Int) == 1
        ).recovered(now: now)
    }

    /// Whether the turn, as judged, would begin a cooldown.
    private func forecastCooling(characterID: String, judged: Judged?, now: Date) throws -> Bool {
        guard let judged else { return false }
        let affinity = try readAffinity(characterID: characterID, now: now)
        return !affinity.cooling && affinity.stepped(judged.step).cooling
    }

    /// The day's gains are counted on Beijing's day, wherever the producer is.
    private static func beijingDay(_ now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - User library

    /// The newest conversation with her, the one records go into; it stays current after
    /// she ends it, until a new one is started (GLOSSARY.md「当前对话」).
    func currentConversationID(_ characterID: String) throws -> String? {
        try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM conversations
                    WHERE character_id = ?
                    ORDER BY created_at DESC, rowid DESC LIMIT 1
                    """,
                arguments: [characterID]
            )
        }
    }

    private func createConversation(characterID: String, now: Date) throws -> String {
        let id = UUID().uuidString
        try userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversations(id, character_id, created_at) VALUES (?, ?, ?)",
                arguments: [id, characterID, Self.timestamp(now)]
            )
        }
        return id
    }

    func loadHistory(conversationID: String, turns: Int) throws -> [StoredMessage] {
        var history = Array(try timeline(conversationID: conversationID).suffix(turns * 2))
        while let first = history.first, first.role == "character" {
            history.removeFirst()
        }
        return history
    }

    /// The conversation as it reads: the recorded messages and the reach-outs between
    /// them, oldest first. Her reach-outs are no turns of their own, but she said them.
    func timeline(conversationID: String) throws -> [StoredMessage] {
        struct Entry {
            var message: StoredMessage
            var reachedOut: Bool
            var rowid: Int64
        }
        return try userQueue.read { db in
            let said = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid, id, role, text, segments, created_at FROM messages
                    WHERE conversation_id = ?
                    """,
                arguments: [conversationID]
            ).map { row in
                Entry(message: StoredMessage(row: row), reachedOut: false, rowid: row["rowid"])
            }
            let reached = try Row.fetchAll(
                db,
                sql: """
                    SELECT rowid, id, segments, created_at FROM reach_outs
                    WHERE conversation_id = ?
                    """,
                arguments: [conversationID]
            ).map { row in
                Entry(
                    message: StoredMessage(
                        id: "reach:\(row["id"] as String)",
                        role: "character",
                        text: nil,
                        segments: Self.decodeSegments(row["segments"]),
                        createdAt: row["created_at"]
                    ),
                    reachedOut: true,
                    rowid: row["rowid"]
                )
            }
            // A turn's two messages share one timestamp: the order they were written in.
            return (said + reached).sorted { left, right in
                if left.message.createdAt != right.message.createdAt {
                    return left.message.createdAt < right.message.createdAt
                }
                if left.reachedOut != right.reachedOut { return !left.reachedOut }
                return left.rowid < right.rowid
            }.map(\.message)
        }
    }

    func messages(conversationID: String) throws -> [ChatMessageRecord] {
        try timeline(conversationID: conversationID).map { message in
            ChatMessageRecord(
                id: message.id,
                role: message.role,
                text: message.text,
                segments: message.segments,
                createdAt: message.createdAt
            )
        }
    }

    private struct RecentTurn {
        var outOfLine: Bool
        var hurt: Double
    }

    private func recentTurns(conversationID: String) throws -> [RecentTurn] {
        let rows = try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT out_of_line, hurt FROM messages
                    WHERE conversation_id = ? AND role = 'character'
                    ORDER BY created_at DESC, rowid DESC
                    LIMIT ?
                    """,
                arguments: [conversationID, AffinityRules.fedUpTurns]
            )
        }
        return rows.reversed().map {
            RecentTurn(outOfLine: ($0["out_of_line"] as Int) == 1, hurt: $0["hurt"])
        }
    }

    func lastContact(conversationID: String?) throws -> Date? {
        guard let conversationID else { return nil }
        return try userQueue.read { db in
            guard let stamp: String = try String.fetchOne(
                db,
                sql: "SELECT MAX(created_at) FROM messages WHERE conversation_id = ?",
                arguments: [conversationID]
            ) else { return nil }
            return ISO8601DateFormatter().date(from: stamp)
        }
    }

    private struct RecordedTurn {
        var conversationID: String
        var affinity: Affinity
        var userMessageID: String
    }

    private func recordTurn(
        conversationID: String?,
        characterID: String,
        userText: String,
        segments: [ReplySegment],
        judged: Judged?,
        ending: EndsReason?,
        now: Date
    ) throws -> RecordedTurn {
        let stamp = Self.timestamp(now)
        let segmentsJSON = try Self.encodeSegments(segments)
        let userID = UUID().uuidString
        let replyID = UUID().uuidString
        let day = Self.beijingDay(now)

        return try userQueue.write { db in
            let conversationID = try conversationID ?? {
                let id = UUID().uuidString
                try db.execute(
                    sql: "INSERT INTO conversations(id, character_id, created_at) VALUES (?, ?, ?)",
                    arguments: [id, characterID, stamp]
                )
                return id
            }()

            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES (?, ?, 'user', ?, ?)
                    """,
                arguments: [userID, conversationID, userText, stamp]
            )

            // Affinity changes as the turn is recorded, and only then.
            let before = try Self.readAffinity(db, characterID: characterID, now: now)
            var step = judged?.step ?? 0
            let gainRow = try Row.fetchOne(
                db,
                sql: "SELECT gained_today, gained_on FROM affinities WHERE character_id = ?",
                arguments: [characterID]
            )
            let gainedBefore = (gainRow?["gained_on"] as String?) == day
                ? (gainRow?["gained_today"] as Double? ?? 0)
                : 0
            if step > 0 {
                step = min(step, max(AffinityRules.gainsPerDay - gainedBefore, 0))
            }
            let after = before.stepped(step)
            let gainedToday = gainedBefore + max(after.value - before.value, 0)
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(character_id) DO UPDATE SET
                        value = excluded.value, cooling = excluded.cooling,
                        updated_at = excluded.updated_at,
                        gained_today = excluded.gained_today, gained_on = excluded.gained_on
                    """,
                arguments: [
                    characterID, after.value, after.cooling ? 1 : 0, stamp,
                    gainedToday, day,
                ]
            )

            try db.execute(
                sql: """
                    INSERT INTO messages(
                        id, conversation_id, role, ja, zh, segments, created_at,
                        affinity, hurt, out_of_line
                    ) VALUES (?, ?, 'character', ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    replyID, conversationID,
                    segments.map(\.ja).joined(),
                    segments.map(\.zh).joined(),
                    segmentsJSON, stamp,
                    after.tier.rawValue,
                    judged?.hurt ?? 0,
                    (judged?.outOfLine ?? false) ? 1 : 0,
                ]
            )

            if ending != nil {
                try db.execute(
                    sql: "UPDATE conversations SET ended_at = ? WHERE id = ?",
                    arguments: [stamp, conversationID]
                )
                try db.execute(
                    sql: """
                        INSERT INTO conversation_events(conversation_id, kind, created_at)
                        VALUES (?, 'ended', ?)
                        """,
                    arguments: [conversationID, stamp]
                )
            }
            return RecordedTurn(conversationID: conversationID, affinity: after, userMessageID: userID)
        }
    }

    // MARK: - Bundle content

    func loadWorld() throws -> WorldSetting? {
        let url = location.contentDirectory.appendingPathComponent("characters/world.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try WorldSetting(json: data)
    }

    public func producerProfile() throws -> ProducerProfile {
        try userQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM producer_profile WHERE id = 1")
            else { return .default }
            let gender = (row["gender"] as String?).flatMap(ProducerProfile.Gender.init(rawValue:))
            return ProducerProfile(
                formOfAddress: row["form_of_address"],
                gender: gender,
                timezone: row["timezone"],
                birthdayMonth: row["birthday_month"],
                birthdayDay: row["birthday_day"]
            )
        }
    }

    // MARK: - Helpers

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func isoDay(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 1970,
            parts.month ?? 1,
            parts.day ?? 1
        )
    }

    static func decodeSegments(_ json: String?) -> [ReplySegment] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ReplySegment].self, from: data)) ?? []
    }

    static func encodeSegments(_ segments: [ReplySegment]) throws -> String {
        let data = try JSONEncoder().encode(segments)
        return String(decoding: data, as: UTF8.self)
    }
}

struct StoredMessage: Sendable {
    var id: String
    var role: String
    var text: String?
    var segments: [ReplySegment]
    var createdAt: String

    init(id: String, role: String, text: String?, segments: [ReplySegment], createdAt: String = "") {
        self.id = id
        self.role = role
        self.text = text
        self.segments = segments
        self.createdAt = createdAt
    }

    init(row: Row) {
        id = row["id"]
        role = row["role"]
        text = row["text"]
        segments = Eidolon.decodeSegments(row["segments"])
        createdAt = row["created_at"]
    }
}

/// Builds the prompt in upstream's order (ADR-0004, upstream `ConversationEngine._prompt`).
struct PromptAssembler {
    /// What she is told every turn that could have no photo (upstream `photos.CANNOT_SEND`):
    /// photos are out of scope in v1, but she still refuses them in her own words rather
    /// than writing a tag.
    static let cannotSendPhoto = """
        # 照片
        你发不了照片。制作人要你发照片时，用你自己的话推掉，不要写照片标签。
        """

    let bundleDirectory: URL
    let character: CharacterConfig
    let world: WorldSetting?
    let producer: ProducerProfile
    let today: String
    /// The per-turn section: the time, and how she feels toward the producer now.
    let nowSection: String?
    /// The reply format: the variant the voice model reads (ADR-0015's call turns pass
    /// the model; text turns pass none).
    var formatInstructions: String = ReplyFormatInstructions.text

    func prompt(history: [StoredMessage], text: String) throws -> [PromptMessage] {
        guard let sheetPath = character.sheet else {
            throw EidolonError.invalidContent("角色 \(character.id) 没有人设文件")
        }
        let sheetURL = bundleDirectory.appendingPathComponent(sheetPath)
        guard let contents = try? String(contentsOf: sheetURL, encoding: .utf8) else {
            throw EidolonError.invalidContent("读不到 \(sheetPath)")
        }
        // Upstream loads a sheet trimmed; the blank run between sections would differ.
        let sheet = contents.trimmingCharacters(in: .whitespacesAndNewlines)

        var shared = [sheet]
        if let world {
            shared.append(world.prompt(name: character.name, today: today))
        }
        shared.append(formatInstructions)

        var messages = [
            PromptMessage(.system, shared.joined(separator: "\n\n")),
            PromptMessage(.system, producer.prompt),
        ]
        for message in history {
            if message.role == "user" {
                messages.append(PromptMessage(.user, message.text ?? ""))
            } else {
                messages.append(PromptMessage(.assistant, Self.formatReply(message.segments)))
            }
        }
        if let nowSection {
            messages.append(PromptMessage(.system, nowSection))
        }
        messages.append(PromptMessage(.user, text))
        return messages
    }

    static func formatReply(_ segments: [ReplySegment]) -> String {
        segments.map { "<ja>\($0.ja)</ja><zh>\($0.zh)</zh>" }.joined()
    }

    /// What the judge model is told of the history: her replies without their cues.
    static func judgeHistory(_ history: [StoredMessage]) -> [PromptMessage] {
        history.map { message in
            if message.role == "user" {
                return PromptMessage(.user, message.text ?? "")
            }
            return PromptMessage(.assistant, ReplyCues.shown(message.segments.map(\.ja).joined()))
        }
    }
}
