import XCTest
@testable import EidolonCore

/// The upstream animation table (`frontend/src/lib/standAnimations.test.ts`): which of an
/// outfit's animations show a direction on each of the player's five tracks, and the order
/// each fallback walks.
final class StandAnimatorTests: XCTestCase {
    // 镜像（shinycolors-spine）里真实衣装的动画名单，只取名字；口型另记时长，`lip_*_s` 的时长是 0。

    /// 真乃【ナチュラルモード】（stand/1030010010）：没有 face_serious、lip_wait、lip_shy、
    /// lip_surp，有 yes2/no2。
    private var mano: [String: Double] { outfit(
        "anger1 anger2 anger3 arm_down arm_down_R arm_down_surp arm_up_R blank eye_front eye_left eye_right face_anger face_anger2 face_close face_close2 face_cry face_sad face_shy face_smile face_smile2 face_smile3 face_surp face_wait hello no no2 sad1 sad2 shy1 shy2 skill1 smile1 smile2 smile3 surp1 surp2 think touch wait wait1 wait2 wait3 wait4 wait_return_L wait_return_R yes yes2",
        lips: [
            "lip_anger": 1.5, "lip_anger2": 1.5, "lip_anger_s": 0, "lip_anger_s2": 0,
            "lip_sad": 1.767, "lip_sad_s": 0, "lip_sad_s2": 0,
            "lip_smile": 1.5, "lip_smile2": 1.5, "lip_smile_s": 0, "lip_smile_s2": 0, "lip_smile_s3": 0,
            "lip_surp_s": 0, "lip_trouble": 1.5, "lip_trouble_s": 0,
        ]
    ) }

    /// 真乃【こころ、みちびく。ゆかり】（stand/3000010580）：没有 shy1/shy2、face_shy。
    private var manoNoShy: [String: Double] { outfit(
        "anger1 anger2 arm_down arm_down_R blank eye_front eye_left eye_right face_anger face_close face_close2 face_close3 face_close4 face_close5 face_cry face_sad face_smile face_smile2 face_smile3 face_surp face_wait no no2 sad1 smile1 smile2 surp1 think wait wait1 wait2 wait3 wait4 yes yes2",
        lips: [
            "lip_anger": 1.5, "lip_anger_s": 0, "lip_sad": 1.767, "lip_sad_s": 0,
            "lip_smile": 1.5, "lip_smile_s": 0, "lip_trouble": 1.5, "lip_trouble_s": 0,
        ]
    ) }

    /// 恋钟【ばってん長崎恋岬】（stand/1030040010）：没有 face_surp、lip_serious，有 lip_a；
    /// 没有 yes2/no2。
    private var kogane: [String: Double] { outfit(
        "anger1 anger2 arm_down arm_down_L arm_down_R arm_shy1 blank cheek_red eye_front eye_left eye_right face_anger face_close face_close2 face_cry face_doya face_sad face_serious face_shy face_shy2 face_smile face_wait no sad1 sad2 shy1 shy2 skill1 smile1 smile2 smile3 smile4 surp1 surp2 think touch wait wait1 wait2 wait3 wait4 wait5 yes",
        lips: [
            "lip_a": 10, "lip_anger": 1.567, "lip_sad": 1.567, "lip_sad_s": 0,
            "lip_shy": 1.567, "lip_smile": 1.567, "lip_smile_s": 0,
            "lip_surp": 1.567, "lip_surp_s": 0, "lip_wait": 1.567, "lip_wait_s": 0,
        ]
    ) }

    /// 恋钟（stand/3000040580）：没有 sad1/sad2。
    private var koganeNoSad: [String: Double] { outfit(
        "anger1 arm_down arm_down_L arm_down_R arm_shy1 blank eye_front eye_left eye_right face_anger face_close face_close2 face_close3 face_close4 face_cry face_doya face_sad face_shy face_smile face_surp face_wait no shy1 smile1 smile2 surp1 think wait wait1 wait2 wait3 wait4 wait5 yes",
        lips: [
            "lip_anger": 1.567, "lip_anger_s": 0, "lip_sad": 1.567, "lip_sad2": 1.567,
            "lip_sad_s": 0, "lip_shy": 1.567, "lip_smile": 1.567, "lip_smile_s": 0,
            "lip_surp": 1.567, "lip_surp_s": 0, "lip_wait": 1.567, "lip_wait_s": 0,
        ]
    ) }

    private func outfit(_ names: String, lips: [String: Double]) -> [String: Double] {
        var animations = Dictionary(
            uniqueKeysWithValues: names.split(separator: " ").map { (String($0), 1.0) }
        )
        animations.merge(lips) { _, new in new }
        return animations
    }

