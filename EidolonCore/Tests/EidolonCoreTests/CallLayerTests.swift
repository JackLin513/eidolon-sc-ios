import XCTest
@testable import EidolonCore

/// The call layer's presentation (spec #46, upstream `liveConversation.nextLayer`): when it
/// exists, when it is open, when it is folded with a bar.
final class CallLayerTests: XCTestCase {
    func testWithNoCallThereIsNoLayerAndNoBar() {
        XCTAssertFalse(CallLayer.absent.showsBar(live: false))
        XCTAssertFalse(CallLayer.absent.showsBar(live: true))
    }

    func testANewCallStartsOpen() {
        XCTAssertEqual(CallLayer.dialing, .expanded)
        XCTAssertFalse(CallLayer.dialing.showsBar(live: true))
    }

    func testALiveCallFoldsAndUnfoldsWithItsBar() {
        let folded = CallLayer.dialing.collapsing(live: true)
        XCTAssertEqual(folded, .collapsed)
        XCTAssertTrue(folded.showsBar(live: true))
        XCTAssertEqual(folded.expanding(live: true), .expanded)
        XCTAssertFalse(folded.expanding(live: true).showsBar(live: true))
    }

    func testAnEndedCallCannotBeFoldedOrUnfoldedAndOpens() {
        XCTAssertEqual(CallLayer.expanded.collapsing(live: false), .expanded)
        XCTAssertEqual(CallLayer.collapsed.expanding(live: false), .collapsed)
        XCTAssertEqual(CallLayer.collapsed.ended(), .expanded)
        XCTAssertEqual(CallLayer.expanded.ended(), .expanded)
        XCTAssertFalse(CallLayer.collapsed.showsBar(live: false))
    }

    func testConnectingKeepsWhetherItWasFolded() {
        XCTAssertEqual(CallLayer.collapsed.connected(), .collapsed)
        XCTAssertEqual(CallLayer.expanded.connected(), .expanded)
        XCTAssertEqual(CallLayer.absent.connected(), .expanded)
    }

    func testTheBarOnlyShowsForACallUnderWayThatIsFolded() {
        XCTAssertTrue(CallLayer.collapsed.showsBar(live: true))
        XCTAssertFalse(CallLayer.collapsed.showsBar(live: false))
        XCTAssertFalse(CallLayer.expanded.showsBar(live: true))
        XCTAssertFalse(CallLayer.absent.showsBar(live: true))
    }
}
