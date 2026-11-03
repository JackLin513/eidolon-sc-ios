import Foundation
import GRDB

/// The writable user library (ADR-0002). Its schema evolves with the app, not
/// with the content bundle, and is therefore managed by GRDB migrations.
enum UserSchema {
    static let version = 16

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
        migrator.registerMigration("v5") { db in
            // An affinity row carried over from v1 has no timestamp: reading it as "now"
            // swallowed the recovery it was owed and moved a cooldown's start. The upgrade
            // is the earliest moment it can be said to have been true, so recovery goes on
            // from there.
            let now = Eidolon.timestamp(Date())
            try db.execute(
                sql: "UPDATE affinities SET updated_at = ? WHERE updated_at IS NULL OR updated_at = ''",
                arguments: [now]
            )
        }
        migrator.registerMigration("v6") { db in
            // When a call that connected ended, so that "when did we last talk" counts it
            // as upstream's `calls` table does (its `connected_at` plus `duration_s`).
            try db.execute(sql: """
                CREATE TABLE call_ends (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                    character_id TEXT NOT NULL,
                    ended_at TEXT NOT NULL
                );
                CREATE INDEX call_ends_by_character
                    ON call_ends(character_id, ended_at);
                """)
        }
        migrator.registerMigration("v7") { db in
            // Older builds wrote every call ending into the conversation, the producer's
            // own hang-up as `hung_up` and hers as `she_hung_up`; now only her hang-up is
            // kept, and `hung_up` means that (upstream records only hers). The old
            // `hung_up` has to go before `she_hung_up` takes its name, or it would be
            // read as her hanging up. The call_* kinds were the other endings upstream
            // only traces; they are dropped.
            try db.execute(sql: "DELETE FROM conversation_events WHERE kind = 'hung_up'")
            try db.execute(sql: "DELETE FROM conversation_events WHERE kind GLOB 'call_*'")
            try db.execute(
                sql: "UPDATE conversation_events SET kind = 'hung_up' WHERE kind = 'she_hung_up'"
            )
        }
        migrator.registerMigration("v8") { db in
            // Each visit to the bar done is written down (GLOSSARY.md「光顾」, ADR-0021): who
            // came, when, why, what about, each order as JSON, whether she got drunk, and
            // whether the visit was rewarded. Nothing of what was said. Its shape follows
            // upstream's `visit_records` row, less the user it is the one user's of.
            try db.execute(sql: """
                CREATE TABLE bar_visits (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    character_id TEXT NOT NULL,
                    entered_at TEXT NOT NULL,
                    left_at TEXT NOT NULL,
                    entered_on TEXT NOT NULL,
                    reason TEXT NOT NULL,
                    topic TEXT NOT NULL,
                    orders TEXT NOT NULL,
                    drunk INTEGER NOT NULL,
                    rewarded INTEGER NOT NULL
                );
                CREATE INDEX bar_visits_by_her ON bar_visits (character_id, id);
                CREATE INDEX bar_visits_by_day ON bar_visits (entered_on);
                """)
        }
        migrator.registerMigration("v9") { db in
            // How a reply changed her affinity, kept beside it so the transcript can say
            // it after the fact (spec #38). All three are null when the turn changed
            // nothing; `messages.affinity` still holds the tier she was left in.
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN affinity_up INTEGER")
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN affinity_tier_changed INTEGER")
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN affinity_cooldown INTEGER")
        }
        migrator.registerMigration("v10") { db in
            // The weekly schedule (spec #50): the jobs drawn for a week, kept so the week
            // never changes once published, and what the producer placed.
            try db.execute(sql: """
                CREATE TABLE schedule_weeks (
                    week TEXT PRIMARY KEY,
                    drawn_at TEXT NOT NULL
                );
                CREATE TABLE weekly_jobs (
                    id TEXT PRIMARY KEY,
                    week TEXT NOT NULL,
                    character_id TEXT NOT NULL,
                    listed_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    note TEXT NOT NULL,
                    category TEXT NOT NULL,
                    length INTEGER NOT NULL,
                    slots TEXT
                );
                CREATE INDEX weekly_jobs_by_week
                    ON weekly_jobs(week, character_id);
                CREATE TABLE schedule_placements (
                    week TEXT NOT NULL,
                    job_id TEXT NOT NULL,
                    character_id TEXT NOT NULL,
                    day INTEGER NOT NULL,
                    slot INTEGER NOT NULL,
                    saved_at TEXT NOT NULL,
                    counted_at TEXT,
                    PRIMARY KEY (week, job_id)
                );
                CREATE INDEX schedule_placements_by_her
                    ON schedule_placements(character_id, week);
                """)
        }
        migrator.registerMigration("v11") { db in
            // Her cycle (spec #52): a stable seed for each character on this device, and the
            // one switch for all of them. The seed is made when first needed; cycles are on
            // until switched off.
            try db.execute(sql: """
                CREATE TABLE cycle_seeds (
                    character_id TEXT PRIMARY KEY,
                    seed BLOB NOT NULL
                );
                CREATE TABLE cycle_settings (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    enabled INTEGER NOT NULL DEFAULT 1
                );
                """)
        }
        migrator.registerMigration("v12") { db in
            // The periods the producer writes down (spec #53); the estimate is worked out
            // from them whenever it is read, never stored, and her true cycle is not read.
            try db.execute(sql: """
                CREATE TABLE cycle_records (
                    id TEXT PRIMARY KEY,
                    character_id TEXT NOT NULL,
                    first_day TEXT NOT NULL,
                    days INTEGER NOT NULL,
                    recorded_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                );
                CREATE INDEX cycle_records_by_her
                    ON cycle_records(character_id, first_day);
                """)
        }
        migrator.registerMigration("v13") { db in
            // A reply's ordered blocks: spoken lines and scene blocks (spec #60). Old rows
            // have no value and are read from `segments` as lines.
            try db.execute(sql: "ALTER TABLE messages ADD COLUMN blocks TEXT")
        }
        migrator.registerMigration("v14") { db in
            // The current conversation is a pointer, not "the newest one" any more: a
            // debug action can put an older one back in use without rewriting its start
            // time (spec #62). An upgraded library points at what it showed before.
            try db.execute(sql: """
                CREATE TABLE current_conversations (
                    character_id TEXT PRIMARY KEY,
                    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE
                );
                INSERT INTO current_conversations(character_id, conversation_id)
                SELECT c.character_id, c.id
                FROM conversations c
                WHERE c.rowid = (
                    SELECT c2.rowid FROM conversations c2
                    WHERE c2.character_id = c.character_id
                    ORDER BY c2.created_at DESC, c2.rowid DESC
                    LIMIT 1
                );
                """)
        }
        migrator.registerMigration("v15") { db in
            // A debug conversation can keep going after the affinity that would have
            // ended it (spec #62). Off for every conversation until the debug page turns
            // it on; a new conversation starts off.
            try db.execute(sql: """
                ALTER TABLE conversations ADD COLUMN debug_no_ending INTEGER NOT NULL DEFAULT 0
                """)
        }
        migrator.registerMigration("v16") { db in
            // Gifts and achievements (spec #63, #65): what the producer has drawn, what is
            // in the backpack, the rewards already given by their key (so each is given
            // once), and the achievement stages reached. One producer, so no user column.
            try db.execute(sql: """
                CREATE TABLE gift_balances (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    draws INTEGER NOT NULL,
                    given_on TEXT NOT NULL,
                    reset_cards INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE gift_backpack (
                    gift_id TEXT PRIMARY KEY,
                    count INTEGER NOT NULL
                );
                CREATE TABLE gift_rewards (
                    key TEXT PRIMARY KEY,
                    draws INTEGER NOT NULL,
                    reset_cards INTEGER NOT NULL,
                    rewarded_at TEXT NOT NULL
                );
                CREATE TABLE achievement_progress (
                    achievement TEXT NOT NULL,
                    character_id TEXT NOT NULL,
                    count REAL NOT NULL,
                    last_day TEXT,
                    PRIMARY KEY (achievement, character_id)
                );
                CREATE TABLE achievement_stages (
                    achievement TEXT NOT NULL,
                    character_id TEXT NOT NULL,
                    stage INTEGER NOT NULL,
                    unlocked_at TEXT NOT NULL,
                    PRIMARY KEY (achievement, character_id, stage)
                );
                CREATE TABLE achievements_launched (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    launched_at TEXT NOT NULL,
                    notice_seen INTEGER NOT NULL DEFAULT 0
                );
                """)
            // A connected call's start and length, for the call achievements (spec #63).
            // Old rows keep NULL, and the one-time backfill reads them as zero. A library
            // that never ran v6 has no call table, as the partial test libraries show.
            if try db.tableExists("call_ends") {
                try db.execute(sql: "ALTER TABLE call_ends ADD COLUMN connected_at TEXT")
                try db.execute(sql: "ALTER TABLE call_ends ADD COLUMN duration_s REAL")
            }
            // A gift given to her, as the conversation event that tells her of it (spec
            // #63): which gift, whether she likes it, and the affinity change it showed.
            if try db.tableExists("conversation_events") {
                try db.execute(sql: "ALTER TABLE conversation_events ADD COLUMN gift_id TEXT")
                try db.execute(sql: "ALTER TABLE conversation_events ADD COLUMN liked INTEGER")
                try db.execute(sql: "ALTER TABLE conversation_events ADD COLUMN affinity TEXT")
            }
        }
        try migrator.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
    }
}
