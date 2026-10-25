import Foundation
import GRDB

/// The writable user library (ADR-0002). Its schema evolves with the app, not
/// with the content bundle, and is therefore managed by GRDB migrations.
enum UserSchema {
    static let version = 4

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE conversations (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    title TEXT,
                    ended_at TEXT
                );
                CREATE INDEX conversations_by_character
                    ON conversations(character_id, created_at);

                CREATE TABLE messages (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    text TEXT,
                    ja TEXT,
                    zh TEXT,
                    segments TEXT,
                    created_at TEXT NOT NULL,
                    affinity TEXT,
                    hurt INTEGER NOT NULL DEFAULT 0,
                    out_of_line INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX messages_by_conversation
                    ON messages(conversation_id, created_at);

                CREATE TABLE conversation_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );

                CREATE TABLE reach_outs (
                    id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    ja TEXT NOT NULL,
                    zh TEXT,
                    segments TEXT,
                    seen INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL
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

                CREATE TABLE fact_vectors (
                    scope TEXT NOT NULL,
                    entry_id TEXT NOT NULL,
                    model TEXT NOT NULL,
                    embedding BLOB NOT NULL,
                    PRIMARY KEY (scope, entry_id, model)
                );

                CREATE TABLE affinities (
                    character_id TEXT PRIMARY KEY,
                    value REAL NOT NULL,
                    cooling INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE pending_jobs (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    kind TEXT NOT NULL,
                    conversation_id TEXT,
                    message_id TEXT,
                    created_at TEXT NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE turn_traces (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT,
                    created_at TEXT NOT NULL,
                    payload TEXT NOT NULL
                );

                CREATE TABLE producer_profile (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    form_of_address TEXT,
                    gender TEXT,
                    timezone TEXT,
                    birthday_month INTEGER,
                    birthday_day INTEGER
                );

                CREATE TABLE app_state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: "ALTER TABLE affinities ADD COLUMN updated_at TEXT NOT NULL DEFAULT ''")
            try db.execute(sql: "ALTER TABLE affinities ADD COLUMN gained_today REAL NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE affinities ADD COLUMN gained_on TEXT")
        }
        migrator.registerMigration("v3") { db in
            // One user: the same memory written down twice is the same memory.
            try db.execute(sql: "CREATE UNIQUE INDEX memories_by_text ON memories(text)")
            // A memory's vector is per embedding model, as the content library's are.
            try db.execute(sql: """
                CREATE TABLE memory_vectors_v3 (
                    memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
                    model TEXT NOT NULL,
                    embedding BLOB NOT NULL,
                    PRIMARY KEY (memory_id, model)
                );
                INSERT INTO memory_vectors_v3(memory_id, model, embedding)
                    SELECT memory_id, model, embedding FROM memory_vectors;
                DROP TABLE memory_vectors;
                ALTER TABLE memory_vectors_v3 RENAME TO memory_vectors;
                """)
        }
        migrator.registerMigration("v4") { db in
            // A turn taken in a call counts in the call, not in the conversation's typed
            // turns; what was written before this is read as a typed turn (upstream
            // records the distinction as `hurt IS NOT NULL`).
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN typed INTEGER NOT NULL DEFAULT 1")
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
    }
}
