import Foundation
import XCTest
@testable import EidolonCore

// MARK: - Jev

final class JevJudgeTests: XCTestCase {
    func testTheAddressIsTheBaseWithoutTrailingSlashesPlusSystemone() throws {
        XCTAssertEqual(JevJudgeConfig.defaultBaseURL, "https://openrouter.ai/api/v1")
        XCTAssertEqual(JevJudgeConfig.defaultModel, "typesafe/jev-1.13")

        let config = JevJudgeConfig(apiKey: "secret")
        XCTAssertEqual(
            try XCTUnwrap(config.systemOneURL).absoluteString,
            "https://openrouter.ai/api/v1/systemone"
        )
        // However many slashes the producer leaves at the end, the endpoint is the same.
        let padded = JevJudgeConfig(baseURL: " https://openrouter.ai/api/v1/// ", apiKey: "secret")
        XCTAssertEqual(
            try XCTUnwrap(padded.systemOneURL).absoluteString,
            "https://openrouter.ai/api/v1/systemone"
        )
    }

    func testAConfigWithoutAnAddressOrAModelOrAKeyIsIncomplete() {
        XCTAssertNil(JevJudgeConfig(baseURL: " ", apiKey: "secret").systemOne)
        XCTAssertNil(JevJudgeConfig(model: " ", apiKey: "secret").systemOne)
        XCTAssertNil(JevJudgeConfig(apiKey: " ").systemOne)
        XCTAssertNotNil(JevJudgeConfig(apiKey: "secret").systemOne)
    }

    func testJevIsItsOwnServiceWithPlainAnswers() throws {
        let config = try XCTUnwrap(JevJudgeConfig(apiKey: "secret").systemOne)
        XCTAssertEqual(config.service, "Jev")
        XCTAssertEqual(config.response, .plain)
        XCTAssertEqual(config.model, "typesafe/jev-1.13")
    }

    func testTheRequestCarriesTheModelTheStateAndAllSixQuestions() async throws {
        let recorder = RequestRecorder()
        let provider = SystemOneJudgeProvider(
            config: try XCTUnwrap(JevJudgeConfig(apiKey: "secret").systemOne),
            transport: StubJudgeTransport { request in
                await recorder.record(request)
                return (try systemOneBody(systemOneAnswers()), http(200))
            }
        )
        _ = try await provider.judgedWithRaw(characterName: "真乃", history: [], said: "ねえ")

        let recorded = await recorder.only()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
        XCTAssertEqual(body["state"] as? [String: String], [
            "角色": "真乃",
            "上文": "（对话刚开始）",
            "制作人最新的一句话": "ねえ",
        ])
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(
            Set(questions.keys),
            ["affinity", "out_of_line", "manipulation", "needs_retrieval", "recall", "about_producer"]
        )
    }
}

// MARK: - Cloudflare

final class CloudflareJudgeTests: XCTestCase {
    func testTheAddressIsTheAccountTheBareModelAndWorkersAI() throws {
        XCTAssertEqual(CloudflareJudgeConfig.defaultModel, "clef-flash")

        let config = CloudflareJudgeConfig(accountID: "acc-123", apiKey: "secret")
        XCTAssertEqual(
            try XCTUnwrap(config.systemOneURL).absoluteString,
            "https://api.cloudflare.com/client/v4/accounts/acc-123/ai/run/@cf/cloudflare/clef-flash"
        )
        // The URL already says where the model lives; the name must not say it twice.
        XCTAssertEqual(
            CloudflareJudgeConfig(accountID: "acc", model: "@cf/cloudflare/clef", apiKey: "k").bareModel,
            "clef"
        )
        XCTAssertEqual(
            CloudflareJudgeConfig(accountID: "acc", model: "cloudflare/clef", apiKey: "k").bareModel,
            "clef"
        )
    }

    func testAConfigWithoutAnAccountOrAModelOrAKeyIsIncomplete() {
        XCTAssertNil(CloudflareJudgeConfig(accountID: " ", apiKey: "secret").systemOne)
        XCTAssertNil(CloudflareJudgeConfig(accountID: "acc", model: " ", apiKey: "secret").systemOne)
        XCTAssertNil(CloudflareJudgeConfig(accountID: "acc", apiKey: " ").systemOne)
        XCTAssertNotNil(CloudflareJudgeConfig(accountID: "acc", apiKey: "secret").systemOne)
    }

