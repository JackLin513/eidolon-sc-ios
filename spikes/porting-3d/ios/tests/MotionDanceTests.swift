import XCTest

@testable import Eidolon3DSpike

final class MotionDanceTests: XCTestCase {
    /// One bone, three frames: AngleX constant at 0, AngleY animated
    /// (100, 150, 100 hundredths of a degree), AngleZ constant at 9 degrees,
    /// PositionX animated (0, 8, 16 quarter-millimetres).
    private let fixture = """
    {"format":"eidolon.motion/1","fps":30,"frames":3,"time_length":0.0666667,
     "angle_scale":100,"position_scale":4000,
     "bones":[{"path":"MODEL_00/HIPS",
               "rot":[0,[100,50,-50],900],
               "pos":[[0,8,8],1000,0]}]}
    """

    private func decode(_ json: String) throws -> MotionDance {
        try JSONDecoder().decode(MotionDance.self, from: Data(json.utf8))
    }

    // MARK: - Format

    func testDecodesTheHeaderAndOneBone() throws {
        let dance = try decode(fixture)

        XCTAssertEqual(dance.formatName, MotionDance.format)
        XCTAssertEqual(dance.fps, 30)
        XCTAssertEqual(dance.frames, 3)
        XCTAssertEqual(dance.timeLength, 0.0666667, accuracy: 1e-9)
        XCTAssertEqual(dance.angleScale, 100)
        XCTAssertEqual(dance.positionScale, 4000)
        XCTAssertEqual(dance.bones.map(\.path), ["MODEL_00/HIPS"])
    }

    func testScalarChannelsDecodeAsConstants() throws {
        let bone = try decode(fixture).bones[0]

        XCTAssertEqual(bone.rot[0], .constant(0))
        XCTAssertEqual(bone.rot[2], .constant(900))
        XCTAssertEqual(bone.rot[1], .deltas([100, 50, -50]))
    }

    func testBoneWithoutPositionsDecodesWithNilPos() throws {
        let json = """
        {"format":"eidolon.motion/1","fps":30,"frames":1,"time_length":0,
         "angle_scale":100,"position_scale":4000,
         "bones":[{"path":"MODEL_00/HIPS","rot":[1,2,3]}]}
        """

        let bone = try decode(json).bones[0]

        XCTAssertNil(bone.pos)
    }

    // MARK: - Channels

    func testDeltaChannelSumsBackToEveryFrame() throws {
        let channel = try decode(fixture).bones[0].rot[1]

        XCTAssertEqual((0...2).map { channel.value(at: $0) }, [100, 150, 100])
    }

    func testDeltaChannelClampsOutsideTheEncodedRange() throws {
        let channel = try decode(fixture).bones[0].rot[1]

        XCTAssertEqual(channel.value(at: -1), 100)
        XCTAssertEqual(channel.value(at: 99), 100)
    }

    func testExpandedPadsWithTheLastValue() {
        let channel = MotionChannel.deltas([100, 50, -50])

        XCTAssertEqual(channel.expanded(frames: 5), [100, 150, 100, 100, 100])
        XCTAssertEqual(MotionChannel.constant(7).expanded(frames: 2), [7, 7])
    }

    func testEmptyDeltaChannelReadsAsZero() throws {
        let json = """
        {"format":"eidolon.motion/1","fps":30,"frames":1,"time_length":0,
         "angle_scale":100,"position_scale":4000,
         "bones":[{"path":"A","rot":[[],0,0]}]}
        """

        let bone = try decode(json).bones[0]

        XCTAssertEqual(bone.rot[0], .deltas([]))
        XCTAssertEqual(bone.rot[0].value(at: 0), 0)
        XCTAssertEqual(bone.rot[0].expanded(frames: 2), [0, 0])
    }

    // MARK: - Values

