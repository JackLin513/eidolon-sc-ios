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

    private func openAPIPage(
        fakeProbe: String? = nil,
        envText: String? = nil,
        chatBaseURL: String = "https://api.example.com/v1",
        chatProtocol: String = "chat-completions",
        retrievalAPIKey: String? = nil,
        geminiAPIKey: String? = nil,
        fakeGeminiBundle: Bool = false,
        sttProvider: String? = nil,
        dashscopeAPIKey: String? = nil
    ) {
        // A configured chat model makes the page's fetch and test buttons usable without
        // typing a key.
        app.launchEnvironment["EIDOLON_CHAT_API_KEY"] = "ui-test-key"
        app.launchEnvironment["EIDOLON_CHAT_BASE_URL"] = chatBaseURL
        app.launchEnvironment["EIDOLON_CHAT_PROTOCOL"] = chatProtocol
        app.launchEnvironment["EIDOLON_CHAT_MODEL"] = "model-a"
        app.launchEnvironment["EIDOLON_API_MODEL_LIST"] = "model-a,model-b,another-model"
        if let fakeProbe {
            app.launchEnvironment["EIDOLON_API_PROBE"] = fakeProbe
        }
        if let envText {
            app.launchEnvironment["EIDOLON_API_ENV_TEXT"] = envText
        }
        if let retrievalAPIKey {
            app.launchEnvironment["EIDOLON_RETRIEVAL_API_KEY"] = retrievalAPIKey
        }
        if let geminiAPIKey {
            app.launchEnvironment["EIDOLON_GEMINI_API_KEY"] = geminiAPIKey
        }
        if fakeGeminiBundle {
            app.launchEnvironment["EIDOLON_FAKE_GEMINI_BUNDLE"] = "1"
        }
        app.launchEnvironment["EIDOLON_STT_PROVIDER"] = sttProvider ?? "soniox"
        if let dashscopeAPIKey {
            app.launchEnvironment["EIDOLON_DASHSCOPE_API_KEY"] = dashscopeAPIKey
        }
        app.launch()

        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no settings button")
        settings.tap()

        let api = app.buttons["settings.api"].firstMatch
        XCTAssertTrue(api.waitForExistence(timeout: 10), "no API row")
        api.tap()

        if envText == nil {
            XCTAssertTrue(
                scroll(to: "api.chat.baseURL"),
                "the API page did not open"
            )
        }
        // With a sample .env, the import preview sheet covers the page; that test waits
        // for the preview itself instead of the field underneath.
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
        XCTAssertTrue(
            app.staticTexts["preview-model"].firstMatch.exists,
            "the preview does not show the value that will be written"
        )
        XCTAssertTrue(app.staticTexts["EIDOLON_DOMAIN"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["UNKNOWN_SETTING"].firstMatch.exists)

        app.buttons["api.import.confirm"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "import did not save")
        saved.buttons["好"].tap()

        XCTAssertTrue(scroll(to: "api.chat.model"))
        let model = app.textFields["api.chat.model"]
        XCTAssertEqual(model.value as? String, "preview-model")
    }

    func testBailianRecognitionCanBeChosenAndShowsItsKeyAndModel() {
        openAPIPage(sttProvider: "bailian", dashscopeAPIKey: "ui-test-dashscope")

        XCTAssertTrue(scroll(to: "api.call.dashscopeKey"))
        XCTAssertTrue(
            app.secureTextFields["api.call.dashscopeKey"].exists,
            "the Bailian key field is missing"
        )
        XCTAssertTrue(scroll(to: "api.call.bailianSTTModel"))
        let model = app.textFields["api.call.bailianSTTModel"]
        XCTAssertTrue(model.exists, "the Bailian model field is missing")
        XCTAssertEqual(model.value as? String, "qwen-audio-3.1-asr-flash-streaming")
        XCTAssertTrue(scroll(to: "api.test.bailianSTT"))
        XCTAssertFalse(
            app.textFields["api.call.sonioxModel"].exists,
            "Soniox fields must not show while Bailian is chosen"
        )

        let provider = app.buttons["api.call.sttProvider"].firstMatch
        XCTAssertTrue(provider.exists, "no recognition provider picker")
        provider.tap()
        let soniox = app.buttons["Soniox"].firstMatch
        XCTAssertTrue(soniox.waitForExistence(timeout: 5), "no Soniox option")
        soniox.tap()
        XCTAssertTrue(scroll(to: "api.call.sonioxModel"))
        XCTAssertFalse(
            app.secureTextFields["api.call.dashscopeKey"].exists,
            "Bailian fields must not show while Soniox is chosen"
        )
    }

    func testBailianProbeShowsItsResult() {
        openAPIPage(
            fakeProbe: "failure",
            sttProvider: "bailian",
            dashscopeAPIKey: "ui-test-dashscope"
        )

        XCTAssertTrue(scroll(to: "api.test.bailianSTT"))
        let test = app.buttons["api.test.bailianSTT"]
        XCTAssertTrue(test.exists)
        test.tap()

        let result = app.staticTexts["失败"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10), "no Bailian probe result")
        XCTAssertTrue(app.staticTexts["调试注入：密钥无效"].firstMatch.exists)
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

    func testSwitchingToAnthropicMovesTheDeepSeekAddress() {
        openAPIPage(chatBaseURL: "https://api.deepseek.com")

        let picker = app.buttons["api.chat.protocol"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no protocol picker")
        picker.tap()
        let anthropic = app.buttons["Anthropic Messages"].firstMatch
        XCTAssertTrue(anthropic.waitForExistence(timeout: 5), "no Anthropic option")
        anthropic.tap()

        let baseURL = app.textFields["api.chat.baseURL"]
        XCTAssertTrue(baseURL.waitForExistence(timeout: 5))
        XCTAssertEqual(
            baseURL.value as? String,
            "https://api.deepseek.com/anthropic",
            "the Anthropic surface of DeepSeek is under /anthropic"
        )

        picker.tap()
        let chatCompletions = app.buttons["Chat Completions"].firstMatch
        XCTAssertTrue(chatCompletions.waitForExistence(timeout: 5))
        chatCompletions.tap()
        XCTAssertEqual(baseURL.value as? String, "https://api.deepseek.com")
    }

    func testAStoredDeepSeekAnthropicAddressIsHealedOnLoad() {
        openAPIPage(
            chatBaseURL: "https://api.deepseek.com",
            chatProtocol: "anthropic"
        )
        let baseURL = app.textFields["api.chat.baseURL"]
        XCTAssertTrue(baseURL.waitForExistence(timeout: 5))
        XCTAssertEqual(
            baseURL.value as? String,
            "https://api.deepseek.com/anthropic",
            "an older saved Anthropic config should be moved on load"
        )
    }

    func testTheRetrievalFetchButtonWorksWithTheDefaultAddress() {
        openAPIPage(retrievalAPIKey: "ui-test-retrieval")

        XCTAssertTrue(scroll(to: "api.retrieval.embeddingModel"))
        XCTAssertTrue(scroll(to: "api.fetch.embedding"))
        let fetch = app.buttons["api.fetch.embedding"]
        XCTAssertTrue(fetch.exists)
        XCTAssertTrue(fetch.isEnabled, "the default SiliconFlow address should be usable")
        fetch.tap()
        XCTAssertTrue(
            app.buttons["api.model.model-b"].firstMatch.waitForExistence(timeout: 10),
            "the model picker did not open with the default address"
        )
    }

    func testAGeminiBundleShowsGeminiFieldsAndLocksItsModel() {
        openAPIPage(
            retrievalAPIKey: "ui-test-siliconflow",
            geminiAPIKey: "ui-test-gemini",
            fakeGeminiBundle: true
        )

        XCTAssertTrue(scroll(to: "api.retrieval.geminiKey"))
        XCTAssertTrue(app.secureTextFields["api.retrieval.geminiKey"].exists)
        XCTAssertTrue(scroll(to: "api.retrieval.embeddingModel"))
        let model = app.textFields["api.retrieval.embeddingModel"]
        XCTAssertTrue(model.exists)
        XCTAssertFalse(model.isEnabled, "the bundle decides the embedding model")
        XCTAssertEqual(model.value as? String, "gemini-embedding-2")
    }

    func testClearingAKeySavesTheClearedValue() {
        openAPIPage()

        XCTAssertTrue(scroll(to: "api.clearSecret.chat"))
        let clear = app.buttons["api.clearSecret.chat"]
        XCTAssertTrue(clear.exists, "no clear-key button")
        clear.tap()

        app.buttons["api.save"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "the page did not save")
        saved.buttons["好"].tap()

        app.buttons["api.back"].tap()
        let api = app.buttons["settings.api"].firstMatch
        XCTAssertTrue(api.waitForExistence(timeout: 5))
        api.tap()

        XCTAssertTrue(scroll(to: "api.chat.key"))
        let key = app.secureTextFields["api.chat.key"]
        XCTAssertTrue(key.exists)
        let shown = (key.value as? String) ?? ""
        XCTAssertTrue(
            shown.isEmpty || shown.contains("留空保留"),
            "the cleared key still shows a value: \(shown)"
        )
        XCTAssertFalse(
            app.buttons["api.clearSecret.chat"].waitForExistence(timeout: 2),
            "a cleared key still offers the clear button"
        )
    }

    @discardableResult
    func testSwitchingAProfileAppliesAtOnceAndSurvivesRelaunch() {
        openAPIPage()

        XCTAssertTrue(scrollUp(to: "api.profile.new"), "no new profile button")
        app.buttons["api.profile.new"].firstMatch.tap()

        replace(app.textFields["api.profile.name"], with: "本地")
        replace(
            app.textFields["api.profile.baseURL"],
            with: "http://192.0.2.10:8080/v1"
        )
        replace(app.textFields["api.profile.model"], with: "qwen-local")
        let save = app.buttons["api.profile.save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()

        let row = app.buttons["本地"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the new profile is not listed")
        XCTAssertTrue(app.staticTexts["未填完"].exists, "a keyless profile is not marked")
        row.tap()

        // Switching saves on its own: no 保存 tap between the row and this check.
        XCTAssertTrue(scroll(to: "api.chat.baseURL"))
        let baseURL = app.textFields["api.chat.baseURL"]
        XCTAssertEqual(baseURL.value as? String, "http://192.0.2.10:8080/v1")
        let model = app.textFields["api.chat.model"]
        XCTAssertEqual(model.value as? String, "qwen-local")

        // Relaunch without the debug seeding: the switch and the profile must both stay.
        app.launchEnvironment = [:]
        app.terminate()
        app.launch()
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let api = app.buttons["settings.api"].firstMatch
        XCTAssertTrue(api.waitForExistence(timeout: 10))
        api.tap()
        XCTAssertTrue(scroll(to: "api.chat.baseURL"))
        let again = app.textFields["api.chat.baseURL"]
        XCTAssertEqual(again.value as? String, "http://192.0.2.10:8080/v1")
        XCTAssertEqual(app.textFields["api.chat.model"].value as? String, "qwen-local")

        // The other profile is still there, not just the selected one.
        XCTAssertTrue(scrollUp(to: "api.profile.new"))
        XCTAssertTrue(
            app.buttons["当前配置"].waitForExistence(timeout: 5),
            "the profile that was active before the switch is gone"
        )
    }

    func testAProfileCannotTakeAnExistingName() {
        openAPIPage()

        XCTAssertTrue(scrollUp(to: "api.profile.new"))
        app.buttons["api.profile.new"].firstMatch.tap()
        replace(app.textFields["api.profile.name"], with: "当前配置")
        app.buttons["api.profile.save"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["已经有同名配置了，换一个名字。"].waitForExistence(timeout: 5),
            "a duplicate name is not refused"
        )
        app.buttons["api.profile.cancel"].firstMatch.tap()
    }

    func testTheLastProfileCannotBeDeleted() {
        openAPIPage()

        XCTAssertTrue(scrollUp(to: "api.profile.new"))
        let row = app.buttons["当前配置"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["删除"].exists, "the last profile still offers delete")
    }

    func testTheFieldsExplainWhatGoesInThem() {
        openAPIPage()

        XCTAssertTrue(scroll(to: "api.hint.chat.maxTokens"), "no max tokens hint")
        XCTAssertTrue(app.staticTexts["api.hint.chat.maxTokens"].exists)
        XCTAssertTrue(scroll(to: "api.hint.chat.extraBody"), "no extra body hint")
        XCTAssertTrue(app.staticTexts["api.hint.chat.extraBody"].exists)
        XCTAssertTrue(
            scroll(to: "api.hint.judge.bailianWorkspace"),
            "no workspace hint"
        )
        XCTAssertTrue(app.staticTexts["api.hint.judge.bailianWorkspace"].exists)

        // Every judge family has its own fields; Cloudflare's account id is the one the
        // producer is least likely to know by heart.
        let judge = app.buttons["api.judge.service"].firstMatch
        XCTAssertTrue(judge.exists)
        judge.tap()
        let cloudflare = app.buttons["Cloudflare"].firstMatch
        XCTAssertTrue(cloudflare.waitForExistence(timeout: 5))
        cloudflare.tap()
        XCTAssertTrue(
            scroll(to: "api.hint.judge.cloudflareAccount"),
            "no Cloudflare account hint"
        )
        XCTAssertTrue(app.staticTexts["api.hint.judge.cloudflareAccount"].exists)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String, !value.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    /// The top of the page: the profile rows live above the chat fields.
    private func scrollUp(to identifier: String) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        let form = app.collectionViews.firstMatch
        func onScreen() -> Bool {
            guard element.exists, element.frame.height > 1 else { return false }
            let mid = element.frame.midY
            return mid > 150 && mid < 930
        }
        for _ in 0..<20 where !onScreen() {
            form.swipeDown(velocity: .slow)
        }
        return onScreen()
    }

    private func scroll(to identifier: String) -> Bool {
        let element = app.descendants(matching: .any)[identifier]
        let form = app.collectionViews.firstMatch
        func onScreen() -> Bool {
            guard element.exists, element.frame.height > 1 else { return false }
            let mid = element.frame.midY
            return mid > 150 && mid < 930
        }
        for _ in 0..<60 where !onScreen() {
            if element.exists, element.frame.height > 1, element.frame.midY < 150 {
                form.swipeDown(velocity: .slow)
            } else {
                form.swipeUp(velocity: .slow)
            }
        }
        return onScreen()
    }
}
