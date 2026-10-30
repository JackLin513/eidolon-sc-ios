import XCTest
@testable import EidolonCore

/// How the bar's screen is scaled and placed (upstream `lib/barScreen.ts`).
final class BarScreenTests: XCTestCase {
    private func viewport(
        width: Double = 1280, height: Double = 720, insets: BarScreen.Insets = .none,
        callBar: Double = 0, pointer: BarScreen.Pointer = .fine
    ) -> BarScreen.Viewport {
        BarScreen.Viewport(width: width, height: height, insets: insets, callBar: callBar, pointer: pointer)
    }

    func testOnADesktop1280By720IsExactlyTwice() {
        XCTAssertEqual(BarScreen.placement(viewport()), .init(scale: 2, left: 0, top: 0))
    }

    func testOnADesktopItIsTheLargestWholeMultipleThatFitsCentred() {
        XCTAssertEqual(
            BarScreen.placement(viewport(width: 1920, height: 1080)),
            .init(scale: 3, left: 0, top: 0)
        )
        XCTAssertEqual(
            BarScreen.placement(viewport(width: 1500, height: 900)),
            .init(scale: 2, left: 110, top: 90)
        )
    }

    func testOnADesktopNotEvenOneFitsAndItFallsToAFraction() {
        XCTAssertEqual(
            BarScreen.placement(viewport(width: 480, height: 600)),
            .init(scale: 0.75, left: 0, top: 165)
        )
    }

    func testOnAPhoneItIsTheLargestFractionThatFits() {
        let placed = BarScreen.placement(viewport(width: 844, height: 390, pointer: .coarse))

        XCTAssertEqual(placed.scale, 390.0 / 360.0, accuracy: 0.000_001)
        XCTAssertEqual(placed.top, 0)
        XCTAssertEqual(placed.left, 75)
    }

    func testACallBarIsTakenOffAndThePlaceIsCountedFromUnderIt() {
        XCTAssertEqual(
            BarScreen.placement(viewport(callBar: 48)),
            .init(scale: 1, left: 320, top: 156)
        )
    }

    /// A finger's point comes in the viewport's own coordinates; what the bar draws and what
    /// it calls a place (the shaker's box, say) are in the 640×360 screen's. Reading one as the
    /// other put a dragged bottle a screen's width to the right and left the drop short.
    func testAPointOfTheViewportIsReadOnTheScreen() {
        let placed = BarScreen.placement(viewport(width: 844, height: 390, pointer: .coarse))

        // The screen's own top-left corner, and the shaker's middle on a phone.
        XCTAssertEqual(placed.screenX(placed.left), 0, accuracy: 0.000_001)
        XCTAssertEqual(placed.screenY(placed.top), 0, accuracy: 0.000_001)
        XCTAssertEqual(placed.screenX(placed.left + 513 * placed.scale), 513, accuracy: 0.000_001)
        XCTAssertEqual(placed.screenY(placed.top + 216 * placed.scale), 216, accuracy: 0.000_001)
    }

    func testAPointHereIsNotAScreenPointWhenTheScreenIsOffset() {
        // 1500×900 desktop: scale 2, the screen starts 110 to the right. A finger at the far
        // left of the viewport is off the screen's left edge, not at x = 0.
        let placed = BarScreen.placement(viewport(width: 1500, height: 900))

        XCTAssertEqual(placed.screenX(0), -55, accuracy: 0.000_001)
        XCTAssertEqual(placed.screenX(500), 195, accuracy: 0.000_001)
    }

    func testTheSafeAreaIsTakenOffToo() {
        let placed = BarScreen.placement(viewport(
            width: 844, height: 390,
            insets: BarScreen.Insets(top: 0, right: 47, bottom: 21, left: 47),
            pointer: .coarse
        ))

        XCTAssertEqual(placed.scale, 369.0 / 360.0, accuracy: 0.000_001)
        XCTAssertEqual(placed.top, 0)
        XCTAssertEqual(placed.left, 47 + ((750 - 640 * (369.0 / 360.0)) / 2).rounded(.down))
    }
}
