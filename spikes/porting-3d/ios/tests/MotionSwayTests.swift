import XCTest
import simd

@testable import Eidolon3DSpike

/// The runtime sway for the bones the game's dances do not key (issue #28).
///
/// The solver is a port of the game's `SwayBoneMT` and takes the game's own
/// numbers straight out of `_sway.txt` (`stiffness 0.02`, `drag 0.6`,
/// `gravity 0.0001`, thigh capsule r 0.088), so these tests pin the judgements
/// that keep a skirt out of the legs: the angle window, the collider push, the
/// anti-fold of neighbouring panels, and the base-follow that stops a
/// translation turning into a kick.
final class MotionSwayTests: XCTestCase {
    /// The game's skirt numbers (`cb_ss003_014mir_sway`).
    private let skirt = MotionSway.Spring(stiffness: 0.02, drag: 0.6, gravity: 0.0001)
    private let half = Float.pi / 8

    private func emptyPose() -> JointPose { .identity }

    /// `BASE` with one skirt panel under it, plus the two landmarks the solver
    /// reads its up axis from: `HAIR` above `KOSHI`, both roots at rest.
    private func rig() -> (joints: [String], rest: [JointPose]) {
        var rest = [JointPose](repeating: .identity, count: 4)
        // HAIR sits on the up axis in world space, KOSHI at the origin.
        rest[2].translation = SIMD3(0, 0, 1)
        return (["BASE", "BASE/skirt_a", "HAIR", "KOSHI"], rest)
    }

    /// `BASE` with a thigh capsule hung on `BASE/MOMO_L` and one skirt panel on
    /// `BASE/skirt_a`, plus the two landmarks the solver reads its up axis from.
    private func collisionRig() -> (joints: [String], rest: [JointPose]) {
        var rest = [JointPose](repeating: .identity, count: 5)
        rest[3].translation = SIMD3(0, 0, 1) // HAIR on the up axis
        return (["BASE", "BASE/MOMO_L", "BASE/skirt_a", "HAIR", "KOSHI"], rest)
    }

    private let skirtParents: [Int?] = [nil, 0, 0, nil, nil]

    private func bone(
        _ path: String,
        tail: SIMD3<Float> = SIMD3(1, 0, 0),
        radius: Float? = nil,
        spring: MotionSway.Spring? = nil,
        follow: Float? = nil,
        limit: MotionSway.Limit? = nil,
        colliders: [Int]? = nil,
        sideLink: String? = nil,
        sideSpring: Float? = nil,
        antiFold: MotionSway.AntiFold? = nil,
        hitTwice: Bool? = nil,
        useLinkHit: Bool? = nil
    ) -> MotionSway.Bone {
        MotionSway.Bone(
            name: path, family: "skirt", tail: [tail.x, tail.y, tail.z],
            radius: radius, spring: spring, follow: follow, limit: limit,
            colliders: colliders, sideLink: sideLink, sideSpring: sideSpring,
            antiFold: antiFold, hitTwice: hitTwice, useLinkHit: useLinkHit
        )
    }

    private func configuration(
        bones: [MotionSway.Bone],
        colliders: [MotionSway.Collider] = []
    ) -> MotionSway.Configuration {
        MotionSway.Configuration(
            format: MotionSway.format, families: ["skirt": skirt], bones: bones,
            colliders: colliders.isEmpty ? nil : colliders
        )
    }

    /// The bone's actual world direction, computed the way the renderer sees
    /// it: parent's world rotation times the bone's local rotation.
    private func direction(of joint: Int, poses: [JointPose], parents: [Int?],
                           tail: SIMD3<Float>) -> SIMD3<Float> {
        let world = JointWorld.transforms(poses, parents: parents)
        return simd_normalize(QuaternionMath.rotate(world[joint].rotation, tail))
    }

    private func worldTip(of joint: Int, poses: [JointPose], parents: [Int?],
                          tail: SIMD3<Float>) -> SIMD3<Float> {
        let world = JointWorld.transforms(poses, parents: parents)
        return world[joint].position + QuaternionMath.rotate(world[joint].rotation, tail)
    }

