import XCTest
import simd

@testable import Eidolon3DSpike

/// The runtime spring for the bones the game's dances do not key.
///
/// Without the game's own `SwayBone` assets the constants are tuned rather than
/// derived, so these tests pin the three things that would silently break the
/// tuning: the sidecar shape, the rest pose being a fixed point, and gravity
/// acting along the skeleton's up axis (+Z), not the model's (+Y).
final class MotionSwayTests: XCTestCase {
    private let skirt = MotionSway.Spring(stiffness: 16, drag: 1.5, gravity: 6)

    /// `BASE` with one skirt panel under it, plus the two landmarks the solver
    /// reads its up axis from: `HAIR` above `KOSHI`, both roots at rest.
    private func rig() -> (joints: [String], rest: [JointPose]) {
        var rest = [JointPose](repeating: .identity, count: 4)
        // HAIR sits on the up axis in world space, KOSHI at the origin.
        rest[2].translation = SIMD3(0, 0, 1)
        return (["BASE", "BASE/skirt_a", "HAIR", "KOSHI"], rest)
    }

    private func configuration(
        bones: [(name: String, tail: SIMD3<Float>)]
    ) -> MotionSway.Configuration {
        MotionSway.Configuration(
            format: MotionSway.format,
            families: ["skirt": skirt],
            bones: bones.map {
                MotionSway.Bone(name: $0.name, family: "skirt", tail: [$0.tail.x, $0.tail.y, $0.tail.z])
            }
        )
    }

    private func makeSway(
        tail: SIMD3<Float> = SIMD3(1, 0, 0),
        rest: [JointPose]? = nil,
        joints: [String]? = nil
    ) -> MotionSway? {
        let (names, poses) = rig()
        return MotionSway(
            configuration: configuration(bones: [("BASE/skirt_a", tail)]),
            joints: joints ?? names,
            rest: rest ?? poses
        )
    }

    /// The bone's actual world direction, computed the way the renderer sees
    /// it: parent's world rotation times the bone's local rotation.
    private func direction(of joint: Int, poses: [JointPose], parents: [Int?],
                           tail: SIMD3<Float>) -> SIMD3<Float> {
        let world = JointWorld.transforms(poses, parents: parents)
        let parentRotation = parents[joint].map { world[$0].rotation }
            ?? SIMD4<Float>(0, 0, 0, 1)
        let rigid = QuaternionMath.multiply(parentRotation, poses[joint].rotation)
        return simd_normalize(QuaternionMath.rotate(rigid, tail))
    }

    // MARK: - The sidecar

    func testDecodesTheGeneratorOutput() throws {
        let json = """
        {
          "format": "eidolon.sway/1",
          "families": {
            "skirt": { "stiffness": 16, "drag": 1.5, "gravity": 6 },
            "hair": { "stiffness": 110, "drag": 11, "gravity": 0.5 }
          },
          "bones": [
            { "name": "BASE/skirt_a", "family": "skirt", "tail": [0.1, 0.2, -0.3] },
            { "name": "BASE/hair_a", "family": "hair", "tail": [0, 0.5, 0] }
          ]
        }
        """
        let configuration = try JSONDecoder().decode(
            MotionSway.Configuration.self, from: Data(json.utf8)
        )
        XCTAssertEqual(configuration.format, MotionSway.format)
        XCTAssertEqual(configuration.families["skirt"]?.stiffness, 16)
        XCTAssertEqual(configuration.families["hair"]?.gravity, 0.5)
        XCTAssertEqual(configuration.bones.count, 2)
        XCTAssertEqual(configuration.bones[0].tail[0], 0.1, accuracy: 1e-6)
        XCTAssertEqual(configuration.bones[0].tail[1], 0.2, accuracy: 1e-6)
        XCTAssertEqual(configuration.bones[0].tail[2], -0.3, accuracy: 1e-6)
    }

    func testAcceptsNoForeignOrUnknownSidecar() {
        let (names, poses) = rig()
        let foreign = MotionSway.Configuration(
            format: "other/1", families: ["skirt": skirt],
            bones: [.init(name: "BASE/skirt_a", family: "skirt", tail: [1, 0, 0])]
        )
        XCTAssertNil(MotionSway(configuration: foreign, joints: names, rest: poses))

        let unknown = configuration(bones: [("BASE/nothing", SIMD3(1, 0, 0))])
        XCTAssertNil(MotionSway(configuration: unknown, joints: names, rest: poses))

        let zeroTail = configuration(bones: [("BASE/skirt_a", .zero)])
        XCTAssertNil(MotionSway(configuration: zeroTail, joints: names, rest: poses))
    }

    func testSkipsBonesTheRigDoesNotHaveButKeepsTheRest() {
        let (names, poses) = rig()
        let mixed = configuration(bones: [
            ("BASE/nothing", SIMD3(1, 0, 0)),
            ("BASE/skirt_a", SIMD3(1, 0, 0)),
        ])
        let sway = MotionSway(configuration: mixed, joints: names, rest: poses)
        XCTAssertEqual(sway?.count, 1)
    }

