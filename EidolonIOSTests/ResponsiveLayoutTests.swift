import XCTest
@testable import Eidolon

final class ResponsiveLayoutTests: XCTestCase {
    func testWidthBandsFollowTheContainerNotTheScreen() {
        XCTAssertEqual(ResponsiveLayout.band(width: 649, sizeClass: .regular), .compact)
        XCTAssertEqual(ResponsiveLayout.band(width: 650, sizeClass: .regular), .medium)
        XCTAssertEqual(ResponsiveLayout.band(width: 960, sizeClass: .regular), .medium)
        XCTAssertEqual(ResponsiveLayout.band(width: 961, sizeClass: .regular), .wide)
        XCTAssertEqual(ResponsiveLayout.band(width: 1024, sizeClass: .regular), .wide)
        XCTAssertEqual(ResponsiveLayout.band(width: 1366, sizeClass: .regular), .wide)
    }

    func testCompactPhonesNeverBecomeThePadShell() {
        // A landscape phone is wider than 650 but still has a compact size class.
        XCTAssertEqual(ResponsiveLayout.band(width: 852, sizeClass: .compact), .compact)
        XCTAssertEqual(ResponsiveLayout.band(width: 1366, sizeClass: .compact), .compact)
    }

    func testPadWidths() {
        XCTAssertEqual(ResponsiveLayout.railWidth, 165)
        XCTAssertEqual(ResponsiveLayout.rosterStandardWidth, 320)
        XCTAssertEqual(ResponsiveLayout.rosterExpandedWidth, 460)
        XCTAssertEqual(ResponsiveLayout.rosterCollapsedWidth, 0)
        XCTAssertEqual(ResponsiveLayout.rosterMinContentWidth, 280)
    }

    func testDragSnapsToTheNearestBreakpoint() {
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: -30), 0)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 0), 0)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 159), 0)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 160), 320)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 320), 320)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 389), 320)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 390), 460)
        XCTAssertEqual(ResponsiveLayout.snapRosterWidth(projectedWidth: 900), 460)
    }

    func testDraggingWidthsClampToTheAvailableRange() {
        XCTAssertEqual(ResponsiveLayout.draggingRosterWidth(start: 320, translation: -500), 0)
        XCTAssertEqual(ResponsiveLayout.draggingRosterWidth(start: 320, translation: 500), 460)
        XCTAssertEqual(ResponsiveLayout.draggingRosterWidth(start: 320, translation: -10), 310)
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
