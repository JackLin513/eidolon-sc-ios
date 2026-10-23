import Foundation
import GRDB
import XCTest
@testable import EidolonCore

final class ContentBundleImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEidolon() throws -> Eidolon {
        try Eidolon(location: .init(root: root.appendingPathComponent("app", isDirectory: true)))
    }

    // MARK: - Happy path

    func testInstallsValidBundle() async throws {
        let eidolon = try makeEidolon()
        let needsBundleBeforeInstall = try await eidolon.needsContentBundle()
        XCTAssertTrue(needsBundleBeforeInstall)

        let bundle = try Fixture.makeBundle(in: root)
        let info = try await eidolon.install(bundleAt: bundle)

        XCTAssertEqual(info.formatVersion, 1)
        XCTAssertEqual(info.contentSchemaVersion, ContentSchema.version)
        XCTAssertEqual(info.embeddingModel, "test-embed")
        XCTAssertEqual(info.embeddingDimensions, 4)
        XCTAssertEqual(info.episodeCount, 2)
        XCTAssertEqual(info.passageCount, 3)
        XCTAssertEqual(info.characterCount, 2)

        let needsBundleAfterInstall = try await eidolon.needsContentBundle()
        XCTAssertFalse(needsBundleAfterInstall)
        let installed = try await eidolon.installedContentInfo()
        XCTAssertEqual(installed?.episodeCount, 2)

        let characters = try await eidolon.characters()
        XCTAssertEqual(characters.map(\.id), ["mano", "hiori"])
        XCTAssertEqual(characters.first?.sheet, "characters/sheets/mano.md")
        XCTAssertEqual(characters.first?.speakers, ["真乃"])

        let manoPassages = try await eidolon.episodeCount(characterID: "mano")
        XCTAssertEqual(manoPassages, 2)
    }

    // MARK: - Rejections

    func testRejectsUnsupportedFormatVersion() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.formatVersion = 2
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .unsupportedVersion = eidolonError
            else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testRejectsMissingVectors() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.embedPassages = false
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidContent = eidolonError
            else {
                return XCTFail("expected invalidContent, got \(error)")
            }
        }
    }

    func testRejectsEmbeddingModelMismatch() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.manifestModel = "another-embed"
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidContent = eidolonError
            else {
                return XCTFail("expected invalidContent, got \(error)")
            }
        }
    }

    func testRejectsCorruptedFile() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.corruptCRC = true
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidBundle = eidolonError
            else {
                return XCTFail("expected invalidBundle, got \(error)")
            }
        }
    }

    func testRejectsUnreadableArchive() async throws {
        let eidolon = try makeEidolon()
        let fake = root.appendingPathComponent("not-a-bundle.eidolonpkg")
        try "hello".write(to: fake, atomically: true, encoding: .utf8)

        await assertThrows(eidolon, fake) { error in
            guard let eidolonError = error as? EidolonError,
                  case .unreadableBundle = eidolonError
            else {
                return XCTFail("expected unreadableBundle, got \(error)")
            }
        }
    }

    // MARK: - Previous bundle and user data

    func testFailedImportKeepsPreviousBundle() async throws {
        let eidolon = try makeEidolon()
        let good = try Fixture.makeBundle(in: root)
        try await eidolon.install(bundleAt: good)

        var bad = Fixture.Options()
        bad.formatVersion = 2
        let badBundle = try Fixture.makeBundle(in: root, options: bad)
        await assertThrows(eidolon, badBundle) { _ in }

        let info = try await eidolon.installedContentInfo()
        XCTAssertEqual(info?.episodeCount, 2)
        let characters = try await eidolon.characters()
        XCTAssertEqual(characters.count, 2)
    }

    func testInstallLeavesUserDataAlone() async throws {
        let eidolon = try makeEidolon()
        let userDatabase = root.appendingPathComponent("app/User/eidolon.sqlite")

        let queue = try DatabaseQueue(path: userDatabase.path)
        let before: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations")
        }
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations(id, character_id, created_at)
                    VALUES ('c1', 'mano', '2026-10-01T00:00:00Z')
                    """
            )
        }

        let bundle = try Fixture.makeBundle(in: root)
        try await eidolon.install(bundleAt: bundle)

        let after: Int? = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations")
        }
        XCTAssertEqual(before, 0)
        XCTAssertEqual(after, 1)
    }

    // MARK: - Helper

    private func assertThrows(
        _ eidolon: Eidolon,
        _ bundle: URL,
        _ check: (Error) -> Void
    ) async {
        do {
            _ = try await eidolon.install(bundleAt: bundle)
            XCTFail("expected import to fail")
        } catch {
            check(error)
        }
    }
}

