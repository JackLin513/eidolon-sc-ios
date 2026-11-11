import XCTest

/// S2.2 visual QA. Every state is attached as a screenshot; `tools/qa_ipad.sh` extracts
/// them into `.qa-screenshots/` for direct inspection.
final class IPadVisualQATests: XCTestCase {
    private var app: XCUIApplication!
    private var baseEnvironment: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        baseEnvironment = [
            "EIDOLON_FAKE_CHAT": "1",
            "EIDOLON_CHAT_BASE_URL": "http://example.invalid",
            "EIDOLON_CHAT_MODEL": "fake",
            "EIDOLON_CHAT_API_KEY": "fake",
        ]
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    private var width: CGFloat {
        app.windows.firstMatch.frame.width
    }

    private func launch(environment: [String: String] = [:]) {
        app.terminate()
        app.launchEnvironment = baseEnvironment.merging(environment) { _, new in new }
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.splitHandle"].waitForExistence(timeout: 20)
                || app.buttons["对话"].waitForExistence(timeout: 20),
            "app did not become reachable"
        )
    }

    func testIPadVisualStates() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch()
        try XCTSkipUnless(width >= 650, "Run this on an iPad simulator")
        XCTAssertTrue(
            app.descendants(matching: .any)["conversation.splitHandle"].waitForExistence(timeout: 20),
            "landscape did not reach the wide shell"
        )
        attach("landscape-standard")

        launch(environment: ["EIDOLON_PAD_RAIL_WIDTH": "88"])
        attach("landscape-rail-narrow")

        launch(environment: ["EIDOLON_PAD_RAIL_WIDTH": "240"])
        attach("landscape-rail-wide")

        launch(environment: [
            "EIDOLON_PAD_RAIL_WIDTH": "165",
            "EIDOLON_PAD_ROSTER_WIDTH": "280",
        ])
        attach("landscape-roster-min")

        launch(environment: ["EIDOLON_PAD_DRAG_FEEDBACK": "split"])
        attach("landscape-split-active")

        launch(environment: ["EIDOLON_PAD_DRAG_FEEDBACK": "rail"])
        attach("landscape-rail-active")

        launch()
        openFirstChat()
        attach("landscape-selected")

        launch(environment: ["EIDOLON_PAD_ROSTER_WIDTH": "0"])
        openFirstChat()
        XCTAssertTrue(anyElement("conversation.splitHandle").label == "显示角色列表")
        attach("landscape-collapsed")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 20), "portrait transition did not show the chat")
        if width > 960 {
            // A 13-inch iPad is still wide in portrait; its chat stays in the split.
            XCTAssertTrue(anyElement("conversation.splitHandle").exists)
        } else {
            XCTAssertTrue(
                anyElement("conversation.splitHandle").waitForNonExistence(timeout: 10),
                "rotation kept the old wide splitter"
            )
        }
        attach("portrait-push")

        XCUIDevice.shared.orientation = .landscapeLeft
        tapTab("moments")
        XCTAssertTrue(app.staticTexts["朋友圈"].waitForExistence(timeout: 10))
        attach("moments-title")

        tapTab("play")
        XCTAssertTrue(app.buttons["play.gifts"].waitForExistence(timeout: 20))
        attach("play-title")

        tapTab("settings")
        XCTAssertTrue(app.buttons["settings.account"].waitForExistence(timeout: 10))
        attach("settings-title")
    }


    func testIPadSettingsSurfaceOptions() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        launch()
        try XCTSkipUnless(width >= 650, "Run this on an iPad simulator")

        let options: [(String, String)] = [
            ("allGray", "settings-all-gray"),
            ("middleWhite", "settings-middle-white"),
            ("grayCapsules", "settings-gray-capsules"),
        ]
        for (surface, name) in options {
            launch(environment: ["EIDOLON_SETTINGS_SURFACE": surface])
            tapTab("settings")
            XCTAssertTrue(
                app.buttons["settings.account"].waitForExistence(timeout: 15),
                "settings did not open for \(surface)"
            )
            attach(name)
        }
    }

    func testCompactPhoneVisualState() throws {
        launch()
        try XCTSkipUnless(width < 650, "Run this on an iPhone simulator")
        XCTAssertTrue(app.buttons["对话"].waitForExistence(timeout: 20), "compact tab bar missing")
        attach("compact-phone")
    }

    private func openFirstChat() {
        let name = app.staticTexts["櫻木真乃"].firstMatch.exists
            ? app.staticTexts["櫻木真乃"].firstMatch
            : app.staticTexts["大崎甘奈"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 20), "no roster row to select")
        name.tap()
        XCTAssertTrue(app.textFields["chat.input"].waitForExistence(timeout: 20), "chat did not open")
    }

    private func tapTab(_ tab: String) {
        let button = app.buttons["pad.tab.\(tab)"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "missing tab \(tab)")
        button.tap()
    }

    private func anyElement(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attach(_ name: String) {
        Thread.sleep(forTimeInterval: 0.7)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