    func testCloudflareIsItsOwnServiceWithEnvelopedAnswers() throws {
        let config = try XCTUnwrap(
            CloudflareJudgeConfig(accountID: "acc", apiKey: "secret").systemOne
        )
        XCTAssertEqual(config.service, "Cloudflare Workers AI")
        XCTAssertEqual(config.response, .cloudflare)
        XCTAssertEqual(config.model, "clef-flash")
    }

    func testTheAnswersAreUnwrappedAndTheBareModelIsSent() async throws {
        let recorder = RequestRecorder()
        let provider = SystemOneJudgeProvider(
            config: try XCTUnwrap(CloudflareJudgeConfig(accountID: "acc", apiKey: "secret").systemOne),
            transport: StubJudgeTransport { request in
                await recorder.record(request)
                let envelope: [String: Any] = [
                    "success": true,
                    "errors": [],
                    "messages": [],
                    "result": [
                        "answers": systemOneAnswers(outOfLine: 0.6),
                        "usage": ["input_tokens": 77],
                    ],
                ]
                return (
                    try JSONSerialization.data(withJSONObject: envelope),
                    http(200, url: "https://api.cloudflare.com/client/v4/accounts/acc/ai/run/@cf/cloudflare/clef-flash")
                )
            }
        )
        let answer = try await provider.judgedWithRaw(
            characterName: "真乃",
            history: [],
            said: "ねえ"
        )
        XCTAssertEqual(answer.inputTokens, 77)
        XCTAssertEqual(answer.verdict.affinity, Judged(level: 2, outOfLine: true))
        XCTAssertEqual(answer.verdict.need, .nothing, "all the other answers are below clef-flash's thresholds")

        let recorded = await recorder.only()
        let request = try XCTUnwrap(recorded)
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "clef-flash", "the URL carries the host, the body the bare name")
    }

    func testAFailureInsideASuccessfulResponseIsARealFailure() async {
        let provider = SystemOneJudgeProvider(
            config: try! XCTUnwrap(CloudflareJudgeConfig(accountID: "acc", apiKey: "secret").systemOne),
            transport: StubJudgeTransport { _ in
                let refusal: [String: Any] = [
                    "success": false,
                    "errors": [["code": 7000, "message": "No route for that URI"]],
                    "messages": [],
                    "result": NSNull(),
                ]
                return (
                    try JSONSerialization.data(withJSONObject: refusal),
                    http(200, url: "https://api.cloudflare.com/client/v4/accounts/acc/ai/run/@cf/cloudflare/clef-flash")
                )
            }
        )
        do {
            _ = try await provider.judgedWithRaw(characterName: "真乃", history: [], said: "ねえ")
            XCTFail("expected an account mismatch")
        } catch let error as SystemOneError {
            XCTAssertEqual(error, .accountMismatch("No route for that URI"))
        } catch {
            XCTFail("expected SystemOneError, got \(error)")
        }
    }
}

// MARK: - Thresholds

final class JudgeThresholdTests: XCTestCase {
    private func verdict(
        _ answers: [String: Any],
        family: JudgeFamily
    ) throws -> JudgeVerdict {
        try SystemOneJudgeProvider.read(
            answers: answers,
            thresholds: JudgeFamilies.thresholds(of: family)
        )
    }

