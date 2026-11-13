import Foundation
import GRDB

/// What a reply's debug snapshot says about how the turn ended.
public enum TurnDebugStatus: String, Codable, Sendable, Hashable {
    case complete
    case failed
    case cancelled

    public var title: String {
        switch self {
        case .complete: "已生成"
        case .failed: "失败"
        case .cancelled: "已停止"
        }
    }
}

/// One named block of what the reply actually read. The blocks keep their original
/// strings instead of being reconstructed from the final prompt, so the person reading
/// them sees the exact world/sheet/memory/retrieval text that went into the request.
public struct TurnDebugSection: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: String
    public var title: String
    public var content: String

    public init(id: String = UUID().uuidString, kind: String, title: String, content: String) {
        self.id = id
        self.kind = kind
        self.title = title
        self.content = content
    }
}

/// One request in a turn. A turn with a tool call has more than one: the first prompt,
/// then the prompt with the tool result appended.
public struct TurnDebugRequest: Codable, Sendable, Hashable, Identifiable {
    public var index: Int
    public var messages: [TracedMessage]
    public var rawResponse: String?

    public var id: Int { index }

    public init(index: Int, messages: [TracedMessage], rawResponse: String? = nil) {
        self.index = index
        self.messages = messages
        self.rawResponse = rawResponse
    }
}

/// The one-turn debug payload. It is deliberately independent of the normal
/// `turn_traces` retention: a reply's button must keep working even when the producer has
/// turned tracing off.
public struct TurnDebugSnapshot: Codable, Sendable, Hashable {
    public var characterID: String
    public var conversationID: String?
    public var userMessageID: String?
    public var replyMessageID: String?
    public var status: TurnDebugStatus
    public var createdAt: String
    public var model: String?
    public var providerHost: String?
    public var talking: String?
    public var faceToFace: Bool?
    public var replyStyle: String?
    public var adultMode: Bool?
    public var photoEligible: Bool?
    public var photoUsedUp: Bool?
    public var wantsPhoto: Bool?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cachedInputTokens: Int?
    public var sections: [TurnDebugSection]
    public var judge: JudgeTrace?
    public var verdict: String?
    public var retrieval: RetrievalTrace?
    public var requests: [TurnDebugRequest]
    public var toolCalls: [String]
    public var degradation: [String]
    public var timings: TurnTimings?
    public var error: String?

    public init(
        characterID: String,
        conversationID: String? = nil,
        userMessageID: String? = nil,
        replyMessageID: String? = nil,
        status: TurnDebugStatus = .failed,
        createdAt: String,
        model: String? = nil,
        providerHost: String? = nil,
        talking: String? = nil,
        faceToFace: Bool? = nil,
        replyStyle: String? = nil,
        adultMode: Bool? = nil,
        photoEligible: Bool? = nil,
        photoUsedUp: Bool? = nil,
        wantsPhoto: Bool? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        sections: [TurnDebugSection] = [],
        judge: JudgeTrace? = nil,
        verdict: String? = nil,
        retrieval: RetrievalTrace? = nil,
        requests: [TurnDebugRequest] = [],
        toolCalls: [String] = [],
        degradation: [String] = [],
        timings: TurnTimings? = nil,
        error: String? = nil
    ) {
        self.characterID = characterID
        self.conversationID = conversationID
        self.userMessageID = userMessageID
        self.replyMessageID = replyMessageID
        self.status = status
        self.createdAt = createdAt
        self.model = model
        self.providerHost = providerHost
        self.talking = talking
        self.faceToFace = faceToFace
        self.replyStyle = replyStyle
        self.adultMode = adultMode
        self.photoEligible = photoEligible
        self.photoUsedUp = photoUsedUp
        self.wantsPhoto = wantsPhoto
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.sections = sections
        self.judge = judge
        self.verdict = verdict
        self.retrieval = retrieval
        self.requests = requests
        self.toolCalls = toolCalls
        self.degradation = degradation
        self.timings = timings
        self.error = error
    }
}

public struct TurnDebugSnapshotRecord: Sendable, Identifiable, Hashable {
    public var id: Int64
    public var snapshot: TurnDebugSnapshot

    public init(id: Int64, snapshot: TurnDebugSnapshot) {
        self.id = id
        self.snapshot = snapshot
    }
}

/// Mutable object filled while `performTurn` runs. It never leaves the turn's task; the
/// value is encoded and written only once the turn reaches a terminal state.
final class TurnDebugCapture: @unchecked Sendable {
    var snapshot: TurnDebugSnapshot
    private var sectionIndex = 0

    init(characterID: String, now: Date) {
        snapshot = TurnDebugSnapshot(
            characterID: characterID,
            createdAt: Eidolon.timestamp(now)
        )
    }

