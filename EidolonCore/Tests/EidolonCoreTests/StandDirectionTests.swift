import XCTest
@testable import EidolonCore

/// Her stand direction through a call (the upstream `standDirection.test.ts`): a string of
/// call events in, a `StandDirection` out. The text-only, `line-shown` and `typed` branches
/// are not ported (spec「端上引擎」), so the tests about them are gone; the rest follow the
/// upstream cases one for one.
final class StandDirectionTests: XCTestCase {
    /// The stand after these events in a call, from its start.
    private func after(_ events: [StandEvent]) -> StandDirector {
        var director = StandDirector()
        for event in events { director.apply(event) }
        return director
    }

    /// How she looks after these events in a call, from its start.
    private func direction(_ events: [StandEvent]) -> StandDirection {
        after(events).direction
    }

    /// The judged emotion of segment `segment` of reply `reply`, with a nod if given.
    private func judged(
        _ reply: Int,
        _ segment: Int,
        _ emotion: StandEmotion,
        nod: StandNod.Kind? = nil
    ) -> StandEvent {
        .segmentJudged(
            StandJudgement(
                segment: StandSegment(reply: reply, segment: segment),
                emotion: emotion,
                nod: nod
            )
        )
    }

    private func playing(_ reply: Int, _ segment: Int) -> StandEvent {
        .segmentStarted(StandSegment(reply: reply, segment: segment))
    }

    private let botStarted = StandEvent.botStartedSpeaking
    private let botStopped = StandEvent.botStoppedSpeaking
    private let userStarted = StandEvent.userStartedSpeaking
    private let userStopped = StandEvent.userStoppedSpeaking
    private let callOver = StandEvent.callOver

    // MARK: - 谁在说话

    func testStartsEachCallCalmLookingAheadWithHerMouthShut() {
        // 上游第一条：通话开始时平静、看着前方、嘴闭着。
        XCTAssertEqual(direction([]), .calm)
    }

    func testOpensHerMouthWhileHerVoicePlaysAndShutsItWhenItStops() {
        // 她的声音在播时张嘴，停下就闭嘴。
        XCTAssertTrue(direction([botStarted]).speaking)
        XCTAssertFalse(direction([botStarted, botStopped]).speaking)
    }

    func testLooksAtTheUserWhileTheySpeakThenNodsOnceWhenTheyStop() {
        // 我说话时她看镜头，我说完点一次头。
        XCTAssertTrue(direction([userStarted]).looking)
        XCTAssertNil(direction([userStarted]).nod)

        let first = direction([userStarted, userStopped])
        XCTAssertFalse(first.looking)
        XCTAssertEqual(first.nod?.kind, .yes)

        let second = direction([userStarted, userStopped, userStarted, userStopped])
        XCTAssertEqual(second.nod?.kind, .yes)
        XCTAssertNotEqual(second.nod?.id, first.nod?.id)
    }

    func testKeepsNoddingWithNewIdsOnceTheCallIsOver() {
        // 上一通挂断后忘掉一切（包括刚点过的头），但点头次数接着数。
        let nodded = after([userStarted, userStopped])
        let over = after([userStarted, userStopped, callOver])
        XCTAssertEqual(over.direction, .calm)

        var next = over
        next.apply(userStarted)
        next.apply(userStopped)
        XCTAssertEqual(next.direction.nod?.kind, .yes)
        XCTAssertNotEqual(next.direction.nod?.id, nodded.direction.nod?.id)
    }

    func testForgetsAllOfTheLastCallWhenItIsOver() {
        // 挂断后忘掉谁在说话、我刚才开过口、她的情绪，回到初始。
        let speaking = [botStarted, userStarted, userStopped, userStarted]
        XCTAssertEqual(direction(speaking + [callOver]), .calm)

        let events = [playing(1, 0), judged(1, 0, .happy), botStarted]
        XCTAssertEqual(direction(events).mood, .happy)
        XCTAssertEqual(direction(events + [callOver]), .calm)
        XCTAssertEqual(direction(events + [callOver, playing(1, 0)]).mood, .calm)
    }

    func testGivesTheSameDirectionWhileNothingAboutItChanges() {
        // 上游用 `toBe` 担保「没变就还是同一个对象」；Swift 的值类型按值比较，同样的
        // 方向就是相等的方向。
        let before = after([userStarted, playing(1, 0), botStarted, judged(1, 0, .happy)])
        let unchanged: [StandEvent] = [
            userStarted,
            botStarted,
            judged(0, 0, .sad),  // 上一条回复的，丢掉
            judged(1, 0, .happy),  // 正在说这一段，再判一次同样的
        ]

        for event in unchanged {
            var next = before
            next.apply(event)
            XCTAssertEqual(next.direction, before.direction, "\(event) 不该改变她的样子")
        }
    }

