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

        XCTAssertEqual(info.formatVersion, ContentManifest.supportedFormatVersion)
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
        XCTAssertEqual(characters.first?.birthday, Birthday(month: 4, day: 25))
        XCTAssertEqual(characters.first?.idolID, 1)
        XCTAssertEqual(characters.last?.birthday, Birthday(month: 3, day: 4))

        let holidays = try await eidolon.holidayTable()
        XCTAssertEqual(holidays.name(year: 2026, month: 1, day: 1), "元日")
        XCTAssertNil(holidays.name(year: 2026, month: 1, day: 2))

        let manoPassages = try await eidolon.episodeCount(characterID: "mano")
        XCTAssertEqual(manoPassages, 2)
    }

    // MARK: - Installed bundle versions

    /// A bundle installed by an older app is kept but not read: the app asks for a new
    /// import instead of running on a format it does not fully understand.
    func testABundleFromAnotherFormatIsNotUsed() async throws {
        let eidolon = try makeEidolon()
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        try await rewriteInstalledInfo(on: eidolon) { info in
            info.formatVersion = ContentManifest.supportedFormatVersion - 1
        }

        let needsBundle = try await eidolon.needsContentBundle()
        let usable = try await eidolon.usableContentInfo()
        XCTAssertTrue(needsBundle, "an old bundle asks to be imported again")
        XCTAssertNil(usable)
        let kept = try await eidolon.installedContentInfo()
        XCTAssertEqual(kept?.formatVersion, ContentManifest.supportedFormatVersion - 1)
        do {
            _ = try await eidolon.characters()
            XCTFail("an old bundle's characters are not read")
        } catch {
            XCTAssertEqual(error as? EidolonError, .contentNotInstalled)
        }
    }

    func testABundleFromAnotherContentSchemaIsNotUsed() async throws {
        let eidolon = try makeEidolon()
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        try await rewriteInstalledInfo(on: eidolon) { info in
            info.contentSchemaVersion = ContentSchema.version - 1
        }

        let needsBundle = try await eidolon.needsContentBundle()
        let usable = try await eidolon.usableContentInfo()
        XCTAssertTrue(needsBundle)
        XCTAssertNil(usable)
    }

    func testTheInstalledBundlesVersionsAreTheOnesThisBuildReads() async throws {
        let eidolon = try makeEidolon()
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        let needsBundle = try await eidolon.needsContentBundle()
        let info = try await eidolon.usableContentInfo()
        XCTAssertFalse(needsBundle)
        XCTAssertEqual(info?.formatVersion, ContentManifest.supportedFormatVersion)
        XCTAssertEqual(info?.contentSchemaVersion, ContentSchema.version)
    }

    /// Rewrites the installed record as an older app would have left it.
    private func rewriteInstalledInfo(
        on eidolon: Eidolon,
        _ change: (inout ContentBundleInfo) -> Void
    ) async throws {
        let stored: String? = try await eidolon.userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'content.bundle'")
        }
        var info = try JSONDecoder().decode(
            ContentBundleInfo.self,
            from: Data(try XCTUnwrap(stored).utf8)
        )
        change(&info)
        let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "UPDATE app_state SET value = ? WHERE key = 'content.bundle'",
                arguments: [encoded]
            )
        }
    }

    // MARK: - Birthdays

    func testDecodesFebruary29Birthday() throws {
        let character = try CharacterConfig(json: .object([
            "id": .string("leap"),
            "name": .string("うるう"),
            "birthday": .string("02-29"),
        ]))
        XCTAssertEqual(character.birthday, Birthday(month: 2, day: 29))
        XCTAssertEqual(character.birthday?.text, "02-29")
    }

    func testRejectsMalformedBirthdayNamingTheCharacter() throws {
        XCTAssertThrowsError(try CharacterConfig(json: .object([
            "id": .string("mano"),
            "name": .string("櫻木真乃"),
            "birthday": .string("02-30"),
        ]))) { error in
            XCTAssertEqual(
                error as? EidolonError,
                .invalidContent("角色 mano 的生日应为 MM-DD 格式、一年中有的一天（例如 \"04-25\"），现在是 \"02-30\"")
            )
        }
        XCTAssertThrowsError(try CharacterConfig(json: .object([
            "id": .string("mano"),
            "name": .string("櫻木真乃"),
        ])))
    }

    // MARK: - Rejections

    func testRejectsUnsupportedFormatVersion() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.formatVersion = ContentManifest.supportedFormatVersion + 1
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .unsupportedVersion = eidolonError
            else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
        }
    }

    func testRejectsOldBundleAndAsksToReExport() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.formatVersion = 1
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .unsupportedVersion(let reason) = eidolonError
            else {
                return XCTFail("expected unsupportedVersion, got \(error)")
            }
            XCTAssertTrue(reason.contains("重新导出"), reason)
        }
    }

    func testRejectsBundleWithoutHolidays() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.includeHolidays = false
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidBundle(let reason) = eidolonError
            else {
                return XCTFail("expected invalidBundle, got \(error)")
            }
            XCTAssertTrue(reason.contains("节假日"), reason)
        }
    }

    /// The world setting is read at install, so a bundle whose `world.json` cannot be
    /// parsed is refused then rather than failing every turn afterwards.
    func testRejectsUnparseableWorldSetting() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.world = .broken
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidBundle(let reason) = eidolonError
            else {
                return XCTFail("expected invalidBundle, got \(error)")
            }
            XCTAssertTrue(reason.contains("world.json"), reason)
        }
    }

    func testInstallsWhenTheWorldSettingParses() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.world = .valid
        let bundle = try Fixture.makeBundle(in: root, options: options)

        let info = try await eidolon.install(bundleAt: bundle)
        XCTAssertEqual(info.characterCount, 2)
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

    func testRejectsCorruptedStandFile() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.includeStand = true
        options.corruptStandCRC = true
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidBundle(let reason) = eidolonError
            else {
                return XCTFail("expected invalidBundle, got \(error)")
            }
            XCTAssertTrue(reason.contains("stand/"), reason)
        }
    }

    func testRejectsWrongDatabaseTableCount() async throws {
        let eidolon = try makeEidolon()
        var options = Fixture.Options()
        options.extraContentCounts = ["episodes": 99]
        let bundle = try Fixture.makeBundle(in: root, options: options)

        await assertThrows(eidolon, bundle) { error in
            guard let eidolonError = error as? EidolonError,
                  case .invalidContent(let reason) = eidolonError
            else {
                return XCTFail("expected invalidContent, got \(error)")
            }
            XCTAssertTrue(reason.contains("episodes"), reason)
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
        bad.formatVersion = 1
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

