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
}
