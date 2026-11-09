import EidolonCore
import UIKit
import XCTest

@testable import Eidolon

@MainActor
private final class FixtureRuntime: PresentationRuntime {
    let runtimeID: RuntimeID
    let capabilities = RuntimeCapabilities.spine2D
    var isAvailable = true
    var throwsOnMake = false
    private(set) var renderers: [FixtureRenderer] = []

    init(_ id: RuntimeID) {
        runtimeID = id
    }

    func makeRenderer(_ assets: RuntimeAssets) throws -> any CharacterRenderer {
        if throwsOnMake { throw RuntimeFailure.unavailable("fixture") }
        let renderer = FixtureRenderer(runtimeID: runtimeID, assets: assets)
        renderers.append(renderer)
        return renderer
    }

    func setPausedAll(_ paused: Bool) {}
}

@MainActor
private final class FixtureRenderer: CharacterRenderer {
    let runtimeID: RuntimeID
    let view = UIView()
    var onReady: ((RuntimeReport) -> Void)?
    var onFailure: ((RuntimeFailure) -> Void)?
    private(set) var prepared: [RuntimeAssets] = []
    private(set) var frames: [PresentationFrame] = []

    init(runtimeID: RuntimeID, assets: RuntimeAssets) {
        self.runtimeID = runtimeID
    }

    func prepare(_ assets: RuntimeAssets) {
        prepared.append(assets)
    }

    func load(_ outfit: StandOutfit) {}
    func present(_ frame: PresentationFrame) { frames.append(frame) }
    func setPaused(_ paused: Bool) {}
    func setViewport(_ size: CGSize) {}
    func snapshot() async -> UIImage? { nil }
}

@MainActor
final class RuntimeRegistryTests: XCTestCase {
    private func assets(_ framing: StandFraming = .full) -> RuntimeAssets {
        RuntimeAssets(
            contentRoot: URL(fileURLWithPath: "/tmp/model"),
            characterID: "001har",
            outfit: StandOutfit(id: "pr001", directory: URL(fileURLWithPath: "/tmp/pr001")),
            framing: framing
        )
    }

    func testPreferredRuntimeIsChosenWhenAvailable() {
        let unity = FixtureRuntime(.unityUaaL)
        let spine = FixtureRuntime(.spineWebGL)
        let registry = RuntimeRegistry(runtimes: [unity, spine])
        let requirement = RuntimeRequirement(
            preferred: .unityUaaL,
            fallbacks: [.spineWebGL, .avatar]
        )

        XCTAssertEqual(registry.runtime(for: requirement)?.runtimeID, .unityUaaL)
        XCTAssertNotNil(registry.makeRenderer(requirement, assets: assets()))
        XCTAssertEqual(unity.renderers.count, 1)
        XCTAssertTrue(spine.renderers.isEmpty)
    }

    func testFallsBackToSpineWhenThePreferredRuntimeIsUnavailable() {
        let unity = FixtureRuntime(.unityUaaL)
        unity.isAvailable = false
        let spine = FixtureRuntime(.spineWebGL)
        let registry = RuntimeRegistry(runtimes: [unity, spine])
        let requirement = RuntimeRequirement(
            preferred: .unityUaaL,
            fallbacks: [.spineWebGL, .avatar]
        )

        XCTAssertEqual(registry.runtime(for: requirement)?.runtimeID, .spineWebGL)
        XCTAssertEqual(
            registry.makeRenderer(requirement, assets: assets())?.runtimeID,
            .spineWebGL
        )
    }

    func testFallsThroughToSpineWhenThePreferredRuntimeThrows() {
        let unity = FixtureRuntime(.unityUaaL)
        unity.throwsOnMake = true
        let spine = FixtureRuntime(.spineWebGL)
        let registry = RuntimeRegistry(runtimes: [unity, spine])
        let requirement = RuntimeRequirement(
            preferred: .unityUaaL,
            fallbacks: [.spineWebGL, .avatar]
        )

        XCTAssertEqual(
            registry.makeRenderer(requirement, assets: assets())?.runtimeID,
            .spineWebGL
        )
    }

