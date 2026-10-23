import Foundation
import GRDB
import XCTest
@testable import EidolonCore

final class CharacterListTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCoreList-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let bundle = try Fixture.makeBundle(in: root)
        try await eidolon.install(bundleAt: bundle)
        return eidolon
    }

    // MARK: - Search

    func testSearchMatchesEveryNameSheCanBeFoundBy() async throws {
        let eidolon = try await installedEidolon()
        let characters = try await eidolon.characters()
        let mano = try XCTUnwrap(characters.first { $0.id == "mano" })

        XCTAssertTrue(mano.matches("樱木"))
        XCTAssertTrue(mano.matches("さくらぎ"))
        XCTAssertTrue(mano.matches("sakuragi"))
        XCTAssertTrue(mano.matches("Sakuragi Mano"))
        XCTAssertTrue(mano.matches("illumination"))
        XCTAssertTrue(mano.matches("  "))
        XCTAssertFalse(mano.matches("灯織"))

        XCTAssertEqual(mano.subtitle, "樱木真乃")
        let hiori = try XCTUnwrap(characters.first { $0.id == "hiori" })
        XCTAssertEqual(hiori.subtitle, "")
    }

    // MARK: - Avatars

    func testAvatarURLOnlyExistsWhenTheBundleHasIt() async throws {
        let eidolon = try await installedEidolon()
        let manoAvatar = await eidolon.avatarURL(for: "mano")
        XCTAssertNotNil(manoAvatar)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manoAvatar?.path ?? ""))

        let hioriAvatar = await eidolon.avatarURL(for: "hiori")
        XCTAssertNil(hioriAvatar)
    }

    // MARK: - Latest activity

    func testLatestActivityIsEmptyBeforeAnyConversation() async throws {
        let eidolon = try await installedEidolon()
        let activities = try await eidolon.latestActivities()
        XCTAssertTrue(activities.isEmpty)
    }

    func testLatestActivityShowsLatestMessageAndUnseenReachOut() async throws {
        let eidolon = try await installedEidolon()
        let userDatabase = root.appendingPathComponent("app/User/eidolon.sqlite")
        let queue = try DatabaseQueue(path: userDatabase.path)

        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations(id, character_id, created_at)
                    VALUES ('c1', 'mano', '2026-10-01T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, ja, zh, created_at)
                    VALUES ('m1', 'c1', 'user', 'こんばんは', 'こんばんは', '晚上好', '2026-10-01T00:00:01Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, ja, zh, created_at)
                    VALUES ('m2', 'c1', 'character', NULL, 'おはよう', '', '2026-10-02T00:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO reach_outs(id, conversation_id, ja, zh, seen, created_at)
                    VALUES ('r1', 'c1', 'ねえ', '喂', 0, '2026-10-03T00:00:00Z')
                    """
            )
        }

        let activities = try await eidolon.latestActivities()
        let mano = try XCTUnwrap(activities["mano"])
        // The reach-out is the latest thing said, so it is the preview.
        XCTAssertEqual(mano.lastMessageRole, "character")
        XCTAssertEqual(mano.lastMessagePreview, "喂")
        XCTAssertTrue(mano.unseenReachOut)

        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES ('m3', 'c1', 'user', 'まだ起きてる？', '2026-10-04T00:00:00Z')
                    """
            )
        }
        let after = try await eidolon.latestActivities()
        let later = try XCTUnwrap(after["mano"])
        XCTAssertEqual(later.lastMessagePreview, "まだ起きてる？")
        XCTAssertEqual(later.lastMessageRole, "user")
        XCTAssertTrue(later.unseenReachOut)
    }
}
