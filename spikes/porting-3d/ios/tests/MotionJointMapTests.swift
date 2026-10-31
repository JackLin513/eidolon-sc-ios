import XCTest

@testable import Eidolon3DSpike

final class MotionJointMapTests: XCTestCase {
    /// The shape RealityKit reports on a device: the skeleton's joints are
    /// named by their path from the root joint, and `MODEL_00`/`BASE` do not
    /// exist at all.
    private let joints = [
        "MUNE1",
        "MUNE1/MUNE2",
        "MUNE1/MUNE2/SAKOTSU_L",
        "MUNE1/MUNE2/SAKOTSU_L/KATA_L",
        "MUNE1/MUNE2/SAKOTSU_L/KATA_L/HIJI_L__rot_UDE_L__z50",
        "MUNE1/MUNE2/SAKOTSU_L/KATA_L/UDE_L",
        "KOSHI",
        "KOSHI/MOMO_L",
    ]

    private func resolve(_ paths: [String]) -> MotionJointMap {
        MotionJointMap.resolve(paths: paths, joints: joints)
    }

    /// The game's path starts above the skeleton root; the matching joint is
    /// the longest suffix that names one.
    func testGamePathBindsToTheJointOfItsLongestMatchingSuffix() {
        let map = resolve(["MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L"])

        XCTAssertEqual(map.bindings, [.init(bone: 0, joint: 2)])
        XCTAssertEqual(map.unmapped, [])
    }

    /// A root joint's name is the leaf of the game's path.
    func testRootJointBindsByItsLeaf() {
        let map = resolve(["MODEL_00/BODY_SCALE/BASE/KOSHI"])

        XCTAssertEqual(map.bindings, [.init(bone: 0, joint: 6)])
    }

    func testLeafIsTheLastResortWhenNoLongerSuffixMatches() {
        let map = resolve(["SOMEWHERE/ELSE/MUNE1"])

        XCTAssertEqual(map.bindings, [.init(bone: 0, joint: 0)])
    }

    /// Two of the dance's paths are root transforms the export dropped, so
    /// nothing in the skeleton answers to them.
    func testPathsWithNoJointAreReportedInDanceOrder() {
        let map = resolve([
            "MODEL_00/POSITION",
            "MODEL_00/BODY_SCALE/BASE/KOSHI",
            "POSITION/SCALE_POINT",
        ])

        XCTAssertEqual(map.bindings, [.init(bone: 1, joint: 6)])
        XCTAssertEqual(map.unmapped, ["MODEL_00/POSITION", "POSITION/SCALE_POINT"])
    }

    /// A shorter suffix also names a joint here; guessing the leaf first would
    /// drive the parent instead of the bone the dance meant.
    func testTheLongestSuffixWins() {
        let map = resolve(["MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2"])

        XCTAssertEqual(map.bindings, [.init(bone: 0, joint: 1)])
    }

    /// The character has mesh bones whose names extend an animation bone's; a
    /// full match must not let the longer name be missed.
    func testExtendedJointNamesStayDistinct() {
        let map = resolve([
            "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/HIJI_L",
            "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/HIJI_L__rot_UDE_L__z50",
        ])

        XCTAssertEqual(map.bindings, [.init(bone: 1, joint: 4)])
        XCTAssertEqual(map.unmapped, [
            "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L/KATA_L/HIJI_L",
        ])
    }

    /// A joint is bound once; a second path naming it is reported rather than
    /// silently fighting over the same bone.
    func testEachJointBindsAtMostOnce() {
        let path = "MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L"
        let map = resolve([path, path])

        XCTAssertEqual(map.bindings, [.init(bone: 0, joint: 2)])
        XCTAssertEqual(map.unmapped, [path])
    }

    func testEmptyDanceResolvesToNothing() {
        let map = resolve([])

        XCTAssertTrue(map.bindings.isEmpty)
        XCTAssertTrue(map.unmapped.isEmpty)
    }

    /// A joint whose name is a bare leaf hangs off the model space rather than
    /// a parent joint, which is the one thing playback has to treat specially.
    func testRootsAreTheJointsNamedByABareLeaf() {
        XCTAssertEqual(resolve([]).roots, [0, 6])
    }
}