    func testJevsThresholds() throws {
        // 0.5 / 0.5 / 0.5 / 0.7 / 0.4, and exactly at the line counts as yes.
        XCTAssertEqual(
            try verdict(systemOneAnswers(outOfLine: 0.7, manipulation: 0.4), family: .jev).affinity,
            Judged(level: 2, outOfLine: true, manipulation: true)
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(outOfLine: 0.69, manipulation: 0.39), family: .jev).affinity,
            Judged(level: 2)
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.9, recall: 0.5, aboutProducer: 0.9), family: .jev).need,
            .recall
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.5, recall: 0.49, aboutProducer: 0.9), family: .jev).need,
            .references
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.49, recall: 0.49, aboutProducer: 0.5), family: .jev).need,
            .memories
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.49, recall: 0.49, aboutProducer: 0.49), family: .jev).need,
            .nothing
        )
    }

    func testClefsThresholds() throws {
        // 0.5 / 0.8 / 0.1 / 0.5 / 0.5.
        XCTAssertEqual(
            try verdict(systemOneAnswers(outOfLine: 0.5, manipulation: 0.5), family: .clef).affinity,
            Judged(level: 2, outOfLine: true, manipulation: true)
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(outOfLine: 0.49, manipulation: 0.49), family: .clef).affinity,
            Judged(level: 2)
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.9, recall: 0.8, aboutProducer: 0.9), family: .clef).need,
            .recall
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.5, recall: 0.79, aboutProducer: 0.9), family: .clef).need,
            .references
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.49, recall: 0.79, aboutProducer: 0.1), family: .clef).need,
            .memories
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.49, recall: 0.79, aboutProducer: 0.09), family: .clef).need,
            .nothing
        )
    }

    func testClefFlashsThresholds() throws {
        // 0.5 / 0.7 / 0.3 / 0.6 / 0.6.
        XCTAssertEqual(
            try verdict(systemOneAnswers(outOfLine: 0.6, manipulation: 0.6), family: .clefFlash).affinity,
            Judged(level: 2, outOfLine: true, manipulation: true)
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(outOfLine: 0.59, manipulation: 0.59), family: .clefFlash).affinity,
            Judged(level: 2)
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.9, recall: 0.7, aboutProducer: 0.9), family: .clefFlash).need,
            .recall
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.5, recall: 0.69, aboutProducer: 0.9), family: .clefFlash).need,
            .references
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.49, recall: 0.69, aboutProducer: 0.3), family: .clefFlash).need,
            .memories
        )
        XCTAssertEqual(
            try verdict(systemOneAnswers(needsRetrieval: 0.49, recall: 0.69, aboutProducer: 0.29), family: .clefFlash).need,
            .nothing
        )
    }

    func testAnUncalibratedModelIsReadByJevsThresholdsAndSaysSo() throws {
        let config = SystemOneConfig(
            baseURL: URL(string: "https://openrouter.ai/api/v1/systemone")!,
            model: "qwen-plus",
            apiKey: "secret"
        )
        XCTAssertNil(JudgeFamilies.family(of: "qwen-plus"))
        XCTAssertFalse(config.isCalibrated)
        XCTAssertEqual(config.thresholds, JudgeFamilies.thresholds(of: .jev))

        XCTAssertEqual(
            try SystemOneJudgeProvider.read(
                answers: systemOneAnswers(outOfLine: 0.7),
                thresholds: config.thresholds
            ).affinity,
            Judged(level: 2, outOfLine: true)
        )
        XCTAssertEqual(
            try SystemOneJudgeProvider.read(
                answers: systemOneAnswers(outOfLine: 0.69),
                thresholds: config.thresholds
            ).affinity,
            Judged(level: 2)
        )
        XCTAssertEqual(JudgeCalibration.uncalibratedNote, "这个模型没有校准，按 Jev 的阈值算")
    }

    func testEveryKnownModelIsCalibrated() {
        for model in ["typesafe/jev-1.13", "clef", "clef-flash", "decision-model-preview"] {
            let config = SystemOneConfig(
                baseURL: URL(string: "https://example.com/systemone")!,
                model: model,
                apiKey: "secret"
            )
            XCTAssertTrue(config.isCalibrated, "\(model) has thresholds of its own")
        }
    }
}

// MARK: - The test button

final class JudgeCheckTests: XCTestCase {
    private var jev: SystemOneConfig {
        JevJudgeConfig(apiKey: "secret").systemOne!
    }

    private var bailian: SystemOneConfig {
        BailianJudgeConfig(workspaceID: "ws-123", apiKey: "secret").systemOne!
    }

    private var cloudflare: SystemOneConfig {
        CloudflareJudgeConfig(accountID: "acc-123", apiKey: "secret").systemOne!
    }