    /// 从一套真实衣装里去掉几个动画，走到替代链更靠后的一级。
    private func without(_ animations: [String: Double], _ names: String...) -> [String: Double] {
        animations.filter { !names.contains($0.key) }
    }

    private func direction(
        mood: StandEmotion = .calm,
        speaking: Bool = false,
        looking: Bool = false,
        nod: StandNod? = nil
    ) -> StandDirection {
        StandDirection(mood: mood, speaking: speaking, looking: looking, nod: nod)
    }

    private func pick(
        _ animations: [String: Double],
        mood: StandEmotion = .calm,
        speaking: Bool = false,
        looking: Bool = false,
        nod: StandNod? = nil,
        reducedMotion: Bool = false
    ) -> StandPose {
        StandAnimator.pose(
            for: direction(mood: mood, speaking: speaking, looking: looking, nod: nod),
            reducedMotion: reducedMotion,
            animations: animations
        )
    }

    // MARK: - 身体、表情和口型

    /// 上游 `it.each`：恋钟【ばってん長崎恋岬】每种情绪的身体、表情与说话口型。
    func testEachEmotionPicksItsBodyFaceAndMouth() {
        let cases: [(StandEmotion, String, String, String)] = [
            (.calm, "wait", "face_wait", "lip_wait"),
            (.happy, "smile1", "face_smile", "lip_smile"),
            (.shy, "shy1", "face_shy", "lip_shy"),
            (.surprised, "surp1", "blank", "lip_surp"),  // 这套没有 face_surp
            (.sad, "sad1", "face_sad", "lip_sad"),
            (.angry, "anger1", "face_anger", "lip_anger"),
            (.thinking, "think", "face_serious", "lip_smile"),  // 没有 lip_serious
        ]
        for (mood, body, face, mouth) in cases {
            let pose = pick(kogane, mood: mood, speaking: true)
            XCTAssertEqual(pose.body, body, "\(mood) 的身体")
            XCTAssertEqual(pose.face, face, "\(mood) 的表情")
            XCTAssertEqual(pose.mouth, StandPose.Mouth(name: mouth, open: true), "\(mood) 的口型")
        }
    }

    func testShyFallsBackToSmile2AndBlank() {
        // 害羞缺 shy1、shy2 时用 smile2，缺 face_shy 时用 blank。
        let pose = pick(manoNoShy, mood: .shy)
        XCTAssertEqual(pose.body, "smile2")
        XCTAssertEqual(pose.face, "blank")
    }

    func testSadWithoutABodyAnimationWalksToWait() {
        // 难过找不到身体动作时用 wait。
        let pose = pick(koganeNoSad, mood: .sad)
        XCTAssertEqual(pose.body, "wait")
        XCTAssertEqual(pose.face, "face_sad")
    }

    func testHappyWalksSmile1ToSmile2AndFaceSmileToFaceSmile2() {
        // 逐级往后找：开心 smile1 → smile2，表情 face_smile → face_smile2。
        let pose = pick(without(mano, "smile1", "face_smile"), mood: .happy)
        XCTAssertEqual(pose.body, "smile2")
        XCTAssertEqual(pose.face, "face_smile2")
    }

    func testSurprisedAndAngryWalkToTheirSecondAnimation() {
        // 惊讶 surp1 → surp2，生气 anger1 → anger2、face_anger → face_anger2。
        let trimmed = without(mano, "surp1", "anger1", "face_anger")
        XCTAssertEqual(pick(trimmed, mood: .surprised).body, "surp2")
        XCTAssertEqual(pick(trimmed, mood: .surprised).face, "face_surp")
        XCTAssertEqual(pick(trimmed, mood: .angry).body, "anger2")
        XCTAssertEqual(pick(trimmed, mood: .angry).face, "face_anger2")
    }

    func testShyWalksShy1ToShy2AndFaceShyToFaceShy2() {
        // 害羞 shy1 → shy2，表情 face_shy → face_shy2。
        let pose = pick(without(kogane, "shy1", "face_shy"), mood: .shy)
        XCTAssertEqual(pose.body, "shy2")
        XCTAssertEqual(pose.face, "face_shy2")
    }

    func testThinkingWalksThinkToWait4ThenWait() {
        // 思考没有 think 时依次找 wait4、wait。
        XCTAssertEqual(pick(without(kogane, "think"), mood: .thinking).body, "wait4")
        XCTAssertEqual(pick(without(kogane, "think", "wait4"), mood: .thinking).body, "wait")
    }

