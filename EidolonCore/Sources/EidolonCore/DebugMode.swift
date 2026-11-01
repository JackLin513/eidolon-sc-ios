import Foundation
import GRDB

/// What the in-app debug mode writes (spec #62, ADR-0026). These deliberately cross rules
/// the normal paths enforce: she can be given a value she never earned, a conversation she
/// ended can be opened again, and a past conversation can be made current. Nothing here is
/// reachable unless the debug switch is on, and nothing here writes a turn, an event, a
/// trace or a title.
extension Eidolon {
    // MARK: - Affinity

    /// Her affinity as the debug page edits it: the value after the recovery time has
    /// passed, so the number on screen is the one a turn would see.
    public func debugAffinity(characterID: String, now: Date = Date()) throws -> Affinity {
        try readAffinity(characterID: characterID, now: now)
    }

    /// Sets her affinity outright. The day's gains are cleared too, so the next turn does
    /// not start from an allowance earlier turns already used. Reaching the lowest value
    /// begins a cooldown; any value above it ends one.
    public func debugSetAffinity(characterID: String, value: Double, now: Date = Date()) throws {
        let clamped = min(max(value, AffinityRules.lowest), AffinityRules.highest)
        let cooling = clamped <= AffinityRules.lowest
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES (?, ?, ?, ?, 0, NULL)
                    ON CONFLICT(character_id) DO UPDATE SET
                        value = excluded.value, cooling = excluded.cooling,
                        updated_at = excluded.updated_at,
                        gained_today = excluded.gained_today, gained_on = excluded.gained_on
                    """,
                arguments: [
                    characterID, clamped, cooling ? 1 : 0, Self.timestamp(now),
                ]
            )
        }
    }

    // MARK: - Conversations

    /// Opens an ended conversation again. The event that ended it goes with the flag: the
    /// next turn's narration must not tell her she ended a conversation she is now in.
    /// A `hung_up` event stays.
    @discardableResult
    public func debugReopenConversation(id: String) throws -> Bool {
        try userQueue.write { db in
            guard let exists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?)",
                arguments: [id]
            ), exists else { return false }
            try Self.reopen(db, conversationID: id)
            return true
        }
    }

    /// Puts a conversation back in use without touching when it started. `reopen` also
    /// clears an ending, so a past conversation that ended can be typed in at once.
    @discardableResult
    public func debugSetCurrentConversation(
        characterID: String,
        id: String,
        reopen: Bool = false
    ) throws -> Bool {
        try userQueue.write { db in
            guard let owner = try String.fetchOne(
                db,
                sql: "SELECT character_id FROM conversations WHERE id = ?",
                arguments: [id]
            ), owner == characterID else { return false }
            try Self.pointCurrentConversation(db, characterID: characterID, id: id)
            if reopen {
                try Self.reopen(db, conversationID: id)
            }
            return true
        }
    }

    private static func reopen(_ db: Database, conversationID: String) throws {
        try db.execute(
            sql: "UPDATE conversations SET ended_at = NULL WHERE id = ?",
            arguments: [conversationID]
        )
        try db.execute(
            sql: "DELETE FROM conversation_events WHERE conversation_id = ? AND kind = 'ended'",
            arguments: [conversationID]
        )
    }

    // MARK: - Memories

    /// What this conversation was remembered for, newest first. Memory writing that is
    /// still under way is waited for, so a line just said is already listed.
    public func debugMemories(conversationID: String) async throws -> [MemoryRecord] {
        await settleMemories()
        return try await userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_character_id, text, created_at, superseded_by
                    FROM memories WHERE conversation_id = ?
                    ORDER BY created_at DESC, rowid DESC
                    """,
                arguments: [conversationID]
            ).map { row in
                MemoryRecord(
                    id: row["id"],
                    sourceCharacterID: row["source_character_id"],
                    text: row["text"],
                    createdAt: row["created_at"],
                    supersededBy: row["superseded_by"]
                )
            }
        }
    }

    /// Forgets the chosen memories and the vectors that would find them, in one write.
    /// Says how many rows were really deleted; ids that are already gone are not errors.
    @discardableResult
    public func debugDeleteMemories(ids: [String]) async throws -> Int {
        guard !ids.isEmpty else { return 0 }
        await settleMemories()
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let arguments = StatementArguments(ids)
        return try await userQueue.write { db in
            try db.execute(
                sql: "DELETE FROM memory_vectors WHERE memory_id IN (\(marks))",
                arguments: arguments
            )
            try db.execute(
                sql: "DELETE FROM memories WHERE id IN (\(marks))",
                arguments: arguments
            )
            return db.changesCount
        }
    }

}
