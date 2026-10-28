import Foundation
import GRDB

/// What the producer's line has to be for a turn to take it (upstream `engine.turn`).
public enum TurnInput {
    /// Upstream's `MAX_INPUT_LENGTH`: a longer line is refused rather than sent.
    public static let maxLength = 2000

    /// The line as the turn takes it: trimmed, and refused when it is blank or longer
    /// than `maxLength`, with what the producer reads.
    public static func checked(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EidolonError.blankInput }
        guard trimmed.count <= maxLength else { throw EidolonError.inputTooLong(maxLength) }
        return trimmed
    }
}

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
    /// What this turn took off her, as `ends` counts it; a call adds it to the call's own.
    public var hurt: Double
    /// Whether this turn was out of line.
    public var outOfLine: Bool
    /// In a call, the turn made her want to hang up, and why; a text turn ends the
    /// conversation instead (`ended`) and leaves this nil.
    public var hangUp: EndsReason?
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
    /// One of her reach-outs, kept apart from her turns in the record (`reach:` ids).
    public var isReachOut: Bool { id.hasPrefix("reach:") }

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
        // The call this turn is taken in, and what its turns have come to; it counts
        // apart from the conversation's typed turns.
        inCall: CallScope? = nil,
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
                        inCall: inCall,
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
        inCall: CallScope?,
        voicedBy model: String?,
        emit: (TurnEvent) -> Void
    ) async throws -> TurnRecord {
        // Where the turn's time goes, for the trace (ADR-0012): the producer waits through
        // earlier memories, the judge, retrieval and the model's first token before hearing
        // anything, and the whole turn is what a slow reply feels like.
        let turnStarted = ContinuousClock.now
        // Nothing is asked or written of a line that is blank or too long (upstream
        // `engine.turn` rejects it before the turn begins).
        let text = try TurnInput.checked(text)
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
        let memoryStarted = ContinuousClock.now
        await settleMemories()
        let memoryElapsed = ContinuousClock.now - memoryStarted

        let world = try loadWorld()
        let producer = try producerProfile()
        // The producer's days go by the profile's time zone, when they set one.
        let zone = producer.timezone.flatMap(TimeZone.init(identifier:)) ?? timeZone
        let existingConversation = try currentConversationID(characterID)
        if let existingConversation, try isEnded(conversationID: existingConversation) {
            throw EidolonError.conversationEnded
        }
        // What the judge and retrieval read (her latest turns, and her reach-outs after
        // the last one), and what the chat model reads (the latest turns cut back in
        // chunks, with the events and reach-outs before each line as narration).
        let record = try existingConversation.map {
            try promptRecord(conversationID: $0, turns: historyTurns, timeZone: zone)
        } ?? PromptRecord()
        let history = record.judgingHistory

        // The judge is advisory (ADR-0005, ADR-0016): whatever it says, the turn goes on.
        // When it fails — times out, is refused, or answers unreadably — the turn still
        // looks references up, as upstream retrieves anyway on `JudgeError`; only the
        // affinity is left alone. With no judge asked at all it looks references up too.
        var degradation: [String] = []
        var verdict: JudgeVerdict?
        var judgeTrace: JudgeTrace?
        if let judge {
            let started = Date()
            var raw: String?
            var tokens: Int?
            var failure: String?
            do {
                if let tracingJudge = judge as? any TracingJudgeProvider {
                    let answer = try await tracingJudge.judgedWithRaw(
                        characterName: character.name,
                        history: PromptAssembler.judgeHistory(history),
                        said: text
                    )
                    raw = answer.raw
                    tokens = answer.inputTokens
                    verdict = answer.verdict
                } else {
                    verdict = try await judge.judge(
                        characterName: character.name,
                        history: PromptAssembler.judgeHistory(history),
                        said: text
                    )
                }
            } catch {
                if let unreadable = error as? JudgeUnreadable { raw = unreadable.raw }
                failure = error.localizedDescription
                degradation.append("判断模型失败，仍按 references 检索、本回合不动好感：\(failure ?? "")")
            }
            judgeTrace = JudgeTrace(
                service: judge.judgeService,
                model: judge.judgeModel,
                family: judge.judgeFamily,
                uncalibrated: judge.judgeUncalibrated ? true : nil,
                raw: raw,
                inputTokens: tokens,
                latency: Date().timeIntervalSince(started),
                failure: failure
            )
        }
        let judged: Judged? = verdict?.affinity
        // A judge that failed still has the turn look references up (upstream `retrieval.py`
        // retrieves anyway on `JudgeError`).
        let need: RetrievalNeed = verdict?.need ?? .references
        let retrieval = RetrievalEngine(
            eidolon: self,
            character: character,
            world: world,
            embedder: embedder,
            reranker: reranker,
            timeZone: zone
        )
        let retrievalStarted = ContinuousClock.now
        let retrieved = await retrieval.retrieve(history: history, text: text, need: need)
        let retrievalElapsed = ContinuousClock.now - retrievalStarted

        // A call's turns count apart from the conversation's typed ones: what it holds
        // comes from the call, not from the messages (upstream `in_call`).
        let call = inCall ?? (talking == .inCall ? CallScope() : nil)
        let cools = try forecastCooling(characterID: characterID, judged: judged, now: now)
        let outOfLineBefore: Int
        let hurtBefore: [Double]
        if let call {
            outOfLineBefore = call.outOfLine
            hurtBefore = call.hurts
        } else {
            let recent = try existingConversation.map {
                try recentTurns(conversationID: $0)
            } ?? []
            outOfLineBefore = recent.suffix(AffinityRules.fedUpTurns - 1)
                .filter(\.outOfLine).count
            hurtBefore = recent.map(\.hurt)
        }
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
        let way: Parting = call != nil ? .hangsUp : .parts
        let affinityLines = AffinityPrompt.lines(
            tier: affinity.tier,
            judged: judged,
            parting: (ending != nil || cools) ? way : nil,
            warning: warning ? way : nil
        )
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
            talking: talking,
            affinityLines: affinityLines,
            // In a call they are talking right now: no "last time" to tell her.
            lastContact: talking == .inCall
                ? nil
                : try lastContact(characterID: characterID),
            birthday: producer.birthday,
            todayLines: todayLines
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
            formatInstructions: ReplyFormatInstructions.forVoice(model: model),
            narration: record.narration,
            currentNarration: record.trailingNarration
        )
        let messages = try assembler.prompt(history: record.chatHistory, text: text)

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
        let chatStarted = ContinuousClock.now
        var firstTokenAt: ContinuousClock.Instant?
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
                            if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
                            said += chunk
                            shown(parser.feed(chunk))
                        case let .toolCalls(made):
                            calls += made
                        }
                    }
                } else {
                    for try await chunk in provider.stream(messages: prompt) {
                        try Task.checkCancellation()
                        if firstTokenAt == nil { firstTokenAt = ContinuousClock.now }
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
        // A provider whose stream cancelled quietly leaves the loop through its end, not
        // through an error: the turn was still stopped by the producer.
        if Task.isCancelled { stopped = true }

        // What this turn can be gone over by, later: what she was asked, what the judge
        // wrote, what retrieval found and what the fallbacks cost (ADR-0012).
        func recordTrace(_ conversationID: String?, error: String?) {
            guard tracing.enabled else { return }
            var degraded = degradation + retrieved.trace.degradation
            if let error { degraded.append(error) }
            let trace = TurnTrace(
                characterID: characterID,
                prompts: prompts,
                judge: judgeTrace,
                verdict: verdict.map { judged in
                    "level=\(judged.affinity.level) step=\(judged.affinity.step)"
                        + " out_of_line=\(judged.affinity.outOfLine)"
                        + " manipulation=\(judged.affinity.manipulation)"
                        + " retrieval=\(judged.need.rawValue)"
                },
                retrieval: retrieved.trace,
                toolCalls: toolCalls,
                degradation: degraded,
                error: error,
                timings: TurnTimings(
                    memory: memoryElapsed.inSeconds,
                    retrieval: retrievalElapsed.inSeconds,
                    firstToken: firstTokenAt.map { ($0 - chatStarted).inSeconds },
                    total: (ContinuousClock.now - turnStarted).inSeconds
                )
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
            // What the producer reads is upstream's `FAILED`; the details stay in the trace.
            throw EidolonError.turnFailed
        }
        // A call's turn cancelled by a hang-up is one the producer left (upstream's
        // `left`): nothing of it is written — not the line, not her half-said reply, not
        // the affinity, not a trace. A text turn's stop is not the same: it keeps what
        // she already said (upstream `engine.turn`'s `stop`).
        if call != nil, stopped {
            throw CancellationError()
        }
        let segments = parser.segments.filter { !($0.ja.isEmpty && $0.zh.isEmpty) }
        // Stopped before she said anything: there is no reply to keep, and upstream
        // records none — not an empty bubble, not a blank assistant message in the
        // history (upstream raises `EmptyReply` before `_keep`).
        if segments.isEmpty, stopped {
            throw CancellationError()
        }
        if segments.isEmpty {
            recordTrace(existingConversation, error: "她说的话是空的")
            throw EidolonError.turnFailed
        }
        // Her reply is stamped a microsecond after the question, in the turn's own moment:
        // the two rows of a turn stay in the order they were written, and a turn simulated
        // on an injected clock stays on it rather than drifting by how long the model took.
        let replyAt = now.addingTimeInterval(0.000001)
        let recorded = try recordTurn(
            conversationID: existingConversation,
            characterID: characterID,
            userText: text,
            segments: segments,
            judged: judged,
            ending: ending,
            typed: call == nil,
            now: now,
            replyAt: replyAt
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
            turn: recorded.turn,
            provider: provider
        )
        return TurnRecord(
            conversationID: recorded.conversationID,
            segments: segments,
            stopped: stopped,
            affinityTier: recorded.affinity.tier,
            cooldownUntil: recorded.affinity.cooldownUntil,
            hurt: judged?.hurt ?? 0,
            outOfLine: judged?.outOfLine ?? false,
            hangUp: call != nil ? ending : nil,
            ended: call == nil && ending != nil
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
        let at = Self.parseTimestamp(row["updated_at"]) ?? now
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
        calendar.timeZone = TimeZone(identifier: AffinityRules.dayTimeZone) ?? .current
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

    /// What one turn reads of a conversation: its messages, the narration the events and
    /// her reach-outs put before them, and how much of it the chat model and the judge each
    /// get (upstream `chat_history`, `latest_turns` and `narrations`).
    struct PromptRecord {
        /// Every message, her reach-outs and events left out.
        var allMessages: [StoredMessage] = []
        /// What the chat model reads: at least the latest turns, cut back in chunks.
        var chatHistory: [StoredMessage] = []
        /// What the judge and retrieval read: the latest turns, then her reach-outs after
        /// the last message.
        var judgingHistory: [StoredMessage] = []
        /// What she is told before each user message, by its id.
        var narration: [String: String] = [:]
        /// What she is told before what the producer says now.
        var trailingNarration: String = ""
    }

    /// Reads `conversation` as a turn does: her reach-outs and the events she is told of
    /// become narration before the next thing the producer says, and the chat model's
    /// history is cut back to whole turns, in chunks (upstream `narrations`,
    /// `chat_history`).
    func promptRecord(
        conversationID: String,
        turns: Int,
        timeZone: TimeZone
    ) throws -> PromptRecord {
        var record = PromptRecord()
        var pending: [String] = []
        var answering: [StoredMessage] = []
        for line in try conversationRecord(conversationID: conversationID) {
            switch line {
            case let .event(event):
                // Upstream `_narration_line` ends every line with a newline and joins
                // them with nothing between: two events in a row read as two lines.
                if let said = ConversationEventKind(stored: event.kind).narration {
                    pending.append(said + "\n")
                }
            case let .message(message):
                let stored = StoredMessage(
                    id: message.id,
                    role: message.role,
                    text: message.text,
                    segments: message.segments,
                    createdAt: message.createdAt
                )
                if message.isReachOut {
                    if let said = Self.reachOutNarration(message, in: timeZone) {
                        pending.append(said + "\n")
                    }
                    answering.append(stored)
                } else {
                    answering = []
                    if message.role == "user", !pending.isEmpty {
                        record.narration[message.id] = pending.joined()
                        pending = []
                    }
                    record.allMessages.append(stored)
                }
            }
        }
        record.chatHistory = Self.chatHistory(record.allMessages, turns: turns)
        record.judgingHistory = Self.latestTurns(record.allMessages, turns: turns) + answering
        record.trailingNarration = pending.joined()
        return record
    }

    /// What she is told of her own reach-out: when, then her words as her replies are
    /// written (upstream `engine._reached_out`).
    static func reachOutNarration(_ message: ChatMessageRecord, in timeZone: TimeZone) -> String? {
        guard let at = parseTimestamp(message.createdAt) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: at)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        return "（\(parts.month ?? 0)月\(parts.day ?? 0)日 \(clock)，你先给制作人发了：）"
            + PromptAssembler.formatReply(message.segments)
    }

    /// The messages from the `turns`th last user message on (from the first if `turns` is
    /// 0 or there are fewer), so what reads them always opens with the user (upstream
    /// `latest_turns`).
    static func latestTurns(_ messages: [StoredMessage], turns: Int) -> [StoredMessage] {
        let starts = messages.indices.filter { messages[$0].role == "user" }
        guard let first = starts.first else { return [] }
        guard turns > 0, turns < starts.count else {
            return Array(messages[first...])
        }
        return Array(messages[starts[starts.count - turns]...])
    }

    /// The latest turns the chat model reads: at least `turns`, cut back to that many each
    /// time they reach half as many again, rather than one at a time, so what it reads
    /// opens the same way from turn to turn in between (upstream `chat_history`).
    static func chatHistory(_ messages: [StoredMessage], turns: Int) -> [StoredMessage] {
        let total = messages.filter { $0.role == "user" }.count
        guard turns > 0, total > turns else { return latestTurns(messages, turns: 0) }
        let step = max(1, turns / 2)
        return latestTurns(messages, turns: total - step * ((total - turns) / step))
    }

    /// The conversation as it reads: the recorded messages and the reach-outs between
    /// them, oldest first, in the database's order. Her reach-outs are no turns of their
    /// own, but she said them; events stay out of the prompt.
    func timeline(conversationID: String) throws -> [StoredMessage] {
        try conversationRecord(conversationID: conversationID).compactMap { line in
            guard case let .message(message) = line else { return nil }
            return StoredMessage(
                id: message.id,
                role: message.role,
                text: message.text,
                segments: message.segments,
                createdAt: message.createdAt
            )
        }
    }

    func messages(conversationID: String) throws -> [ChatMessageRecord] {
        try conversationRecord(conversationID: conversationID).compactMap { line in
            guard case let .message(message) = line else { return nil }
            return message
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
                    WHERE conversation_id = ? AND role = 'character' AND typed = 1
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

    /// When the producer and she were last in touch in `conversation`: their last message,
    /// or the end of a call that connected in it, whichever was later (upstream
    /// `_last_contact_in`).
    func lastContact(conversationID: String?) throws -> Date? {
        guard let conversationID else { return nil }
        return try userQueue.read { db in
            var moments: [Date] = []
            if let stamp: String = try String.fetchOne(
                db,
                sql: "SELECT MAX(created_at) FROM messages WHERE conversation_id = ?",
                arguments: [conversationID]
            ), let at = Self.parseTimestamp(stamp) {
                moments.append(at)
            }
            if let stamp: String = try String.fetchOne(
                db,
                sql: "SELECT MAX(ended_at) FROM call_ends WHERE conversation_id = ?",
                arguments: [conversationID]
            ), let at = Self.parseTimestamp(stamp) {
                moments.append(at)
            }
            return moments.max()
        }
    }

    /// When the producer and she were last in touch, in any conversation: the producer's
    /// last message, a conversation event (her hang-up, the conversation's end) or the end
    /// of a call that connected, whichever was later (upstream `read_last_contact`).
    func lastContact(characterID: String) throws -> Date? {
        try userQueue.read { db in
            var moments: [Date] = []
            func add(_ sql: String) throws {
                if let stamp: String = try String.fetchOne(db, sql: sql, arguments: [characterID]),
                   let at = Self.parseTimestamp(stamp) {
                    moments.append(at)
                }
            }
            // The producer's own line: her reply is written a moment after it, and it is
            // his last words that say when they last spoke.
            try add("""
                SELECT MAX(m.created_at) FROM messages m
                JOIN conversations c ON c.id = m.conversation_id
                WHERE c.character_id = ? AND m.role = 'user'
                """)
            try add("""
                SELECT MAX(e.created_at) FROM conversation_events e
                JOIN conversations c ON c.id = e.conversation_id
                WHERE c.character_id = ?
                """)
            try add("SELECT MAX(ended_at) FROM call_ends WHERE character_id = ?")
            return moments.max()
        }
    }

    private struct RecordedTurn {
        var conversationID: String
        var affinity: Affinity
        var userMessageID: String
        /// Which turn of the conversation this was, counting from 1.
        var turn: Int
    }

    private func recordTurn(
        conversationID: String?,
        characterID: String,
        userText: String,
        segments: [ReplySegment],
        judged: Judged?,
        ending: EndsReason?,
        typed: Bool,
        now: Date,
        replyAt: Date
    ) throws -> RecordedTurn {
        let nowMicros = Self.microseconds(now)
        let replyMicros = max(Self.microseconds(replyAt), nowMicros + 1)
        let stamp = Self.timestamp(microseconds: nowMicros)
        let replyStamp = Self.timestamp(microseconds: replyMicros)
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
            // The turn this is, after the line was written: the third is the one that
            // names the conversation (upstream `titles.py`).
            let turn = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM messages
                    WHERE conversation_id = ? AND role = 'user'
                    """,
                arguments: [conversationID]
            ) ?? 0

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
            step = AffinityRules.limited(step, left: AffinityRules.gainsPerDay - gainedBefore)
            let after = before.stepped(step)
            let rose = max(after.value - before.value, 0)
            let gainedToday = gainedBefore + min(max(step, 0), rose)
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
                    characterID, after.value, after.cooling ? 1 : 0, replyStamp,
                    gainedToday, day,
                ]
            )

            // What this turn took off her is a typed turn's to record: a call keeps it
            // itself, and never ends the conversation (upstream `Typed`).
            let hurt = typed ? (judged?.hurt ?? 0) : 0
            let outOfLine = typed && (judged?.outOfLine ?? false)
            try db.execute(
                sql: """
                    INSERT INTO messages(
                        id, conversation_id, role, ja, zh, segments, created_at,
                        affinity, hurt, out_of_line, typed
                    ) VALUES (?, ?, 'character', ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    replyID, conversationID,
                    segments.map(\.ja).joined(),
                    segments.map(\.zh).joined(),
                    segmentsJSON, replyStamp,
                    after.tier.rawValue,
                    hurt,
                    outOfLine ? 1 : 0,
                    typed ? 1 : 0,
                ]
            )

            if typed, ending != nil {
                // Written after the reply it ends, as upstream writes it (`_now()`).
                let endedStamp = Self.timestamp(microseconds: replyMicros + 1)
                try db.execute(
                    sql: "UPDATE conversations SET ended_at = ? WHERE id = ?",
                    arguments: [endedStamp, conversationID]
                )
                try db.execute(
                    sql: """
                        INSERT INTO conversation_events(conversation_id, kind, created_at)
                        VALUES (?, 'ended', ?)
                        """,
                    arguments: [conversationID, endedStamp]
                )
            }
            return RecordedTurn(
                conversationID: conversationID,
                affinity: after,
                userMessageID: userID,
                turn: turn
            )
        }
    }

    // MARK: - Bundle content

    func loadWorld() throws -> WorldSetting? {
        // Parsed once for the installed bundle and kept: every turn reads it, and it is a
        // 1.3 MB file, not something to parse on the way to the first token.
        if worldCached { return cachedWorld }
        let url = location.contentDirectory.appendingPathComponent("characters/world.json")
        let world = try (try? Data(contentsOf: url)).map { try WorldSetting(json: $0) }
        cachedWorld = world
        worldCached = true
        return world
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

    /// Now, as the store writes when things happened: UTC, to the microsecond as upstream's
    /// `_now()` (`datetime.now(UTC).isoformat()`). Sub-second stamps keep a turn's two rows
    /// and the events around them apart.
    static func timestamp(_ date: Date) -> String {
        timestamp(microseconds: microseconds(date))
    }

    /// The moment as whole microseconds since the epoch, as the stamps are written.
    static func microseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded(.down))
    }

    /// A stamp from whole microseconds; adding to it cannot round back onto itself the way
    /// adding a fraction of a second to a `Date` can.
    static func timestamp(microseconds total: Int64) -> String {
        var seconds = total / 1_000_000
        var fraction = total % 1_000_000
        if fraction < 0 {
            seconds -= 1
            fraction += 1_000_000
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: Date(timeIntervalSince1970: TimeInterval(seconds))
        )
        func padded(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return digits.count >= width
                ? digits
                : String(repeating: "0", count: width - digits.count) + digits
        }
        return padded(parts.year ?? 1970, 4)
            + "-" + padded(parts.month ?? 1, 2)
            + "-" + padded(parts.day ?? 1, 2)
            + "T" + padded(parts.hour ?? 0, 2)
            + ":" + padded(parts.minute ?? 0, 2)
            + ":" + padded(parts.second ?? 0, 2)
            + "." + padded(Int(fraction), 6)
            + "Z"
    }

    /// A stored timestamp as a moment: the stamps this app writes now carry microseconds,
    /// and older ones do not.
    public static func parseTimestamp(_ timestamp: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: timestamp) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: timestamp)
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
    /// What she is told before each user message, by its id: the events and her own
    /// reach-outs since the last thing said (upstream `engine.narrations`).
    var narration: [String: String] = [:]
    /// What she is told before what the producer says now.
    var currentNarration: String = ""

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

        // Everything every turn of hers carries, apart from what the turn is about, in
        // upstream's order: her sheet, her birthday, the world, the reply format.
        var shared = [sheet]
        if let birthday = character.birthday {
            shared.append(TodayPrompt.herBirthday(birthday))
        }
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
                messages.append(PromptMessage(
                    .user,
                    (narration[message.id] ?? "") + (message.text ?? "")
                ))
            } else {
                messages.append(PromptMessage(.assistant, Self.formatReply(message.segments)))
            }
        }
        if let nowSection {
            messages.append(PromptMessage(.system, nowSection))
        }
        messages.append(PromptMessage(.user, currentNarration + text))
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
