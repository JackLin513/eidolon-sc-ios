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
        XCTAssertEqual(ResponsiveLayout.band(width: 852, sizeClass: .compact), .compact)
        XCTAssertEqual(ResponsiveLayout.band(width: 1366, sizeClass: .compact), .compact)
    }

    func testRailWidthsAndLabelThreshold() {
        XCTAssertEqual(ResponsiveLayout.clampedRailWidth(10), 88)
        XCTAssertEqual(ResponsiveLayout.clampedRailWidth(165), 165)
        XCTAssertEqual(ResponsiveLayout.clampedRailWidth(400), 240)
        XCTAssertFalse(ResponsiveLayout.railShowsLabels(width: 149))
        XCTAssertTrue(ResponsiveLayout.railShowsLabels(width: 150))
        XCTAssertTrue(ResponsiveLayout.railShowsLabels(width: 240))
    }

    func testRosterBoundsLeaveRoomForTheChat() {
        XCTAssertEqual(ResponsiveLayout.rosterBounds(availableWidth: 900), 280...460)
        XCTAssertEqual(ResponsiveLayout.rosterBounds(availableWidth: 1133), 280...460)
        // 800 - 12 - 420 = 368 upper bound.
        XCTAssertEqual(ResponsiveLayout.rosterBounds(availableWidth: 800), 280...368)
        // Not enough room: fall back to the minimum so the roster stays usable.
        XCTAssertEqual(ResponsiveLayout.rosterBounds(availableWidth: 650), 280...280)
    }

    func testSafeZoneDragKeepsTheFingerWidth() {
        let result = ResponsiveLayout.resolveRosterDrag(
            rawWidth: 360,
            availableWidth: 1133,
            hasSelection: true
        )
        XCTAssertEqual(result.visibleWidth, 360)
        XCTAssertEqual(result.settledWidth, 360)
        XCTAssertFalse(result.willCollapse)
    }

    func testUnselectedRosterRubberBandsAndNeverCollapses() {
        let result = ResponsiveLayout.resolveRosterDrag(
            rawWidth: 250,
            availableWidth: 1133,
            hasSelection: false
        )
        XCTAssertLessThan(result.visibleWidth, 280)
        XCTAssertGreaterThan(result.visibleWidth, 270)
        XCTAssertEqual(result.settledWidth, 280)
        XCTAssertFalse(result.willCollapse)

        let deep = ResponsiveLayout.resolveRosterDrag(
            rawWidth: 0,
            availableWidth: 1133,
            hasSelection: false
        )
        XCTAssertLessThan(deep.visibleWidth, 280)
        XCTAssertGreaterThan(deep.visibleWidth, 230)
        XCTAssertEqual(deep.settledWidth, 280)
        XCTAssertFalse(deep.willCollapse)
    }

    func testSelectedRosterCollapsesOnlyAfterOvershootThresholdOnRelease() {
        let slight = ResponsiveLayout.resolveRosterDrag(
            rawWidth: 260,
            availableWidth: 1133,
            hasSelection: true
        )
        XCTAssertGreaterThan(slight.visibleWidth, 270)
        XCTAssertEqual(slight.settledWidth, 280)
        XCTAssertFalse(slight.willCollapse)

        let threshold = ResponsiveLayout.resolveRosterDrag(
            rawWidth: 244,
            availableWidth: 1133,
            hasSelection: true
        )
        XCTAssertEqual(threshold.visibleWidth, 0)
        XCTAssertEqual(threshold.settledWidth, 0)
        XCTAssertTrue(threshold.willCollapse)
    }

    func testRememberedWidthClampsAfterRailResize() {
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(460, availableWidth: 800, hasSelection: true), 368)
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(0, availableWidth: 800, hasSelection: true), 0)
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(0, availableWidth: 800, hasSelection: false), 280)
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(320, availableWidth: 1133, hasSelection: false), 320)
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
