import XCTest
@testable import Eidolon

final class ResponsiveLayoutTests: XCTestCase {
    func testConversationIsSplitOnlyAtRegularWidths() {
        XCTAssertEqual(ResponsiveLayout.conversationColumns(width: 390), 1)
        XCTAssertEqual(ResponsiveLayout.conversationColumns(width: 759), 1)
        XCTAssertEqual(ResponsiveLayout.conversationColumns(width: 760), 2)
        XCTAssertEqual(ResponsiveLayout.conversationColumns(width: 1366), 2)
    }

    func testReadingWidthStopsAtTheMaximumAndNeverGoesNegative() {
        XCTAssertEqual(ResponsiveLayout.contentWidth(container: 390), 390)
        XCTAssertEqual(ResponsiveLayout.contentWidth(container: 680), 680)
        XCTAssertEqual(ResponsiveLayout.contentWidth(container: 1366), 680)
        XCTAssertEqual(ResponsiveLayout.contentWidth(container: -10), 0)
    }

    func testCollapsedCallTravelsPastTheContainerIncludingSafeArea() {
        XCTAssertEqual(
            ResponsiveLayout.callCollapsedOffset(containerHeight: 800, safeTop: 24, safeBottom: 20),
            844
        )
        XCTAssertEqual(
            ResponsiveLayout.callCollapsedOffset(containerHeight: 500, safeTop: 0, safeBottom: 0),
            500
        )
    }
}
