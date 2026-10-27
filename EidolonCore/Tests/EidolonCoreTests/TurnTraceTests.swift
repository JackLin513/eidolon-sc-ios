import Foundation
import XCTest
@testable import EidolonCore

struct TracingFixedJudge: TracingJudgeProvider {
    var judged: Judged
    var need: RetrievalNeed = .references
    var raw: String

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        JudgeVerdict(affinity: judged, need: need)
    }

    func judgedWithRaw(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeAnswer {
        JudgeAnswer(verdict: JudgeVerdict(affinity: judged, need: need), raw: raw)
    }
}

struct UncalibratedTracingJudge: TracingJudgeProvider {
    var judged: Judged = Judged(level: 2)
    var need: RetrievalNeed = .nothing

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        JudgeVerdict(affinity: judged, need: need)
    }

    func judgedWithRaw(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeAnswer {
        JudgeAnswer(verdict: JudgeVerdict(affinity: judged, need: need), raw: "{}")
    }

    var judgeService: String { "Jev" }
    var judgeModel: String { "qwen-plus" }
    var judgeFamily: String? { nil }
    var judgeUncalibrated: Bool { true }
}

struct UnreadableJudge: TracingJudgeProvider {
    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        throw JudgeUnreadable(raw: "ごめんなさい", reason: "没有 JSON")
    }

    func judgedWithRaw(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeAnswer {
        throw JudgeUnreadable(raw: "ごめんなさい", reason: "没有 JSON")
    }
}

struct FailingTracingJudge: TracingJudgeProvider {
    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        throw ChatProviderError.status(500, "boom")
    }

    func judgedWithRaw(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeAnswer {
        throw ChatProviderError.status(500, "boom")
    }
}

