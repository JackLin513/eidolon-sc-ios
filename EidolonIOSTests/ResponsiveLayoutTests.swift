import XCTest
@testable import Eidolon

final class ResponsiveLayoutTests: XCTestCase {
    func testConversationIsSplitOnlyAtRegularWidths() {
        // A landscape phone is wide but still compact.
        XCTAssertFalse(ResponsiveLayout.isSplit(width: 852, sizeClass: .compact))
        XCTAssertFalse(ResponsiveLayout.isSplit(width: 699, sizeClass: .regular))
        XCTAssertTrue(ResponsiveLayout.isSplit(width: 700, sizeClass: .regular))
        XCTAssertTrue(ResponsiveLayout.isSplit(width: 1366, sizeClass: .regular))
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
