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
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    private var width: CGFloat {
        app.windows.firstMatch.frame.width
    }

    func testIPadVisualStates() throws {
        launch()
        try XCTSkipUnless(width >= 650, "Run this on an iPad simulator")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.splitHandle"].waitForExistence(timeout: 20),
            "landscape did not reach the wide shell"
        )
        attach("landscape-standard")

        relaunch(rosterWidth: 0)
        attach("landscape-collapsed")

        relaunch(rosterWidth: 460)
        attach("landscape-expanded")

        relaunch(rosterWidth: nil)
        XCUIDevice.shared.orientation = .portrait
        let row = app.staticTexts["櫻木真乃"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no roster row after rotating back")
        row.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 20), "chat did not open")
        attach("portrait-push")
    }

    func testCompactPhoneVisualState() throws {
        launch()
        try XCTSkipUnless(width < 650, "Run this on an iPhone simulator")
        XCTAssertTrue(app.buttons["对话"].waitForExistence(timeout: 20), "compact tab bar missing")
        attach("compact-phone")
    }

    private func launch() {
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.splitHandle"].waitForExistence(timeout: 20)
                || app.buttons["对话"].waitForExistence(timeout: 20),
            "app did not become reachable"
        )
    }

    private func relaunch(rosterWidth: Int?) {
        app.terminate()
        if let rosterWidth {
            app.launchEnvironment["EIDOLON_PAD_ROSTER_WIDTH"] = String(rosterWidth)
        } else {
            app.launchEnvironment.removeValue(forKey: "EIDOLON_PAD_ROSTER_WIDTH")
        }
        launch()
        if rosterWidth == 0 {
            XCTAssertTrue(
                app.descendants(matching: .any)["conversation.splitHandle"].label == "显示角色列表",
                "the collapsed QA seed did not reach the shell"
            )
        } else if rosterWidth == 460 {
            XCTAssertTrue(
                app.descendants(matching: .any)["conversation.splitHandle"].label == "调整角色列表宽度",
                "the expanded QA seed did not reach the shell"
            )
        }
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
