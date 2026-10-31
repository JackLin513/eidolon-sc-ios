import XCTest
@testable import EidolonCore

/// Typing during a call is a follow-on until she has started saying a complete segment, and
/// an interruption after (upstream `turn_taking.py`).
final class CallTypingTests: XCTestCase {
    private func reply(
        _ active: Bool,
        recorded: Bool = false,
        started: Bool = false,
        complete: Int = 0,
        speaking: Bool = false
    ) -> CallTypedTurn.Reply {
        CallTypedTurn.Reply(
            turnActive: active,
            recorded: recorded,
            startedSpeaking: started,
            completeSegments: complete,
            stillSpeaking: speaking
        )
    }

    func testWithNoTurnATypedLineStartsOne() {
        XCTAssertEqual(CallTypedTurn.action(for: reply(false)), .start)
    }

    func testBeforeSheHasSaidACompleteSegmentTypingIsAFollowOn() {
        XCTAssertEqual(CallTypedTurn.action(for: reply(true)), .followOn)
        XCTAssertEqual(CallTypedTurn.action(for: reply(true, started: true)), .followOn)
        XCTAssertEqual(CallTypedTurn.action(for: reply(true, complete: 1)), .followOn)
        XCTAssertEqual(
            CallTypedTurn.action(for: reply(true, started: true, complete: 1)),
            .interrupt
        )
    }

    func testARecordedReplyWithACompleteSegmentCanBeInterrupted() {
        XCTAssertEqual(
            CallTypedTurn.action(for: reply(true, recorded: true, complete: 1)),
            .interrupt
        )
        XCTAssertEqual(
            CallTypedTurn.action(for: reply(true, recorded: true, complete: 0)),
            .followOn,
            "nothing complete means nothing to keep, so it is still a follow-on"
        )
    }

    func testARecordedReplyStillBeingHeardIsInterrupted() {
        XCTAssertEqual(
            CallTypedTurn.action(for: reply(false, recorded: true, complete: 1, speaking: true)),
            .interrupt
        )
        XCTAssertEqual(
            CallTypedTurn.action(for: reply(false, complete: 0, speaking: true)),
            .start,
            "a defensive fallback: no complete segment means there is nothing to interrupt"
        )
    }
}

    func testACallTurnIsDroppedUntilTheCallSaysToKeepWhatSheSaid() {
        let stop = CallTurnStop()
        XCTAssertEqual(stop.currentMode(), .drop)
        stop.keepCompleteSegments(2)
        XCTAssertEqual(stop.currentMode(), .keepCompleteSegments(2))
        stop.keepCompleteSegments(-1)
        XCTAssertEqual(stop.currentMode(), .keepCompleteSegments(0))
    }
