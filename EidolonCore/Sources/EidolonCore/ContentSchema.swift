import Foundation

/// The read-only content library's schema (ADR-0002). It mirrors the upstream
/// story tables; the exporter copies rows into this shape and stamps
/// `PRAGMA user_version` with the schema version.
public enum ContentSchema {
    public static let version = 1

    public static let ddl = """
        CREATE TABLE episodes (
            id TEXT PRIMARY KEY,
            category TEXT NOT NULL,
            source TEXT NOT NULL,
            title TEXT NOT NULL,
            imported_from TEXT NOT NULL DEFAULT 'csv',
            imported_at TEXT NOT NULL
        );
        CREATE TABLE episode_cast (
            episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
            character_id TEXT NOT NULL,
            PRIMARY KEY (episode_id, character_id)
        );
        CREATE INDEX episode_cast_by_character ON episode_cast(character_id);
        CREATE TABLE episode_lines (
            episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            speaker TEXT,
            ja TEXT NOT NULL,
            zh TEXT,
            PRIMARY KEY (episode_id, seq)
        );
        CREATE TABLE episode_passages (
            episode_id TEXT NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
            seq INTEGER NOT NULL,
            text TEXT NOT NULL,
            model TEXT NOT NULL,
            embedding BLOB NOT NULL,
            PRIMARY KEY (episode_id, seq)
        );
        """
}
