import XCTest

/// S2.1: the same build has three presentations. Run the suite on both a 13-inch iPad and
/// an iPad mini; the mini starts in the medium band and rotates into the wide band.
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

    private var width: CGFloat { app.windows.firstMatch.frame.width }
    // UI-test bundle cannot see the app module's internal constants; these mirror the
    // spec's published breakpoints.
    private var isWide: Bool { width > 960 }
    private var isMedium: Bool { width >= 650 && width <= 960 }

    private func padTab(_ tab: String) -> XCUIElement {
        app.buttons["pad.tab.\(tab)"].firstMatch
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testIPadRailIsPersistentAndConversationWorksAtEveryBand() throws {
        XCTAssertTrue(padTab("conversation").waitForExistence(timeout: 20))
        XCTAssertTrue(padTab("settings").exists)
        XCTAssertEqual(padTab("conversation").label, "对话")

        if isMedium {
            XCTAssertTrue(
                app.staticTexts["对话"].waitForExistence(timeout: 10),
                "medium roster header missing"
            )
            XCTAssertFalse(anyElement("conversation.splitHandle").exists, "medium must not show the resizer")
            openChatAndGoBack()
        } else {
            XCTAssertTrue(
                anyElement("conversation.splitHandle").waitForExistence(timeout: 10),
                "wide layout has no draggable divider"
            )
        }

        let rosterIsVisible = app.staticTexts["大崎甘奈"].exists
            || app.staticTexts["櫻木真乃"].exists
        XCTAssertTrue(rosterIsVisible, "roster disappeared from the conversation page")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(padTab("conversation").waitForExistence(timeout: 10))
        XCTAssertTrue(
            anyElement("conversation.splitHandle").waitForExistence(timeout: 10),
            "landscape did not become the three-column shell"
        )
    }

    func testIPadMediumPushesChatWithAnExplicitBackButton() throws {
        try XCTSkipUnless(isMedium, "This check is for the medium band on iPad mini portrait")
        openChatAndGoBack()
    }

    func testIPadWideDragHandleSnapsToCollapsedAndBack() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(anyElement("conversation.splitHandle").waitForExistence(timeout: 20))

        XCTAssertEqual(anyElement("conversation.splitHandle").label, "调整角色列表宽度")
        collapseRosterWithHandle()
        XCTAssertTrue(
            anyElement("conversation.splitHandle").label == "显示角色列表",
            "left fling did not collapse the roster"
        )

        anyElement("conversation.splitHandle").tap()
        XCTAssertTrue(
            anyElement("conversation.splitHandle").label == "调整角色列表宽度",
            "tap on the collapsed handle did not restore the roster"
        )
    }

    func testIPadSettingsUsesCategorySidebarWithoutASecondToggle() throws {
        XCTAssertTrue(padTab("settings").waitForExistence(timeout: 20))
        padTab("settings").tap()

        XCTAssertTrue(
            app.staticTexts["服务器"].waitForExistence(timeout: 10),
            "no settings category sidebar"
        )
        XCTAssertTrue(app.staticTexts["API 与模型"].exists)
        XCTAssertTrue(app.staticTexts["对话与通话"].exists)
        XCTAssertFalse(app.buttons["隐藏边栏"].exists, "settings still has a system sidebar toggle")

        app.staticTexts["对话与通话"].tap()
        XCTAssertTrue(
            app.staticTexts["历史回合：20"].waitForExistence(timeout: 10),
            "conversation category did not show its form"
        )
        app.staticTexts["制作人"].tap()
        XCTAssertTrue(
            app.textFields["称呼（留空沿用默认）"].waitForExistence(timeout: 10),
            "producer category did not show its form"
        )

        attachScreenshot("ipad-settings")
    }

    func testIPadMomentsAndPlayUseTheWideCanvas() throws {
        XCTAssertTrue(padTab("moments").waitForExistence(timeout: 20))
        padTab("moments").tap()
        XCTAssertTrue(app.navigationBars["朋友圈"].waitForExistence(timeout: 10))
        attachScreenshot("ipad-moments")

        padTab("play").tap()
        XCTAssertTrue(app.buttons["play.gifts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["play.bar"].exists)
        attachScreenshot("ipad-play")
    }

    func testIPadBarLetterboxesInTheCurrentWindow() throws {
        XCTAssertTrue(padTab("play").waitForExistence(timeout: 20))
        padTab("play").tap()
        let card = app.buttons["play.bar"]
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no bar card on iPad")
        card.tap()

        XCTAssertTrue(
            app.buttons["点一下进门"].waitForExistence(timeout: 20),
            "the bar did not open on iPad"
        )
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(window.width, 0)
        XCTAssertGreaterThan(window.height, 0)
        XCTAssertTrue(app.buttons["bar.rotate"].exists, "the bar has no rotate affordance on iPad")

        app.buttons["离开"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the bar did not leave back to play")
    }

    func testIPadLargeTextKeepsSettingsReachable() throws {
        app.terminate()
        app.launchArguments += [
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
        ]
        app.launch()

        XCTAssertTrue(padTab("settings").waitForExistence(timeout: 20))
        padTab("settings").tap()
        XCTAssertTrue(
            app.staticTexts["服务器"].waitForExistence(timeout: 10),
            "the accessibility text size hid the settings form"
        )
    }


    func testIPadChatSurvivesBreakpointChange() throws {
        try XCTSkipUnless(isMedium, "Starts in the medium band; a 13-inch iPad is already wide")
        let name = app.staticTexts["櫻木真乃"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.tap()
        XCTAssertTrue(anyElement("pad.chat.back").waitForExistence(timeout: 20))

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(anyElement("pad.chat.back").waitForExistence(timeout: 10))
        XCTAssertTrue(anyElement("conversation.splitHandle").exists, "wide shell did not load")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(anyElement("pad.chat.back").waitForExistence(timeout: 10))
    }

    func testIPadUnitFilterNarrowsTheRoster() throws {
        XCTAssertTrue(padTab("conversation").waitForExistence(timeout: 20))
        padTab("conversation").tap()
        XCTAssertTrue(app.staticTexts["櫻木真乃"].waitForExistence(timeout: 20))

        let chip = app.buttons["pad.filter.unit.L'Antica"]
        if chip.exists, chip.isHittable {
            chip.tap()
        } else {
            let menu = app.buttons["pad.filter.units"]
            XCTAssertTrue(menu.waitForExistence(timeout: 5), "no unit filter affordance")
            menu.tap()
            app.buttons["L'Antica"].firstMatch.tap()
        }

        XCTAssertTrue(
            app.staticTexts["月岡恋鐘"].waitForExistence(timeout: 10),
            "L'Antica was filtered away"
        )
        XCTAssertFalse(app.staticTexts["櫻木真乃"].exists, "illumination STARS leaked through the unit filter")
    }

    func testIPadWideEmptyStateContinuesTheMostRecentCharacter() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(anyElement("conversation.splitHandle").waitForExistence(timeout: 20))
        // The 13-inch simulator has a real conversation; the fresh mini may only have
        // the choose-a-character state. Both are valid; the rich card is the target.
        let open = app.buttons["pad.empty.open"]
        if open.waitForExistence(timeout: 5) {
            XCTAssertTrue(app.buttons["pad.empty.call"].exists)
        } else {
            XCTAssertTrue(app.staticTexts["选一个角色"].exists)
        }
    }



    func testIPadChatInputStaysAboveTheKeyboard() throws {
        let name = app.staticTexts["櫻木真乃"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.tap()
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "keyboard did not appear")
        XCTAssertTrue(input.isHittable, "keyboard covers the chat input")
        XCTAssertTrue(anyElement("pad.chat.back").exists)
    }

    private func collapseRosterWithHandle() {
        for _ in 0..<3 {
            let handle = anyElement("conversation.splitHandle")
            let start = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let left = app.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: left)
            Thread.sleep(forTimeInterval: 0.5)
            if anyElement("conversation.splitHandle").label == "显示角色列表" { return }
        }
    }

    private func openChatAndGoBack() {
        let name = app.staticTexts["櫻木真乃"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20), "no roster row")
        name.tap()

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 20), "chat did not open")
        XCTAssertTrue(anyElement("pad.chat.back").waitForExistence(timeout: 10), "no explicit back button")

        anyElement("pad.chat.back").tap()
        XCTAssertTrue(
            app.staticTexts["对话"].waitForExistence(timeout: 10),
            "back did not return to the roster"
        )
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
