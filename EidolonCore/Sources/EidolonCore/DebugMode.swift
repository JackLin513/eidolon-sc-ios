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
            try Self.writeAffinity(
                db,
                characterID: characterID,
                value: clamped,
                cooling: cooling,
                updatedAt: Self.timestamp(now),
                gainedToday: 0,
                gainedOn: nil
            )
        }
    }

    // MARK: - Gifts

    /// Puts the gift page in a known state for UI tests: a number of chances and cards,
    /// and an empty backpack. Like the rest of this file it is not on a normal path.
    public func debugSetGiftBalance(
        draws: Int,
        resetCards: Int = 0,
        now: Date = Date()
    ) throws {
        let today = GiftRules.day(now)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO gift_balances (id, draws, given_on, reset_cards)
                    VALUES (1, ?, ?, ?)
                    ON CONFLICT (id) DO UPDATE SET
                        draws = excluded.draws,
                        given_on = excluded.given_on,
                        reset_cards = excluded.reset_cards
                    """,
                arguments: [max(0, draws), today, max(0, resetCards)]
            )
            try db.execute(sql: "DELETE FROM gift_backpack")
        }
    }

    /// Puts gifts in the backpack for UI tests, replacing it.
    public func debugSetGiftBackpack(_ gifts: [String: Int]) throws {
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM gift_backpack")
            for (id, count) in gifts where count > 0 {
                try db.execute(
                    sql: "INSERT INTO gift_backpack(gift_id, count) VALUES (?, ?)",
                    arguments: [id, count]
                )
            }
        }
    }

    /// Adds draw chances, with no cap, for trying the gift page in debug mode. It gives
    /// the day's chances first, as opening the page would; it does not draw anything, so
    /// nothing goes into the backpack and the draw achievements do not move.
    public func debugAddGiftDraws(_ count: Int, now: Date = Date()) throws -> Int {
        try userQueue.write { db in
            try Self.giveDueGiftDraws(db, at: now)
            if count > 0 {
                try db.execute(
                    sql: "UPDATE gift_balances SET draws = draws + ? WHERE id = 1",
                    arguments: [count]
                )
            }
            return try Int.fetchOne(
                db,
                sql: "SELECT draws FROM gift_balances WHERE id = 1"
            ) ?? 0
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
        return try await userQueue.write { db in
            try Self.deleteMemoryRows(db, ids: ids)
        }
    }

    // MARK: - Keeping this conversation open

    /// Whether this conversation is shielded from the affinity-driven endings: the two
    /// out-of-line turns, the accumulated hurt, and the cooldown that would begin. The
    /// affinity itself still falls; only ending the conversation is held back.
    public func debugNoEnding(conversationID: String) throws -> Bool {
        try userQueue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT debug_no_ending FROM conversations WHERE id = ?",
                arguments: [conversationID]
            ) ?? false
        }
    }

    /// Turns the shield on or off for this conversation. Only this row changes; a new
    /// conversation starts off, and the normal rules come back when it is turned off.
    public func setDebugNoEnding(conversationID: String, on: Bool) throws {
        try userQueue.write { db in
            try db.execute(
                sql: "UPDATE conversations SET debug_no_ending = ? WHERE id = ?",
                arguments: [on ? 1 : 0, conversationID]
            )
        }
    }

}
