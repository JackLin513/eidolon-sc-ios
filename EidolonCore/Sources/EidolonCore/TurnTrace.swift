import Foundation
import GRDB

/// A prompt as it was sent: what the model read, exactly.
public struct TracedMessage: Codable, Sendable, Hashable {
    public var role: String
    public var content: String
    public var toolCalls: [String]?

    public init(role: String, content: String, toolCalls: [String]? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
    }

    init(_ message: PromptMessage) {
        role = message.role.rawValue
        content = message.content
        toolCalls = message.toolCalls.isEmpty
            ? nil
            : message.toolCalls.map { "\($0.name)(\($0.arguments))" }
    }
}

/// What one candidate looked like before and after reranking, for a turn's trace.
public struct RetrievalCandidate: Codable, Sendable, Hashable {
    public var kind: String
    public var title: String
    public var similarity: Double
    public var score: Double?
    public var chosen: Bool

    public init(kind: String, title: String, similarity: Double, score: Double? = nil, chosen: Bool = false) {
        self.kind = kind
        self.title = title
        self.similarity = similarity
        self.score = score
        self.chosen = chosen
    }
}

/// What retrieval did in a turn: what it looked for, what it found, what it used, and
/// where it could not go on (ADR-0011).
public struct RetrievalTrace: Codable, Sendable, Hashable {
    public var need: String
    public var query: String?
    public var candidates: [RetrievalCandidate]
    public var degradation: [String]

    public init(
        need: String = "",
        query: String? = nil,
        candidates: [RetrievalCandidate] = [],
        degradation: [String] = []
    ) {
        self.need = need
        self.query = query
        self.candidates = candidates
        self.degradation = degradation
    }
}

/// What the judge did in a turn: which service and model judged, how the model's family
/// read it, what it answered, what it cost and how long it took — or why it failed
/// (ADR-0016). Nothing here leaves the phone.
public struct JudgeTrace: Codable, Sendable, Hashable {
    public var service: String
    public var model: String
    public var family: String?
    /// True when the model's family is unknown and Jev's thresholds were used instead;
    /// nil when the model was calibrated, so older traces decode unchanged.
    public var uncalibrated: Bool?
    /// The response as it came, when there was one.
    public var raw: String?
    public var inputTokens: Int?
    /// Seconds from sending the request to reading the answer.
    public var latency: Double?
    public var failure: String?

    public init(
        service: String,
        model: String,
        family: String? = nil,
        uncalibrated: Bool? = nil,
        raw: String? = nil,
        inputTokens: Int? = nil,
        latency: Double? = nil,
        failure: String? = nil
    ) {
        self.service = service
        self.model = model
        self.family = family
        self.uncalibrated = uncalibrated
        self.raw = raw
        self.inputTokens = inputTokens
        self.latency = latency
        self.failure = failure
    }
}

/// How long each part of a turn took, in seconds: what the producer waits through before
/// her first word (ADR-0012). Every part is optional so a trace from an older build still
/// reads, and a turn that ended before reaching one leaves it nil.
public struct TurnTimings: Codable, Sendable, Hashable {
    /// Waiting for what earlier turns were still writing down (`settleMemories`).
    public var memory: Double?
    /// Looking references and memories up: the local search and any embedding/rerank calls.
    public var retrieval: Double?
    /// From the chat request to the first text chunk of her reply.
    public var firstToken: Double?
    /// From the turn's start to its trace — after the reply is written down.
    public var total: Double?

    public init(
        memory: Double? = nil,
        retrieval: Double? = nil,
        firstToken: Double? = nil,
        total: Double? = nil
    ) {
        self.memory = memory
        self.retrieval = retrieval
        self.firstToken = firstToken
        self.total = total
    }
}

/// How long a call's replies took to come back and to be heard: the call layer's part of
/// what the producer waits through, written on the call's own trace when it ends
/// (ADR-0012). The turn's text-side timings are on each reply's own trace.
public struct CallTimings: Codable, Sendable, Hashable {
    public struct Turn: Codable, Sendable, Hashable {
        /// Which of her replies in the call this is, from 0.
        public var reply: Int
        /// From the end of the producer's line to her reply being recorded.
        public var replyDelay: Double?
        /// From her reply being recorded to the first segment's voice starting.
        public var voiceWait: Double?
        /// From the end of the producer's line to the first segment's voice.
        public var firstVoice: Double?
        /// From the end of the producer's line to the first line card (voice or subtitles).
        public var firstLine: Double?

        public init(
            reply: Int,
            replyDelay: Double? = nil,
            voiceWait: Double? = nil,
            firstVoice: Double? = nil,
            firstLine: Double? = nil
        ) {
            self.reply = reply
            self.replyDelay = replyDelay
            self.voiceWait = voiceWait
            self.firstVoice = firstVoice
            self.firstLine = firstLine
        }
    }

    public var turns: [Turn]

    public init(turns: [Turn] = []) {
        self.turns = turns
    }
}

