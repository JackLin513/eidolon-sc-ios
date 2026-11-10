import XCTest

/// S2.1 visual QA. Each state is attached as a screenshot; the QA script extracts the
/// attachments into `.qa-screenshots/` so the five states can be inspected directly.
final class IPadVisualQATests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_CHAT_BASE_URL"] = "http://example.invalid"
        app.launchEnvironment["EIDOLON_CHAT_MODEL"] = "fake"
        app.launchEnvironment["EIDOLON_CHAT_API_KEY"] = "fake"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    private var width: CGFloat { app.windows.firstMatch.frame.width }

    func testIPadVisualStates() throws {
        try XCTSkipUnless(width >= 650, "Run this on an iPad simulator")

        XCUIDevice.shared.orientation = .landscapeLeft
        let handle = anyElement("conversation.splitHandle")
        XCTAssertTrue(handle.waitForExistence(timeout: 20), "wide handle never appeared")
        attach("landscape-standard")

        drag(handle, towardX: 120)
        if anyElement("conversation.splitHandle").label != "显示角色列表" {
            drag(anyElement("conversation.splitHandle"), towardX: 100)
        }
        XCTAssertTrue(
            anyElement("conversation.splitHandle").label == "显示角色列表",
            "the roster did not collapse"
        )
        attach("landscape-collapsed")

        anyElement("conversation.splitHandle").tap()
        XCTAssertTrue(anyElement("conversation.splitHandle").label == "调整角色列表宽度")
        drag(anyElement("conversation.splitHandle"), towardX: 900)
        attach("landscape-expanded")

        XCUIDevice.shared.orientation = .portrait
        let row = app.staticTexts["櫻木真乃"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no roster row after rotating back")
        row.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 20), "chat did not open")
        attach("portrait-push")
    }

    func testCompactPhoneVisualState() throws {
        try XCTSkipUnless(width < 650, "Run this on an iPhone simulator")
        XCTAssertTrue(app.buttons["对话"].waitForExistence(timeout: 20), "compact tab bar missing")
        attach("compact-phone")
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func drag(_ element: XCUIElement, towardX x: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(
            dx: min(max(x / width, 0.05), 0.95),
            dy: 0.5
        ))
        start.press(forDuration: 0.05, thenDragTo: target)
    }

    private func attach(_ name: String) {
        // Let the spring settle before the image is taken; otherwise a collapsing roster
        // is captured mid-fade even though its final frame is clean.
        Thread.sleep(forTimeInterval: 0.7)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