    func testReducedMotionKeepsTheBodyStillAndTheRestPlaying() {
        // 减少动态效果时，身体一律用 wait，表情、口型和点头照常。
        XCTAssertEqual(pick(kogane, mood: .angry, reducedMotion: true).body, "wait")
        XCTAssertEqual(pick(kogane, mood: .angry, reducedMotion: true).face, "face_anger")
        XCTAssertEqual(pick(mano, mood: .happy, reducedMotion: true).body, "wait")
        XCTAssertEqual(pick(mano, mood: .happy, reducedMotion: true).face, "face_smile")
        XCTAssertEqual(
            pick(kogane, mood: .sad, speaking: true, reducedMotion: true).mouth,
            StandPose.Mouth(name: "lip_sad", open: true)
        )
        XCTAssertEqual(
            pick(mano, nod: StandNod(kind: .yes, id: 1), reducedMotion: true).nod,
            StandPose.Nod(name: "yes", id: 1)
        )
    }

    // MARK: - 口型

    func testAnEmotionWithoutItsMouthFallsBackToLipSmile() {
        // 找不到这种情绪的口型时退到 lip_smile：真乃没有 lip_wait、lip_shy、lip_surp。
        for mood in [StandEmotion.calm, .shy, .surprised] {
            XCTAssertEqual(
                pick(mano, mood: mood, speaking: true).mouth?.name,
                "lip_smile",
                "\(mood) 的口型"
            )
        }
    }

    func testAnEmotionFallsBackToLipK1AndLipK2() {
        // 找 lip_<k>1、lip_<k>2。
        let pose = pick(without(koganeNoSad, "lip_sad"), mood: .sad, speaking: true)
        XCTAssertEqual(pose.mouth?.name, "lip_sad2")
    }

    func testAMissingLipSmileFallsBackToLipWait() {
        // lip_smile 也没有时用 lip_wait。
        let pose = pick(without(kogane, "lip_anger", "lip_smile"), mood: .angry, speaking: true)
        XCTAssertEqual(pose.mouth?.name, "lip_wait")
    }

    func testOtherwiseAnyMovingMouthButNotStillsOrLipA() {
        // 再找不到就用任意一个时长不为 0 的口型，不用 lip_*_s 和 lip_a。
        let trimmed = without(mano, "lip_smile", "lip_smile2")
        let name = pick(trimmed, mood: .calm, speaking: true).mouth?.name
        XCTAssertNotNil(name)
        XCTAssertTrue(
            ["lip_anger", "lip_anger2", "lip_sad", "lip_trouble"].contains(name ?? ""),
            "实际用了 \(name ?? "nil")"
        )

        let onlyStops = without(
            kogane, "lip_anger", "lip_sad", "lip_shy", "lip_smile", "lip_surp", "lip_wait"
        )
        XCTAssertNil(pick(onlyStops, mood: .calm, speaking: true).mouth)
    }

    func testAShutMouthIsTheSameTalkingMouthHeldClosed() {
        // 闭嘴时用同一个说话口型，只是不开。
        XCTAssertEqual(
            pick(kogane, mood: .happy, speaking: false).mouth,
            StandPose.Mouth(name: "lip_smile", open: false)
        )
    }

    // MARK: - 点头和视线

    func testNodUsesYesOrNoWithItsIdAndEmptiesTheTrackWithoutOne() {
        // 点头用 yes，摇头用 no，带上这次的编号；没有点头时这条轨道什么都不放。
        XCTAssertEqual(
            pick(mano, nod: StandNod(kind: .yes, id: 3)).nod,
            StandPose.Nod(name: "yes", id: 3)
        )
        XCTAssertEqual(
            pick(kogane, nod: StandNod(kind: .no, id: 4)).nod,
            StandPose.Nod(name: "no", id: 4)
        )
        XCTAssertNil(pick(mano).nod)
    }

    func testAMissingYesOrNoFallsBackToYes2OrNo2() {
        // 没有 yes、no 时用 yes2、no2，都没有就不点。
        let trimmed = without(mano, "yes", "no")
        XCTAssertEqual(
            pick(trimmed, nod: StandNod(kind: .yes, id: 1)).nod,
            StandPose.Nod(name: "yes2", id: 1)
        )
        XCTAssertEqual(
            pick(trimmed, nod: StandNod(kind: .no, id: 2)).nod,
            StandPose.Nod(name: "no2", id: 2)
        )
        XCTAssertNil(pick(without(kogane, "no"), nod: StandNod(kind: .no, id: 5)).nod)
    }

    func testGazeUsesEyeFrontOnlyWhenLookingAndTheOutfitHasIt() {
        // 看向用户时用 eye_front，不看时清空。
        XCTAssertEqual(pick(kogane, looking: true).eye, "eye_front")
        XCTAssertNil(pick(kogane, looking: false).eye)
        XCTAssertNil(pick(without(kogane, "eye_front"), looking: true).eye)
    }
}