    // MARK: - 她的情绪

    func testChangesAsHerVoiceStartsPlayingTheSegmentNotBefore() {
        // 判断结果先到，声音开始播这一段时才换表情。
        let judgedSegment = [judged(1, 0, .happy)]
        XCTAssertEqual(direction(judgedSegment).mood, .calm)
        XCTAssertEqual(direction(judgedSegment + [playing(1, 0)]).mood, .happy)
    }

    func testChangesOnALateEmotionWhileTheSegmentIsStillPlaying() {
        // 正在说这一段时，判断结果晚到也当场换上。
        XCTAssertEqual(
            direction([playing(1, 0), botStarted, judged(1, 0, .sad)]).mood,
            .sad
        )
    }

    func testDropsAnEmotionThatComesOnceTheSegmentHasBeenSaid() {
        // 这一段已经过了：晚到的判断丢掉，不往前跳。
        let said = [playing(1, 0), botStarted, playing(1, 1)]
        XCTAssertEqual(direction(said + [judged(1, 0, .sad)]).mood, .calm)
        XCTAssertEqual(
            direction(said + [judged(1, 0, .sad), botStopped, judged(1, 1, .angry)]).mood,
            .calm
        )
    }

    func testDropsAnEmotionThatComesOnceTheNextTurnWasTakenUp() {
        // 下一条回复已经开演，上一条的判断结果丢掉。
        XCTAssertEqual(
            direction([playing(1, 0), playing(2, 0), judged(1, 0, .sad)]).mood,
            .calm
        )
    }

    func testKeepsAnEmotionForASegmentWhoseVoiceStartsRightAfterTheLastOneStopped() {
        // 她的声音刚停，下一段的消息就到了，又马上开始播：判断仍然作数。
        let said = [playing(1, 0), botStarted, playing(1, 1)]
        XCTAssertEqual(
            direction(said + [botStopped, botStarted, judged(1, 1, .shy)]).mood,
            .shy
        )
    }

    func testKeepsHerMoodThroughCalmSegmentsUntilAReplyStartsCalm() {
        // 平静不覆盖上一段的情绪，除非这一段是她这条回复的开头。
        let first = [
            playing(1, 0), judged(1, 0, .happy), judged(1, 1, .calm),
            playing(1, 1),
        ]
        XCTAssertEqual(direction(first).mood, .happy)

        XCTAssertEqual(
            direction(first + [judged(2, 0, .calm), playing(2, 0)]).mood,
            .calm
        )
    }

    func testNodsOrShakesHerHeadAlongWithTheEmotionOnceEach() {
        // 点头 / 摇头跟着情绪一起生效，各算一次。
        let judgedSegments = [judged(1, 0, .happy, nod: .yes), judged(1, 1, .calm, nod: .no)]
        XCTAssertNil(direction(judgedSegments).nod)

        let nod = direction(judgedSegments + [playing(1, 0)]).nod
        XCTAssertEqual(nod?.kind, .yes)
        let shake = direction(judgedSegments + [playing(1, 0), playing(1, 1)]).nod
        XCTAssertEqual(shake?.kind, .no)
        XCTAssertNotEqual(shake?.id, nod?.id)
    }

    func testGivesAnEmotionsNodAnIdPastTheUsersNods() {
        // 配合情绪的点头，编号排在我点头之后。
        let user = direction([userStarted, userStopped]).nod
        let own = direction([
            userStarted, userStopped, playing(1, 0), judged(1, 0, .happy, nod: .yes),
        ]).nod

        XCTAssertNotNil(user)
        XCTAssertNotNil(own)
        XCTAssertNotEqual(own?.id, user?.id)
    }

    func testKeepsAnEmotionOnlyForTheReplyItWasJudgedIn() {
        // 判断结果属于那条回复；那条回复被下一条取代后，它就作废。
        XCTAssertEqual(
            direction([judged(1, 1, .sad), playing(2, 0), playing(2, 1)]).mood,
            .calm
        )
    }

    func testDoesNotGoBackToASegmentSheIsPast() {
        // 已经过了的段：迟到的判断不会让她跳回去。
        let past = [playing(1, 1), playing(1, 0), judged(1, 0, .sad)]
        XCTAssertEqual(direction(past).mood, .calm)
    }

    func testLeavesHerMoodAloneWhenSheIsInterruptedAndLooksAtTheUser() {
        // 被打断：情绪不变，声音一停就闭嘴，看镜头。
        let events = [playing(1, 0), judged(1, 0, .happy), botStarted]
        let interrupted = direction(events + [userStarted, botStopped, judged(1, 1, .sad)])
        XCTAssertEqual(interrupted.mood, .happy)
        XCTAssertFalse(interrupted.speaking)
        XCTAssertTrue(interrupted.looking)
    }
}