    func addSection(_ kind: String, _ title: String, _ content: String?) {
        guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        sectionIndex += 1
        snapshot.sections.append(TurnDebugSection(
            id: "\(kind)-\(sectionIndex)",
            kind: kind,
            title: title,
            content: content
        ))
    }
}

extension Eidolon {
    /// The maximum number of debug snapshots kept for one conversation.
    public static let debugSnapshotRetention = 20

    /// Writes a debug snapshot and rolls old ones off. This is debug-only and deliberately
    /// uses `try?` at call sites: a failed debug write must never fail the reply.
    func writeDebugSnapshot(_ snapshot: TurnDebugSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(snapshot)
        let payload = String(decoding: encoded, as: UTF8.self)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO turn_debug_snapshots(
                        conversation_id, character_id, user_message_id, reply_message_id,
                        status, created_at, payload
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    snapshot.conversationID,
                    snapshot.characterID,
                    snapshot.userMessageID,
                    snapshot.replyMessageID,
                    snapshot.status.rawValue,
                    snapshot.createdAt,
                    payload,
                ]
            )
            try db.execute(
                sql: """
                    DELETE FROM turn_debug_snapshots WHERE id NOT IN (
                        SELECT id FROM turn_debug_snapshots
                        WHERE character_id = ? AND conversation_id IS ?
                        ORDER BY id DESC LIMIT ?
                    ) AND character_id = ? AND conversation_id IS ?
                    """,
                arguments: [
                    snapshot.characterID,
                    snapshot.conversationID,
                    Self.debugSnapshotRetention,
                    snapshot.characterID,
                    snapshot.conversationID,
                ]
            )
        }
    }

    /// Debug snapshots for one conversation, newest first.
    public func debugSnapshots(
        conversationID: String,
        limit: Int = Eidolon.debugSnapshotRetention
    ) throws -> [TurnDebugSnapshotRecord] {
        try userQueue.read { db in
            try Self.decodeDebugSnapshots(
                db,
                sql: """
                    SELECT id, payload FROM turn_debug_snapshots
                    WHERE conversation_id = ? ORDER BY id DESC LIMIT ?
                    """,
                arguments: [conversationID, max(limit, 0)]
            )
        }
    }

    /// The most recent failed/cancelled snapshot for a character, optionally restricted to
    /// one conversation. A failed first turn has no conversation yet, hence the character
    /// fallback.
    public func latestFailedDebugSnapshot(
        characterID: String,
        conversationID: String? = nil
    ) throws -> TurnDebugSnapshotRecord? {
        try userQueue.read { db in
            let sql: String
            let arguments: StatementArguments
            if let conversationID {
                sql = """
                    SELECT id, payload FROM turn_debug_snapshots
                    WHERE character_id = ? AND conversation_id = ? AND status != 'complete'
                    ORDER BY id DESC LIMIT 1
                    """
                arguments = [characterID, conversationID]
            } else {
                sql = """
                    SELECT id, payload FROM turn_debug_snapshots
                    WHERE character_id = ? AND status != 'complete'
                    ORDER BY id DESC LIMIT 1
                    """
                arguments = [characterID]
            }
            return try Self.decodeDebugSnapshots(db, sql: sql, arguments: arguments).first
        }
    }

    /// One snapshot by its reply message id; nil if the reply predates this feature or the
    /// snapshot was pruned.
    public func debugSnapshot(replyMessageID: String) throws -> TurnDebugSnapshotRecord? {
        try userQueue.read { db in
            try Self.decodeDebugSnapshots(
                db,
                sql: """
                    SELECT id, payload FROM turn_debug_snapshots
                    WHERE reply_message_id = ? ORDER BY id DESC LIMIT 1
                    """,
                arguments: [replyMessageID]
            ).first
        }
    }

    /// Clears snapshots for one conversation, or every snapshot when `conversationID` is nil.
    public func clearDebugSnapshots(conversationID: String? = nil) throws {
        try userQueue.write { db in
            if let conversationID {
                try db.execute(
                    sql: "DELETE FROM turn_debug_snapshots WHERE conversation_id = ?",
                    arguments: [conversationID]
                )
            } else {
                try db.execute(sql: "DELETE FROM turn_debug_snapshots")
            }
        }
    }

    private static func decodeDebugSnapshots(
        _ db: Database,
        sql: String,
        arguments: StatementArguments
    ) throws -> [TurnDebugSnapshotRecord] {
        let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
        return rows.compactMap { row in
            let payload: String = row["payload"]
            guard let data = payload.data(using: .utf8),
                  let snapshot = try? JSONDecoder().decode(TurnDebugSnapshot.self, from: data)
            else { return nil }
            return TurnDebugSnapshotRecord(id: row["id"], snapshot: snapshot)
        }
    }
}
