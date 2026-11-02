import XCTest

/// The conversation's transcript can be selected and copied (spec #75, #76).
final class ChatSelectionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testTranscriptTextShowsTheSelectionMenuOnLongPress() throws {
        // Start from an empty conversation so the known fake reply is the only line to press.
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no chat menu")
        more.tap()
        app.buttons["新对话"].tap()
        sleep(1)

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no chat input")
        let ready = NSPredicate(format: "isEnabled == true")
        expectation(for: ready, evaluatedWith: input)
        waitForExpectations(timeout: 10)
        input.tap()
        sleep(1)
        input.tap()
        sleep(1)
        input.typeText("你好")
        app.buttons["chat.send"].tap()

        let line = app.staticTexts["晚上好。今天怎么了？"]
        XCTAssertTrue(line.waitForExistence(timeout: 20), "her line did not appear")
        line.press(forDuration: 1.2)
        XCTAssertTrue(
            app.menuItems.firstMatch.waitForExistence(timeout: 5),
            "long press did not show the system text menu"
        )
        XCTAssertTrue(input.exists, "text selection left the chat")
    }
}
