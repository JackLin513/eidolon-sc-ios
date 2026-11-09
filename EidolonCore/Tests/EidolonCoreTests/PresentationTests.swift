import XCTest
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