    /// Nil on success; otherwise the error the button would show.
    private func checkError(
        status: Int,
        body: String,
        config: SystemOneConfig
    ) async -> JudgeCheckError? {
        let provider = SystemOneJudgeProvider(
            config: config,
            transport: StubJudgeTransport { _ in
                (Data(body.utf8), http(status, url: config.baseURL.absoluteString))
            }
        )
        do {
            _ = try await provider.checkJudge()
            return nil
        } catch let error as JudgeCheckError {
            return error
        } catch {
            XCTFail("expected JudgeCheckError, got \(error)")
            return nil
        }
    }

    func testTheTrialRequestIsOneYesOrNoQuestionAboutATestState() async throws {
        let recorder = RequestRecorder()
        let provider = SystemOneJudgeProvider(
            config: jev,
            transport: StubJudgeTransport { request in
                await recorder.record(request)
                let answers: [String: Any] = ["check": ["type": "noul", "noul": 0.9]]
                return (try systemOneBody(answers), http(200))
            }
        )
        let check = try await provider.checkJudge()
        XCTAssertEqual(
            check,
            JudgeCheck(
                service: "Jev",
                model: "typesafe/jev-1.13",
                family: .jev,
                inputTokens: 128
            )
        )

        let recorded = await recorder.only()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "typesafe/jev-1.13")
        XCTAssertEqual(body["state"] as? [String: String], ["测试": "保存前试调"])
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(Set(questions.keys), ["check"])
        let question = try XCTUnwrap(questions["check"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "noul")
    }

    func testAnUncalibratedTrialReportsTheModelHasNoThresholdsOfItsOwn() async throws {
        let config = SystemOneConfig(
            baseURL: URL(string: "https://openrouter.ai/api/v1/systemone")!,
            model: "qwen-plus",
            apiKey: "secret",
            service: "Jev"
        )
        let provider = SystemOneJudgeProvider(
            config: config,
            transport: StubJudgeTransport { _ in
                let answers: [String: Any] = ["check": ["type": "noul", "noul": 0.9]]
                return (try systemOneBody(answers, tokens: 9), http(200))
            }
        )
        let check = try await provider.checkJudge()
        XCTAssertEqual(check.service, "Jev")
        XCTAssertEqual(check.model, "qwen-plus")
        XCTAssertNil(check.family)
        XCTAssertTrue(check.uncalibrated)
        XCTAssertEqual(check.inputTokens, 9)
        XCTAssertTrue(provider.judgeUncalibrated)
    }

    func testAWorkspaceOrRegionMismatchIsNamed() async {
        let error = await checkError(
            status: 400,
            body: #"{"error":{"code":"InvalidParameter","message":"Workspace ws-123 does not exist in region cn-beijing"}}"#,
            config: bailian
        )
        XCTAssertEqual(
            error,
            .workspaceMismatch("Workspace ws-123 does not exist in region cn-beijing")
        )
    }

    func testAnInvalidKeyIsNamed() async {
        let bailianError = await checkError(
            status: 401,
            body: #"{"error":{"code":"invalid_api_key","message":"bad key"}}"#,
            config: bailian
        )
        XCTAssertEqual(bailianError, .invalidKey("bad key"))

        // Workers AI says the same with an error code of its own.
        let cloudflareError = await checkError(
            status: 403,
            body: #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#,
            config: cloudflare
        )
        XCTAssertEqual(
            cloudflareError,
            .invalidKey("密钥无效，或者它不属于这个账号、没有 Workers AI 的权限：Authentication error")
        )
    }

    func testAMissingModelIsNamed() async {
        let bailianError = await checkError(
            status: 404,
            body: #"{"error":{"code":"model_not_found","message":"model nope not found"}}"#,
            config: bailian
        )
        XCTAssertEqual(bailianError, .modelWrong("model nope not found"))

        // A 404 with nothing to read is still the model name's fault on Model Studio.
        let plain404 = await checkError(status: 404, body: "not found", config: bailian)
        XCTAssertEqual(plain404, .modelWrong("not found"))
    }

