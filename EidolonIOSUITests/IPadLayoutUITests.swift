import XCTest

/// S2: the same build turns the conversation tab into roster + chat on a regular-width
/// iPad and keeps it usable after a rotation. Run on an iPad simulator only; the compact
/// iPhone keeps its single navigation stack and is covered by the existing tests.
final class IPadLayoutUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testIPadConversationIsSplitAndSurvivesRotation() throws {
        XCTAssertTrue(
            app.buttons["对话"].waitForExistence(timeout: 20),
            "the floating iPad tab bar did not appear"
        )
        // Landscape is regular width on every iPad, including the mini.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(
            app.staticTexts["选一个角色"].waitForExistence(timeout: 10),
            "the split detail disappeared after rotating to landscape"
        )

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["对话"].waitForExistence(timeout: 10))

        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 10))
        app.buttons.matching(identifier: "设置").firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["服务器"].waitForExistence(timeout: 10),
            "settings did not open on iPad"
        )
    }

    func testIPadLargeTextKeepsSettingsReachable() throws {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 20))
        app.buttons.matching(identifier: "设置").firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["服务器"].waitForExistence(timeout: 10),
            "the accessibility text size hid the settings form"
        )
    }

    func testIPadSplitSelectsChatAndKeyboardDoesNotHideTheInput() throws {
        XCTAssertTrue(app.buttons["对话"].waitForExistence(timeout: 20))
        let name = app.staticTexts["樱木真乃"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20), "no roster row in the split sidebar")
        name.tap()

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20), "the split detail did not open her chat")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard did not appear")
        XCTAssertTrue(input.isHittable, "keyboard covers the chat input")
    }

}