    // MARK: - The spring

    /// A held frame with no time passing must leave the pose exactly as the
    /// dance wrote it: the spring seeds on the rigid tip, so its first clamp is
    /// a no-op. Otherwise every pause would snap the skirt somewhere.
    func testRestPoseIsAFixedPoint() throws {
        let (names, rest) = rig()
        var sway = try XCTUnwrap(makeSway())
        var poses = rest
        sway.apply(&poses, dt: 0)
        for (index, expected) in rest.enumerated() {
            let actual = poses[index].rotation
            let difference = max(
                abs(actual.x - expected.rotation.x), abs(actual.y - expected.rotation.y),
                abs(actual.z - expected.rotation.z), abs(actual.w - expected.rotation.w)
            )
            XCTAssertLessThan(difference, 1e-5, "joint \(names[index]) moved on a held frame")
        }
    }

    func testGravityPullsTheBoneAlongTheSkeletonsUpAxis() throws {
        let (names, rest) = rig()
        var sway = try XCTUnwrap(makeSway())
        var poses = rest
        for _ in 0..<120 { // four seconds at the dance's rate
            poses = rest
            sway.apply(&poses, dt: 1 / 30)
        }
        // Rigid would be (1, 0, 0). The tuned skirt spring settles near 20°
        // below horizontal; the skeleton's up is +Z, so "below" is −Z.
        let settled = direction(of: 1, poses: poses, parents: [nil, 0, nil, nil],
                                tail: SIMD3(1, 0, 0))
        XCTAssertGreaterThan(settled.x, 0.85)
        XCTAssertLessThan(settled.z, -0.2)
        XCTAssertGreaterThan(settled.z, -0.5)
        XCTAssertEqual(settled.y, 0, accuracy: 1e-4)
        XCTAssertFalse(settled.x.isNaN, "\(names)")
    }

    /// The spring turns the bone around its parent's *current* pose, so a
    /// turned parent must carry the bone with it before gravity is applied.
    func testBoneRidesItsParentsTurn() throws {
        var (names, rest) = rig()
        let half = Float.pi / 8
        rest[0].rotation = SIMD4(0, 0, sin(half), cos(half)) // BASE turned 45° about Z
        var sway = try XCTUnwrap(makeSway(rest: rest))
        var poses = rest
        sway.apply(&poses, dt: 0)
        let direction = direction(of: 1, poses: poses, parents: [nil, 0, nil, nil],
                                  tail: SIMD3(1, 0, 0))
        XCTAssertEqual(direction.x, 0.7071068, accuracy: 1e-4)
        XCTAssertEqual(direction.y, 0.7071068, accuracy: 1e-4)
        XCTAssertEqual(names.count, poses.count)
    }

    /// However the parents move, the bone must stay a unit-length vector off
    /// its base — a drifting length is how a skirt starts poking through legs.
    func testLengthNeverDrifts() throws {
        var (names, rest) = rig()
        var sway = try XCTUnwrap(makeSway())
        var poses = rest
        for step in 0..<60 {
            let angle = Float(step) * 0.7
            rest[0].rotation = SIMD4(0, 0, sin(angle / 2), cos(angle / 2))
            poses = rest
            sway.apply(&poses, dt: 1 / 30)
            let world = JointWorld.transforms(poses, parents: [nil, 0, nil, nil])
            let rigid = QuaternionMath.multiply(world[0].rotation, poses[1].rotation)
            let length = simd_length(QuaternionMath.rotate(rigid, SIMD3(1, 0, 0)))
            XCTAssertEqual(length, 1, accuracy: 1e-4, "step \(step)")
            XCTAssertFalse(length.isNaN, "\(names)")
        }
    }

    func testResetForgetsTheSimulatedTip() throws {
        let (_, rest) = rig()
        var sway = try XCTUnwrap(makeSway())
        var first = rest
        for _ in 0..<45 { first = rest; sway.apply(&first, dt: 1 / 30) }
        let before = first[1].rotation
        sway.reset()
        var second = rest
        for _ in 0..<45 { second = rest; sway.apply(&second, dt: 1 / 30) }
        let after = second[1].rotation

        let difference = max(
            abs(before.x - after.x), abs(before.y - after.y),
            abs(before.z - after.z), abs(before.w - after.w)
        )
        XCTAssertLessThan(difference, 1e-5)
    }

    /// The solver reports the up axis from the rest skeleton, so a rig without
    /// those landmarks still runs instead of trapping.
    func testMissingLandmarksFallBackToZ() throws {
        let (names, rest) = rig()
        let trimmed = Array(names.prefix(2))
        let poses = Array(rest.prefix(2))
        var sway = try XCTUnwrap(makeSway(rest: poses, joints: trimmed))
        var driven = poses
        for _ in 0..<30 { driven = poses; sway.apply(&driven, dt: 1 / 30) }
        let settled = direction(of: 1, poses: driven, parents: [nil, 0],
                                tail: SIMD3(1, 0, 0))
        XCTAssertLessThan(settled.z, -0.05)
    }
}
