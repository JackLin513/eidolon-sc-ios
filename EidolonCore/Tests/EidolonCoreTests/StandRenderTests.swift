import Foundation
import XCTest
@testable import EidolonCore

/// The parts of drawing her that are not the WebView itself: where the camera sits
/// (the upstream `StandEngine.aim`), which files the player may fetch, and what a
/// stand pose looks like on the wire.
final class StandRenderTests: XCTestCase {
    // MARK: - Framing

    private let bounds = StandBounds(x: 0, y: 0, width: 100, height: 400)

    func testCompactWidthFramesDownToTheKnees() {
        XCTAssertEqual(StandFraming(compactWidth: true), .knees)
    }

    func testRegularWidthFramesDownToTheWaist() {
        XCTAssertEqual(StandFraming(compactWidth: false), .waist)
    }

    func testKneesCameraHangsFromHerHead() {
        let camera = StandFraming.knees.camera(bounds: bounds, aspect: 0.5)

        XCTAssertEqual(camera.x, 50, accuracy: 1e-9)
        XCTAssertEqual(camera.y, 242, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportWidth, 170, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportHeight, 340, accuracy: 1e-9)
    }

    func testWaistCameraHangsFromHerHead() {
        let camera = StandFraming.waist.camera(bounds: bounds, aspect: 0.5)

        XCTAssertEqual(camera.x, 50, accuracy: 1e-9)
        XCTAssertEqual(camera.y, 280, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportWidth, 132, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportHeight, 264, accuracy: 1e-9)
    }

    func testNarrowAspectKeepsAtLeastMostOfHerWidth() {
        // A wide body on a wide screen: the width floor wins over the height.
        let wide = StandBounds(x: 10, y: 20, width: 200, height: 10)
        let camera = StandFraming.knees.camera(bounds: wide, aspect: 2)

        XCTAssertEqual(camera.x, 110, accuracy: 1e-9)
        XCTAssertEqual(camera.y, -4.7, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportWidth, 140, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportHeight, 70, accuracy: 1e-9)
    }

    func testFullFramingCentresHerWholeBody() {
        let camera = StandFraming.full.camera(bounds: bounds, aspect: 0.5)

        XCTAssertEqual(camera.x, 50, accuracy: 1e-9)
        XCTAssertEqual(camera.y, 200, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportWidth, 212, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportHeight, 424, accuracy: 1e-9)
    }

    func testFullFramingFitsHerWidthOnAWideScreen() {
        let camera = StandFraming.full.camera(bounds: bounds, aspect: 2)

        XCTAssertEqual(camera.x, 50, accuracy: 1e-9)
        XCTAssertEqual(camera.y, 200, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportWidth, 848, accuracy: 1e-9)
        XCTAssertEqual(camera.viewportHeight, 424, accuracy: 1e-9)
    }

    // MARK: - Which files the player may fetch

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCoreStandAssets-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Content/current", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent().deletingLastPathComponent())
    }

    func testOutfitUnderContentBecomesABundlePath() throws {
        let directory = root.appendingPathComponent("stand/idols/stand/1030010010")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertEqual(
            StandAssets.relativeDirectory(of: directory, under: root),
            "stand/idols/stand/1030010010/"
        )
    }

    func testOutfitOutsideContentHasNoPath() {
        let outside = root.deletingLastPathComponent().appendingPathComponent("elsewhere")
        XCTAssertNil(StandAssets.relativeDirectory(of: outside, under: root))
    }

    func testSiblingDirectorySharingThePrefixIsOutside() {
        let sibling = URL(fileURLWithPath: root.path + "-other").appendingPathComponent("stand")
        XCTAssertNil(StandAssets.relativeDirectory(of: sibling, under: root))
    }

    func testContentRootItselfIsNotAnOutfit() {
        XCTAssertNil(StandAssets.relativeDirectory(of: root, under: root))
    }

    func testRequestPathResolvesInsideTheContent() throws {
        let file = root.appendingPathComponent("stand/idols/stand/1030010010/data.json")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: file)

        let found = StandAssets.file(at: "/stand/idols/stand/1030010010/data.json", under: root)
        XCTAssertEqual(found?.path, file.path)
    }

    func testPercentEncodedNamesResolve() throws {
        let file = root.appendingPathComponent("stand/a b/data.png")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: file)

        XCTAssertEqual(
            StandAssets.file(at: "/stand/a%20b/data.png", under: root)?.path,
            file.path
        )
    }

    func testParentTraversalIsRejected() {
        XCTAssertNil(StandAssets.file(at: "/stand/../../secret", under: root))
        XCTAssertNil(StandAssets.file(at: "/../secret", under: root))
    }

    func testPercentEncodedParentTraversalIsRejected() {
        XCTAssertNil(StandAssets.file(at: "/stand/%2e%2e/%2e%2e/secret", under: root))
    }

    func testPathsMustBeAbsolute() {
        XCTAssertNil(StandAssets.file(at: "stand/idols/data.json", under: root))
    }

    func testTheContentRootIsNotAFile() {
        XCTAssertNil(StandAssets.file(at: "/", under: root))
    }

    func testSymlinkOutOfContentIsRejected() throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret"))
        let link = root.appendingPathComponent("stand/link")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(StandAssets.file(at: "/stand/link/secret", under: root))
    }

    // MARK: - What the player is told

    func testCalmPoseEncodesWhatThePlayerPlays() throws {
        let json = try XCTUnwrap(String(data: StandPose.calm.json(), encoding: .utf8))
        XCTAssertEqual(json, #"{"body":"wait","face":"face_wait"}"#)
    }

    func testPoseCarriesTheMouthAndNod() throws {
        let pose = StandPose(
            body: "smile1",
            face: "face_smile",
            mouth: .init(name: "lip_smile", open: true),
            eye: "eye_front",
            nod: .init(name: "yes", id: 3)
        )
        let json = try XCTUnwrap(String(data: pose.json(), encoding: .utf8))
        XCTAssertEqual(
            json,
            #"{"body":"smile1","eye":"eye_front","face":"face_smile","mouth":{"name":"lip_smile","open":true},"nod":{"id":3,"name":"yes"}}"#
        )
    }

    func testCalmDirectionIsHowACallStarts() {
        XCTAssertEqual(StandDirection.calm, StandDirection(mood: .calm, speaking: false, looking: false, nod: nil))
    }
}
