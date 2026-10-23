import Foundation
import GRDB

/// One conversation with her, as the history list shows it (GLOSSARY.md「对话」).
public struct ConversationSummary: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String?
    public var createdAt: String
    public var ended: Bool
    /// The turns and reach-outs it holds: one without any is not a past conversation.
    public var records: Int
    public var lastPreview: String?
    public var lastAt: String?
    /// The newest one, where records go, even after she ends it.
    public var isCurrent: Bool
}

extension Eidolon {
    /// Her conversations, newest first: the current one, ended or not, then the past
    /// ones — those with nothing in them are not listed as past.
    public func conversations(characterID: String) throws -> [ConversationSummary] {
        try userQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT c.id, c.title, c.created_at, c.ended_at,
                        (SELECT COUNT(*) FROM messages m WHERE m.conversation_id = c.id)
                            + (SELECT COUNT(*) FROM reach_outs r WHERE r.conversation_id = c.id)
                            AS records,
                        (SELECT COALESCE(NULLIF(m.zh, ''), NULLIF(m.ja, ''), NULLIF(m.text, ''))
                         FROM messages m WHERE m.conversation_id = c.id
                         ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1) AS said_preview,
                        (SELECT m.created_at FROM messages m WHERE m.conversation_id = c.id
                         ORDER BY m.created_at DESC, m.rowid DESC LIMIT 1) AS said_at,
                        (SELECT COALESCE(NULLIF(r.zh, ''), NULLIF(r.ja, ''))
                         FROM reach_outs r WHERE r.conversation_id = c.id
                         ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS reach_preview,
                        (SELECT r.created_at FROM reach_outs r WHERE r.conversation_id = c.id
                         ORDER BY r.created_at DESC, r.rowid DESC LIMIT 1) AS reach_at
                    FROM conversations c
                    WHERE c.character_id = ?
                    ORDER BY c.created_at DESC, c.rowid DESC
                    """,
                arguments: [characterID]
            )
            return rows.enumerated().compactMap { index, row -> ConversationSummary? in
                let records: Int = row["records"]
                let isCurrent = index == 0
                guard isCurrent || records > 0 else { return nil }
                let saidAt: String? = row["said_at"]
                let reachAt: String? = row["reach_at"]
                let reachIsLatest = (reachAt ?? "") > (saidAt ?? "")
                return ConversationSummary(
                    id: row["id"],
                    title: row["title"],
                    createdAt: row["created_at"],
                    ended: (row["ended_at"] as String?) != nil,
                    records: records,
                    lastPreview: reachIsLatest ? row["reach_preview"] : row["said_preview"],
                    lastAt: reachIsLatest ? reachAt : saidAt,
                    isCurrent: isCurrent
                )
            }
        }
    }

    /// One conversation as it reads, ended or not.
    public func conversation(id: String) throws -> ConversationSnapshot? {
        let row = try userQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT ended_at FROM conversations WHERE id = ?", arguments: [id])
        }
        guard let row else { return nil }
        return ConversationSnapshot(
            id: id,
            messages: try messages(conversationID: id),
            ended: (row["ended_at"] as String?) != nil
        )
    }

    func isEnded(conversationID: String) throws -> Bool {
        try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT ended_at FROM conversations WHERE id = ?",
                arguments: [conversationID]
            ) != nil
        }
    }

    /// Starts a new conversation with her: the next turn goes into it, and the one that
    /// was current becomes a past conversation. Does nothing while the current one is
    /// still open.
    @discardableResult
    public func startConversation(characterID: String, now: Date = Date()) throws -> String {
        if let current = try currentConversationID(characterID),
           try !isEnded(conversationID: current) {
            return current
        }
        let id = UUID().uuidString
        try userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversations(id, character_id, created_at) VALUES (?, ?, ?)",
                arguments: [id, characterID, Self.timestamp(now)]
            )
        }
        return id
    }

    /// Deletes a past conversation for good. What she remembered from it stays, as does
    /// the affinity it moved (GLOSSARY.md「历史对话」).
    public func deleteConversation(id: String) throws {
        try userQueue.write { db in
            guard let characterID = try String.fetchOne(
                db,
                sql: "SELECT character_id FROM conversations WHERE id = ?",
                arguments: [id]
            ) else { return }
            let current = try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM conversations WHERE character_id = ?
                    ORDER BY created_at DESC, rowid DESC LIMIT 1
                    """,
                arguments: [characterID]
            )
            guard current != id else { throw EidolonError.conversationIsCurrent }
            // She remembers what she was told there; the conversation it came from is gone.
            try db.execute(
                sql: "UPDATE memories SET conversation_id = NULL WHERE conversation_id = ?",
                arguments: [id]
            )
            try db.execute(
                sql: "DELETE FROM pending_jobs WHERE conversation_id = ?",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM reach_outs WHERE conversation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM conversation_events WHERE conversation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM messages WHERE conversation_id = ?", arguments: [id])
            try db.execute(sql: "DELETE FROM conversations WHERE id = ?", arguments: [id])
        }
    }

    /// Saves the producer profile: how she addresses the producer, their gender, the time
    /// zone their days go by and their birthday (GLOSSARY.md「制作人档案」). It reaches the
    /// next turn's prompt; it never rewrites the story.
    public func updateProducerProfile(_ profile: ProducerProfile) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO producer_profile(
                        id, form_of_address, gender, timezone, birthday_month, birthday_day
                    ) VALUES (1, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        form_of_address = excluded.form_of_address,
                        gender = excluded.gender,
                        timezone = excluded.timezone,
                        birthday_month = excluded.birthday_month,
                        birthday_day = excluded.birthday_day
                    """,
                arguments: [
                    profile.formOfAddress?.isEmpty == true ? nil : profile.formOfAddress,
                    profile.gender?.rawValue,
                    profile.timezone?.isEmpty == true ? nil : profile.timezone,
                    profile.birthdayMonth,
                    profile.birthdayDay,
                ]
            )
        }
    }
}