    private func distance(from p: SIMD3<Float>, to a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let ab = b - a
        let t = simd_clamp(simd_dot(p - a, ab) / simd_dot(ab, ab), 0, 1)
        return simd_length(p - (a + ab * t))
    }

    // MARK: - The sidecar

    func testDecodesTheLegacyGeneratorOutput() throws {
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
        XCTAssertEqual(configuration.format, MotionSway.legacyFormat)
        XCTAssertEqual(configuration.families?["skirt"]?.stiffness, 16)
        XCTAssertEqual(configuration.families?["hair"]?.gravity, 0.5)
        XCTAssertEqual(configuration.bones.count, 2)
        XCTAssertEqual(configuration.bones[0].tail[0], 0.1, accuracy: 1e-6)
    }

    func testDecodesTheGameDataSidecar() throws {
        let json = """
        {
          "format": "eidolon.sway/2",
          "bones": [
            {
              "name": "MODEL_00/BODY_SCALE/BASE/KOSHI/skirt_GP/skirt_LB0",
              "family": "skirt", "tail": [0.16, 0, 0], "radius": 0.04,
              "spring": { "stiffness": 0.02, "drag": 0.6, "gravity": 0.0001 },
              "follow": 0.3,
              "limit": { "minY": -5, "maxY": 5, "minZ": -80, "maxZ": -5 },
              "colliders": [0, 1]
            }
          ],
          "colliders": [
            { "joint": "MODEL_00/BODY_SCALE/BASE/KOSHI/MOMO_L", "type": "Capsule",
              "radius": 0.088, "distance": 0.3551699, "offset": [-0.177585, 0, 0],
              "axis": "X" }
          ]
        }
        """
        let configuration = try JSONDecoder().decode(
            MotionSway.Configuration.self, from: Data(json.utf8)
        )
        XCTAssertEqual(configuration.format, MotionSway.format)
        let bone = try XCTUnwrap(configuration.bones.first)
        XCTAssertEqual(bone.limit?.minZ, -80)
        XCTAssertEqual(bone.radius, 0.04)
        XCTAssertEqual(bone.colliders, [0, 1])
        let collider = try XCTUnwrap(configuration.colliders?.first)
        XCTAssertEqual(collider.type, "Capsule")
        XCTAssertEqual(collider.distance, 0.3551699, accuracy: 1e-6)
    }

    func testAcceptsNoForeignOrUnknownSidecar() {
        let (names, poses) = rig()
        let foreign = MotionSway.Configuration(
            format: "other/1", families: ["skirt": skirt],
            bones: [bone("BASE/skirt_a")], colliders: nil
        )
        XCTAssertNil(MotionSway(configuration: foreign, joints: names, rest: poses))

        let unknown = configuration(bones: [bone("BASE/nothing")])
        XCTAssertNil(MotionSway(configuration: unknown, joints: names, rest: poses))

        let zeroTail = configuration(bones: [bone("BASE/skirt_a", tail: .zero)])
        XCTAssertNil(MotionSway(configuration: zeroTail, joints: names, rest: poses))
    }

    func testSkipsBonesTheRigDoesNotHaveButKeepsTheRest() {
        let (names, poses) = rig()
        let mixed = configuration(bones: [bone("BASE/nothing"), bone("BASE/skirt_a")])
        XCTAssertEqual(MotionSway(configuration: mixed, joints: names, rest: poses)?.count, 1)
    }

    // MARK: - The spring

