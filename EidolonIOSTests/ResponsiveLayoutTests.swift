import SwiftUI
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
        XCTAssertEqual(threshold.visibleWidth, 280)
        XCTAssertEqual(threshold.settledWidth, 0)
        XCTAssertTrue(threshold.willCollapse)
    }

    func testDuoPageUsesTwoColumnsBelowTheIPadWideThreshold() {
        // 280 roster + 12 splitter + 340 chat = 632; an iPad's 960 threshold would
        // never fire on the Duo inner display. The pad shell keeps chatMinWidth 420.
        XCTAssertEqual(ResponsiveLayout.chatMinWidth, 420)
        XCTAssertEqual(ResponsiveLayout.duoChatMinWidth, 340)
        XCTAssertEqual(ResponsiveLayout.duoConversationWideMinWidth, 632)
        XCTAssertEqual(ResponsiveLayout.duoPageBand(width: 631, height: 900), .compact)
        XCTAssertEqual(ResponsiveLayout.duoPageBand(width: 650, height: 600), .wide)
        XCTAssertEqual(ResponsiveLayout.duoPageBand(width: 632, height: 600), .wide)
        XCTAssertEqual(ResponsiveLayout.duoPageBand(width: 951, height: 669), .wide)
        XCTAssertEqual(ResponsiveLayout.duoPageBand(width: 669, height: 951), .compact)
        XCTAssertEqual(ResponsiveLayout.duoPageBand(width: 600, height: 900), .compact)
    }

    func testIPadKeepsThePadShellAndIPhoneUsesTheSystemShell() {
        XCTAssertTrue(ResponsiveLayout.usesPadShell(isPad: true, band: .medium))
        XCTAssertTrue(ResponsiveLayout.usesPadShell(isPad: true, band: .wide))
        XCTAssertFalse(ResponsiveLayout.usesPadShell(isPad: true, band: .compact))
        XCTAssertFalse(ResponsiveLayout.usesPadShell(isPad: false, band: .medium))
        XCTAssertFalse(ResponsiveLayout.usesPadShell(isPad: false, band: .wide))
    }

    func testTitleAnchorsAreSharedConstants() {
        XCTAssertEqual(ResponsiveLayout.pageTitleLeading, 20)
        XCTAssertEqual(ResponsiveLayout.pageTitleTop, 12)
        XCTAssertEqual(ResponsiveLayout.filterButtonWidth, 44)
    }

    func testRememberedWidthClampsAfterRailResize() {
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(460, availableWidth: 800, hasSelection: true), 368)
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(0, availableWidth: 800, hasSelection: true), 0)
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(0, availableWidth: 800, hasSelection: false), 280)
        XCTAssertEqual(ResponsiveLayout.clampedRosterWidth(320, availableWidth: 1133, hasSelection: false), 320)
    }


    func testCallPresentationKeepsTheRosterOnAWideConversation() {
        XCTAssertEqual(
            ResponsiveLayout.callPresentation(band: .wide, onConversation: true),
            .conversationPane
        )
        XCTAssertEqual(
            ResponsiveLayout.callPresentation(band: .wide, onConversation: false),
            .page
        )
        XCTAssertEqual(
            ResponsiveLayout.callPresentation(band: .medium, onConversation: true),
            .fullScreen
        )
        XCTAssertEqual(
            ResponsiveLayout.callPresentation(band: .compact, onConversation: false),
            .fullScreen
        )
    }

    func testCallStandFramingAndHeight() {
        let desktop = CGSize(width: 880, height: 1024)
        let phonePane = CGSize(width: 538, height: 1366)
        XCTAssertEqual(CallPresentation.page.standFraming, .waist)
        XCTAssertEqual(CallPresentation.conversationPane.standFraming, .waist)
        XCTAssertEqual(CallPresentation.fullScreen.standFraming, .knees)
        XCTAssertEqual(CallPresentation.phonePane.standFraming, .full)
        XCTAssertEqual(
            CallPresentation.page.standHeight(in: desktop, isCompactPhone: false),
            desktop.height * 0.92,
            accuracy: 0.01
        )
        XCTAssertEqual(
            CallPresentation.fullScreen.standHeight(in: desktop, isCompactPhone: false),
            desktop.height * 0.70,
            accuracy: 0.01
        )
        XCTAssertEqual(
            CallPresentation.fullScreen.standHeight(in: desktop, isCompactPhone: true),
            desktop.height * 0.80,
            accuracy: 0.01
        )
        XCTAssertEqual(
            CallPresentation.phonePane.standHeight(in: phonePane, isCompactPhone: false),
            phonePane.height * 0.92,
            accuracy: 0.01
        )
    }

    func testNarrowConversationPaneBecomesPhonePane() {
        XCTAssertEqual(
            ResponsiveLayout.resolvePaneCallPresentation(
                .conversationPane,
                paneSize: CGSize(width: 538, height: 1366),
                containerSize: CGSize(width: 1024, height: 1366)
            ),
            .phonePane
        )
        XCTAssertEqual(
            ResponsiveLayout.resolvePaneCallPresentation(
                .conversationPane,
                paneSize: CGSize(width: 880, height: 1024),
                containerSize: CGSize(width: 1366, height: 1024)
            ),
            .conversationPane
        )
        // A stale tall pane from portrait must not keep phone layout in landscape.
        XCTAssertEqual(
            ResponsiveLayout.resolvePaneCallPresentation(
                .conversationPane,
                paneSize: CGSize(width: 538, height: 1366),
                containerSize: CGSize(width: 1366, height: 1024)
            ),
            .conversationPane
        )
        XCTAssertEqual(
            ResponsiveLayout.resolvePaneCallPresentation(
                .page,
                paneSize: CGSize(width: 538, height: 1366),
                containerSize: CGSize(width: 1024, height: 1366)
            ),
            .page
        )
    }

    func testCallCapsuleSnapsInsideTheSafeArea() {
        let container = CGSize(width: 1000, height: 700)
        let insets = EdgeInsets(top: 20, leading: 10, bottom: 24, trailing: 14)
        let size = CGSize(width: 140, height: 44)
        let bottomTrailing = ResponsiveLayout.callCapsuleCenter(
            corner: .bottomTrailing,
            size: size,
            container: container,
            safeInsets: insets
        )
        XCTAssertEqual(bottomTrailing.x, 1000 - 14 - 16 - 70)
        XCTAssertEqual(bottomTrailing.y, 700 - 24 - 16 - 22)
        XCTAssertEqual(
            ResponsiveLayout.callCapsuleCorner(
                for: CGPoint(x: 150, y: 640),
                size: size,
                container: container,
                safeInsets: insets
            ),
            .bottomLeading
        )
        XCTAssertEqual(
            ResponsiveLayout.callCapsuleCorner(
                for: CGPoint(x: 900, y: 50),
                size: size,
                container: container,
                safeInsets: insets
            ),
            .topTrailing
        )
        XCTAssertEqual(
            ResponsiveLayout.callCapsuleCorner(
                for: CGPoint(x: 890, y: 350),
                size: size,
                container: container,
                safeInsets: insets
            ),
            .trailing
        )
        XCTAssertEqual(
            ResponsiveLayout.callCapsuleCenter(
                corner: .trailing, size: size, container: container, safeInsets: insets
            ).y,
            container.height / 2
        )
        let dragged = ResponsiveLayout.clampedCallCapsuleCenter(
            CGPoint(x: -100, y: 2000),
            size: size,
            container: container,
            safeInsets: insets
        )
        XCTAssertEqual(dragged.x, 10 + 16 + 70)
        XCTAssertEqual(dragged.y, 700 - 24 - 16 - 22)
    }
    func testSplitHandlePillKeepsTheSameGapToTheSeamWhenCollapsed() {
        let collapsed = ResponsiveLayout.splitHandleOffset(listWidth: 0)
        XCTAssertEqual(
            collapsed + ResponsiveLayout.handleHitSize / 2,
            ResponsiveLayout.handleLineGap,
            accuracy: 0.01
        )
        let open = ResponsiveLayout.splitHandleOffset(listWidth: 320)
        XCTAssertEqual(
            open + ResponsiveLayout.handleHitSize / 2,
            320 + ResponsiveLayout.handleLineGap,
            accuracy: 0.01
        )
    }

}