/// One turn, as it can be gone over afterwards: what she was asked, what the judge
/// answered, what retrieval found and what each fallback cost (ADR-0012). It stays in the
/// user library and never leaves the phone.
public struct TurnTrace: Codable, Sendable, Hashable {
    public var characterID: String
    public var prompts: [[TracedMessage]]
    public var judge: JudgeTrace?
    public var verdict: String?
    public var retrieval: RetrievalTrace
    public var toolCalls: [String]
    public var degradation: [String]
    public var error: String?
    /// Where the turn's time went; nil for traces written before it was recorded.
    public var timings: TurnTimings?
    /// The call's own replies, on the trace written when the call ends; nil on a turn's
    /// trace and on calls recorded before this was kept.
    public var callTimings: CallTimings?

    public init(
        characterID: String,
        prompts: [[TracedMessage]] = [],
        judge: JudgeTrace? = nil,
        verdict: String? = nil,
        retrieval: RetrievalTrace = RetrievalTrace(),
        toolCalls: [String] = [],
        degradation: [String] = [],
        error: String? = nil,
        timings: TurnTimings? = nil,
        callTimings: CallTimings? = nil
    ) {
        self.characterID = characterID
        self.prompts = prompts
        self.judge = judge
        self.verdict = verdict
        self.retrieval = retrieval
        self.toolCalls = toolCalls
        self.degradation = degradation
        self.error = error
        self.timings = timings
        self.callTimings = callTimings
    }
}

public struct TurnTraceRecord: Sendable, Identifiable {
    public var id: Int64
    public var conversationID: String?
    public var createdAt: String
    public var trace: TurnTrace
}

/// Whether turns leave a trace, and how many are kept.
public struct TurnTracing: Sendable, Hashable {
    public var enabled: Bool
    public var retention: Int

    public init(enabled: Bool, retention: Int) {
        self.enabled = enabled
        self.retention = retention
    }

    public static let off = TurnTracing(enabled: false, retention: 0)
    public static let on = TurnTracing(enabled: true, retention: 200)
}

extension Eidolon {
    /// Traces, newest first, at most `limit`.
    public func turnTraces(limit: Int = 200) throws -> [TurnTraceRecord] {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, conversation_id, created_at, payload FROM turn_traces
                    ORDER BY id DESC LIMIT ?
                    """,
                arguments: [limit]
            ).compactMap { row in
                let payload: String = row["payload"]
                guard let data = payload.data(using: .utf8),
                      let trace = try? JSONDecoder().decode(TurnTrace.self, from: data)
                else { return nil }
                return TurnTraceRecord(
                    id: row["id"],
                    conversationID: row["conversation_id"],
                    createdAt: row["created_at"],
                    trace: trace
                )
            }
        }
    }

    /// Every kept trace, as JSON, for the producer to keep elsewhere if they want.
    public func exportedTraces() throws -> Data {
        let records = try turnTraces(limit: Int.max)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(records.map { record in
            ExportedTrace(
                id: record.id,
                conversationID: record.conversationID,
                createdAt: record.createdAt,
                trace: record.trace
            )
        })
    }

    public func clearTraces() throws {
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM turn_traces")
        }
    }

    /// Writes the turn's trace, if tracing is on, and forgets the oldest beyond the
    /// retention the producer chose.
    func writeTrace(
        _ trace: TurnTrace,
        conversationID: String?,
        createdAt: String,
        tracing: TurnTracing
    ) throws {
        guard tracing.enabled else { return }
        let encoded = try JSONEncoder().encode(trace)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO turn_traces(conversation_id, created_at, payload)
                    VALUES (?, ?, ?)
                    """,
                arguments: [conversationID, createdAt, String(decoding: encoded, as: UTF8.self)]
            )
            try db.execute(
                sql: """
                    DELETE FROM turn_traces WHERE id NOT IN (
                        SELECT id FROM turn_traces ORDER BY id DESC LIMIT ?
                    )
                    """,
                arguments: [max(tracing.retention, 0)]
            )
        }
    }

    private struct ExportedTrace: Encodable {
        var id: Int64
        var conversationID: String?
        var createdAt: String
        var trace: TurnTrace
    }
}

/// A judge answer that could not be read: what the model wrote is kept all the same, so
/// the trace shows what went wrong.
public struct JudgeUnreadable: LocalizedError, Equatable {
    public var raw: String
    public var reason: String

    public var errorDescription: String? { "判断模型的回复无法解析：\(reason)" }
}

/// A judge that gives back what the model wrote with its verdict, for the trace.
public struct JudgeAnswer: Sendable, Hashable {
    public var verdict: JudgeVerdict
    public var raw: String
    /// What the judge said the request cost in input tokens, when it says.
    public var inputTokens: Int?

    public init(verdict: JudgeVerdict, raw: String, inputTokens: Int? = nil) {
        self.verdict = verdict
        self.raw = raw
        self.inputTokens = inputTokens
    }
}

public protocol TracingJudgeProvider: JudgeProvider {
    func judgedWithRaw(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeAnswer
}