    func testAvoidingUnityPinsTheRestOfTheSessionToSpine() {
        let unity = FixtureRuntime(.unityUaaL)
        let spine = FixtureRuntime(.spineWebGL)
        let registry = RuntimeRegistry(runtimes: [unity, spine])
        let requirement = RuntimeRequirement(
            preferred: .unityUaaL,
            fallbacks: [.spineWebGL, .avatar]
        )

        let renderer = registry.makeRenderer(
            requirement,
            assets: assets(),
            avoiding: [.unityUaaL]
        )
        XCTAssertEqual(renderer?.runtimeID, .spineWebGL)
        XCTAssertTrue(unity.renderers.isEmpty)
    }

    func testAvatarIsTheFinalRuntimeAndProducesNoRenderer() {
        let avatar = FixtureRuntime(.avatar)
        avatar.isAvailable = true
        avatar.throwsOnMake = true
        let spine = FixtureRuntime(.spineWebGL)
        spine.isAvailable = false
        let registry = RuntimeRegistry(runtimes: [avatar, spine])
        let requirement = RuntimeRequirement(
            preferred: .unityUaaL,
            fallbacks: [.spineWebGL, .avatar]
        )

        XCTAssertEqual(registry.runtime(for: requirement)?.runtimeID, .avatar)
        XCTAssertNil(registry.makeRenderer(requirement, assets: assets()))
    }

    func testRuntimeAssetPreparationFillsTheMatchingModelAndRoot() {
        let root = URL(fileURLWithPath: "/tmp/model3d")
        let manifest = Model3DManifest(
            franchise: "mltd",
            files: [],
            characters: [
                Model3DCharacter(localID: "001har", model: "001har", outfits: ["pr001"]),
                Model3DCharacter(localID: "haruka3d", model: "001har", outfits: ["pr001"]),
            ]
        )
        let prepared = RuntimeAssetPreparation.fill(
            assets(),
            manifest: manifest,
            root: root
        )

        XCTAssertEqual(prepared.model3D?.localID, "001har")
        XCTAssertEqual(prepared.model3DRoot, root)
        XCTAssertNil(
            RuntimeAssetPreparation.fill(
                assets(),
                manifest: manifest,
                root: nil
            ).model3D
        )
    }

    func testTheSpineRuntimeIsBundledWhenTheUpstreamCheckoutIsVisible() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            repoRoot.appendingPathComponent("../eidolon-sc"),
            repoRoot.appendingPathComponent("../../eidolon-sc"),
            repoRoot.appendingPathComponent("../../../eidolon-sc"),
            repoRoot.appendingPathComponent("../../../../eidolon-sc"),
        ]
        let upstream = candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(
                    "frontend/public/vendor/spine-3.6/spine-webgl.js"
                ).path
            )
        }
        guard upstream != nil else {
            throw XCTSkip("没有上游 checkout；本次构建不带 Spine 运行时")
        }
        guard let url = Bundle.main.url(forResource: "spine-webgl", withExtension: "js") else {
            return XCTFail("上游 checkout 可见但 App 包缺少 spine-webgl.js")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testTheFiveStandSurfacesAllGetAConfiguredRenderer() {
        let spine = FixtureRuntime(.spineWebGL)
        let registry = RuntimeRegistry(runtimes: [spine])
        let requirement = RuntimeRequirement(
            preferred: .spineWebGL,
            fallbacks: [.avatar]
        )
        let framings: [StandFraming] = [.knees, .waist, .waist, .full, .full]

        for framing in framings {
            XCTAssertNotNil(registry.makeRenderer(requirement, assets: assets(framing)))
        }
        XCTAssertEqual(spine.renderers.count, framings.count)
    }

    func testPreparedRendererReceivesTheSemanticFrame() {
        let spine = FixtureRuntime(.spineWebGL)
        let registry = RuntimeRegistry(runtimes: [spine])
        let requirement = RuntimeRequirement(preferred: .spineWebGL)
        guard let renderer = registry.makeRenderer(requirement, assets: assets()) else {
            return XCTFail("no renderer")
        }

        renderer.prepare(assets())
        renderer.present(
            PresentationFrame(
                emotion: .shy,
                speaking: true,
                looking: true,
                nod: StandNod(kind: .yes, id: 1),
                framing: .knees,
                reducedMotion: false
            )
        )

        let fixture = spine.renderers[0]
        XCTAssertEqual(fixture.prepared.count, 1)
        XCTAssertEqual(fixture.frames.first?.emotion, .shy)
        XCTAssertEqual(fixture.frames.first?.nod?.kind, .yes)
    }
}
