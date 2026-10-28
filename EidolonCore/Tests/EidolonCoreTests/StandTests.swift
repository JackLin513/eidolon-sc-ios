import Foundation
import XCTest
@testable import EidolonCore

final class StandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCoreStand-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon(_ change: (inout Fixture.Options) -> Void = { _ in }) async throws -> Eidolon {
        var options = Fixture.Options()
        options.includeStand = true
        change(&options)
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: Fixture.makeBundle(in: root, options: options))
        return eidolon
    }

    // MARK: - Reading her stand

    func testReadsDefaultOutfitAndOutfitList() async throws {
        let eidolon = try await installedEidolon()
        let found = await eidolon.stand(for: "mano")
        let stand = try XCTUnwrap(found)

        let content = eidolon.location.contentDirectory
        XCTAssertEqual(stand.defaultOutfit.id, "stand/1030010010")
        XCTAssertEqual(
            stand.defaultOutfit.directory.standardizedFileURL.path,
            content.appendingPathComponent("stand/idols/stand/1030010010").standardizedFileURL.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: stand.defaultOutfit.directory.appendingPathComponent("data.json").path
            )
        )

        let list = try XCTUnwrap(stand.outfitList)
        XCTAssertEqual(list.idolID, 1)
        XCTAssertEqual(list.cards.map(\.id), ["1030010010", "1030010020"])
        XCTAssertEqual(list.cards[0].name, "ナチュラルモード")
        XCTAssertEqual(list.cards[0].type, "P_SR")
        XCTAssertNil(list.cards[1].stage)

        let everyday = try XCTUnwrap(list.cards[0].everyday)
        XCTAssertEqual(everyday.id, "stand/1030010010")
        XCTAssertEqual(
            everyday.directory.standardizedFileURL.path,
            content.appendingPathComponent("stand/idols/stand/1030010010").standardizedFileURL.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: everyday.directory.appendingPathComponent("data.png").path
            )
        )
        XCTAssertEqual(list.cards[0].stage?.id, "stand_costume/1030010010")
    }

    func testOutfitWhoseFilesAreMissingIsLeftOut() async throws {
        let eidolon = try await installedEidolon { $0.missingStandOutfitFiles = true }
        let found = await eidolon.stand(for: "mano")
        let stand = try XCTUnwrap(found)
        let list = try XCTUnwrap(stand.outfitList)

        XCTAssertNotNil(list.cards[0].everyday)
        XCTAssertNotNil(list.cards[0].stage)
        XCTAssertNil(list.cards[1].everyday)
        XCTAssertNil(list.cards[1].stage)
    }

    /// A card that cannot be read is left out; the cards after it are still listed
    /// (upstream `readOutfitList`). One bad card must not cost her the whole picker.
    func testACardThatCannotBeReadIsSkippedAndTheOthersKept() throws {
        let json = """
        {
          "idol_id": 1,
          "cards": [
            {"name": "没有编号", "type": "P_SR"},
            "not a card",
            {"id": "1030010010", "name": "ナチュラルモード", "type": "P_SR"},
            {"id": "1030010020", "name": "ぐうぜんBOOKS"}
          ]
        }
        """
        let list = try XCTUnwrap(
            OutfitList(
                data: Data(json.utf8),
                at: root.appendingPathComponent("stand/outfits/1.json")
            )
        )

        XCTAssertEqual(list.idolID, 1)
        XCTAssertEqual(list.cards.map(\.id), ["1030010010"])
    }

    func testUnreadableOutfitListMeansNoList() async throws {
        let eidolon = try await installedEidolon { $0.unreadableOutfitList = true }
        let found = await eidolon.stand(for: "mano")
        let stand = try XCTUnwrap(found)

        XCTAssertEqual(stand.defaultOutfit.id, "stand/1030010010")
        XCTAssertNil(stand.outfitList)
    }

    func testCharacterWithoutStandHasNone() async throws {
        let eidolon = try await installedEidolon()
        let hiori = await eidolon.stand(for: "hiori")
        XCTAssertNil(hiori)
    }

    /// The lookup can be pointed at more than one root, so a separate stand package can
    /// be tried before the legacy content bundle. Nothing is found under a missing root;
    /// the next one is used.
    func testStandResolverTriesRootsInOrder() async throws {
        let eidolon = try await installedEidolon()
        let characters = try await eidolon.characters()
        let character = try XCTUnwrap(characters.first { $0.id == "mano" })
        let config = try XCTUnwrap(character.stand)
        let missing = root.appendingPathComponent("missing", isDirectory: true)

        let found = StandResolver(
            roots: [missing, eidolon.location.contentDirectory]
        ).stand(for: config)

        XCTAssertEqual(found?.defaultOutfit.id, "stand/1030010010")
        XCTAssertEqual(found?.outfitList?.cards.count, 2)
    }

    // MARK: - Installation

    func testBundleWithStandCountKeyInstallsAndCountsOutfits() async throws {
        let eidolon = try await installedEidolon()
        let info = try await eidolon.installedContentInfo()
        XCTAssertEqual(info?.standOutfitCount, 3)
    }

    func testOldBundleWithoutStandStillInstalls() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: Fixture.makeBundle(in: root))

        let info = try await eidolon.installedContentInfo()
        XCTAssertEqual(info?.standOutfitCount, 0)
        let mano = await eidolon.stand(for: "mano")
        XCTAssertNil(mano)
    }
}
