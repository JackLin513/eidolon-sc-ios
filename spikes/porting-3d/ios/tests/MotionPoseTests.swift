import XCTest

@testable import Eidolon3DSpike

final class MotionPoseTests: XCTestCase {
    /// HIPS moves a quarter unit on X and turns 90° about X by the last frame;
    /// POSITION has no joint, so it must not disturb anything.
    private let fixture = """
    {"format":"eidolon.motion/1","fps":30,"frames":2,"time_length":0.0333333,
     "angle_scale":100,"position_scale":4000,
     "bones":[{"path":"MODEL_00/HIPS","rot":[[0,9000],0,0],"pos":[[0,1000],0,0]},
              {"path":"MODEL_00/POSITION","rot":[0,0,0]}]}
    """

    private let joints = ["MODEL_00/HIPS", "MUNE1"]

    /// A quarter turn about Y at the skeleton root, for the model-space test.
    private let rootFixture = """
    {"format":"eidolon.motion/1","fps":30,"frames":1,"time_length":0.0333333,
     "angle_scale":100,"position_scale":4000,
     "bones":[{"path":"MODEL_00/HIPS","rot":[0,[9000],0]}]}
    """
    private let rest = [
        JointPose(translation: .zero, rotation: SIMD4(0, 0, 0, 1), scale: .one),
        JointPose(translation: SIMD3(0.5, 1, 0), rotation: SIMD4(0, 0, 0, 1), scale: .one),
    ]

    private func sampler() throws -> MotionSampler {
        let dance = try JSONDecoder().decode(MotionDance.self, from: Data(fixture.utf8))
        let map = MotionJointMap.resolve(paths: dance.bones.map(\.path), joints: joints)
        return MotionSampler(dance: dance, map: map, rest: rest)
    }

    func testPoseHasOneEntryPerJointWhateverTheDanceCovers() throws {
        XCTAssertEqual(try sampler().jointCount, joints.count)
        XCTAssertEqual(try sampler().pose(atFrame: 0).count, joints.count)
    }

    /// The first frame of this dance is the rest rotation and offset zero, so
    /// the driven joint is the arm's rest pose plus nothing.
    func testFirstFrameLeavesTheJointNearIdentity() throws {
        let pose = try sampler().pose(atFrame: 0)

        XCTAssertEqual(pose[0].translation, .zero)
        XCTAssertEqual(pose[0].rotation.x, 0, accuracy: 1e-6)
        XCTAssertEqual(pose[0].rotation.w, 1, accuracy: 1e-6)
    }

    /// 90° about X in Unity's left-handed space becomes -90° about X after the
    /// `diag(1, 1, -1)` mirror, i.e. (-√½, 0, 0, √½).
    func testRotationIsMirroredIntoTheRightHandedFrame() throws {
        let pose = try sampler().pose(atFrame: 1)

        XCTAssertEqual(pose[0].rotation.x, -0.7071068, accuracy: 1e-6)
        XCTAssertEqual(pose[0].rotation.y, 0, accuracy: 1e-6)
        XCTAssertEqual(pose[0].rotation.z, 0, accuracy: 1e-6)
        XCTAssertEqual(pose[0].rotation.w, 0.7071068, accuracy: 1e-6)
    }

    /// 1000 quarter-millimetres is a quarter Unity unit; the mirror negates z,
    /// not x.
    func testPositionDividesByTheScaleAndMirrorsZ() throws {
        let pose = try sampler().pose(atFrame: 1)

        XCTAssertEqual(pose[0].translation, SIMD3(0.25, 0, 0))
    }

    func testUnanimatedJointKeepsItsRestPose() throws {
        let sampler = try sampler()

        XCTAssertEqual(sampler.pose(atFrame: 0)[1], rest[1])
        XCTAssertEqual(sampler.pose(atFrame: 1)[1], rest[1])
    }

    func testTimeIsFlooredOntoTheFrameGrid() throws {
        let sampler = try sampler()

        XCTAssertEqual(sampler.pose(at: 0.02), sampler.pose(atFrame: 0))
        XCTAssertEqual(sampler.pose(at: 0.04), sampler.pose(atFrame: 1))
        XCTAssertEqual(sampler.pose(at: -5), sampler.pose(atFrame: 0))
        XCTAssertEqual(sampler.pose(at: 99), sampler.pose(atFrame: 1))
    }

    // MARK: - Root frame

    /// RealityKit reports a root joint against the model space, and the USDZ
    /// pipeline turns that space +90° about X: `MUNE1`'s rest comes back as
    /// `(0.5, 0.5, -0.5, 0.5)` where the game's own rest rotation, mirrored
    /// for the right-handed frame, is a quarter turn about Z.
    func testRootFrameReproducesTheRestPoseTheDeviceReports() {
        let gameRest = UnityHandedness.rotation(SIMD3(0, 0, -90))

        let turned = UnityHandedness.multiply(UnityHandedness.rootFrame, gameRest)

        XCTAssertEqual(turned.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(turned.y, 0.5, accuracy: 1e-6)
        XCTAssertEqual(turned.z, -0.5, accuracy: 1e-6)
        XCTAssertEqual(turned.w, 0.5, accuracy: 1e-6)
    }

    /// A root joint in a dance gets the model-space turn on top of the mirror.
    func testRootJointsGetTheModelSpaceTurn() throws {
        let dance = try JSONDecoder().decode(
            MotionDance.self, from: Data(rootFixture.utf8)
        )
        let map = MotionJointMap.resolve(
            paths: dance.bones.map(\.path), joints: ["HIPS"]
        )
        let sampler = MotionSampler(dance: dance, map: map, rest: [.identity])

        let rotation = sampler.pose(atFrame: 0)[0].rotation

        XCTAssertEqual(rotation.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(rotation.y, -0.5, accuracy: 1e-6)
        XCTAssertEqual(rotation.z, -0.5, accuracy: 1e-6)
        XCTAssertEqual(rotation.w, 0.5, accuracy: 1e-6)
    }

    // MARK: - Handedness

    func testYawIsMirroredToTheOppositeSign() {
        let unity = UnityEuler.quaternion(SIMD3(0, 90, 0))

        XCTAssertEqual(UnityHandedness.rotation(SIMD3(0, 90, 0)), SIMD4(
            -unity.x, -unity.y, unity.z, unity.w
        ))
    }

    func testTranslationMirrorsOnlyZ() {
        XCTAssertEqual(
            UnityHandedness.translation(SIMD3(1, 2, 3)), SIMD3(1, 2, -3)
        )
    }
}
