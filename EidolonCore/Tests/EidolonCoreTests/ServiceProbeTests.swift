import Foundation
import XCTest
@testable import EidolonCore

private actor StubBailianStarter: BailianTaskStarter {
    let refused: Set<BailianRegion>
    private(set) var seen: [BailianRegion] = []

    init(refused: Set<BailianRegion> = []) {
        self.refused = refused
    }

    func startTask(apiKey: String, model: String, region: BailianRegion) async throws {
        seen.append(region)
        if refused.contains(region) {
            throw ProbeError.transport("key 不被接受（HTTP 401）")
        }
    }
}

final class ServiceProbeTests: XCTestCase {
    private func chatConfig(_ apiProtocol: ChatProtocol = .chatCompletions) -> ChatModelConfig {
        ChatModelConfig(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "test-model",
            apiKey: "key",
            apiProtocol: apiProtocol
        )
    }

    func testAChatProbeSendsATinyStreamedRequestWithATool() async throws {
        let transport = StubChatTransport(lines: [textChunk("ok")])
        let probe = ServiceProbe(http: StubHTTPTransport { _ in (Data(), probeHTTP(200)) }, chat: transport)
        let result = await probe.chatModel(chatConfig())
        XCTAssertTrue(result.ok, result.detail)
        XCTAssertEqual(result.model, "test-model")
        XCTAssertNotNil(result.statusCode ?? 200)
        let seen = await transport.seen
        let sent = try body(try XCTUnwrap(seen.first))
        XCTAssertEqual(sent["max_tokens"] as? Int, 16)
        XCTAssertNotNil(sent["tools"])
    }

    func testAChatProbeReportsARefusedKey() async {
        let transport = StubChatTransport(
            status: 401,
            lines: [#"data: {"error":{"message":"invalid key"}}"#]
        )
        let probe = ServiceProbe(http: StubHTTPTransport { _ in (Data(), probeHTTP(200)) }, chat: transport)
        let result = await probe.chatModel(chatConfig())
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.statusCode, 401)
        XCTAssertTrue(result.detail.contains("401"), result.detail)
    }

    func testAnEmbeddingProbeChecksTheDimension() async throws {
        let transport = StubHTTPTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/embeddings")
            return (
                try! JSONSerialization.data(withJSONObject: [
                    "data": [["embedding": [0.1, 0.2, 0.3]]],
                ]),
                probeHTTP(200)
            )
        }
        let probe = ServiceProbe(http: transport, chat: StubChatTransport(lines: []))
        let config = EmbeddingConfig(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "Qwen/Qwen3-Embedding-0.6B",
            apiKey: "key"
        )
        let mismatch = await probe.embedding(config, expectedDimensions: 4)
        XCTAssertFalse(mismatch.ok)
        XCTAssertTrue(mismatch.dimensionMismatch)
        XCTAssertTrue(mismatch.detail.contains("3"))
        XCTAssertTrue(mismatch.detail.contains("4"))

