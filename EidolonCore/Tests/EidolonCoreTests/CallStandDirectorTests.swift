import XCTest
@testable import EidolonCore

/// The call's events driving her stand (spec「通话事件」「立绘指令」): a string of
/// `CallEvent`s in, a `StandDirection` out. The rules themselves are `StandDirector`'s,
/// ported from upstream and tested there; what is tested here is the translation — which
/// call event means her mouth is moving, which means the producer is speaking, and that
/// the end of the call is forgotten.
final class CallStandDirectorTests: XCTestCase {
    /// Her stand after these events in a call, from its start.
    private func after(_ events: [CallEvent]) -> CallStandDirector {
        var stand = CallStandDirector()
        for event in events { stand.apply(event) }
        return stand
    }

    private func started(_ reply: Int, _ segment: Int) -> CallEvent {
        .segmentStarted(reply: reply, segment: segment)
    }

    private func stopped(_ reply: Int, _ segment: Int) -> CallEvent {
        .segmentStopped(reply: reply, segment: segment)
    }

    private func judged(
        _ reply: Int,
        _ segment: Int,
        _ emotion: StandEmotion
    ) -> StandEvent {
        .segmentJudged(
            StandJudgement(
                segment: StandSegment(reply: reply, segment: segment),
                emotion: emotion
            )
        )
    }

    // MARK: - Her voice

    func testHerMouthMovesWhileASegmentPlaysAndShutsWhenItStops() {
        XCTAssertFalse(after([]).direction.speaking)
        XCTAssertTrue(after([started(0, 0)]).direction.speaking)
        XCTAssertFalse(after([started(0, 0), stopped(0, 0)]).direction.speaking)
    }

    func testSheSaysTheSegmentItsVoiceStarted() {
        // The emotion of the segment her voice starts playing is taken up at once.
        var stand = CallStandDirector()
        stand.director.apply(judged(0, 1, .happy))
        stand.apply(started(0, 1))
        XCTAssertEqual(stand.direction.mood, .happy)
    }

    /// A segment behind the one she is saying moves nothing: the call's events can arrive
    /// late, and her mood must not jump back (spec「测试决策」).
    func testASegmentBehindTheOneSheIsSayingDoesNotMoveHerBack() {
        var stand = CallStandDirector()
        stand.director.apply(judged(0, 1, .happy))
        stand.apply(started(0, 1))
        stand.apply(started(0, 0))
        XCTAssertEqual(stand.direction.mood, .happy)
        XCTAssertTrue(stand.direction.speaking)
    }

    /// The emotion judged for the segment she is saying moves her mood and nod at once; one
    /// judged for a later segment waits until she says it (spec「情绪判断」).
    func testAJudgedEmotionReachesHerStand() {
        var stand = CallStandDirector()
        stand.apply(started(0, 0))
        stand.apply(.emotion(reply: 0, segment: 0, emotion: .happy, nod: .yes))
        XCTAssertEqual(stand.direction.mood, .happy)
        XCTAssertEqual(stand.direction.nod?.kind, .yes)

        var later = CallStandDirector()
        later.apply(started(0, 0))
        later.apply(.emotion(reply: 0, segment: 1, emotion: .sad, nod: .no))
        XCTAssertEqual(later.direction.mood, .calm, "not said yet")
        XCTAssertNil(later.direction.nod)
        later.apply(started(0, 1))
        XCTAssertEqual(later.direction.mood, .sad)
        XCTAssertEqual(later.direction.nod?.kind, .no)
    }

    // MARK: - The producer

    func testSheLooksAtTheProducerWhileTheySpeakAndNodsOnceWhenTheHearingClears() {
        let speaking = after([.hearing("こんにちは")])
        XCTAssertTrue(speaking.direction.looking)
        XCTAssertNil(speaking.direction.nod)

        let finished = after([.hearing("こんにちは"), .hearing("")])
        XCTAssertFalse(finished.direction.looking)
        XCTAssertEqual(finished.direction.nod?.kind, .yes)

        // The turn starting afterwards does not make her nod again for the same words.
        let recognized = after([
            .hearing("こんにちは"), .hearing(""), .recognized("こんにちは"),
        ])
        XCTAssertEqual(recognized.direction.nod?.id, finished.direction.nod?.id)
    }

    /// Clearing the hearing is where the producer stopped: it comes as soon as the words
    /// are final, as upstream's voice-activity stop does, even if she is still speaking.
    func testTheProducerStoppingIsTheFinalWordsNotTheTurnStarting() {
        let stand = after([
            started(0, 0),
            .hearing("ねえ"),
            .hearing(""),
        ])
        XCTAssertFalse(stand.direction.looking)
        XCTAssertEqual(stand.direction.nod?.kind, .yes)
        XCTAssertTrue(stand.direction.speaking, "she went on saying her segment")
    }

    /// A recognizer that only sends finals sends nothing to start the producer: the
    /// recognized turn is where she nods, once.
    func testRecognizedNodsWhenNoPartialStartedTheProducer() {
        let heard = after([.hearing("")])
        XCTAssertNil(heard.direction.nod)

        let recognized = after([.hearing(""), .recognized("こんにちは")])
        XCTAssertFalse(recognized.direction.looking)
        XCTAssertEqual(recognized.direction.nod?.kind, .yes)
    }

    // MARK: - The end

    func testTheCallEndingForgetsEverything() {
        let stand = after([
            .hearing("ねえ"),
            started(0, 0),
            .hearing(""),
            .state(.ended(.hungUpByProducer)),
        ])
        XCTAssertFalse(stand.direction.speaking)
        XCTAssertFalse(stand.direction.looking)
        XCTAssertEqual(stand.direction.mood, .calm)
        // A nod that came with the end stays; the next call starts calm.
        let next = after([
            .state(.ended(.hungUpByProducer)),
            started(1, 0),
        ])
        XCTAssertTrue(next.direction.speaking)
        XCTAssertFalse(next.direction.looking)
    }
}
