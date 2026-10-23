import Foundation
import GRDB

/// Read-only access to the installed content library, with the user library
/// attached so later queries can join across the two (ADR-0002).
struct ContentDatabase {
    let queue: DatabaseQueue

    init(contentDirectory: URL, userDatabasePath: URL) throws {
        let path = contentDirectory.appendingPathComponent("content/eidolon.db").path
        var configuration = Configuration()
        configuration.readonly = true
        configuration.prepareDatabase { db in
            try db.execute(
                sql: "ATTACH DATABASE ? AS user",
                arguments: [userDatabasePath.path]
            )
        }
        queue = try DatabaseQueue(path: path, configuration: configuration)
    }

    func counts() throws -> [String: Int] {
        try queue.read { db in
            var counts: [String: Int] = [:]
            for table in ["episodes", "episode_cast", "episode_lines", "episode_passages"] {
                counts[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
            return counts
        }
    }

    func schemaVersion() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
    }

    func integrityCheck() throws -> String {
        try queue.read { db in
            try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
        }
    }

    func embeddingShape() throws -> (models: [String], dimensions: [Int], unembedded: Int) {
        try queue.read { db in
            let models = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT model FROM episode_passages ORDER BY model"
            )
            let dimensions = try Int.fetchAll(
                db,
                sql: "SELECT DISTINCT length(embedding) / 4 FROM episode_passages"
            )
            let unembedded = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM episode_passages
                    WHERE embedding IS NULL OR length(embedding) = 0
                    """
            ) ?? 0
            return (models, dimensions, unembedded)
        }
    }

    func episodeCount(characterID: String) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM episode_passages p
                    JOIN episode_cast c ON c.episode_id = p.episode_id
                    WHERE c.character_id = ?
                    """,
                arguments: [characterID]
            ) ?? 0
        }
    }
}
