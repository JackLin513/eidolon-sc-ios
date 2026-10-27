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
}
