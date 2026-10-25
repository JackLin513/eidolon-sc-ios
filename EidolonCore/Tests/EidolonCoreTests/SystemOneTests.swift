import Foundation
import XCTest
@testable import EidolonCore

/// A judge service that answers from a closure, so the tests need no network.
struct StubJudgeTransport: JudgeTransport {
    var answer: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await answer(request)
    }
}

actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }

    func only() -> URLRequest? { requests.first }
}

func http(_ status: Int, url: String = "https://example.com/systemone") -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

/// A whole System One answer: the affinity levels, then the five yes-or-no questions.
func systemOneAnswers(
    levels: [String: Double] = ["0": 0.02, "1": 0.03, "2": 0.9, "3": 0.03, "4": 0.02],
    outOfLine: Double = 0.1,
    manipulation: Double = 0.1,
    needsRetrieval: Double = 0.1,
    recall: Double = 0.1,
    aboutProducer: Double = 0.1
) -> [String: Any] {
    [
        "affinity": ["type": "score", "probabilities": levels],
        "out_of_line": ["type": "noul", "noul": outOfLine],
        "manipulation": ["type": "noul", "noul": manipulation],
        "needs_retrieval": ["type": "noul", "noul": needsRetrieval],
        "recall": ["type": "noul", "noul": recall],
        "about_producer": ["type": "noul", "noul": aboutProducer],
    ]
}

func systemOneBody(_ answers: [String: Any], tokens: Int? = 128) throws -> Data {
    var object: [String: Any] = ["answers": answers]
    if let tokens { object["usage"] = ["input_tokens": tokens] }
    return try JSONSerialization.data(withJSONObject: object)
}

final class SystemOneTests: XCTestCase {
    private let thresholds = JudgeFamilies.thresholds(of: .decisionModel)

    // MARK: - The address

    func testTheAddressIsMadeFromTheWorkspaceAndTheRegion() throws {
        let beijing = BailianJudgeConfig(workspaceID: "ws-123", apiKey: "key")
        XCTAssertEqual(
            try XCTUnwrap(beijing.systemOneURL).absoluteString,
            "https://ws-123.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/systemone"
        )
        XCTAssertEqual(beijing.model, "decision-model-preview")

        let singapore = BailianJudgeConfig(workspaceID: "ws-123", region: .singapore, apiKey: "key")
        XCTAssertEqual(
            try XCTUnwrap(singapore.systemOneURL).absoluteString,
            "https://ws-123.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1/systemone"
        )

        // One trailing slash at most, however the producer types it.
        let spaced = BailianJudgeConfig(workspaceID: " ws-123 ", apiKey: "key")
        XCTAssertEqual(
            try XCTUnwrap(spaced.systemOneURL).absoluteString,
            beijing.systemOneURL?.absoluteString
        )
    }

    func testAConfigWithoutAWorkspaceOrAKeyIsIncomplete() {
        XCTAssertNil(BailianJudgeConfig(workspaceID: "", apiKey: "key").systemOneURL)
        XCTAssertNil(BailianJudgeConfig(workspaceID: "ws-123", apiKey: " ").systemOne)
        XCTAssertNil(BailianJudgeConfig(workspaceID: "ws-123", model: "", apiKey: "key").systemOne)
        XCTAssertNotNil(BailianJudgeConfig(workspaceID: "ws-123", apiKey: "key").systemOne)
    }

    func testTheFamilyIsReadFromTheModelName() {
        XCTAssertEqual(JudgeFamilies.family(of: "decision-model-preview"), .decisionModel)
        XCTAssertEqual(JudgeFamilies.family(of: "decision-model"), .decisionModel)
        XCTAssertEqual(JudgeFamilies.family(of: "typesafe/jev-1.13"), .jev)
        XCTAssertEqual(JudgeFamilies.family(of: "clef"), .clef)
        XCTAssertEqual(JudgeFamilies.family(of: "cloudflare/clef-flash"), .clefFlash)
        XCTAssertNil(JudgeFamilies.family(of: "qwen-plus"))
        // A model of no known family is judged by Jev's thresholds.
        XCTAssertEqual(JudgeFamilies.thresholds(for: "qwen-plus"), JudgeFamilies.thresholds(of: .jev))
    }

