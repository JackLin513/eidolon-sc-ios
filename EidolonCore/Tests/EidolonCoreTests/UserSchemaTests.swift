import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// The user library's schema, as it is upgraded from what an earlier build wrote (ADR-0002).
final class UserSchemaTests: XCTestCase {
    /// A v1 library kept her affinity without a timestamp to recover from; the upgrade
    /// gives those rows a usable `updated_at` (the moment of the upgrade), so the first
    /// read no longer swallows the recovery or moves a cooldown's start.
    func testAnUpgradedAffinityRowHasAUsableUpdatedAt() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            // What v1 left, with its migration recorded as applied.
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v1')")
            try db.execute(sql: """
                CREATE TABLE affinities (
                    character_id TEXT PRIMARY KEY,
                    value REAL NOT NULL,
                    cooling INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(sql: """
                INSERT INTO affinities(character_id, value, cooling) VALUES ('mano', 30, 0)
                """)
            // The tables the later migrations touch.
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    ended_at TEXT
                );
                CREATE TABLE memories (
                    id TEXT PRIMARY KEY,
                    source_character_id TEXT,
                    conversation_id TEXT,
                    text TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    superseded_by TEXT
                );
                CREATE TABLE memory_vectors (
                    memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
                    model TEXT NOT NULL,
                    embedding BLOB NOT NULL
                );
                CREATE TABLE messages (id TEXT PRIMARY KEY);
                CREATE TABLE conversation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT,
                    kind TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                """)
        }

        try UserSchema.migrate(queue)

        let stamp: String = try queue.read { db in
            try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT updated_at FROM affinities WHERE character_id = 'mano'")
            )
        }
        let date = try XCTUnwrap(Eidolon.parseTimestamp(stamp), "updated_at: \(stamp)")
        XCTAssertLessThan(abs(date.timeIntervalSinceNow), 60)
        let value: Double = try queue.read { db in
            try XCTUnwrap(
                Double.fetchOne(db, sql: "SELECT value FROM affinities WHERE character_id = 'mano'")
            )
        }
        XCTAssertEqual(value, 30)
    }

    /// Older builds wrote every call ending into the conversation: the producer's own
    /// hang-up as `hung_up`, hers as `she_hung_up`, and the other endings as `call_*`.
    /// Now `hung_up` means hers (upstream records only hers), so the old `hung_up` and the
    /// `call_*` rows are dropped, and `she_hung_up` is renamed. The delete has to come
    /// before the rename, or her hang-up would be read as the producer's and dropped too.
    func testOldCallEventsAreRewrittenAndTheProducersHangUpIsDropped() throws {
        let queue = try DatabaseQueue()
        try UserSchema.migrate(queue)
        try queue.write { db in
            // Make the upgrade run again, over a library an older build left behind.
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v7'")
            try db.execute(sql: """
                INSERT INTO conversations(id, character_id, created_at)
                VALUES ('c1', 'mano', '2026-10-27T12:00:00Z')
                """)
            let stamp = "2026-10-27T12:00:00Z"
            for kind in [
                "hung_up", "she_hung_up", "call_unconnected", "call_dropped", "call_failed",
                "call_duration_limit", "call_turn_limit", "ended",
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO conversation_events(conversation_id, kind, created_at)
                        VALUES ('c1', ?, ?)
                        """,
                    arguments: [kind, stamp]
                )
            }
        }

        try UserSchema.migrate(queue)

        let kinds = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events ORDER BY id")
        }
        XCTAssertEqual(
            kinds,
            ["hung_up", "ended"],
            "hers is renamed; the producer's old hang-up and the call_* endings are dropped"
        )
        // The row left under `hung_up` is hers, not the producer's.
        XCTAssertEqual(
            ConversationEventKind(stored: kinds[0]).narration,
            "（你挂断了制作人的电话。）"
        )
    }

    /// v8 did not keep how a reply changed her affinity. Upgrading leaves those replies
    /// without a change rather than guessing one (spec #38).
    func testUpgradingToV9LeavesOldRepliesWithoutAChange() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for version in ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8"] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
                    arguments: [version]
                )
            }
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    ended_at TEXT
                );
                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL,
                    role TEXT NOT NULL,
                    text TEXT,
                    ja TEXT,
                    zh TEXT,
                    segments TEXT,
                    created_at TEXT NOT NULL,
                    affinity TEXT,
                    hurt INTEGER NOT NULL DEFAULT 0,
                    out_of_line INTEGER NOT NULL DEFAULT 0,
                    typed INTEGER NOT NULL DEFAULT 1
                )
                """)
            try db.execute(sql: """
                INSERT INTO messages(id, conversation_id, role, segments, created_at, affinity)
                VALUES ('old', 'c1', 'character', '[]', '2026-10-30T12:00:00.000000Z', 'trust')
                """)
        }

        try UserSchema.migrate(queue)

        let change = try queue.read { db in
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM messages WHERE id = 'old'"))
            return Eidolon.decodeAffinityChange(row)
        }
        XCTAssertNil(change)
    }

    /// v14 made the current conversation an explicit pointer instead of "the newest one".
    /// An upgraded library points each character at the newest conversation she had then
    /// (spec #62).
    func testUpgradingToV14PointsAtEachCharactersNewestConversation() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for version in ["v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12", "v13"] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
                    arguments: [version]
                )
            }
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    ended_at TEXT
                )
                """)
            try db.execute(sql: """
                INSERT INTO conversations(id, character_id, created_at) VALUES
                    ('mano-old', 'mano', '2026-01-01T00:00:00.000000Z'),
                    ('mano-new', 'mano', '2026-02-01T00:00:00.000000Z'),
                    ('hiori-only', 'hiori', '2026-01-15T00:00:00.000000Z')
                """)
        }

        try UserSchema.migrate(queue)

        let pointers = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT character_id, conversation_id FROM current_conversations ORDER BY character_id"
            ).map { (row: Row) in (row["character_id"] as String, row["conversation_id"] as String) }
        }
        XCTAssertEqual(pointers.map(\.0), ["hiori", "mano"])
        XCTAssertEqual(pointers.map(\.1), ["hiori-only", "mano-new"])
    }

    /// v16 adds the gift, achievement and reward tables and the gift columns, without
    /// touching what the producer already had (spec #63, #65).
    func testUpgradingToV16AddsGiftsAndKeepsOldCallsAndEvents() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for version in [
                "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12",
                "v13", "v14", "v15",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
                    arguments: [version]
                )
            }
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    ended_at TEXT
                );
                INSERT INTO conversations(id, character_id, created_at)
                VALUES ('c1', 'mano', '2026-01-01T00:00:00.000000Z');
                CREATE TABLE call_ends (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL,
                    character_id TEXT NOT NULL,
                    ended_at TEXT NOT NULL
                );
                INSERT INTO call_ends(conversation_id, character_id, ended_at)
                VALUES ('c1', 'mano', '2026-01-01T00:10:00.000000Z');
                CREATE TABLE conversation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                INSERT INTO conversation_events(conversation_id, kind, created_at)
                VALUES ('c1', 'ended', '2026-01-01T00:10:00.000000Z');
                """)
        }

        try UserSchema.migrate(queue)

        let tables = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        for table in [
            "gift_balances", "gift_backpack", "gift_rewards", "achievement_progress",
            "achievement_stages", "achievements_launched",
        ] {
            XCTAssertTrue(tables.contains(table), "\(table) was not created")
        }
        let call = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT character_id, connected_at, duration_s FROM call_ends
                    WHERE conversation_id = 'c1'
                    """
            )
        }
        XCTAssertEqual(call?["character_id"] as String?, "mano")
        XCTAssertNil(call?["connected_at"] as String?, "an old call has no connected_at")
        XCTAssertNil(call?["duration_s"] as Double?, "an old call has no length")
        let event = try queue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, gift_id, liked, affinity FROM conversation_events
                    WHERE conversation_id = 'c1'
                    """
            )
        }
        XCTAssertEqual(event?["kind"] as String?, "ended")
        XCTAssertNil(event?["gift_id"] as String?)
        XCTAssertNil(event?["liked"] as Int?)
        XCTAssertNil(event?["affinity"] as String?)
        let conversations = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
        }
        XCTAssertEqual(conversations, 1)
    }

    /// v15's debug shield is off for every conversation an older library already had.
    func testUpgradingToV15LeavesTheDebugShieldOff() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            for version in [
                "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11", "v12",
                "v13", "v14",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations(identifier) VALUES (?)",
                    arguments: [version]
                )
            }
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    ended_at TEXT
                );
                INSERT INTO conversations(id, character_id, created_at)
                VALUES ('c1', 'mano', '2026-01-01T00:00:00.000000Z')
                """)
        }

        try UserSchema.migrate(queue)

        let shielded = try queue.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT debug_no_ending FROM conversations WHERE id = 'c1'"
            )
        }
        XCTAssertEqual(shielded, false)
    }
}
