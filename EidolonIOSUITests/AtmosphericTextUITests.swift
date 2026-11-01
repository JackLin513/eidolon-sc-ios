import XCTest

/// 文字氛围模式 (spec #60): a scene block is shown in the bubble, before the spoken line.
final class AtmosphericTextUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["EIDOLON_FAKE_CHAT"] = "1"
        app.launchEnvironment["EIDOLON_OPEN_CHARACTER"] = "mano"
        app.launchEnvironment["EIDOLON_SEND_TEXT"] = "你好"
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testASceneBlockIsShownBeforeTheLine() throws {
        let scenes = app.staticTexts.matching(identifier: "reply.scene")
        XCTAssertTrue(scenes.firstMatch.waitForExistence(timeout: 20), "scene block did not appear")
        XCTAssertEqual(scenes.firstMatch.label, "她把杯子放下，抬眼看过来。")
    }
}
