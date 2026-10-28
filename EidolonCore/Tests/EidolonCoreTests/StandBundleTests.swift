import Foundation
import XCTest
@testable import EidolonCore

/// Builds small stand bundles for the stand-package tests: four cards, everyday and stage
/// outfits, the character map and file records the installer validates.
enum StandFixture {
    static func makeBundle(
        in parent: URL,
        cards: Int = 4,
        corruptCRC: Bool = false
    ) throws -> URL {
        let staging = parent.appendingPathComponent(
            "stand-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var files: [String: Data] = [:]
        var cardValues: [JSONValue] = []
        for index in 0..<cards {
            let number = "10300100\(index + 1)0"
            let everyday = "stand/\(number)"
            let stage = "stand_costume/\(number)"
            for outfit in [everyday, stage] {
                for name in ["data.json", "data.atlas", "data.png"] {
                    files["idols/\(outfit)/\(name)"] = Data("\(outfit)/\(name)".utf8)
                }
            }
            cardValues.append(
                .object([
                    "id": .string(number),
                    "name": .string("衣装 \(index + 1)"),
                    "type": .string("P_SR"),
                    "everyday": .object([
                        "id": .string(everyday),
                        "url": .string("../idols/\(everyday)/"),
                        "thumbnail": .null,
                    ]),
                    "stage": .object([
                        "id": .string(stage),
                        "url": .string("../idols/\(stage)/"),
                        "thumbnail": .null,
                    ]),
                ])
            )
        }
        let list: [String: JSONValue] = [
            "idol_id": .int(1),
            "cards": .array(cardValues),
        ]
        files["outfits/1.json"] = try JSONEncoder().encode(list)

        let defaultID = "stand/1030010010"
        let config = StandConfig(
            defaultOutfitID: defaultID,
            defaultOutfitPath: "idols/\(defaultID)/",
            outfitListPath: "outfits/1.json"
        )
        var records: [String: StandManifest.FileRecord] = [:]
        for (path, data) in files {
            var crc = CRC32.hex(data)
            if corruptCRC, path.hasSuffix("data.png") {
                crc = "deadbeef"
            }
            records[path] = StandManifest.FileRecord(size: data.count, crc32: crc)
        }
        let manifest = StandManifest(
            mode: .full,
            createdAt: "2026-10-28T00:00:00Z",
            characters: [StandManifest.Character(id: "mano", stand: config)],
            files: records
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: staging.appendingPathComponent("manifest.json"))

        for (path, data) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return try Fixture.zip(
            staging,
            to: parent.appendingPathComponent("stand-\(UUID().uuidString).eidolonpkg")
        )
    }
}

final class StandBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonStandBundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon(includeStand: Bool = false) async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.includeStand = includeStand
        try await eidolon.install(bundleAt: Fixture.makeBundle(in: root, options: options))
        return eidolon
    }

    func testAStandBundleAddsEveryCardToAStoryBundle() async throws {
        let eidolon = try await installedEidolon()
        let before = await eidolon.stand(for: "mano")
        XCTAssertNil(before)

        let info = try await eidolon.installStand(bundleAt: StandFixture.makeBundle(in: root))
        XCTAssertEqual(info.characterCount, 1)
        XCTAssertEqual(info.outfitCount, 8)

        let foundOptional = await eidolon.stand(for: "mano")
        let found = try XCTUnwrap(foundOptional)
        XCTAssertEqual(found.defaultOutfit.id, "stand/1030010010")
        XCTAssertEqual(found.outfitList?.cards.count, 4)
        XCTAssertEqual(found.outfitList?.cards.last?.name, "衣装 4")
        let other = await eidolon.stand(for: "hiori")
        XCTAssertNil(other)
    }

    func testStandPackageIsPreferredOverLegacyAndSurvivesABadImport() async throws {
        let eidolon = try await installedEidolon(includeStand: true)
        let legacyOptional = await eidolon.stand(for: "mano")
        let legacy = try XCTUnwrap(legacyOptional)
        XCTAssertEqual(legacy.outfitList?.cards.count, 2)

        try await eidolon.installStand(bundleAt: StandFixture.makeBundle(in: root))
        let separatedOptional = await eidolon.stand(for: "mano")
        let separated = try XCTUnwrap(separatedOptional)
        XCTAssertEqual(separated.outfitList?.cards.count, 4)

        let bad = try StandFixture.makeBundle(in: root, corruptCRC: true)
        do {
            try await eidolon.installStand(bundleAt: bad)
            XCTFail("a bad stand bundle must not install")
        } catch {}

        let keptOptional = await eidolon.stand(for: "mano")
        let kept = try XCTUnwrap(keptOptional)
        XCTAssertEqual(kept.outfitList?.cards.count, 4)
        let standInfo = try await eidolon.installedStandInfo()
        XCTAssertEqual(standInfo?.outfitCount, 8)
    }

    func testStoryBundleWithoutStandStillInstallsAndChats() async throws {
        let eidolon = try await installedEidolon()
        let installed = try await eidolon.installedContentInfo()
        let info = try XCTUnwrap(installed)
        XCTAssertEqual(info.standOutfitCount, 0)
        let characters = try await eidolon.characters()
        XCTAssertEqual(characters.count, 2)
    }
}