    /// A held frame with no time passing must leave the pose exactly as the
    /// dance wrote it: the solver seeds on the rigid tip, so its first clamp is
    /// a no-op. Otherwise every pause would snap the skirt somewhere.
    func testRestPoseIsAFixedPoint() throws {
        let (names, rest) = rig()
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a")]),
            joints: names, rest: rest
        ))
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

    /// Gravity is tiny next to stiffness in the game's numbers, so a panel hangs
    /// just below its rest direction instead of snapping to world down. A
    /// larger gravity must droop more.
    func testGravityDroopsThePanelInProportionToItsSize() throws {
        let (names, rest) = rig()
        let heavy = MotionSway.Spring(stiffness: 0.02, drag: 0.6, gravity: 0.002)

        func settle(_ spring: MotionSway.Spring) throws -> Float {
            var sway = try XCTUnwrap(MotionSway(
                configuration: configuration(bones: [bone("BASE/skirt_a", spring: spring)]),
                joints: names, rest: rest
            ))
            var poses = rest
            for _ in 0..<120 {
                poses = rest
                sway.apply(&poses, dt: 1 / 60)
            }
            let settled = direction(of: 1, poses: poses, parents: [nil, 0, nil, nil],
                                    tail: SIMD3(1, 0, 0))
            // What is left after the rigid +X rest direction is the droop.
            return simd_length(settled - SIMD3(1, 0, 0))
        }

        let light = try settle(skirt)
        let drooping = try settle(heavy)
        XCTAssertLessThan(light, 0.03)
        XCTAssertGreaterThan(drooping, light * 5)
    }

    /// The solver turns the bone around its parent's *current* pose, so a
    /// turned parent must carry the bone with it.
    func testBoneRidesItsParentsTurn() throws {
        var (names, rest) = rig()
        rest[0].rotation = SIMD4(0, 0, sin(half), cos(half)) // BASE turned 45° about Z
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a")]),
            joints: names, rest: rest
        ))
        var poses = rest
        sway.apply(&poses, dt: 0)
        let direction = direction(of: 1, poses: poses, parents: [nil, 0, nil, nil],
                                  tail: SIMD3(1, 0, 0))
        XCTAssertEqual(direction.x, 0.7071068, accuracy: 1e-4)
        XCTAssertEqual(direction.y, 0.7071068, accuracy: 1e-4)
        XCTAssertEqual(names.count, poses.count)
    }

    /// However the parents move, the drawn tip must stay exactly one tail away
    /// from its base — a drifting length is how a skirt starts poking through
    /// legs.
    func testLengthNeverDrifts() throws {
        var (names, rest) = rig()
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a")]),
            joints: names, rest: rest
        ))
        var poses = rest
        for step in 0..<60 {
            let angle = Float(step) * 0.7
            rest[0].rotation = SIMD4(0, 0, sin(angle / 2), cos(angle / 2))
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
            let world = JointWorld.transforms(poses, parents: [nil, 0, nil, nil])
            let tip = world[1].position
                + QuaternionMath.rotate(world[1].rotation, SIMD3(1, 0, 0))
            XCTAssertEqual(simd_length(tip - world[1].position), 1, accuracy: 1e-4,
                           "step \(step)")
            XCTAssertFalse(tip.x.isNaN, "\(names)")
        }
    }

    /// Root motion is a translation, not a turn. The game carries the tip along
    /// with the base (`MoveTipPos`) instead of rebuilding the direction against
    /// the new base, so two rigs that differ only in how far the pelvis moved
    /// keep identical bone rotations.
    func testRootTranslationDoesNotTurnTheBone() throws {
        let (names, base) = rig()
        let tail = SIMD3<Float>(0.05, 0, 0)
        var first = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a", tail: tail)]),
            joints: names, rest: base
        ))
        var second = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a", tail: tail)]),
            joints: names, rest: base
        ))

        var worst: Float = 0
        for step in 0..<60 {
            var stillRest = base
            var movingRest = base
            movingRest[0].translation = SIMD3(0, Float(step) * 0.01, 0)

            var stillPoses = stillRest
            var movingPoses = movingRest
            first.apply(&stillPoses, dt: 1 / 60)
            second.apply(&movingPoses, dt: 1 / 60)

            let a = stillPoses[1].rotation
            let b = movingPoses[1].rotation
            worst = max(
                worst, abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z), abs(a.w - b.w)
            )
        }
        XCTAssertLessThan(worst, 1e-4, "the pelvis moving turned the panel")
    }

    func testResetForgetsTheSimulatedState() throws {
        let (names, rest) = rig()
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a")]),
            joints: names, rest: rest
        ))
        var first = rest
        for _ in 0..<45 { first = rest; sway.apply(&first, dt: 1 / 60) }
        let before = first[1].rotation
        sway.reset()
        var second = rest
        for _ in 0..<45 { second = rest; sway.apply(&second, dt: 1 / 60) }
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
        let heavy = MotionSway.Spring(stiffness: 0.02, drag: 0.6, gravity: 0.01)
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [bone("BASE/skirt_a", spring: heavy)]),
            joints: trimmed, rest: poses
        ))
        var driven = poses
        for _ in 0..<120 { driven = poses; sway.apply(&driven, dt: 1 / 60) }
        let settled = direction(of: 1, poses: driven, parents: [nil, 0],
                                tail: SIMD3(1, 0, 0))
        XCTAssertLessThan(settled.z, -0.05)
    }

    // MARK: - The game's judgements (issue #28)

    /// The game does not let a skirt panel live inside the thigh. `_sway.txt`
    /// gives every skirt bone a `radius` and points it at `MOMO_L#0`/`MOMO_R#0`
    /// (capsule r 0.088, offset −0.178 along the bone); a panel whose release
    /// direction lands inside that capsule has to be pushed back out to
    /// `radius + bone radius` before anything is rendered.
    func testSkirtPanelIsPushedOutOfTheThighCapsule() throws {
        var (names, rest) = collisionRig()
        let turn = Float.pi * 60 / 180 // panel swings in over the thigh
        rest[2].rotation = SIMD4(0, sin(turn / 2), 0, cos(turn / 2))

        // The thigh hangs straight below the pelvis, as it does on the rig.
        let capsule = MotionSway.Collider(
            joint: "BASE/MOMO_L", type: "capsule", radius: 0.088,
            distance: 0.36, offset: [0, 0, -0.22], axis: "Z"
        )
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(
                bones: [bone("BASE/skirt_a", tail: SIMD3(0.18, 0, 0), radius: 0.04,
                             colliders: [0])],
                colliders: [capsule]
            ),
            joints: names, rest: rest
        ))

        var poses = rest
        var worst = Float.greatestFiniteMagnitude
        for _ in 0..<90 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)

            let world = JointWorld.transforms(poses, parents: skirtParents)
            let centre = world[1].position
                + QuaternionMath.rotate(world[1].rotation, SIMD3(0, 0, -0.22))
            let axis = QuaternionMath.rotate(world[1].rotation, SIMD3(0, 0, 1))
            let halfLength = capsule.distance / 2
            let tip = worldTip(of: 2, poses: poses, parents: skirtParents,
                               tail: SIMD3(0.18, 0, 0))
            worst = min(worst, distance(from: tip,
                                        to: centre - axis * halfLength,
                                        centre + axis * halfLength))
        }
        XCTAssertGreaterThanOrEqual(
            worst, 0.088 + 0.04 - 1e-3,
            "a skirt panel stayed inside the thigh capsule (closest \(worst))"
        )
    }

    /// A panel resting on a capsule must settle, not snap between positions.
    ///
    /// The bind pose really does start the skirt panels inside the thigh
    /// capsules, and a panel's own base can sit inside the capsule too, so the
    /// feasible escape is a thin sliver of directions. Resolving it with one
    /// normalised jump towards the summed correction overshoots, bounces, and
    /// then re-lands on a coarse search cell — up to 6 degrees of jump per
    /// frame, which reads on screen as the skirt flapping in a wind. Measured
    /// on the real model: 11.8 deg/frame before, 0.6 after.
    func testPanelRestingOnACapsuleSettlesInsteadOfFlapping() throws {
        var rest = [JointPose](repeating: .identity, count: 5)
        rest[1].translation = SIMD3(0, 0, 0)          // the capsule's joint
        rest[2].translation = SIMD3(0.04, 0, 0.05)    // panel base, inside the capsule
        rest[3].translation = SIMD3(0, 0, 1)          // HAIR, the up landmark
        let names = ["BASE", "BASE/CAP", "BASE/skirt_a", "HAIR", "KOSHI"]
        let parents: [Int?] = [nil, 0, 0, nil, nil]
        let tail = SIMD3<Float>(0.02, 0, -0.2)

        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(
                bones: [bone("BASE/skirt_a", tail: tail, radius: 0.04, colliders: [0])],
                colliders: [MotionSway.Collider(
                    joint: "BASE/CAP", type: "capsule", radius: 0.09,
                    distance: 0.4, offset: [0, 0, -0.2], axis: "Z"
                )]
            ),
            joints: names, rest: rest
        ))

        var poses = rest
        var previous: SIMD3<Float>?
        var worstStep: Float = 0
        for frame in 0..<600 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
            let current = direction(of: 2, poses: poses, parents: parents, tail: tail)
            if let previous, frame >= 480 {
                worstStep = max(worstStep, acos(min(1, simd_dot(previous, current))) * 180 / .pi)
            }
            previous = current
        }
        XCTAssertLessThan(worstStep, 0.6, "the panel kept snapping (\(worstStep) deg/frame)")
    }


    /// A collider push must not leave the angle window.
    ///
    /// The game runs `SwayMove` (spring) → `SwayHit` (collision on the free
    /// tip) → `CalcRotate` (window). Clamping first and colliding afterwards
    /// let a push drag the bone far outside its window: on the real dance the
    /// hair reached 91 degrees against a ±40/20 window, which is exactly the
    /// "hair floating" the dance showed. Here a sphere pushes the panel 30
    /// degrees off its bind direction while the window allows 5…10.
    func testCollisionPushStaysInsideTheAngleWindow() throws {
        var rest = [JointPose](repeating: .identity, count: 6)
        rest[1].translation = SIMD3(0.18, -0.08, 0) // pushes the tip towards +Y
        rest[3].translation = SIMD3(0, 0, 1)        // HAIR, the up landmark
        let names = ["BASE", "BASE/PUSH", "BASE/skirt_a", "HAIR", "KOSHI", "BASE/unused"]
        let parents: [Int?] = [nil, 0, 0, nil, nil, 0]
        let tail = SIMD3<Float>(0.18, 0, 0)
        let limit = MotionSway.Limit(minY: -5, maxY: 5, minZ: -10, maxZ: -5)

        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(
                bones: [bone("BASE/skirt_a", tail: tail, radius: 0.04,
                             limit: limit, colliders: [0])],
                colliders: [MotionSway.Collider(
                    joint: "BASE/PUSH", type: "sphere", radius: 0.12,
                    distance: 0, offset: [0, 0, 0], axis: "X"
                )]
            ),
            joints: names, rest: rest
        ))

        var poses = rest
        for _ in 0..<90 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
        }
        let world = JointWorld.transforms(poses, parents: parents)
        let tip = worldTip(of: 2, poses: poses, parents: parents, tail: tail)
        let local = QuaternionMath.rotate(
            QuaternionMath.inverse(world[0].rotation), tip - world[2].position
        )
        let pitch = -atan2(local.y, simd_length(SIMD2(local.x, local.z))) * 180 / .pi
        XCTAssertGreaterThanOrEqual(
            pitch, -10 - 0.5,
            "the collider dragged the panel out of its window (pitch \(pitch))"
        )
    }


    /// `SwayColliderMT.CheckPlane`: a half-space through the collider's offset,
    /// keeping the tip `radius` past it. This is the chest/back guard the hair
    /// data leans on (86 of 109 models reference planes), and it was skipped by
    /// the exporter until now.
    func testPlaneKeepsTheTipOutOfItsHalfSpace() throws {
        let (names, rest) = collisionRig()
        let plane = MotionSway.Collider(
            joint: "BASE/MOMO_L", type: "plane", radius: 0.1,
            distance: 0, offset: [0, 0, 0.004], axis: "X",
            normal: [0, 0, -1], target: nil
        )
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(
                bones: [bone("BASE/skirt_a", tail: SIMD3(0.18, 0, 0), radius: 0.01,
                             colliders: [0])],
                colliders: [plane]
            ),
            joints: names, rest: rest
        ))
        var poses = rest
        for _ in 0..<60 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
        }
        let tip = worldTip(of: 2, poses: poses, parents: skirtParents, tail: SIMD3(0.18, 0, 0))
        // The kept side is −Z, measured from the offset at z = 0.004: the
        // margin is the bone radius (0.01) plus the solver's surface epsilon,
        // so the tip has to sit at z ≤ 0.004 − 0.011 = −0.007.
        XCTAssertLessThanOrEqual(tip.z, -0.007 + 1e-3,
                                 "the plane let the tip through (z \(tip.z))")
    }

    /// `SwayColliderMT.CapsuleBridgeHit`: a capsule spanning the collider's
    /// joint and its `bridgetgt` (the neck-to-shoulder gap on the real rig).
    func testBridgeCapsulePushesTheTipOut() throws {
        var rest = [JointPose](repeating: .identity, count: 6)
        rest[1].translation = SIMD3(0, 0.1, -0.3) // the far end of the bridge
        rest[3].translation = SIMD3(0, 0, 1)      // HAIR, the up landmark
        let names = ["BASE", "BASE/FAR", "BASE/skirt_a", "HAIR", "KOSHI", "BASE/unused"]
        let parents: [Int?] = [nil, 0, 0, nil, nil, 0]
        let tail = SIMD3<Float>(0, 0, -0.2)       // tip on the bridge's axis
        let bridge = MotionSway.Collider(
            joint: "BASE", type: "bridge", radius: 0.09,
            distance: 0.316, offset: [0, 0, 0], axis: "X",
            normal: nil, target: "BASE/FAR"
        )
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(
                bones: [bone("BASE/skirt_a", tail: tail, radius: 0.01, colliders: [0])],
                colliders: [bridge]
            ),
            joints: names, rest: rest
        ))
        var poses = rest
        var worst = Float.greatestFiniteMagnitude
        for _ in 0..<120 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
            let world = JointWorld.transforms(poses, parents: parents)
            let tip = worldTip(of: 2, poses: poses, parents: parents, tail: tail)
            let a = world[0].position
            let b = world[1].position
            let ab = b - a
            let t = simd_clamp(simd_dot(tip - a, ab) / simd_dot(ab, ab), 0, 1)
            worst = min(worst, distance(from: tip, to: a + ab * t, a + ab * t))
        }
        XCTAssertGreaterThanOrEqual(
            worst, 0.09 + 0.01 - 1e-3,
            "the bridge capsule let the tip through (closest \(worst))"
        )
    }

    /// `CheckSideLine`: a panel and its `sideLink` neighbour are not two
    /// independent tips. The game tests the *segment between the two tips*
    /// against the colliders, so a pair can straddle a leg even when both of
    /// its tips are already clear of it — the gap a big skirt opens when the
    /// dance swings it between the thighs.
    func testSideLinkKeepsThePairOutOfTheCapsule() throws {
        var rest = [JointPose](repeating: .identity, count: 6)
        rest[1].translation = SIMD3(0.3, 0, -0.05) // the leg, under the pair
        rest[4].translation = SIMD3(0, 0, 1)       // HAIR, the up landmark
        let names = ["BASE", "BASE/MOMO_L", "BASE/skirt_a", "BASE/skirt_b", "HAIR", "KOSHI"]
        let parents: [Int?] = [nil, 0, 0, 0, nil, nil]
        let leg = MotionSway.Collider(
            joint: "BASE/MOMO_L", type: "capsule", radius: 0.03,
            distance: 0, offset: [0, 0, 0], axis: "Z"
        )
        let tails = [SIMD3<Float>(0.3, 0.08, 0), SIMD3<Float>(0.3, -0.08, 0)]
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [
                bone("BASE/skirt_a", tail: tails[0], radius: 0.04, colliders: [0],
                     sideLink: "BASE/skirt_b", useLinkHit: true),
                bone("BASE/skirt_b", tail: tails[1], radius: 0.04, colliders: [0],
                     sideLink: "BASE/skirt_a", useLinkHit: true)
            ], colliders: [leg]),
            joints: names, rest: rest
        ))

        // Each tip is 94 mm from the leg's centre, past its own 70 mm limit,
        // so the point hit alone leaves the pair alone; only the side line
        // sees the segment cut across the leg 50 mm from its centre.
        let wants: Float = 0.03 + 0.9 * 0.04
        var poses = rest
        var worst = Float.greatestFiniteMagnitude
        for _ in 0..<180 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
            let world = JointWorld.transforms(poses, parents: parents)
            let a = world[2].position + QuaternionMath.rotate(world[2].rotation, tails[0])
            let b = world[3].position + QuaternionMath.rotate(world[3].rotation, tails[1])
            worst = min(worst, distance(from: world[1].position, to: a, b))
        }
        XCTAssertGreaterThanOrEqual(
            worst, wants - 2e-3,
            "the side line let the pair through the leg (closest \(worst))"
        )
    }

    /// `minYAngle`/`maxYAngle`/`minZAngle`/`maxZAngle` are the window the game
    /// clamps the panel's direction to, measured in the parent's frame. Without
    /// them a panel is free to rotate all the way into the legs.
    func testAngleLimitKeepsThePanelInsideItsWindow() throws {
        let (names, rest) = collisionRig()
        let limit = MotionSway.Limit(minY: -5, maxY: 5, minZ: -80, maxZ: -5)
        var sway = try XCTUnwrap(MotionSway(
            configuration: configuration(bones: [
                bone("BASE/skirt_a", tail: SIMD3(0.18, 0, 0), radius: 0.04, limit: limit)
            ]),
            joints: names, rest: rest
        ))

        var poses = rest
        for _ in 0..<60 {
            poses = rest
            sway.apply(&poses, dt: 1 / 60)
        }
        let world = JointWorld.transforms(poses, parents: skirtParents)
        let local = QuaternionMath.rotate(
            QuaternionMath.inverse(world[0].rotation),
            worldTip(of: 2, poses: poses, parents: skirtParents, tail: SIMD3(0.18, 0, 0))
                - world[2].position
        )
        // The window is a deviation from the bind direction: the panel rests
        // along +X (yaw 90°, pitch 0°), so it may turn ±5° sideways and
        // 5…80° down.
        let yaw = atan2(local.x, -local.z) * 180 / .pi
        let pitch = -atan2(local.y, simd_length(SIMD2(local.x, local.z))) * 180 / .pi
        XCTAssertLessThanOrEqual(yaw, 90 + 5 + 1e-3, "panel yaw escaped its window (\(yaw))")
        XCTAssertGreaterThanOrEqual(yaw, 90 - 5 - 1e-3)
        XCTAssertLessThanOrEqual(pitch, -5 + 1e-3, "panel pitch escaped its window (\(pitch))")
        XCTAssertGreaterThanOrEqual(pitch, -80 - 1e-3)
    }

    /// The game's `antiFoldForce`: two neighbours folded tighter than
    /// `antiFoldAngle` are pushed apart, which is what stops a panel folding
    /// into the one beside it.
    func testAntiFoldPushesNeighboursApart() throws {
        var rest = [JointPose](repeating: .identity, count: 6)
        rest[4].translation = SIMD3(0, 0, 1) // HAIR
        let names = ["BASE", "BASE/MOMO_L", "BASE/skirt_a", "BASE/skirt_b", "HAIR", "KOSHI"]
        let parents: [Int?] = [nil, 0, 0, 0, nil, nil]

        let tilt = Float.pi * 10 / 180
        rest[2].rotation = SIMD4(0, 0, sin(tilt / 2), cos(tilt / 2))
        rest[3].rotation = SIMD4(0, 0, -sin(tilt / 2), cos(tilt / 2))

        let fold = MotionSway.AntiFold(force: 0.002, angle: 60)
        func angleAfter(_ antiFold: MotionSway.AntiFold?) throws -> Float {
            let bones = [
                bone("BASE/skirt_a", tail: SIMD3(0.18, 0, 0),
                     sideLink: "BASE/skirt_b", antiFold: antiFold),
                bone("BASE/skirt_b", tail: SIMD3(0.18, 0, 0),
                     sideLink: "BASE/skirt_a", antiFold: antiFold),
            ]
            var sway = try XCTUnwrap(MotionSway(
                configuration: configuration(bones: bones), joints: names, rest: rest
            ))
            var poses = rest
            for _ in 0..<120 {
                poses = rest
                sway.apply(&poses, dt: 1 / 60)
            }
            let world = JointWorld.transforms(poses, parents: parents)
            let a = simd_normalize(QuaternionMath.rotate(world[2].rotation, SIMD3(1, 0, 0)))
            let b = simd_normalize(QuaternionMath.rotate(world[3].rotation, SIMD3(1, 0, 0)))
            return acos(simd_clamp(simd_dot(a, b), -1, 1))
        }

        let folded = try angleAfter(nil)
        let pushed = try angleAfter(fold)
        XCTAssertGreaterThan(pushed, folded + 0.01, "anti-fold did not separate the pair")
    }
}
