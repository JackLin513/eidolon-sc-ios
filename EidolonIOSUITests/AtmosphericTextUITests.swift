import XCTest

/// 文字氛围模式 (spec #60): a scene block is shown in the bubble, before the spoken line.
final class AtmosphericTextUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchFakeChat(send: Bool) {
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "mano"
        if send {
            app.launchEnvironment["EIDOLON_SEND_TEXT"] = "你好"
        }
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testASceneBlockIsShownBeforeTheLine() throws {
        launchFakeChat(send: true)
        let scenes = app.staticTexts.matching(identifier: "reply.scene")
        XCTAssertTrue(scenes.firstMatch.waitForExistence(timeout: 20), "scene block did not appear")
        XCTAssertEqual(scenes.firstMatch.label, "她把杯子放下，抬眼看过来。")
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
        launchFakeChat(send: false)
        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no chat menu")
        more.tap()
        app.buttons["新对话"].tap()
        XCTAssertTrue(
            app.staticTexts["从一句问候开始吧。"].waitForExistence(timeout: 10),
            "the conversation did not start over"
        )

        let input = app.textFields["chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5), "no chat input")
        input.tap()
        input.typeText("你好")
        app.buttons["chat.send"].tap()

        XCTAssertTrue(
            app.staticTexts["晚上好。今天怎么了？"].waitForExistence(timeout: 20),
            "the line did not appear"
        )
        XCTAssertFalse(
            app.staticTexts.matching(identifier: "reply.scene").firstMatch.exists,
            "the mode is off but a scene block still appeared"
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
