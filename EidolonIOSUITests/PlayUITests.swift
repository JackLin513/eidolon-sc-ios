import XCTest

/// The play tab and the navigation it brought with it (spec #64, #94): the four tabs, the
/// moments placeholder, the play hub's five cards, and the routes between them. Needs a
/// simulator or device with the content bundle already imported, like the other
/// page-walking tests.
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

        let labels = (0..<app.tabBars.buttons.count).map {
            app.tabBars.buttons.element(boundBy: $0).label
        }
        XCTAssertEqual(labels, ["对话", "朋友圈", "玩法", "设置"], "tabs are not the upstream order")
        XCTAssertFalse(app.buttons["日历"].exists, "the conversation list still has a calendar button")

        let moments = app.tabBars.buttons["朋友圈"]
        moments.tap()
        XCTAssertTrue(app.navigationBars["朋友圈"].waitForExistence(timeout: 5), "moments did not open")
        XCTAssertTrue(
            app.descendants(matching: .any)["moments.placeholder"].waitForExistence(timeout: 5),
            "moments has no placeholder"
        )

        let play = app.tabBars.buttons["玩法"]
        play.tap()
        XCTAssertTrue(app.navigationBars["玩法"].waitForExistence(timeout: 5), "play hub did not open")
        XCTAssertTrue(app.buttons["play.gifts"].waitForExistence(timeout: 5), "no gift card")
        XCTAssertTrue(app.buttons["play.achievements"].exists, "no achievement card")
        XCTAssertTrue(app.buttons["play.calendar"].exists, "no calendar card")
        XCTAssertTrue(app.buttons["play.cycles"].exists, "no cycles card")
        XCTAssertTrue(app.buttons["play.bar"].exists, "no bar card")
        XCTAssertLessThan(
            app.buttons["play.gifts"].frame.minY,
            app.buttons["play.achievements"].frame.minY,
            "the cards are not in the upstream order"
        )
        XCTAssertLessThan(
            app.buttons["play.calendar"].frame.minY,
            app.buttons["play.cycles"].frame.minY,
            "the calendar card is not above the cycles card"
        )
        XCTAssertTrue(app.buttons["play.gifts"].label.contains("抽奖"), "the gift card has no status")
        let achievementsLabel = app.buttons["play.achievements"].label
        XCTAssertTrue(
            achievementsLabel.contains("阶段") || achievementsLabel.contains("新解锁"),
            "the achievement card has no status: \(achievementsLabel)"
        )
        let cyclesLabel = app.buttons["play.cycles"].label
        XCTAssertTrue(
            cyclesLabel.contains("记过") || cyclesLabel.contains("还没有记录"),
            "the cycles card has no status: \(cyclesLabel)"
        )

        app.buttons["play.gifts"].tap()
        XCTAssertTrue(app.navigationBars["礼物"].waitForExistence(timeout: 5), "gift page did not open")
        app.navigationBars.buttons["玩法"].tap()
        XCTAssertTrue(app.navigationBars["玩法"].waitForExistence(timeout: 5))

        app.buttons["play.achievements"].tap()
        XCTAssertTrue(app.navigationBars["成就"].waitForExistence(timeout: 5), "achievement page did not open")
        XCTAssertTrue(
            app.descendants(matching: .any)["achievement.characters"].waitForExistence(timeout: 5),
            "the combined achievements did not show"
        )
        XCTAssertTrue(app.descendants(matching: .any)["achievement.draws"].exists)
        app.navigationBars.buttons["玩法"].tap()

        app.buttons["play.calendar"].tap()
        XCTAssertTrue(app.navigationBars["日历"].waitForExistence(timeout: 5), "calendar page did not open")
        app.navigationBars.buttons["玩法"].tap()

        app.buttons["play.cycles"].tap()
        XCTAssertTrue(app.navigationBars["周期"].waitForExistence(timeout: 5), "cycles page did not open")
        app.navigationBars.buttons["玩法"].tap()

        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5), "settings tab did not open")
        XCTAssertFalse(app.buttons["查看周期"].exists, "settings still opens the cycle page")
        conversation.tap()
        XCTAssertTrue(app.navigationBars["对话"].waitForExistence(timeout: 5), "conversation tab did not return")
    }

    func testReturningFromAGiftShowsItAtOnce() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launchEnvironment["EIDOLON_GIFT_BACKPACK"] = "cake:1"
        app.launch()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "chat did not open")
        more.tap()
        let gifts = app.buttons["送她一件礼物"]
        XCTAssertTrue(gifts.waitForExistence(timeout: 5), "chat has no gift route")
        gifts.tap()

        let cake = app.buttons["gifts.backpack.cake"]
        XCTAssertTrue(cake.waitForExistence(timeout: 10), "the injected cake is not in the backpack")
        cake.tap()
        let send = app.buttons["gifts.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        send.tap()

        let sent = app.alerts["送给蛋糕了"]
        XCTAssertTrue(sent.waitForExistence(timeout: 10), "the gift was not acknowledged")
        sent.buttons["去对话"].tap()

        let lines = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "你送给")
        )
        XCTAssertTrue(lines.firstMatch.waitForExistence(timeout: 5), "the gift is not in her chat")
        // The simulator keeps gifts from earlier runs; the one just sent is the newest.
        let line = lines.element(boundBy: lines.count - 1)
        XCTAssertTrue(line.isHittable, "the chat stayed at the old bottom")
        XCTAssertTrue(
            app.tabBars.buttons["玩法"].waitForNonExistence(timeout: 5),
            "the tab bar came back on the chat page"
        )
    }

    func testHerScheduleFromChatOpensThePlayCalendar() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launch()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "chat did not open")
        more.tap()
        let schedule = app.buttons["她的日程"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5), "chat has no schedule route")
        guard schedule.isEnabled else {
            throw XCTSkip("this content bundle has no job list")
        }
        schedule.tap()

        XCTAssertTrue(
            app.navigationBars["她的日程"].waitForExistence(timeout: 10),
            "her schedule did not open in the play tab"
        )
        XCTAssertTrue(app.tabBars.buttons["玩法"].isSelected, "the play tab is not selected")
        app.navigationBars.buttons["玩法"].tap()
        XCTAssertTrue(
            app.navigationBars["玩法"].waitForExistence(timeout: 5),
            "back did not reach the play page"
        )
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
    private func launchGiftPage(
        draws: Int,
        debugMode: Bool = false,
        backpack: String? = nil
    ) {
        app.terminate()
        app.launchEnvironment = ["EIDOLON_GIFT_DRAWS": "\(draws)"]
        if let backpack {
            app.launchEnvironment["EIDOLON_GIFT_BACKPACK"] = backpack
        }
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

    func testGivingAGiftFromTheBackpackShowsTheResult() throws {
        launchGiftPage(draws: 0, backpack: "cake:1")

        let cake = app.buttons["gifts.backpack.cake"]
        XCTAssertTrue(cake.waitForExistence(timeout: 10), "the injected cake is not in the backpack")
        cake.tap()
        XCTAssertTrue(app.navigationBars["送礼物"].waitForExistence(timeout: 5), "no gift panel")
        let send = app.buttons["gifts.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "no send button")
        XCTAssertTrue(send.isEnabled, "the first character should be selected")
        send.tap()

        XCTAssertTrue(
            app.alerts["送给蛋糕了"].waitForExistence(timeout: 10),
            "the gift was not acknowledged"
        )
        app.alerts["送给蛋糕了"].buttons["好"].tap()
    }

    func testHerAchievementsOpenFromTheChatMenu() throws {
        app.terminate()
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launch()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "chat did not open")
        more.tap()
        let achievements = app.buttons["成就"]
        XCTAssertTrue(achievements.waitForExistence(timeout: 5), "chat has no achievements")
        achievements.tap()

        let title = app.navigationBars
            .matching(NSPredicate(format: "identifier ENDSWITH %@", "的成就"))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), "her achievements did not open")
        XCTAssertTrue(
            app.descendants(matching: .any)["achievement.turns"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.descendants(matching: .any)["achievement.complete"].exists)
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
        XCTAssertTrue(
            app.tabBars.buttons["玩法"].waitForNonExistence(timeout: 5),
            "the tab bar came back on the chat page"
        )
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
        let roster = app.navigationBars["对话"]
        XCTAssertTrue(roster.waitForExistence(timeout: 5), "back did not reach the roster")

        // The folded call's banner is a band above the tab's navigation, not inside it:
        // inside the list, the iOS 26 navigation bar tints itself with the banner's dark
        // colour and the title disappears (spec #64).
        let bar = app.buttons["回到通话"].firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "no folded call banner on the roster")
        XCTAssertGreaterThan(
            roster.frame.minY, bar.frame.maxY,
            "the roster's navigation is under the call banner"
        )

        app.tabBars.buttons["玩法"].tap()
        let playTitle = app.staticTexts["玩法"].firstMatch
        XCTAssertTrue(playTitle.waitForExistence(timeout: 5), "play title is missing")
        XCTAssertGreaterThan(
            playTitle.frame.minY, bar.frame.maxY,
            "the play title is under the call banner"
        )

        app.tabBars.buttons["朋友圈"].tap()
        let momentsTitle = app.staticTexts["朋友圈"].firstMatch
        XCTAssertTrue(momentsTitle.waitForExistence(timeout: 5), "moments title is missing")
        XCTAssertGreaterThan(
            momentsTitle.frame.minY, bar.frame.maxY,
            "the moments title is under the call banner"
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
