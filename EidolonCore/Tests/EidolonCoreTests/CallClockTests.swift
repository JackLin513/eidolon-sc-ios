import Foundation
import XCTest
@testable import EidolonCore

/// The time the call screen shows: how long it has lasted, or—in its last minute—how long
/// is left (upstream `callTime.ts`).
final class CallClockTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_000)

    func testTheCallShowsHowLongItHasLasted() {
        XCTAssertEqual(
            CallClock.time(since: since, limit: .seconds(600), now: since.addingTimeInterval(539)),
            .elapsed(seconds: 539)
        )
        XCTAssertEqual(
            CallClock.time(since: since, limit: nil, now: since.addingTimeInterval(700)),
            .elapsed(seconds: 700)
        )
    }

    /// The last minute is shown as what is left: at exactly 60 seconds left it is still the
    /// elapsed clock, as upstream takes `< 60`.
    func testTheLastMinuteCountsDown() {
        XCTAssertEqual(
            CallClock.time(since: since, limit: .seconds(600), now: since.addingTimeInterval(540)),
            .elapsed(seconds: 540)
        )
        XCTAssertEqual(
            CallClock.time(since: since, limit: .seconds(600), now: since.addingTimeInterval(541)),
            .remaining(seconds: 59)
        )
        XCTAssertEqual(
            CallClock.time(since: since, limit: .seconds(600), now: since.addingTimeInterval(700)),
            .remaining(seconds: 0)
        )
    }

    func testTheClockNeverGoesBackwards() {
        XCTAssertEqual(
            CallClock.time(since: since, limit: .seconds(600), now: since.addingTimeInterval(-5)),
            .elapsed(seconds: 0)
        )
    }

    func testItIsShownAsTheCallScreenWritesIt() {
        XCTAssertEqual(CallClock.clock(0), "00:00")
        XCTAssertEqual(CallClock.clock(81), "01:21")
        XCTAssertEqual(CallClock.clock(3_599), "59:59")
        XCTAssertEqual(CallClock.shown(.elapsed(seconds: 81)), "01:21")
        XCTAssertEqual(CallClock.shown(.remaining(seconds: 42)), "还剩 00:42")
    }
}