    func testAWrongAccountIsNamed() async {
        for code in [7000, 7003] {
            let error = await checkError(
                status: 200,
                body: #"{"success":false,"errors":[{"code":\#(code),"message":"No route for that URI"}]}"#,
                config: cloudflare
            )
            XCTAssertEqual(error, .accountMismatch("No route for that URI"), "error \(code)")
        }
        // Workers AI answers 404 for an account it cannot find, too.
        let notFound = await checkError(
            status: 404,
            body: #"{"success":false,"errors":[{"code":1000,"message":"not found"}]}"#,
            config: cloudflare
        )
        XCTAssertEqual(notFound, .accountMismatch("not found"))
    }

    func testTodaysFreeQuotaRunningOutIsNamed() async {
        let error = await checkError(
            status: 429,
            body: #"{"success":false,"errors":[{"code":4006,"message":"Daily free allocation of 10,000 neurons exceeded"}]}"#,
            config: cloudflare
        )
        XCTAssertEqual(error, .quotaExhausted("Daily free allocation of 10,000 neurons exceeded"))
    }

    func testAnythingElseIsShownAsTheServiceSaidIt() async {
        let error = await checkError(
            status: 500,
            body: #"{"error":{"message":"boom"}}"#,
            config: bailian
        )
        XCTAssertEqual(error, .other("判断服务返回 500：boom"))
    }

    func testTheChatJudgesOwnFailuresAreNamed() {
        XCTAssertEqual(
            ChatJudgeProvider.checkError(.status(401, "bad key")),
            .invalidKey("bad key")
        )
        XCTAssertEqual(
            ChatJudgeProvider.checkError(.status(404, "nope")),
            .modelWrong("nope")
        )
        XCTAssertEqual(
            ChatJudgeProvider.checkError(.status(500, "boom")),
            .other("对话模型返回 500：boom")
        )
    }
}

// MARK: - Choosing a service

final class JudgeServiceChoiceTests: XCTestCase {
    func testTheFourServicesInTheOrderTheSettingsShowThem() {
        XCTAssertEqual(
            JudgeService.allCases.map(\.title),
            ["阿里云百炼", "Jev", "Cloudflare", "对话模型（JSON）"]
        )
    }

    func testEachServiceKeepsItsKeyApart() {
        let accounts = JudgeService.allCases.map(\.keychainAccount)
        XCTAssertEqual(Set(accounts).count, JudgeService.allCases.count, "no two services share an account")
        XCTAssertEqual(JudgeService.bailian.keychainAccount, "judge.bailian.key")
        XCTAssertEqual(JudgeService.jev.keychainAccount, "judge.jev.key")
        XCTAssertEqual(JudgeService.cloudflare.keychainAccount, "judge.cloudflare.key")
        // The chat judge's entry is the one installs from before the choice already had.
        XCTAssertEqual(JudgeService.chat.keychainAccount, "judge.apiKey")
    }

    func testAStoredChoiceWinsAtLaunch() {
        XCTAssertEqual(JudgeService.atLaunch(stored: "jev", chatJudgeFilledIn: true), .jev)
        XCTAssertEqual(JudgeService.atLaunch(stored: "cloudflare", chatJudgeFilledIn: false), .cloudflare)
        XCTAssertEqual(JudgeService.atLaunch(stored: "chat", chatJudgeFilledIn: false), .chat)
        XCTAssertEqual(JudgeService.atLaunch(stored: "bailian", chatJudgeFilledIn: true), .bailian)
    }

    func testAnUpgradeKeepsTheChatJudgeItWasUsing() {
        // Before the choice was stored, a filled-in chat judge is what the install used.
        XCTAssertEqual(JudgeService.atLaunch(stored: nil, chatJudgeFilledIn: true), .chat)
        XCTAssertEqual(JudgeService.atLaunch(stored: "nonsense", chatJudgeFilledIn: true), .chat)
    }

    func testAFreshInstallDefaultsToBailian() {
        XCTAssertEqual(JudgeService.atLaunch(stored: nil, chatJudgeFilledIn: false), .bailian)
        XCTAssertEqual(JudgeService.atLaunch(stored: "nonsense", chatJudgeFilledIn: false), .bailian)
    }
}
