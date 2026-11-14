import XCTest
import ZIPFoundation
@testable import EidolonCore

final class PresentationTests: XCTestCase {
    func testRuntimeIDRoundTripsAsAPlainString() throws {
        let data = try JSONEncoder().encode(RuntimeID.unityUaaL)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"unity-uaal\"")
        XCTAssertEqual(try JSONDecoder().decode(RuntimeID.self, from: data), .unityUaaL)
    }

    func testResolverPrefersTheRequirementThenWalksFallbacks() {
        let requirement = RuntimeRequirement(
            preferred: .unityUaaL,
            fallbacks: [.spineWebGL, .avatar]
        )
        XCTAssertEqual(RuntimeResolver.order(requirement), [.unityUaaL, .spineWebGL, .avatar])
        XCTAssertEqual(
            RuntimeResolver.resolve(requirement, available: [.spineWebGL, .avatar]),
            .spineWebGL
        )
        XCTAssertEqual(
            RuntimeResolver.resolve(requirement, available: [.avatar]),
            .avatar
        )
        XCTAssertNil(RuntimeResolver.resolve(requirement, available: []))
    }

    func testResolverDoesNotRepeatAPreferredFallback() {
        let requirement = RuntimeRequirement(
            preferred: .spineWebGL,
            fallbacks: [.spineWebGL, .avatar]
        )
        XCTAssertEqual(RuntimeResolver.order(requirement), [.spineWebGL, .avatar])
    }

    func testPresentationFrameCarriesTheDirectionAndEncodes() throws {
        let frame = PresentationFrame(
            StandDirection(
                mood: .shy,
                speaking: true,
                looking: true,
                nod: StandNod(kind: .yes, id: 7)
            ),
            framing: .knees,
            reducedMotion: true
        )
        XCTAssertEqual(frame.emotion, .shy)
        XCTAssertEqual(frame.nod?.kind, .yes)
        XCTAssertEqual(frame.framing, .knees)
        XCTAssertTrue(frame.reducedMotion)

        let data = try JSONEncoder().encode(frame)
        XCTAssertEqual(try JSONDecoder().decode(PresentationFrame.self, from: data), frame)
    }

    func testSpineCapabilitiesAreLowerStageAndSnapshottable() {
        let capabilities = RuntimeCapabilities.spine2D
        XCTAssertFalse(capabilities.fullBleed)
        XCTAssertTrue(capabilities.snapshot)
        XCTAssertTrue(capabilities.outfitSwitch)
        XCTAssertEqual(capabilities.expressions, Set(StandEmotion.allCases))
        XCTAssertEqual(capabilities.framings, Set(StandFraming.allCases))
    }

    func testUnityCapabilitiesAreFullBleed() {
        XCTAssertTrue(RuntimeCapabilities.unity3D.fullBleed)
    }

    func testPackageHeaderDecodesWithAnOmittedFranchiseAsShiny() throws {
        let json = """
        {"formatVersion": 1, "kind": "model3d"}
        """
        let header = try JSONDecoder().decode(PackageHeader.self, from: Data(json.utf8))
        XCTAssertEqual(header.kind, .model3d)
        XCTAssertNil(header.franchise)
        XCTAssertEqual(header.resolvedFranchise, "shiny")
    }

    func testPackageHeaderDecodesAModel3DRequirement() throws {
        let json = """
        {
          "formatVersion": 1,
          "kind": "model3d",
          "franchise": "mltd",
          "runtime": {
            "preferred": "unity-uaal",
            "engineVersion": "unity/6000.3",
            "fallbacks": ["spine-webgl", "avatar"]
          }
        }
        """
        let header = try JSONDecoder().decode(PackageHeader.self, from: Data(json.utf8))
        XCTAssertEqual(header.franchise, "mltd")
        XCTAssertEqual(header.runtime?.preferred, .unityUaaL)
        XCTAssertEqual(header.runtime?.engineVersion, "unity/6000.3")
    }

    func testModel3DPackagesAreScopedByFranchise() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "eidolon-model3d-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let installer = Model3DBundleInstaller(contentRoot: root, fileManager: .default)
        XCTAssertEqual(
            installer.directory("shiny").path,
            root.appending(path: "shiny/model3d").path
        )
        XCTAssertEqual(
            installer.directory("totsulover").path,
            root.appending(path: "totsulover/model3d").path
        )
        XCTAssertEqual(
            installer.previousDirectory("totsulover").path,
            root.appending(path: "totsulover/model3d-previous").path
        )
        XCTAssertNotEqual(installer.directory("shiny"), installer.directory("totsulover"))
    }

    private func makeModel3DPackage(
        in parent: URL,
        franchise: String,
        localID: String
    ) throws -> URL {
        let staging = parent.appending(path: "model3d-\(franchise)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let manifest = Model3DManifest(
            franchise: franchise,
            files: [],
            characters: [
                Model3DCharacter(localID: localID, model: "\(localID).model", outfits: ["default"])
            ]
        )
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: "manifest.json"))
        let output = parent.appending(path: "\(franchise)-\(UUID().uuidString).model3d")
        let archive = try Archive(url: output, accessMode: .create)
        try archive.addEntry(with: "manifest.json", fileURL: staging.appending(path: "manifest.json"))
        return output
    }

    func testModel3DPackagesKeepTheirOwnFranchiseSlots() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "eidolon-model3d-slots-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let eidolon = try Eidolon(location: .init(root: root))

        let mltd = try makeModel3DPackage(in: root, franchise: "mltd", localID: "haruka")
        let shiny = try makeModel3DPackage(in: root, franchise: "shiny", localID: "mano")
        let mltdInfo = try await eidolon.installModel3D(bundleAt: mltd)
        let shinyInfo = try await eidolon.installModel3D(bundleAt: shiny)
        XCTAssertEqual(mltdInfo.franchise, "mltd")
        XCTAssertEqual(shinyInfo.franchise, "shiny")

        let mltdInstalled = try await eidolon.installedModel3D(franchise: "mltd")
        let shinyInstalled = try await eidolon.installedModel3D(franchise: "shiny")
        XCTAssertEqual(
            mltdInstalled?.directory.path,
            root.appending(path: "Content/mltd/model3d").path
        )
        XCTAssertEqual(
            shinyInstalled?.directory.path,
            root.appending(path: "Content/shiny/model3d").path
        )
        XCTAssertEqual(mltdInstalled?.manifest.characters.map(\.localID), ["haruka"])
        XCTAssertEqual(shinyInstalled?.manifest.characters.map(\.localID), ["mano"])
    }

    func testModel3DManifestValidatesACharacterAndOutfits() throws {
        let manifest = Model3DManifest(
            franchise: "mltd",
            runtime: RuntimeRequirement(
                preferred: .unityUaaL,
                engineVersion: "unity/6000.3",
                fallbacks: [.spineWebGL, .avatar]
            ),
            files: [
                Model3DFile(
                    path: "characters/001har/pr001.bundle",
                    sha256: String(repeating: "a", count: 64),
                    size: 10
                )
            ],
            characters: [
                Model3DCharacter(
                    localID: "001har",
                    model: "chr_001har",
                    outfits: ["pr001", "ss003"],
                    emotionMap: ["calm": "通常", "happy": "微笑み"]
                )
            ]
        )
        XCTAssertNoThrow(try manifest.validate(expectedEngineVersion: "unity/6000.3"))
        XCTAssertEqual(manifest.character(localID: "001har")?.model, "chr_001har")
        XCTAssertEqual(
            manifest.character(localID: "001har")?.nativeFace(for: .happy),
            "微笑み"
        )
    }

    func testModel3DManifestRejectsAnUnsafePath() {
        let manifest = Model3DManifest(
            franchise: "mltd",
            files: [Model3DFile(path: "../escape", sha256: String(repeating: "a", count: 64), size: 1)],
            characters: [Model3DCharacter(localID: "001har", model: "m", outfits: ["pr001"])]
        )
        XCTAssertThrowsError(try manifest.validate())
    }

    func testModel3DManifestRejectsAnEngineVersionMismatch() {
        let manifest = Model3DManifest(
            franchise: "mltd",
            runtime: RuntimeRequirement(
                preferred: .unityUaaL,
                engineVersion: "unity/2022.3",
                fallbacks: [.spineWebGL]
            ),
            files: [],
            characters: [Model3DCharacter(localID: "001har", model: "m", outfits: ["pr001"])]
        )
        XCTAssertThrowsError(try manifest.validate(expectedEngineVersion: "unity/6000.3"))
    }

    func testModel3DManifestExposesTheCommonPackageHeader() {
        let manifest = Model3DManifest(
            franchise: "mltd",
            files: [],
            characters: [Model3DCharacter(localID: "001har", model: "m", outfits: ["pr001"])]
        )
        XCTAssertEqual(manifest.header.kind, .model3d)
        XCTAssertEqual(manifest.header.franchise, "mltd")
        XCTAssertEqual(manifest.header.runtime?.preferred, .unityUaaL)
    }

    func testModel3DManifestRejectsAMissingEngineVersionWhenOneIsRequired() {
        let manifest = Model3DManifest(
            franchise: "mltd",
            runtime: RuntimeRequirement(
                preferred: .unityUaaL,
                engineVersion: nil,
                fallbacks: [.spineWebGL]
            ),
            files: [],
            characters: [Model3DCharacter(localID: "001har", model: "m", outfits: ["pr001"])]
        )
        XCTAssertThrowsError(try manifest.validate(expectedEngineVersion: "unity/6000.3"))
    }

    func testModel3DManifestRejectsDuplicateCharacters() {
        let manifest = Model3DManifest(
            franchise: "mltd",
            files: [],
            characters: [
                Model3DCharacter(localID: "001har", model: "m1", outfits: ["pr001"]),
                Model3DCharacter(localID: "001har", model: "m2", outfits: ["pr001"]),
            ]
        )
        XCTAssertThrowsError(try manifest.validate())
    }

    func testContentManifestReadsAnOldBundleWithoutAFranchise() throws {
        let json = """
        {
          "format_version": 5,
          "content_schema_version": 1,
          "created_at": "2026-01-01T00:00:00Z",
          "embedding": {"model": "m", "dimensions": 3},
          "content": {},
          "characters": {"count": 1, "ids": ["mano"]}
        }
        """
        let manifest = try JSONDecoder().decode(ContentManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.franchise)
    }

    func testContentManifestReadsTheReservedFranchiseField() throws {
        let json = """
        {
          "format_version": 5,
          "kind": "content",
          "franchise": "mltd",
          "content_schema_version": 1,
          "created_at": "2026-01-01T00:00:00Z",
          "embedding": {"model": "m", "dimensions": 3},
          "content": {},
          "characters": {"count": 1, "ids": ["001har"]}
        }
        """
        let manifest = try JSONDecoder().decode(ContentManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.franchise, "mltd")
    }
}
