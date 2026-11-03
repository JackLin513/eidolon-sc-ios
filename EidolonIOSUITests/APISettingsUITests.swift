import XCTest

/// 设置 → API 与模型 (spec #80): the page exists, a sample `.env` previews before it is
/// applied, a fetched model can be chosen, and a probe's result appears beside its button.
final class APISettingsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func openAPIPage(fakeProbe: String? = nil, envText: String? = nil) {
        // A configured chat model makes the page's fetch and test buttons usable without
        // typing a key.
        app.launchEnvironment["EIDOLON_CHAT_API_KEY"] = "ui-test-key"
        app.launchEnvironment["EIDOLON_CHAT_BASE_URL"] = "https://api.example.com/v1"
        app.launchEnvironment["EIDOLON_CHAT_MODEL"] = "model-a"
        app.launchEnvironment["EIDOLON_API_MODEL_LIST"] = "model-a,model-b,another-model"
        if let fakeProbe {
            app.launchEnvironment["EIDOLON_API_PROBE"] = fakeProbe
        }
        if let envText {
            app.launchEnvironment["EIDOLON_API_ENV_TEXT"] = envText
        }
        app.launch()

        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no settings button")
        settings.tap()

        let api = app.buttons["settings.api"].firstMatch
        XCTAssertTrue(api.waitForExistence(timeout: 10), "no API row")
        api.tap()

        XCTAssertTrue(
            app.textFields["api.chat.baseURL"].waitForExistence(timeout: 10),
            "the API page did not open"
        )
    }

    func testThePageShowsEveryServiceAndSavesAModelChosenFromTheList() {
        openAPIPage()

        // The chat model's list first, while the page is at the top.
        let fetch = app.buttons["api.fetch.chat"]
        XCTAssertTrue(fetch.waitForExistence(timeout: 5), "no fetch button")
        fetch.tap()

        let second = app.buttons["api.model.model-b"].firstMatch
        XCTAssertTrue(second.waitForExistence(timeout: 10), "the model picker did not open")
        XCTAssertTrue(
            app.staticTexts["推荐"].firstMatch.exists,
            "no recommended mark in the picker"
        )
        second.tap()

        XCTAssertEqual(app.textFields["api.chat.model"].value as? String, "model-b")

        app.buttons["api.save"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the page did not save")
        saved.buttons["好"].tap()

        // Then the sections below, which the lazy Form only builds when scrolled to.
        XCTAssertTrue(scroll(to: "api.background.model"))
        XCTAssertTrue(scroll(to: "api.test.judge"))
        XCTAssertTrue(scroll(to: "api.retrieval.embeddingModel"))
        if app.staticTexts["当前内容包"].firstMatch.exists {
            XCTAssertFalse(
                app.textFields["api.retrieval.embeddingModel"].isEnabled,
                "the embedding model must be locked to the installed bundle"
            )
        }
        XCTAssertTrue(scroll(to: "api.test.embedding"))
        XCTAssertTrue(scroll(to: "api.test.soniox"))
    }

    func testASampleEnvPreviewsItsGroupsAndApplies() {
        openAPIPage(envText: """
            CHAT_LLM_MODEL=preview-model
            EIDOLON_DOMAIN=example.com
            UNKNOWN_SETTING=1
            """)

        XCTAssertTrue(
            app.navigationBars["导入 .env"].waitForExistence(timeout: 10),
            "no import preview"
        )
        XCTAssertTrue(app.staticTexts["将改动"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["EIDOLON_DOMAIN"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["UNKNOWN_SETTING"].firstMatch.exists)

        app.buttons["api.import.confirm"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "import did not save")
        saved.buttons["好"].tap()

        let model = app.textFields["api.chat.model"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertEqual(model.value as? String, "preview-model")
    }

    func testAProbeResultShowsBesideItsButton() {
        openAPIPage(fakeProbe: "failure")

        scroll(to: "api.test.chat")
        let test = app.buttons["api.test.chat"]
        XCTAssertTrue(test.waitForExistence(timeout: 5))
        test.tap()

        let result = app.staticTexts["失败"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "no probe result")
        XCTAssertTrue(app.staticTexts["调试注入：密钥无效"].firstMatch.exists)
    }

    @discardableResult
    private func scroll(to identifier: String) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<10 where !element.isHittable {
            app.swipeUp()
        }
        return element.exists
    }
}