    func testFrameIndexFloorsAndClampsToTheDance() throws {
        let dance = try decode(fixture)

        XCTAssertEqual(dance.frame(at: -1), 0)
        XCTAssertEqual(dance.frame(at: 0.1), 2)
        XCTAssertEqual(dance.frame(at: 99), 2)
    }

    func testRotationDegreesDivideByTheAngleScale() throws {
        let dance = try decode(fixture)
        let bone = dance.bones[0]

        XCTAssertEqual(dance.rotationDegrees(of: bone, at: 0)!, SIMD3(0, 1, 9))
        XCTAssertEqual(dance.rotationDegrees(of: bone, at: 1)!, SIMD3(0, 1.5, 9))
        XCTAssertEqual(dance.rotationDegrees(of: bone, at: 2)!, SIMD3(0, 1, 9))
    }

    func testPositionDividesByThePositionScale() throws {
        let dance = try decode(fixture)
        let bone = dance.bones[0]

        XCTAssertEqual(dance.position(of: bone, at: 0)!, SIMD3(0, 0.25, 0))
        XCTAssertEqual(dance.position(of: bone, at: 1)!, SIMD3(0.002, 0.25, 0))
    }

    func testPositionIsNilWhenTheDanceHasNoPositionCurves() throws {
        let json = """
        {"format":"eidolon.motion/1","fps":30,"frames":1,"time_length":0,
         "angle_scale":100,"position_scale":4000,
         "bones":[{"path":"A","rot":[0,0,0]}]}
        """

        let dance = try decode(json)

        XCTAssertNil(dance.position(of: dance.bones[0], at: 0))
    }

    // MARK: - Euler conversion

    func testZeroDegreesIsTheIdentityQuaternion() {
        assertQuaternion(
            UnityEuler.quaternion(SIMD3(0, 0, 0)),
            SIMD4(0, 0, 0, 1)
        )
    }

    func testNinetyDegreesAboutX() {
        // Single-axis rotations do not depend on the Euler order.
        assertQuaternion(
            UnityEuler.quaternion(SIMD3(90, 0, 0)),
            SIMD4(0.7071068, 0, 0, 0.7071068)
        )
    }

    func testZIsAppliedBeforeX() {
        // Unity applies z, then x, then y, so the quaternion is qY * qX * qZ.
        // For x = z = 90 this is (0.5, -0.5, 0.5, 0.5); it sends +X to +Z,
        // which is what rotating 90 about z and then 90 about x does.
        assertQuaternion(
            UnityEuler.quaternion(SIMD3(90, 0, 90)),
            SIMD4(0.5, -0.5, 0.5, 0.5)
        )
    }

    // MARK: - Single bone, single frame

    /// The acceptance test for #27: one bone, one frame, compared with numbers
    /// worked out by hand — 90° about X at frame 1 becomes
    /// (sin 45°, 0, 0, cos 45°).
    func testOneBoneOneFrameAgainstHandComputedNumbers() throws {
        let json = """
        {"format":"eidolon.motion/1","fps":30,"frames":2,"time_length":0.0333333,
         "angle_scale":100,"position_scale":4000,
         "bones":[{"path":"MODEL_00/HIPS","rot":[[0,9000],0,0]}]}
        """

        let dance = try decode(json)
        let bone = dance.bones[0]

        XCTAssertEqual(dance.rotationDegrees(of: bone, at: 1), SIMD3(90, 0, 0))
        assertQuaternion(
            UnityEuler.quaternion(dance.rotationDegrees(of: bone, at: 1)!),
            SIMD4(0.7071068, 0, 0, 0.7071068),
            accuracy: 1e-6
        )
    }

    private func assertQuaternion(
        _ actual: SIMD4<Float>,
        _ expected: SIMD4<Float>,
        accuracy: Float = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for axis in 0..<4 {
            XCTAssertEqual(
                actual[axis], expected[axis], accuracy: accuracy,
                "component \(axis) of \(actual) != \(expected)", file: file, line: line
            )
        }
    }
}
