import XCTest

/// The play tab and the navigation it brought with it (spec #64): the three tabs, the
/// play hub's cards, the placeholder pages, and the routes between them. Needs a simulator
/// or device with the content bundle already imported, like the other page-walking tests.
final class PlayUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testTabsAndPlayHubCards() throws {
        let conversation = app.tabBars.buttons["对话"]
        XCTAssertTrue(conversation.waitForExistence(timeout: 10), "no conversation tab")

        let play = app.tabBars.buttons["玩法"]
        XCTAssertTrue(play.exists, "no play tab")
        play.tap()
        XCTAssertTrue(app.navigationBars["玩法"].waitForExistence(timeout: 5), "play hub did not open")
        XCTAssertTrue(app.buttons["play.gifts"].waitForExistence(timeout: 5), "no gift card")
        XCTAssertTrue(app.buttons["play.achievements"].exists, "no achievement card")
        XCTAssertTrue(app.buttons["play.bar"].exists, "no bar card")

        app.buttons["play.gifts"].tap()
        XCTAssertTrue(app.navigationBars["礼物"].waitForExistence(timeout: 5), "gift page did not open")
        XCTAssertTrue(
            app.staticTexts["礼物、抽奖和背包会在下一张票接入。"].waitForExistence(timeout: 5),
            "gift placeholder did not show"
        )
        app.navigationBars.buttons["玩法"].tap()
        XCTAssertTrue(app.navigationBars["玩法"].waitForExistence(timeout: 5))

        app.buttons["play.achievements"].tap()
        XCTAssertTrue(app.navigationBars["成就"].waitForExistence(timeout: 5), "achievement page did not open")
        XCTAssertTrue(
            app.staticTexts["成就页会在后续版本接入。"].waitForExistence(timeout: 5),
            "achievement placeholder did not show"
        )
        app.navigationBars.buttons["玩法"].tap()

        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "settings tab did not open")
        conversation.tap()
        XCTAssertTrue(app.navigationBars["对话"].waitForExistence(timeout: 5), "conversation tab did not return")
    }

    func testGiftRouteFromChatPreselectsHerAndComesBack() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launch()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "chat did not open")
        more.tap()
        let gifts = app.buttons["送她一件礼物"]
        XCTAssertTrue(gifts.waitForExistence(timeout: 5), "chat has no gift route")
        gifts.tap()

        XCTAssertTrue(app.navigationBars["礼物"].waitForExistence(timeout: 5), "gift page did not open")
        let go = app.buttons["gifts.goToConversation"]
        XCTAssertTrue(go.waitForExistence(timeout: 5), "no preselected character to go back to")
        go.tap()
        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 5), "did not return to her chat")
    }

    func testChatHidesTheTabBar() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launch()

        XCTAssertTrue(app.buttons["更多"].waitForExistence(timeout: 20), "chat did not open")
        XCTAssertFalse(app.tabBars.buttons["对话"].exists, "tab bar is still visible in the chat")
        XCTAssertFalse(app.tabBars.buttons["玩法"].exists, "tab bar is still visible in the chat")

        let back = app.navigationBars.buttons["对话"]
        XCTAssertTrue(
            back.waitForExistence(timeout: 5),
            "chat has no back button: \(app.navigationBars.buttons.debugDescription)"
        )
        back.tap()
        XCTAssertFalse(
            app.buttons["更多"].waitForExistence(timeout: 2),
            "back did not leave the chat"
        )
        XCTAssertTrue(
            app.tabBars.buttons["对话"].waitForExistence(timeout: 5),
            "tab bar did not come back after leaving the chat"
        )
    }

    func testCallBarFollowsToThePlayTab() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launchEnvironment["EIDOLON_OPEN_CALL"] = "1"
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_CALL_FAKE_SPEECH"] = "你好"
        app.launch()

        let hangUp = app.buttons["call.hangUp"]
        XCTAssertTrue(hangUp.waitForExistence(timeout: 20), "call did not start")
        app.buttons["收起"].firstMatch.tap()

        let play = app.tabBars.buttons["玩法"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), "no play tab while calling")
        play.tap()
        let back = app.buttons["回到通话"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "call bar is not on the play tab")
        back.tap()
        XCTAssertTrue(hangUp.waitForExistence(timeout: 5), "call did not expand")
    }
}
