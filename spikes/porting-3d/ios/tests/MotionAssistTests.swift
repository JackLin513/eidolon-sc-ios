import XCTest

@testable import Eidolon3DSpike

/// The game's calc-bone pass, checked against the two properties that make it
/// trustworthy without the game's data: every rule name is recognised exactly
/// once, and the rest pose is a fixed point of every algorithm. The rest-pose
/// check is the same one the offline model did on `rest.json`.
final class MotionAssistTests: XCTestCase {
    private let identity = SIMD4<Float>(0, 0, 0, 1)
    /// Quarter turns in the app's frame: one about Z is a swing of the X axis,
    /// one about X is a pure twist of it.
    private let quarterTurnZ = SIMD4<Float>(0, 0, 0.7071068, 0.7071068)
    private let quarterTurnX = SIMD4<Float>(0.7071068, 0, 0, 0.7071068)

    /// Run the pass on a rig whose joints all start at `rest`, with `changes`
    /// standing in for the dance driving the reference bones.
    private func simulate(
        joints: [String],
        rest: [String: JointPose] = [:],
        changes: [String: JointPose] = [:]
    ) -> [String: JointPose] {
        var poses = joints.map { rest[$0] ?? .identity }
        let assist = MotionAssist(joints: joints, rest: poses)
        for (name, change) in changes {
            guard let index = joints.firstIndex(of: name) else { continue }
            poses[index] = change
        }
        assist.apply(&poses)
        var output: [String: JointPose] = [:]
        for (index, name) in joints.enumerated() { output[name] = poses[index] }
        return output
    }

    private func assertSame(
        _ a: SIMD4<Float>, _ b: SIMD4<Float>, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let direct = max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z), abs(a.w - b.w))
        let negated = max(abs(a.x + b.x), abs(a.y + b.y), abs(a.z + b.z), abs(a.w + b.w))
        XCTAssertLessThan(min(direct, negated), 1e-5, message, file: file, line: line)
    }

    // MARK: - Name grammar

    func testOnlyNamesWithARuleBecomeHelpers() {
        let joints = [
            "MUNE1",
            "MUNE1/KATA_R",
            "MUNE1/KATA_R/UDE_R",
            "MUNE1/KATA_R/HIJI_R__rot_UDE_R__z50",
            "MUNE1/KATA_R/KATA_MD_R__twist_x50",
            "MUNE1/transform26__gnull",
            "MUNE1/transform26__gnull/OPAI_R0",
        ]
        let assist = MotionAssist(joints: joints, rest: joints.map { _ in .identity })

        XCTAssertEqual(assist.count, 2)
    }

    func testNameWithoutItsReferenceIsSkipped() {
        let joints = ["MUNE1", "MUNE1/HIJI_R__rot_UDE_R__z50"]
        let assist = MotionAssist(joints: joints, rest: joints.map { _ in .identity })

        XCTAssertTrue(assist.isEmpty)
    }

    // MARK: - Fixed point

    func testRestPoseIsAFixedPointForEveryRule() {
        let joints = [
            "MUNE1",
            "MUNE1/KATA_R",
            "MUNE1/KATA_R/UDE_R",
            "MUNE1/KATA_R/TE_R",
            "MUNE1/KATA_R/HIJI_R__rot_UDE_R__z50",
            "MUNE1/KATA_R/UDE_R/UDE_MD_R__rot_TE_R__x50",
            "MUNE1/KATA_R/KATA_MD_R__twist_x50",
            "MUNE1/WAKI_R__slerp_KATA_R__i30_x0",
            "MUNE1/MUNE_R__const_KATA_R__rot_SAKOTSU_R__x0",
        ]
        // The chest bone must already point its −X at KATA_R, which sits to its
        // left; every other rest rotation is identity on this model.
        let rest: [String: JointPose] = [
            "MUNE1/KATA_R": JointPose(
                translation: SIMD3(-1, 0, 0), rotation: identity, scale: .one
            ),
        ]
        let output = simulate(joints: joints, rest: rest)

        for name in joints {
            let expected = rest[name] ?? .identity
            assertSame(output[name]?.rotation ?? .zero, expected.rotation, name)
            XCTAssertEqual(output[name]?.translation ?? .zero, expected.translation, name)
        }
    }

    // MARK: - Each algorithm's behaviour

    /// A fully weighted SLERP helper takes the reference's rotation over.
    func testSlerpReachesTheReferenceWhenFullyWeighted() {
        let helper = "MUNE1/WAKI_R__slerp_KATA_R__i100_x100"
        let output = simulate(
            joints: ["MUNE1", "MUNE1/KATA_R", helper],
            changes: ["MUNE1/KATA_R": JointPose(
                translation: .zero, rotation: quarterTurnZ, scale: .one
            )]
        )

        assertSame(output[helper]?.rotation ?? .zero, quarterTurnZ)
    }

    /// ROT only takes the twist about the reference's X axis; a swing of that
    /// axis leaves the helper at its rest rotation.
    func testRotIgnoresASwingAndTakesATwist() {
        let helper = "MUNE1/KATA_R/HIJI_R__rot_UDE_R__x100"
        let joints = ["MUNE1", "MUNE1/KATA_R", "MUNE1/KATA_R/UDE_R", helper]

        let swing = simulate(joints: joints, changes: [
            "MUNE1/KATA_R/UDE_R": JointPose(
                translation: .zero, rotation: quarterTurnZ, scale: .one
            ),
        ])
        assertSame(swing[helper]?.rotation ?? .zero, identity)

        let twist = simulate(joints: joints, changes: [
            "MUNE1/KATA_R/UDE_R": JointPose(
                translation: .zero, rotation: quarterTurnX, scale: .one
            ),
        ])
        assertSame(twist[helper]?.rotation ?? .zero, quarterTurnX)
    }

    /// TWIST is measured in the reference's frame, so a pure swing of the
    /// reference leaves the child at its rest rotation.
    func testTwistIsIdentityForASwing() {
        let helper = "MUNE1/KATA_R/KATA_MD_R__twist_x100"
        let output = simulate(
            joints: ["MUNE1", "MUNE1/KATA_R", helper],
            changes: ["MUNE1/KATA_R": JointPose(
                translation: .zero, rotation: quarterTurnZ, scale: .one
            )]
        )

        assertSame(output[helper]?.rotation ?? .zero, identity)
    }

    /// The chest constraint turns the helper until its −X points at KATA_R.
    func testConstrainTurnsTowardsTheReference() {
        let helper = "MUNE1/MUNE_R__const_KATA_R__rot_SAKOTSU_R__x0"
        let rest: [String: JointPose] = [
            "MUNE1/KATA_R": JointPose(
                translation: SIMD3(-1, 0, 0), rotation: identity, scale: .one
            ),
        ]
        let output = simulate(
            joints: ["MUNE1", "MUNE1/KATA_R", helper],
            rest: rest,
            changes: ["MUNE1/KATA_R": JointPose(
                translation: SIMD3(0, -1, 0), rotation: identity, scale: .one
            )]
        )

        // Rotating (-1, 0, 0) onto (0, -1, 0) is a quarter turn about Z.
        assertSame(output[helper]?.rotation ?? .zero, quarterTurnZ)
    }
}
