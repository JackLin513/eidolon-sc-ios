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

    func testHerJapaneseLineShowsTheSelectionMenu() throws {
        openNewFakeChat()
        assertSelectionMenu(containing: "こんばんは。今日はどうしたの？")
    }

    func testHerChineseSubtitleShowsTheSelectionMenu() throws {
        openNewFakeChat()
        assertSelectionMenu(containing: "晚上好。今天怎么了？")
    }

    /// Starts from an empty conversation so the known fake reply is the only line to press.
    private func openNewFakeChat() {
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
    }

    private func assertSelectionMenu(containing text: String) {
        // The scene, her line and the subtitle are one text view, so the bubble that
        // contains the wanted run is the element to press (spec #76).
        let bubble = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", text))
            .firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 20), "\(text) did not appear")
        XCTAssertTrue(bubble.label.contains(text), "bubble label is missing \(text): \(bubble.label)")
        bubble.press(forDuration: 1.2)
        XCTAssertTrue(
            app.menuItems.firstMatch.waitForExistence(timeout: 5),
            "long press did not show the system text menu for \(text)"
        )

        // The menu is not modal: the chat is still there, and scrolling still works.
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.exists, "text selection left the chat")
        input.tap()
        app.swipeUp()
        XCTAssertTrue(input.exists, "the chat stopped responding after text selection")
    }
}