        let match = await probe.embedding(config, expectedDimensions: 3)
        XCTAssertTrue(match.ok, match.detail)
        XCTAssertEqual(match.model, "Qwen/Qwen3-Embedding-0.6B")
    }

    func testAGeminiEmbeddingProbeChecksTheDimension() async {
        let transport = StubHTTPTransport { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:embedContent"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "key")
            return (
                try! JSONSerialization.data(withJSONObject: [
                    "embedding": ["values": [0.1, 0.2, 0.3]],
                ]),
                probeHTTP(200)
            )
        }
        let probe = ServiceProbe(http: transport, chat: StubChatTransport(lines: []))
        let config = GeminiEmbeddingConfig(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            model: "gemini-embedding-2",
            apiKey: "key",
            dimensions: 3
        )
        let ok = await probe.geminiEmbedding(config, expectedDimensions: 3)
        XCTAssertTrue(ok.ok, ok.detail)
        XCTAssertEqual(ok.model, "gemini-embedding-2")

        let mismatch = await probe.geminiEmbedding(config, expectedDimensions: 4)
        XCTAssertFalse(mismatch.ok)
        XCTAssertTrue(mismatch.dimensionMismatch)
        XCTAssertTrue(mismatch.detail.contains("3"))
        XCTAssertTrue(mismatch.detail.contains("4"))
    }

    func testARerankProbeReadsTheScores() async {
        let transport = StubHTTPTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/rerank")
            return (
                try! JSONSerialization.data(withJSONObject: [
                    "results": [["index": 0, "relevance_score": 0.9]],
                ]),
                probeHTTP(200)
            )
        }
        let probe = ServiceProbe(http: transport, chat: StubChatTransport(lines: []))
        let result = await probe.rerank(RerankConfig(
            baseURL: URL(string: "https://api.example.com/v1")!,
            model: "Qwen/Qwen3-Reranker-0.6B",
            apiKey: "key"
        ))
        XCTAssertTrue(result.ok, result.detail)
        XCTAssertEqual(result.detail, "返回 1 条分数")
    }

    func testSonioxAndFishProbesHitTheirFreeEndpoints() async {
        let transport = StubHTTPTransport { _ in (Data("{}".utf8), probeHTTP(200)) }
        let probe = ServiceProbe(http: transport, chat: StubChatTransport(lines: []))
        let soniox = await probe.soniox(apiKey: "key")
        let fish = await probe.fish(apiKey: "key")
        XCTAssertTrue(soniox.ok)
        XCTAssertTrue(fish.ok)
        let seen = await transport.seen
        XCTAssertEqual(seen.map { $0.url?.absoluteString }, [
            "https://api.soniox.com/v1/models",
            "https://api.fish.audio/wallet/self/api-credit",
        ])
    }

    func testABailianProbeFallsBackToTheOtherRegion() async {
        let starter = StubBailianStarter(refused: [.beijing])
        let probe = ServiceProbe(
            http: StubHTTPTransport { _ in (Data(), probeHTTP(200)) },
            chat: StubChatTransport(lines: []),
            bailian: starter
        )
        let result = await probe.bailianSTT(
            apiKey: "key",
            model: BailianSTTConfiguration.defaultModel
        )
        XCTAssertTrue(result.ok, result.detail)
        XCTAssertTrue(result.detail.contains("新加坡"), result.detail)
        let seen = await starter.seen
        XCTAssertEqual(seen, [.beijing, .singapore])
    }

    func testABailianProbeReportsARefusedKey() async {
        let starter = StubBailianStarter(refused: [.beijing, .singapore])
        let probe = ServiceProbe(
            http: StubHTTPTransport { _ in (Data(), probeHTTP(200)) },
            chat: StubChatTransport(lines: []),
            bailian: starter
        )
        let result = await probe.bailianSTT(
            apiKey: "key",
            model: BailianSTTConfiguration.defaultModel
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("HTTP 401"), result.detail)
    }

    func testABailianProbeNeedsAKey() async {
        let starter = StubBailianStarter()
        let probe = ServiceProbe(
            http: StubHTTPTransport { _ in (Data(), probeHTTP(200)) },
            chat: StubChatTransport(lines: []),
            bailian: starter
        )
        let result = await probe.bailianSTT(apiKey: " ", model: BailianSTTConfiguration.defaultModel)
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("百炼"), result.detail)
        let seen = await starter.seen
        XCTAssertTrue(seen.isEmpty)
    }

    func testATimeoutIsReportedAsSuch() async {
        let transport = StubHTTPTransport { _ in throw URLError(.timedOut) }
        let probe = ServiceProbe(http: transport, chat: StubChatTransport(lines: []))
        let result = await probe.soniox(apiKey: "key")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.detail, "请求超时")
    }

    func testAnEmptyKeyNeverReachesTheService() async {
        let transport = StubHTTPTransport { _ in
            XCTFail("should not send")
            return (Data(), probeHTTP(200))
        }
        let probe = ServiceProbe(http: transport, chat: StubChatTransport(lines: []))
        let result = await probe.soniox(apiKey: " ")
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.detail.contains("Soniox"))
    }
}