final class TurnTraceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonTrace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    private func send(
        on eidolon: Eidolon,
        provider: any ChatProvider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
        judge: (any JudgeProvider)? = nil,
        embedder: (any EmbeddingProvider)? = FakeEmbedding(vector: [1, 0, 0, 0]),
        reranker: (any RerankProvider)? = FakeRerank(scores: [0.9, 0.1, 0.1]),
        tracing: TurnTracing = .on
    ) async throws {
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "写真集の話をして",
            provider: provider,
            judge: judge,
            embedder: embedder,
            reranker: reranker,
            tracing: tracing
        ) {}
        await eidolon.settleMemories()
    }

    func testATurnLeavesThePromptTheJudgeAndTheCandidates() async throws {
        let eidolon = try await installedEidolon()
        try await send(
            on: eidolon,
            judge: TracingFixedJudge(
                judged: Judged(level: 3),
                need: .references,
                raw: #"{"level": 3, "out_of_line": false, "manipulation": false, "retrieval": "references"}"#
            )
        )

        let traces = try await eidolon.turnTraces()
        let trace = try XCTUnwrap(traces.first).trace
        XCTAssertEqual(trace.characterID, "mano")
        XCTAssertEqual(trace.prompts.count, 1)
        let system = trace.prompts[0].filter { $0.role == "system" }.map(\.content).joined(separator: "\n")
        XCTAssertTrue(system.contains("# 真乃"))
        XCTAssertTrue(trace.prompts[0].contains { $0.role == "user" && $0.content == "写真集の話をして" })
        XCTAssertEqual(trace.judge?.raw?.contains("\"level\": 3"), true)
        XCTAssertEqual(trace.judge?.service, "判断模型")
        XCTAssertNotNil(trace.judge?.latency)
        XCTAssertNil(trace.judge?.failure)
        XCTAssertEqual(trace.verdict?.contains("retrieval=references"), true)
        XCTAssertEqual(trace.retrieval.need, "references")
        XCTAssertNotNil(trace.retrieval.query)
        XCTAssertFalse(trace.retrieval.candidates.isEmpty)
        XCTAssertTrue(trace.retrieval.candidates.allSatisfy { $0.similarity.isFinite })
        XCTAssertTrue(trace.retrieval.candidates.contains { $0.chosen })
        XCTAssertTrue(trace.retrieval.candidates.contains { $0.score != nil })
        XCTAssertNil(trace.error)
    }

    func testTracingOffWritesNothing() async throws {
        let eidolon = try await installedEidolon()
        try await send(on: eidolon, tracing: .off)
        let traces = try await eidolon.turnTraces()
        XCTAssertTrue(traces.isEmpty)
    }

    func testAFailingJudgeIsTracedAsADegradation() async throws {
        let eidolon = try await installedEidolon()
        try await send(on: eidolon, judge: FailingTracingJudge())
        let traces = try await eidolon.turnTraces()
        let trace = try XCTUnwrap(traces.first).trace
        XCTAssertTrue(trace.degradation.contains { $0.contains("判断模型失败") })
        XCTAssertNil(trace.judge?.raw)
        XCTAssertNotNil(trace.judge?.failure)
        XCTAssertEqual(trace.retrieval.need, "references", "a failed judge still looks references up")
        XCTAssertNil(trace.verdict)
    }

    func testAReasoningModelsThoughtsAreKeptWhenTheAnswerIsEmpty() throws {
        let data = Data(
            #"{"choices":[{"message":{"content":"","reasoning_content":"{\"level\": 2}"}}]}"#.utf8
        )
        XCTAssertEqual(try ChatJudgeProvider.answerText(data), #"{"level": 2}"#)
    }

    func testAnUnreadableJudgeAnswerIsKeptAsWritten() async throws {
        let eidolon = try await installedEidolon()
        try await send(on: eidolon, judge: UnreadableJudge())
        let traces = try await eidolon.turnTraces()
        let trace = try XCTUnwrap(traces.first).trace
        XCTAssertEqual(trace.judge?.raw, "ごめんなさい")
        XCTAssertTrue(trace.degradation.contains { $0.contains("判断模型失败") })
        XCTAssertEqual(trace.retrieval.need, "references")
        XCTAssertNil(trace.verdict)
    }

    func testAnUncalibratedJudgeIsTracedAsSuch() async throws {
        let eidolon = try await installedEidolon()
        try await send(on: eidolon, judge: UncalibratedTracingJudge())
        let traces = try await eidolon.turnTraces()
        let trace = try XCTUnwrap(traces.first).trace
        XCTAssertEqual(trace.judge?.service, "Jev")
        XCTAssertEqual(trace.judge?.model, "qwen-plus")
        XCTAssertNil(trace.judge?.family)
        XCTAssertEqual(trace.judge?.uncalibrated, true, "the trace says the model has no thresholds of its own")
    }

    func testATraceFromBeforeTheNoteStillDecodes() throws {
        let trace = try JSONDecoder().decode(
            JudgeTrace.self,
            from: Data(#"{"service":"阿里云百炼","model":"decision-model-preview"}"#.utf8)
        )
        XCTAssertNil(trace.uncalibrated)
        XCTAssertNil(trace.family)
    }

    func testAFailingReplyIsTracedWithItsError() async throws {
        let eidolon = try await installedEidolon()
        do {
            try await send(
                on: eidolon,
                provider: RecordingChatProvider(
                    chunks: [],
                    failure: ChatProviderError.status(500, "boom")
                )
            )
            XCTFail("expected the turn to fail")
        } catch {}

        let traces = try await eidolon.turnTraces()
        let trace = try XCTUnwrap(traces.first).trace
        XCTAssertEqual(trace.error?.contains("对话模型失败"), true)
        XCTAssertFalse(trace.prompts.isEmpty, "the prompt that was sent is kept")
    }

    func testRetentionKeepsTheNewest() async throws {
        let eidolon = try await installedEidolon()
        for _ in 0..<3 {
            try await send(on: eidolon, tracing: TurnTracing(enabled: true, retention: 2))
        }
        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(traces.count, 2)
        XCTAssertLessThan(traces[1].id, traces[0].id)
    }

    func testTracesExportAsJSON() async throws {
        let eidolon = try await installedEidolon()
        try await send(on: eidolon)
        let data = try await eidolon.exportedTraces()
        let object = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        XCTAssertEqual(object?.count, 1)
        XCTAssertNotNil(object?.first?["trace"] as? [String: Any])
        try await eidolon.clearTraces()
        let cleared = try await eidolon.turnTraces()
        XCTAssertTrue(cleared.isEmpty)
    }
}
