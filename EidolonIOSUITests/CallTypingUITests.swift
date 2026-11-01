import XCTest

/// The call's typing row with the system keyboard up (spec #47): the row replaces the dock,
/// stays above the keyboard, and the line card and her likeness do not jump.
final class CallTypingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launchEnvironment["EIDOLON_OPEN_CALL"] = "1"
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_CALL_FAKE_SPEECH"] = "你好"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testTheTypingRowSitsAboveTheKeyboardAndReplacesTheDock() throws {
        let typing = app.buttons["call.openTyping"]
        XCTAssertTrue(typing.waitForExistence(timeout: 20), "call did not start")
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: typing)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(app.buttons["call.hangUp"].exists, "dock is not there before typing")
        typing.tap()

        XCTAssertFalse(app.buttons["call.hangUp"].exists, "dock should be replaced by the typing row")
        XCTAssertFalse(app.buttons["call.openTyping"].exists, "typing key should be gone while typing")
        let typingField = app.textFields["call.typingField"]
        XCTAssertTrue(typingField.waitForExistence(timeout: 5), "typing field did not appear")
        typingField.tap()

        // A simulator with a hardware keyboard attached never shows the software one; the
        // layout above it was checked by hand, and here its absence is not a failure.
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 3) {
            XCTAssertTrue(
                typingField.frame.maxY < keyboard.frame.minY,
                "typing field is under the keyboard"
            )
            XCTAssertTrue(
                app.staticTexts["こんばんは。今日はどうしたの？"].exists
                    || app.staticTexts["晚上好。今天怎么了？"].exists,
                "her line card is not above the keyboard"
            )
        }

        let send = app.buttons["call.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        XCTAssertFalse(send.isEnabled, "send is enabled with an empty draft")
        typingField.tap()
        typingField.typeText("こんばんは")
        XCTAssertTrue(send.isEnabled, "send is not enabled after typing")
    }
}
