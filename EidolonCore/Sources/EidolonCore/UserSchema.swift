import Foundation
import GRDB

/// The writable user library (ADR-0002). Its schema evolves with the app, not
/// with the content bundle, and is therefore managed by GRDB migrations.
///
/// v25 is a break: Phase B scopes the library by franchise, so an older library is
/// backed up and replaced instead of migrated (ADR-0037). A fresh library is created
/// directly at v25; there is no data to carry over.
enum UserSchema {
    static let version = 25

    struct LegacyLibrary: Error, CustomStringConvertible {
        var version: Int
        var description: String {
            "user library is v\(version), but this build only opens a fresh v\(UserSchema.version) library"
        }
    }

    static func migrate(_ dbQueue: DatabaseQueue) throws {
        let current = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        if current == version { return }
        guard current == 0 else { throw LegacyLibrary(version: current) }
        try dbQueue.write { db in
            try db.execute(sql: ddl)
            try db.execute(sql: "PRAGMA user_version = \(version)")
        }
    }

    /// A fresh v25 library.
    ///
    /// `conversations.franchise_id` and `current_conversations` are the first identity
    /// boundary: a local character id only names someone inside a franchise.
    /// `conversation_participants` and the `messages.speaker_*` columns are the shared
    /// shapes group conversations will use; a one-character conversation still writes
    /// one participant row and leaves the speaker columns for her replies.
    private static let ddl = """
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            franchise_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            created_at TEXT NOT NULL,
            title TEXT,
            ended_at TEXT,
            debug_no_ending INTEGER NOT NULL DEFAULT 0,
            face_to_face INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX conversations_by_character
            ON conversations(franchise_id, character_id, created_at);

        CREATE TABLE conversation_participants (
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            franchise_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            role TEXT NOT NULL,
            joined_at TEXT NOT NULL,
            PRIMARY KEY (conversation_id, franchise_id, character_id)
        );
        CREATE INDEX conversation_participants_by_character
            ON conversation_participants(franchise_id, character_id);

        CREATE TABLE messages (
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            speaker_kind TEXT,
            speaker_franchise TEXT,
            speaker_character TEXT,
            text TEXT,
            ja TEXT,
            zh TEXT,
            segments TEXT,
            created_at TEXT NOT NULL,
            affinity TEXT,
            hurt INTEGER NOT NULL DEFAULT 0,
            out_of_line INTEGER NOT NULL DEFAULT 0,
            typed INTEGER NOT NULL DEFAULT 1,
            affinity_up INTEGER,
            affinity_tier_changed INTEGER,
            affinity_cooldown INTEGER,
            blocks TEXT
        );
        CREATE INDEX messages_by_conversation
            ON messages(conversation_id, created_at);

        CREATE TABLE conversation_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            kind TEXT NOT NULL,
            created_at TEXT NOT NULL,
            gift_id TEXT,
            liked INTEGER,
            affinity TEXT
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
            source_franchise_id TEXT,
            source_character_id TEXT,
            conversation_id TEXT,
            text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            superseded_by TEXT
        );
        CREATE UNIQUE INDEX memories_by_text ON memories(text);
        CREATE INDEX memories_by_source
            ON memories(source_franchise_id, source_character_id);

        CREATE TABLE memory_vectors (
            memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (memory_id, model)
        );

        CREATE TABLE fact_vectors (
            scope TEXT NOT NULL,
            entry_id TEXT NOT NULL,
            model TEXT NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (scope, entry_id, model)
        );

        CREATE TABLE affinities (
            franchise_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            value REAL NOT NULL,
            cooling INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT '',
            gained_today REAL NOT NULL DEFAULT 0,
            gained_on TEXT,
            PRIMARY KEY (franchise_id, character_id)
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
            franchise_id TEXT PRIMARY KEY,
            form_of_address TEXT,
            gender TEXT,
            timezone TEXT,
            birthday_month INTEGER,
            birthday_day INTEGER,
            birthday_year INTEGER
        );

        CREATE TABLE app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );

        CREATE TABLE call_ends (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            character_id TEXT NOT NULL,
            ended_at TEXT NOT NULL,
            connected_at TEXT,
            duration_s REAL
        );
        CREATE INDEX call_ends_by_character
            ON call_ends(character_id, ended_at);

        CREATE TABLE bar_visits (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            franchise_id TEXT NOT NULL,
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
        CREATE INDEX bar_visits_by_her ON bar_visits (franchise_id, character_id, id);
        CREATE INDEX bar_visits_by_day ON bar_visits (franchise_id, entered_on);

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

        CREATE TABLE cycle_seeds (
            franchise_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            seed BLOB NOT NULL,
            PRIMARY KEY (franchise_id, character_id)
        );
        CREATE TABLE cycle_settings (
            franchise_id TEXT PRIMARY KEY,
            enabled INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE cycle_records (
            id TEXT PRIMARY KEY,
            franchise_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            first_day TEXT NOT NULL,
            days INTEGER NOT NULL,
            recorded_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX cycle_records_by_her
            ON cycle_records(franchise_id, character_id, first_day);

        CREATE TABLE current_conversations (
            franchise_id TEXT NOT NULL,
            character_id TEXT NOT NULL,
            conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
            PRIMARY KEY (franchise_id, character_id)
        );

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
            rewarded_at TEXT NOT NULL,
            seen INTEGER NOT NULL DEFAULT 0
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
            seen INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (achievement, character_id, stage)
        );
        CREATE TABLE achievements_launched (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            launched_at TEXT NOT NULL,
            notice_seen INTEGER NOT NULL DEFAULT 0,
            notice_stages INTEGER NOT NULL DEFAULT 0,
            notice_draws INTEGER NOT NULL DEFAULT 0,
            notice_reset_cards INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE achievement_play_seen (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            seen_at TEXT NOT NULL
        );

        CREATE TABLE service_calls (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            at TEXT NOT NULL,
            service TEXT NOT NULL,
            provider TEXT NOT NULL DEFAULT '',
            model TEXT NOT NULL DEFAULT '',
            operation TEXT NOT NULL,
            unit TEXT NOT NULL,
            input INTEGER NOT NULL DEFAULT 0,
            output INTEGER,
            cached_input INTEGER,
            estimated INTEGER NOT NULL DEFAULT 0,
            latency REAL,
            error TEXT,
            conversation_id TEXT,
            call_id TEXT
        );
        CREATE INDEX service_calls_by_at ON service_calls(at);
        CREATE INDEX service_calls_by_service
            ON service_calls(service, provider, model, at);

        CREATE TABLE price_overrides (
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            unit TEXT NOT NULL,
            input REAL NOT NULL,
            output REAL,
            cached_input REAL,
            currency TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            PRIMARY KEY (provider, model, unit)
        );

        CREATE TABLE photos (
            id TEXT PRIMARY KEY,
            conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
            message_id TEXT REFERENCES messages(id) ON DELETE CASCADE,
            tag TEXT NOT NULL,
            status TEXT NOT NULL,
            reason TEXT,
            file TEXT,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            started_at TEXT NOT NULL,
            finished_at TEXT
        );
        CREATE INDEX photos_by_message ON photos(message_id);
        CREATE INDEX photos_by_started ON photos(started_at);

        CREATE TABLE moment_posts (
            id TEXT PRIMARY KEY,
            character_id TEXT NOT NULL,
            ja TEXT NOT NULL,
            zh TEXT NOT NULL,
            plan_day TEXT NOT NULL,
            reveal_at TEXT NOT NULL,
            created_at TEXT NOT NULL,
            place_id TEXT,
            place_name TEXT,
            place_area TEXT,
            place_lat REAL,
            place_lon REAL,
            weather_code INTEGER,
            weather_temperature INTEGER
        );
        CREATE INDEX moment_posts_by_reveal
            ON moment_posts(reveal_at);
        CREATE INDEX moment_posts_by_character
            ON moment_posts(character_id, plan_day);
        CREATE TABLE moment_images (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL REFERENCES moment_posts(id) ON DELETE CASCADE,
            file TEXT NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            composition TEXT NOT NULL,
            tag TEXT NOT NULL,
            note TEXT,
            created_at TEXT NOT NULL
        );
        CREATE INDEX moment_images_by_post ON moment_images(post_id);
        CREATE TABLE moment_reactions (
            id TEXT PRIMARY KEY,
            post_id TEXT NOT NULL REFERENCES moment_posts(id) ON DELETE CASCADE,
            character_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            ja TEXT,
            zh TEXT,
            position INTEGER NOT NULL DEFAULT 0,
            reveal_at TEXT NOT NULL
        );
        CREATE INDEX moment_reactions_by_post
            ON moment_reactions(post_id, reveal_at);
        CREATE TABLE moment_likes (
            post_id TEXT PRIMARY KEY REFERENCES moment_posts(id) ON DELETE CASCADE,
            created_at TEXT NOT NULL
        );
        CREATE TABLE moment_comments (
            post_id TEXT PRIMARY KEY REFERENCES moment_posts(id) ON DELETE CASCADE,
            text TEXT NOT NULL,
            created_at TEXT NOT NULL,
            reply_reveal_at TEXT,
            reply_ja TEXT,
            reply_zh TEXT,
            reply_at TEXT
        );
        CREATE TABLE moment_plans (
            id TEXT PRIMARY KEY,
            character_id TEXT NOT NULL,
            plan_day TEXT NOT NULL,
            due_at TEXT NOT NULL,
            kind TEXT NOT NULL,
            birthday INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
        );
        CREATE INDEX moment_plans_by_due ON moment_plans(due_at);
        CREATE TABLE moment_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            last_opened_at TEXT,
            planned_day TEXT
        );

        CREATE TABLE turn_debug_snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT REFERENCES conversations(id) ON DELETE CASCADE,
            character_id TEXT NOT NULL,
            user_message_id TEXT,
            reply_message_id TEXT,
            status TEXT NOT NULL,
            created_at TEXT NOT NULL,
            payload TEXT NOT NULL
        );
        CREATE INDEX turn_debug_snapshots_by_conversation
            ON turn_debug_snapshots(conversation_id, id);
        CREATE INDEX turn_debug_snapshots_by_reply
            ON turn_debug_snapshots(reply_message_id);
        CREATE INDEX turn_debug_snapshots_by_character
            ON turn_debug_snapshots(character_id, status, id);
        """
}
