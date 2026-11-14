import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// The user library's schema (ADR-0002, ADR-0037).
final class UserSchemaTests: XCTestCase {
    func testAFreshLibraryIsCreatedAtV25() throws {
        let queue = try DatabaseQueue()
        try UserSchema.migrate(queue)

        let version = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(version, UserSchema.version)

        let tables = try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }
        for expected in [
            "conversations", "conversation_participants", "messages",
            "current_conversations", "memories", "turn_debug_snapshots",
        ] {
            XCTAssertTrue(tables.contains(expected), "missing table \(expected)")
        }
        XCTAssertFalse(tables.contains("grdb_migrations"))
    }

    func testMigratingAFreshLibraryTwiceIsANoOp() throws {
        let queue = try DatabaseQueue()
        try UserSchema.migrate(queue)
        try UserSchema.migrate(queue)
        let version = try queue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        XCTAssertEqual(version, UserSchema.version)
    }

    func testOpeningALegacyLibraryBacksItUpAndStartsClean() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eidolon-v25-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let location = Eidolon.Location(root: root)
        try FileManager.default.createDirectory(
            at: location.userDirectory,
            withIntermediateDirectories: true
        )

        let legacy = try DatabaseQueue(path: location.userDatabase.path)
        try legacy.write { db in
            try db.execute(sql: "CREATE TABLE legacy_marker (id INTEGER PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO legacy_marker DEFAULT VALUES")
            try db.execute(sql: "PRAGMA user_version = 24")
        }
        try legacy.close()

        _ = try Eidolon(location: location)

        let fresh = try DatabaseQueue(path: location.userDatabase.path)
        let version = try fresh.read { db in
            try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
        let legacyTable = try fresh.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'legacy_marker'"
            ) ?? 0
        }
        XCTAssertEqual(version, UserSchema.version)
        XCTAssertEqual(legacyTable, 0)

        let files = try FileManager.default.contentsOfDirectory(
            atPath: location.userDirectory.path
        )
        XCTAssertTrue(
            files.contains { $0.contains("eidolon.sqlite.bak-") },
            "legacy library should have been backed up: \(files)"
        )
        try fresh.close()
    }
}
