import XCTest

/// S2.3 call layer: wide panes, full-screen rotation, and the folded capsule.
final class IPadCallLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchEnvironment = [
            "EIDOLON_FAKE_CHAT": "1",
            "EIDOLON_CHAT_BASE_URL": "http://example.invalid",
            "EIDOLON_CHAT_MODEL": "fake",
            "EIDOLON_CHAT_API_KEY": "fake",
            "EIDOLON_OPEN_CHARACTER": "hiori",
            "EIDOLON_OPEN_CALL": "1",
            "EIDOLON_CALL_FAKE_SPEECH": "你好",
        ]
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    private var width: CGFloat { app.windows.firstMatch.frame.width }

    private func attach(_ name: String) {
        Thread.sleep(forTimeInterval: 8.0)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func launch() {
        app.terminate()
        app.launch()
        XCTAssertTrue(
            app.buttons["call.hangUp"].waitForExistence(timeout: 45),
            "call did not open; env=\(app.launchEnvironment)"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["call.layer"].waitForExistence(timeout: 5),
            "call layer has no identifier"
        )
    }

    func testWideCallFillsOnlyTheChatColumn() throws {
        launch()
        try XCTSkipUnless(width > 960, "Run this on a 13-inch iPad")

        let split = app.descendants(matching: .any)["conversation.splitHandle"].firstMatch
        XCTAssertTrue(split.waitForExistence(timeout: 10), "wide roster is gone")
        let layer = app.descendants(matching: .any)["call.layer"].firstMatch
        let call = layer.frame
        XCTAssertGreaterThan(
            call.minX, split.frame.midX - split.frame.width / 2,
            "the call pane still covers the roster: call=\(call) split=\(split.frame)"
        )
        XCTAssertLessThan(call.width, width - 280, "the call is still full width")
        XCTAssertTrue(app.buttons["pad.tab.conversation"].exists, "the rail disappeared")
        attach("call-wide-pane")
    }

    func testWideCallOnAnotherTabLeavesTheRail() throws {
        launch()
        try XCTSkipUnless(width > 960, "Run this on a 13-inch iPad")
        app.buttons["pad.tab.moments"].tap()
        XCTAssertTrue(app.staticTexts["朋友圈"].firstMatch.waitForExistence(timeout: 10))

        let layer = app.descendants(matching: .any)["call.layer"].firstMatch
        let call = layer.frame
        let rail = app.buttons["pad.tab.conversation"].frame
        XCTAssertGreaterThan(call.minX, rail.maxX, "the call covered the rail")
        XCTAssertLessThan(call.width, width - 88, "the call is still the whole window")
        attach("call-wide-moments")
    }

    func testFoldedCallBecomesACapsuleThatCanBeMovedAndExpanded() throws {
        launch()
        app.buttons["收起"].firstMatch.tap()

        let capsule = app.buttons["call.capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 5), "no folded call capsule")
        XCTAssertLessThan(capsule.frame.width, 200, "the capsule is still a full-width bar")
        attach("call-capsule-collapsed")

        // The bottom-resting capsule must not intersect a page title.
        app.buttons["pad.tab.moments"].tap()
        XCTAssertTrue(app.staticTexts["朋友圈"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(
            capsule.frame.intersects(app.staticTexts["朋友圈"].firstMatch.frame),
            "the capsule covers the moments title"
        )

        // Drag it to the top-leading corner; it should snap there.
        let start = capsule.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.10)))
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertLessThan(capsule.frame.midX, width / 2, "capsule did not snap left")
        XCTAssertLessThan(capsule.frame.midY, app.windows.firstMatch.frame.height / 2, "capsule did not snap up")
        attach("call-capsule-top-leading")

        // Long press gives expand/hang up; expanding restores the call layer.
        capsule.press(forDuration: 1.2)
        let expand = app.buttons["展开通话"]
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "no expand menu")
        expand.tap()
        XCTAssertTrue(app.buttons["call.hangUp"].waitForExistence(timeout: 5), "call did not expand")
    }

    func testMediumWidthUsesTheFullScreenCall() throws {
        XCUIDevice.shared.orientation = .portrait
        launch()
        try XCTSkipUnless(width < 960, "Run this on an iPad mini or portrait iPad")
        XCTAssertFalse(
            app.descendants(matching: .any)["conversation.splitHandle"].exists,
            "portrait medium kept the wide splitter"
        )
        let layer = app.descendants(matching: .any)["call.layer"].firstMatch
        XCTAssertEqual(layer.frame.width, width, accuracy: 1, "medium call is not full width")
        attach("call-fullscreen-medium")
    }
}
