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

    func testGiftPageShowsTheEmptyBackpackAndNoChances() throws {
        launchGiftPage(draws: 0)

        let noDraws = app.staticTexts["今天的次数用完了"]
        XCTAssertTrue(noDraws.waitForExistence(timeout: 10), "no no-chances state")
        XCTAssertTrue(app.staticTexts["背包还是空的"].exists, "no empty backpack state")
        XCTAssertFalse(app.buttons["gifts.drawOne"].isEnabled, "a draw is offered with no chances")
        XCTAssertTrue(app.staticTexts["我的礼物"].exists, "no gift-list section")
        XCTAssertTrue(app.staticTexts["重置卡"].exists, "no reset card section")
    }

    func testDrawingRevealsAResultAndKeepsThePage() throws {
        launchGiftPage(draws: 2)

        let draw = app.buttons["gifts.drawOne"]
        XCTAssertTrue(draw.waitForExistence(timeout: 10), "no draw button")
        XCTAssertTrue(draw.isEnabled, "the draw button is disabled with two chances")
        draw.tap()

        XCTAssertTrue(
            app.staticTexts["这次抽到"].waitForExistence(timeout: 10),
            "the draw did not reveal a result"
        )
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "gifts.result."))
            .firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5), "no result card")
        XCTAssertTrue(app.buttons["gifts.drawOne"].exists, "the gift page left after drawing")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let predicate = NSPredicate(format: "label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    /// Launches with a known number of chances (debug injection) and opens the gift page.
    private func launchGiftPage(draws: Int, debugMode: Bool = false) {
        app.terminate()
        app.launchEnvironment = ["EIDOLON_GIFT_DRAWS": "\(draws)"]
        if debugMode {
            app.launchEnvironment["EIDOLON_DEBUG_MODE"] = "1"
        }
        app.launch()
        let play = app.tabBars.buttons["玩法"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "no play tab")
        play.tap()
        let gifts = app.buttons["play.gifts"]
        XCTAssertTrue(gifts.waitForExistence(timeout: 10), "no gift card")
        gifts.tap()
        XCTAssertTrue(app.navigationBars["礼物"].waitForExistence(timeout: 5), "gift page did not open")
    }

    func testDebugModeAddsDrawsFromTheGiftPagesCorner() throws {
        launchGiftPage(draws: 0, debugMode: true)

        let debug = app.buttons["gifts.debug"]
        XCTAssertTrue(debug.waitForExistence(timeout: 5), "no debug button on the gift page")
        debug.tap()
        XCTAssertTrue(
            app.navigationBars["调试：抽奖次数"].waitForExistence(timeout: 5),
            "the debug sheet did not open"
        )
        let sheetDraws = app.staticTexts["gifts.debug.draws"]
        XCTAssertTrue(sheetDraws.waitForExistence(timeout: 5), "no draw count in the sheet")
        XCTAssertEqual(sheetDraws.label, "0", "the debug launch did not start from zero")
        app.buttons["gifts.debug.addTen"].tap()
        XCTAssertTrue(
            NSPredicate(format: "label == %@", "10").evaluate(with: sheetDraws)
                || waitForLabel(sheetDraws, "10"),
            "the sheet did not show ten after adding: \(sheetDraws.label)"
        )
        app.buttons["完成"].tap()

        let pageDraws = app.staticTexts["gifts.draws"]
        XCTAssertTrue(pageDraws.waitForExistence(timeout: 5), "no draw count on the gift page")
        XCTAssertEqual(
            pageDraws.label,
            "10 / 7",
            "the gift page did not pick up the added chances"
        )
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

    func testBarTurnsLandscapeAndComesBackUpright() throws {
        app.tabBars.buttons["玩法"].tap()
        let bar = app.buttons["play.bar"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), "no bar card")
        bar.tap()

        let door = app.buttons["点一下进门"]
        XCTAssertTrue(door.waitForExistence(timeout: 10), "bar did not open")
        let sideways = app.windows.firstMatch.frame
        XCTAssertGreaterThan(sideways.width, sideways.height, "bar did not turn landscape")

        let leave = app.buttons["离开"]
        XCTAssertTrue(leave.waitForExistence(timeout: 5), "no leave control")
        leave.tap()

        let upright = app.windows.firstMatch.frame
        XCTAssertGreaterThan(upright.height, upright.width, "did not return to portrait")
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

    func testCollapsedCallBannerStaysAboveEachTabsTitle() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launchEnvironment["EIDOLON_OPEN_CALL"] = "1"
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_CALL_FAKE_SPEECH"] = "你好"
        app.launch()

        XCTAssertTrue(app.buttons["call.hangUp"].waitForExistence(timeout: 20), "call did not start")
        app.buttons["收起"].firstMatch.tap()

        // Leave her chat for the roster: the debug launch must only open it once, or the
        // back button immediately reopens the chat (spec #62).
        let back = app.navigationBars.buttons["对话"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "chat has no back to the roster")
        back.tap()
        let calendar = app.buttons["日历"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5), "back did not reach the roster")

        // The folded call's banner is a band above the tab's navigation, not inside it:
        // inside the list, the iOS 26 navigation bar tints itself with the banner's dark
        // colour and the title disappears (spec #64).
        let bar = app.buttons["回到通话"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no folded call banner on the roster")
        XCTAssertGreaterThan(
            calendar.frame.minY, bar.frame.maxY,
            "the roster's navigation is under the call banner"
        )

        app.tabBars.buttons["玩法"].tap()
        let playTitle = app.staticTexts["玩法"].firstMatch
        XCTAssertTrue(playTitle.waitForExistence(timeout: 5), "play title is missing")
        XCTAssertGreaterThan(
            playTitle.frame.minY, bar.frame.maxY,
            "the play title is under the call banner"
        )

        app.tabBars.buttons["设置"].tap()
        let settingsTitle = app.staticTexts["设置"].firstMatch
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "settings title is missing")
        XCTAssertGreaterThan(
            settingsTitle.frame.minY, bar.frame.maxY,
            "the settings title is under the call banner"
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
