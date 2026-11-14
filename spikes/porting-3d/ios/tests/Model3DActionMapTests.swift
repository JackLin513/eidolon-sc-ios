import EidolonCore
import XCTest
@testable import Eidolon3DSpike

final class Model3DActionMapTests: XCTestCase {
    func testCalmStartsIdleWithMouthShut() {
        let action = Model3DActionMap.action(for: .calm)
        XCTAssertEqual(action.body, .idle)
        XCTAssertFalse(action.mouthOpen)
        XCTAssertEqual(action.mood, .calm)
    }

    func testSpeakingUsesTalkAndOpensMouth() {
        let direction = StandDirection(mood: .happy, speaking: true, looking: false, nod: nil)
        let action = Model3DActionMap.action(for: direction)
        XCTAssertEqual(action.body, .talk)
        XCTAssertTrue(action.mouthOpen)
        XCTAssertEqual(action.mood, .happy)
    }

    func testLookingUsesListen() {
        let direction = StandDirection(mood: .calm, speaking: false, looking: true, nod: nil)
        let action = Model3DActionMap.action(for: direction)
        XCTAssertEqual(action.body, .listen)
        XCTAssertFalse(action.mouthOpen)
    }

    func testNodsOverrideTheRestingBody() {
        let yes = StandDirection(mood: .shy, speaking: true, looking: true, nod: StandNod(kind: .yes, id: 1))
        let no = StandDirection(mood: .angry, speaking: false, looking: false, nod: StandNod(kind: .no, id: 2))
        XCTAssertEqual(Model3DActionMap.action(for: yes).body, .nodYes)
        XCTAssertEqual(Model3DActionMap.action(for: no).body, .nodNo)
        XCTAssertEqual(Model3DActionMap.action(for: yes).mood, .shy)
    }
}