    // MARK: - What is asked

    func testTheRequestCarriesTheModelTheStateAndAllSixQuestions() async throws {
        let recorder = RequestRecorder()
        let provider = SystemOneJudgeProvider(
            config: SystemOneConfig(
                baseURL: URL(string: "https://judge.example/systemone")!,
                model: "decision-model-preview",
                apiKey: "secret"
            ),
            transport: StubJudgeTransport { request in
                await recorder.record(request)
                return (try systemOneBody(systemOneAnswers()), http(200))
            }
        )
        let history = [
            PromptMessage(.user, "おはよう"),
            PromptMessage(.assistant, "おはようございます"),
            PromptMessage(.user, "今日は何をするの"),
            PromptMessage(.assistant, "撮影です"),
            PromptMessage(.user, "古い話"),
        ]
        let answer = try await provider.judgedWithRaw(
            characterName: "樱木真乃",
            history: history,
            said: "写真集の話をして"
        )
        XCTAssertEqual(answer.verdict.affinity.level, 2)
        XCTAssertEqual(answer.inputTokens, 128)

        let recorded = await recorder.only()
        let request = try XCTUnwrap(recorded)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://judge.example/systemone")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 5)

        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(body["model"] as? String, "decision-model-preview")
        let state = try XCTUnwrap(body["state"] as? [String: String])
        XCTAssertEqual(state["角色"], "樱木真乃")
        XCTAssertEqual(state["制作人最新的一句话"], "写真集の話をして")
        // The last four messages, named by who said them, and nothing older.
        XCTAssertEqual(
            state["上文"],
            "樱木真乃：おはようございます\n制作人：今日は何をするの\n樱木真乃：撮影です\n制作人：古い話"
        )

        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual(
            Set(questions.keys),
            ["affinity", "out_of_line", "manipulation", "needs_retrieval", "recall", "about_producer"]
        )
        let affinity = try XCTUnwrap(questions["affinity"] as? [String: Any])
        XCTAssertEqual(affinity["type"] as? String, "score")
        XCTAssertEqual((affinity["criteria"] as? [String])?.count, 5)
        XCTAssertTrue((affinity["instructions"] as? String)?.contains("拿不准时就是对她没有影响") ?? false)
        let recall = try XCTUnwrap(questions["recall"] as? [String: Any])
        XCTAssertEqual(recall["type"] as? String, "noul")
        let criteria = try XCTUnwrap(recall["criteria"] as? [String: String])
        XCTAssertEqual(Set(criteria.keys), ["true", "false"])
    }

    func testWithNoHistoryTheStateSaysTheConversationHasJustBegun() {
        let state = SystemOneJudgeProvider.state(
            characterName: "樱木真乃",
            history: [],
            said: "はじめまして"
        )
        XCTAssertEqual(state["上文"], "（对话刚开始）")
    }

    // MARK: - How the answer is read

    func testTheLikeliestLevelWins() throws {
        let verdict = try SystemOneJudgeProvider.read(
            answers: systemOneAnswers(levels: ["0": 0.1, "1": 0.1, "2": 0.1, "3": 0.6, "4": 0.1]),
            thresholds: thresholds
        )
        XCTAssertEqual(verdict.affinity.level, 3)
    }

