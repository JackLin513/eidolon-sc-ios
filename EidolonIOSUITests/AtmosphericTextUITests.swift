import XCTest

/// 文字氛围模式 (spec #60): a scene block is shown in the bubble, before the spoken line.
final class AtmosphericTextUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchFakeChat() {
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "hiori"
        app.launch()
    }

    /// Starts from an empty conversation so an older scene cannot satisfy the assertion.
    private func startNewConversation() {
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
    }

    private func send(_ text: String) {
        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 10), "no chat input")
        // The page can rebuild once the new conversation's affinity arrives, dropping the
        // focus the first tap gave; tap again on the field the query now resolves to.
        input.tap()
        sleep(1)
        input.tap()
        sleep(1)
        input.typeText(text)
        app.buttons["chat.send"].tap()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testASceneBlockIsShownBeforeTheLine() throws {
        launchFakeChat()
        startNewConversation()
        send("你好")
        let bubble = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "她把杯子放下，抬眼看过来。"))
            .firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 20), "scene block did not appear")
        let label = bubble.label
        let sceneRange = label.range(of: "她把杯子放下，抬眼看过来。")
        let lineRange = label.range(of: "こんばんは。今日はどうしたの？")
        XCTAssertNotNil(sceneRange, "scene is missing from \(label)")
        XCTAssertNotNil(lineRange, "line is missing from \(label)")
        if let sceneRange, let lineRange {
            XCTAssertLessThan(sceneRange.lowerBound, lineRange.lowerBound, "scene is not before the line")
        }
    }

    func testTurningTheModeOffShowsOnlyTheLine() throws {
        addTeardownBlock { [weak self] in
            self?.setAtmosphericText(on: true)
        }

        app.launch()
        openSettings()
        let toggle = app.switches["settings.atmosphericText"].firstMatch
        scrollTo(toggle)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no atmospheric text toggle")
        Self.setSwitch(toggle, on: false)
        XCTAssertEqual(
            toggle.value as? String,
            "0",
            "the toggle did not turn off: \(toggle.frame) hittable=\(toggle.isHittable)"
        )
        app.buttons["保存"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "settings did not save")
        saved.buttons["好"].tap()
        sleep(2)
        app.terminate()

        // A new conversation, so no scene from an older reply can be mistaken for this one.
        launchFakeChat()
        startNewConversation()
        send("你好")

        let bubble = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS %@", "晚上好。今天怎么了？"))
            .firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 20), "the line did not appear")
        XCTAssertTrue(bubble.label.contains("こんばんは。今日はどうしたの？"), "Japanese line is missing")
        XCTAssertFalse(
            bubble.label.contains("她把杯子放下，抬眼看过来。"),
            "the mode is off but a scene block still appeared"
        )

        // The bubble is one selectable run; long press anywhere in it (spec #75, #76).
        bubble.press(forDuration: 1.2)
        XCTAssertTrue(
            app.menuItems.firstMatch.waitForExistence(timeout: 5),
            "long press on her line did not show the selection menu"
        )
    }

    private func openSettings() {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no settings button")
        settings.tap()
    }

    private func scrollTo(_ element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
    }

    private func setAtmosphericText(on: Bool) {
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        openSettings()
        let toggle = app.switches["settings.atmosphericText"].firstMatch
        scrollTo(toggle)
        Self.setSwitch(toggle, on: on)
        app.buttons["保存"].tap()
        _ = app.alerts["已保存"].waitForExistence(timeout: 10)
        sleep(1)
        app.terminate()
    }

    private static func setSwitch(_ toggle: XCUIElement, on: Bool) {
        if (toggle.value as? String) == (on ? "1" : "0") { return }
        // The identifier is on the row; the switch itself is a child element.
        let knob = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        knob.tap()
    }
}

/// 成人模式 (spec #61): default off, saved locally; its footer states the 18+ boundary.
final class AdultModeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testAdultModeDefaultsOffAndStaysOnAfterSaving() throws {
        addTeardownBlock { [weak self] in
            self?.setAdultMode(on: false)
        }

        app.launch()
        openSettings()
        let toggle = app.switches["settings.adultMode"].firstMatch
        for _ in 0..<8 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no adult mode toggle")
        XCTAssertEqual(toggle.value as? String, "0", "adult mode should default off")
        XCTAssertTrue(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "18 岁及以上")
            ).firstMatch.exists,
            "the 18+ boundary is not explained"
        )

        Self.setSwitch(toggle, on: true)
        app.buttons["保存"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "settings did not save")
        saved.buttons["好"].tap()
        sleep(2)
        app.terminate()

        app.launch()
        openSettings()
        let again = app.switches["settings.adultMode"].firstMatch
        for _ in 0..<8 where !again.isHittable {
            app.swipeUp()
        }
        XCTAssertEqual(again.value as? String, "1", "adult mode did not persist")
    }

    func testDebugInjectionTurnsAdultModeOn() throws {
        addTeardownBlock { [weak self] in
            self?.setAdultMode(on: false)
        }

        app.launchEnvironment["EIDOLON_ADULT_MODE"] = "1"
        app.launch()
        openSettings()
        let toggle = app.switches["settings.adultMode"].firstMatch
        for _ in 0..<8 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no adult mode toggle")
        XCTAssertEqual(toggle.value as? String, "1", "the debug injection did not turn it on")
    }

    private func openSettings() {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no settings button")
        settings.tap()
    }

    private func setAdultMode(on: Bool) {
        app.terminate()
        app.launchEnvironment = [:]
        app.launch()
        openSettings()
        let toggle = app.switches["settings.adultMode"].firstMatch
        for _ in 0..<8 where !toggle.isHittable {
            app.swipeUp()
        }
        Self.setSwitch(toggle, on: on)
        app.buttons["保存"].tap()
        _ = app.alerts["已保存"].waitForExistence(timeout: 10)
        sleep(1)
        app.terminate()
    }

    private static func setSwitch(_ toggle: XCUIElement, on: Bool) {
        if (toggle.value as? String) == (on ? "1" : "0") { return }
        let knob = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        knob.tap()
    }
}
