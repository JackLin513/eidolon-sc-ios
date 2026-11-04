import Foundation
import XCTest
@testable import EidolonCore

/// The instrumentation: a turn, a judge, a voice and an embedding each leave one row in the
/// ledger, with real numbers where the service reports them and marked estimates where it
/// does not (spec #96).
final class UsageRecordingTests: XCTestCase {
    private var root: URL!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonUsageRecording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installed() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    private func noon() -> Date {
        Eidolon.parseTimestamp("2026-11-05T03:00:00Z")!
    }

    private final class ReportingChat: ChatProvider, ChatUsageReporting, ServiceMetadata, @unchecked Sendable {
        let text: String
        let box = ChatUsageBox()
        init(_ text: String, usage: ChatUsage? = nil) {
            self.text = text
            if let usage { box.add(input: usage.input, output: usage.output, cachedInput: usage.cachedInput) }
        }

        var usageProviderHost: String { "api.deepseek.com" }
        var usageModel: String { "deepseek-v4-pro" }
        var serviceHost: String? { "api.deepseek.com" }
        var serviceModel: String? { "deepseek-v4-pro" }

        func takeUsage() async -> ChatUsage? { box.take() }

        func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                continuation.yield(text)
                continuation.finish()
            }
        }
    }

    func testAnEndedCallRecordsTheRecognizerSeconds() async throws {
        let eidolon = try await installed()
        let session = try await eidolon.beginCall(
            characterID: "mano",
            setup: CallSetup(
                capture: FakeCapture(),
                playback: FakePlayback(),
                recognition: FakeRecognition([.hang]),
                synthesis: FakeSynthesis(),
                voiceModel: "s2.1-pro-free",
                recognitionHost: "stt-rt.soniox.com",
                recognitionModel: "stt-rt-v5",
                provider: ReplyScriptProvider([])
            )
        )
        await session.start()
        for _ in 0..<100 {
            if await session.currentState() == .listening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await session.hangUp()
        try await Task.sleep(for: .milliseconds(50))

        let calls = try await eidolon.serviceCalls()
        let call = try XCTUnwrap(calls.first { $0.operation == .recognition })
        XCTAssertEqual(call.service, .recognition)
        XCTAssertEqual(call.provider, "stt-rt.soniox.com")
        XCTAssertEqual(call.model, "stt-rt-v5")
        XCTAssertEqual(call.unit, .seconds)
        XCTAssertFalse(call.estimated)
        XCTAssertNotNil(call.callID)
    }

    private struct MetadataJudge: JudgeProvider, ServiceMetadata {
        var serviceHost: String? { "openrouter.ai" }
        var serviceModel: String? { "cloudflare/clef" }
        var judgeService: String { "判断模型" }
        var judgeModel: String { "cloudflare/clef" }

        func judge(
            characterName: String, history: [PromptMessage], said: String
        ) async throws -> JudgeVerdict {
            JudgeVerdict(affinity: .noEffect, need: .nothing)
        }
    }

    private struct FakeSpeech: SpeechSynthesis {
        func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
            Data([1, 2, 3])
        }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [ServiceCall] = []

        func add(_ call: ServiceCall) {
            lock.lock()
            values.append(call)
            lock.unlock()
        }

        var all: [ServiceCall] {
            lock.lock()
            defer { lock.unlock() }
            return values
        }
    }

    func testATurnUsesTheUsageTheServiceReported() async throws {
        let eidolon = try await installed()
        let provider = ReportingChat(
            "「你好」", usage: ChatUsage(input: 1_234, output: 56, cachedInput: 12)
        )
        for try await _ in eidolon.sendTurn(
            characterID: "mano", text: "你好", provider: provider,
            now: noon(), timeZone: tokyo
        ) {}

        let calls = try await eidolon.serviceCalls()
        let call = try XCTUnwrap(calls.first { $0.operation == .chatText })
        XCTAssertEqual(call.service, .chat)
        XCTAssertEqual(call.provider, "api.deepseek.com")
        XCTAssertEqual(call.model, "deepseek-v4-pro")
        XCTAssertEqual(call.unit, .tokens)
        XCTAssertEqual(call.input, 1_234)
        XCTAssertEqual(call.output, 56)
        XCTAssertEqual(call.cachedInput, 12)
        XCTAssertFalse(call.estimated)
    }

    func testATurnWithoutReportedUsageIsAnEstimate() async throws {
        let eidolon = try await installed()
        let provider = ReportingChat("「你好」")
        for try await _ in eidolon.sendTurn(
            characterID: "mano", text: "你好", provider: provider,
            now: noon(), timeZone: tokyo
        ) {}

        let calls = try await eidolon.serviceCalls()
        let call = try XCTUnwrap(calls.first { $0.operation == .chatText })
        XCTAssertTrue(call.estimated)
        XCTAssertGreaterThan(call.input, 0)
        XCTAssertGreaterThan(call.output ?? 0, 0)
        XCTAssertEqual(call.provider, "api.deepseek.com")
    }

    func testTheJudgeLeavesARowWithItsInputTokens() async throws {
        let eidolon = try await installed()
        let provider = ReportingChat("「你好」")
        for try await _ in eidolon.sendTurn(
            characterID: "mano", text: "你好", provider: provider,
            judge: MetadataJudge(), now: noon(), timeZone: tokyo
        ) {}

        let calls = try await eidolon.serviceCalls()
        let call = try XCTUnwrap(calls.first { $0.operation == .judge })
        XCTAssertEqual(call.service, .judge)
        XCTAssertEqual(call.provider, "openrouter.ai")
        XCTAssertEqual(call.model, "cloudflare/clef")
        XCTAssertGreaterThan(call.input, 0)
        XCTAssertTrue(call.estimated) // the output is estimated even without one
    }

    func testDramaThreeIsBilledPerCharacterAndOtherVoicesPerByte() async throws {
        let calls = Calls()
        let recorded = RecordingSpeech(base: FakeSpeech()) { calls.add($0) }
        _ = try await recorded.synthesize(
            "こんにちは", voice: CallVoice(id: "v", model: "drama-3")
        )
        _ = try await recorded.synthesize(
            "こんにちは", voice: CallVoice(id: "v", model: "s2-pro")
        )
        XCTAssertEqual(calls.all.map(\.unit), [.characters, .bytes])
        XCTAssertEqual(calls.all.map(\.input), [5, 15])
        XCTAssertEqual(calls.all.map(\.estimated), [false, false])
    }

    func testAnEmbeddingIsRecordedWithTheProvidersTokens() async throws {
        let eidolon = try await installed()
        let embedding = UsageEmbedding()
        let recorded = RecordingEmbedding(base: embedding, eidolon: eidolon)
        _ = try await recorded.embed(["你好", "世界"])

        let calls = try await eidolon.serviceCalls()
        let call = try XCTUnwrap(calls.first { $0.operation == .embedding })
        XCTAssertEqual(call.service, .embedding)
        XCTAssertEqual(call.provider, "api.siliconflow.cn")
        XCTAssertEqual(call.model, "Qwen/Qwen3-Embedding-0.6B")
        XCTAssertEqual(call.input, 321)
        XCTAssertFalse(call.estimated)
    }

    func testARerankIsRecordedWithTheProvidersTokens() async throws {
        let eidolon = try await installed()
        let rerank = UsageRerank()
        let recorded = RecordingRerank(base: rerank, eidolon: eidolon)
        _ = try await recorded.rerank(query: "她喜欢什么", documents: ["蛋糕", "花"])

        let calls = try await eidolon.serviceCalls()
        let call = try XCTUnwrap(calls.first { $0.operation == .rerank })
        XCTAssertEqual(call.service, .rerank)
        XCTAssertEqual(call.provider, "api.siliconflow.cn")
        XCTAssertEqual(call.model, "Qwen/Qwen3-Reranker-0.6B")
        XCTAssertEqual(call.input, 456)
        XCTAssertFalse(call.estimated)
    }

    private struct UsageRerank: RerankProvider, RerankUsageReporting, ServiceMetadata {
        var model: String { "Qwen/Qwen3-Reranker-0.6B" }
        var serviceHost: String? { "api.siliconflow.cn" }
        var serviceModel: String? { model }

        func takeRerankUsage() async -> ChatUsage? {
            ChatUsage(input: 456, output: 0)
        }

        func rerank(
            query: String, documents: [String]
        ) async throws -> [(index: Int, score: Double)] {
            documents.indices.map { (index: $0, score: 1) }
        }
    }

    private struct UsageEmbedding: EmbeddingProvider, EmbeddingUsageReporting, ServiceMetadata {
        var model: String { "Qwen/Qwen3-Embedding-0.6B" }
        var serviceHost: String? { "api.siliconflow.cn" }
        var serviceModel: String? { model }
        private let box = ChatUsageBox()

        func takeEmbeddingUsage() async -> ChatUsage? {
            let usage = ChatUsage(input: 321, output: 0)
            return usage
        }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { _ in [1, 0, 0, 0] }
        }

        func embedQuery(_ text: String) async throws -> [Float] { [1, 0, 0, 0] }
    }
}