    func testTwoLevelsTiedAtTheTopMeanNoEffect() throws {
        let two = try SystemOneJudgeProvider.read(
            answers: systemOneAnswers(levels: ["0": 0.1, "1": 0.2, "2": 0.4, "3": 0.4, "4": 0.1]),
            thresholds: thresholds
        )
        XCTAssertEqual(two.affinity.level, AffinityRules.noEffect)
        let all = try SystemOneJudgeProvider.read(
            answers: systemOneAnswers(levels: ["0": 0.1, "1": 0.1, "2": 0.1, "3": 0.1, "4": 0.1]),
            thresholds: thresholds
        )
        XCTAssertEqual(all.affinity.level, AffinityRules.noEffect)
    }

    func testOnlyLevelsZeroToFourCount() throws {
        let verdict = try SystemOneJudgeProvider.read(
            answers: systemOneAnswers(levels: ["4": 0.4, "5": 0.6, "9": 0.1, "message": 0.1]),
            thresholds: thresholds
        )
        XCTAssertEqual(verdict.affinity.level, 4)
        XCTAssertThrowsError(try SystemOneJudgeProvider.read(
            answers: systemOneAnswers(levels: ["5": 0.6, "9": 0.4]),
            thresholds: thresholds
        ))
    }

    func testAYesOrNoAnswerIsYesAtOrAboveTheThreshold() throws {
        // decision-model reads needs_retrieval at 0.06, out_of_line at 0.3, manipulation at 0.4.
        XCTAssertEqual(
            try SystemOneJudgeProvider.read(
                answers: systemOneAnswers(outOfLine: 0.3, manipulation: 0.4),
                thresholds: thresholds
            ).affinity,
            Judged(level: 2, outOfLine: true, manipulation: true)
        )
        XCTAssertEqual(
            try SystemOneJudgeProvider.read(
                answers: systemOneAnswers(outOfLine: 0.29, manipulation: 0.39),
                thresholds: thresholds
            ).affinity,
            Judged(level: 2)
        )
    }

    func testRetrievalIsDecidedInOneFixedOrder() throws {
        func need(
            recall: Double, needsRetrieval: Double, aboutProducer: Double
        ) throws -> RetrievalNeed {
            try SystemOneJudgeProvider.read(
                answers: systemOneAnswers(
                    needsRetrieval: needsRetrieval, recall: recall, aboutProducer: aboutProducer
                ),
                thresholds: thresholds
            ).need
        }
        // decision-model: recall 0.8, needs_retrieval 0.06, about_producer 0.1.
        XCTAssertEqual(
            try need(recall: 0.8, needsRetrieval: 0.9, aboutProducer: 0.9),
            .recall,
            "recall comes before the others"
        )
        XCTAssertEqual(
            try need(recall: 0.79, needsRetrieval: 0.06, aboutProducer: 0.9),
            .references,
            "references come before memories"
        )
        XCTAssertEqual(
            try need(recall: 0.79, needsRetrieval: 0.05, aboutProducer: 0.1),
            .memories
        )
        XCTAssertEqual(
            try need(recall: 0.79, needsRetrieval: 0.05, aboutProducer: 0.09),
            .nothing
        )
    }

    func testAMissingQuestionFailsTheJudgment() {
        var answers = systemOneAnswers()
        answers.removeValue(forKey: "about_producer")
        XCTAssertThrowsError(try SystemOneJudgeProvider.read(answers: answers, thresholds: thresholds))
        answers = systemOneAnswers()
        answers.removeValue(forKey: "affinity")
        XCTAssertThrowsError(try SystemOneJudgeProvider.read(answers: answers, thresholds: thresholds))
    }

    // MARK: - Failures

    func testATimeoutIsAFailureInWords() async {
        let provider = SystemOneJudgeProvider(
            config: SystemOneConfig(
                baseURL: URL(string: "https://judge.example/systemone")!,
                model: "decision-model-preview",
                apiKey: "secret"
            ),
            transport: StubJudgeTransport { _ in
                throw URLError(.timedOut)
            }
        )
        do {
            _ = try await provider.judgedWithRaw(characterName: "真乃", history: [], said: "ねえ")
            XCTFail("expected a timeout")
        } catch let error as SystemOneError {
            XCTAssertEqual(error, .timedOut)
            XCTAssertEqual(error.errorDescription, "判断服务超时")
        } catch {
            XCTFail("expected SystemOneError, got \(error)")
        }
    }

    func testAMissingModelIsNamedInWords() async throws {
        let body = Data(#"{"error":{"code":"model_not_found","message":"model decision-model-nope not found"}}"#.utf8)
        let provider = SystemOneJudgeProvider(
            config: SystemOneConfig(
                baseURL: URL(string: "https://judge.example/systemone")!,
                model: "decision-model-nope",
                apiKey: "secret"
            ),
            transport: StubJudgeTransport { _ in (body, http(404)) }
        )
        do {
            _ = try await provider.judgedWithRaw(characterName: "真乃", history: [], said: "ねえ")
            XCTFail("expected modelNotFound")
        } catch let error as SystemOneError {
            XCTAssertEqual(error, .modelNotFound("model decision-model-nope not found"))
            XCTAssertEqual(
                error.errorDescription,
                "百炼没有这个模型：model decision-model-nope not found"
            )
        }
    }

    func testARefusalCarriesItsStatusAndMessage() async throws {
        let body = Data(#"{"error":{"code":"invalid_api_key","message":"bad key"}}"#.utf8)
        let provider = SystemOneJudgeProvider(
            config: SystemOneConfig(
                baseURL: URL(string: "https://judge.example/systemone")!,
                model: "decision-model-preview",
                apiKey: "bad"
            ),
            transport: StubJudgeTransport { _ in (body, http(401)) }
        )
        do {
            _ = try await provider.judgedWithRaw(characterName: "真乃", history: [], said: "ねえ")
            XCTFail("expected a refusal")
        } catch let error as SystemOneError {
            XCTAssertEqual(error, .refused(status: 401, detail: "bad key"))
        }
    }

    func testAnUnreadableBodyIsAFailure() async throws {
        let provider = SystemOneJudgeProvider(
            config: SystemOneConfig(
                baseURL: URL(string: "https://judge.example/systemone")!,
                model: "decision-model-preview",
                apiKey: "secret"
            ),
            transport: StubJudgeTransport { _ in
                (Data(#"{"answers": {}}"#.utf8), http(200))
            }
        )
        do {
            _ = try await provider.judgedWithRaw(characterName: "真乃", history: [], said: "ねえ")
            XCTFail("expected an unreadable answer")
        } catch let error as SystemOneError {
            guard case .invalidResponse = error else {
                return XCTFail("expected invalidResponse, got \(error)")
            }
        }
    }

    // MARK: - In a turn

    func testAFailedJudgeLeavesTheTurnRunningWithNothingLookedUp() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonSystemOne-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        let before = try await eidolon.readAffinity(characterID: "mano", now: Date())
        let judge = SystemOneJudgeProvider(
            config: SystemOneConfig(
                baseURL: URL(string: "https://judge.example/systemone")!,
                model: "decision-model-preview",
                apiKey: "secret"
            ),
            transport: StubJudgeTransport { _ in
                throw URLError(.timedOut)
            }
        )
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            judge: judge
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        XCTAssertNotNil(record, "the turn goes on without the judge")
        let after = try await eidolon.readAffinity(characterID: "mano", now: Date())
        XCTAssertEqual(after.value, before.value, accuracy: 0.001)

        let traces = try await eidolon.turnTraces()
        let trace = try XCTUnwrap(traces.first).trace
        XCTAssertEqual(trace.judge?.service, "阿里云百炼")
        XCTAssertEqual(trace.judge?.model, "decision-model-preview")
        XCTAssertEqual(trace.judge?.family, "decision-model")
        XCTAssertEqual(trace.judge?.failure, "判断服务超时")
        XCTAssertNotNil(trace.judge?.latency)
        XCTAssertEqual(trace.retrieval.need, "nothing")
    }
}
