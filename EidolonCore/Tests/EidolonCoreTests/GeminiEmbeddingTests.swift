import Foundation
import XCTest
@testable import EidolonCore

final class GeminiEmbeddingTests: XCTestCase {
    private func embedding(_ transport: any HTTPTransport, dimensions: Int = 3) -> GeminiEmbedding {
        GeminiEmbedding(
            config: GeminiEmbeddingConfig(
                baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
                model: "gemini-embedding-2",
                apiKey: "secret",
                dimensions: dimensions
            ),
            transport: transport
        )
    }

    func testTheBatchRequestCarriesTheModelAndDimension() async throws {
        let transport = StubHTTPTransport { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://generativelanguage.googleapis.com/v1beta/models/gemini-embedding-2:batchEmbedContents"
            )
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "secret")
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            let requests = try XCTUnwrap(body["requests"] as? [[String: Any]])
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[0]["model"] as? String, "models/gemini-embedding-2")
            XCTAssertEqual(requests[0]["outputDimensionality"] as? Int, 3)
            return (geminiAnswer(dimensions: 3, count: 2), probeHTTP(200))
        }
        let vectors = try await embedding(transport).embed(["甲", "乙"])
        XCTAssertEqual(vectors.count, 2)
        XCTAssertEqual(vectors[0], [0.1, 0.1, 0.1])
        let seen = await transport.seen
        XCTAssertEqual(seen.count, 1)
    }

    func testMoreThanTheBatchLimitIsSplitIntoBatches() async throws {
        let transport = StubHTTPTransport { request in
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            let count = try XCTUnwrap((body["requests"] as? [[String: Any]])?.count)
            return (geminiAnswer(dimensions: 3, count: count), probeHTTP(200))
        }
        let texts = (0..<150).map { "第\($0)段" }
        let vectors = try await embedding(transport).embed(texts)
        XCTAssertEqual(vectors.count, 150)
        let seen = await transport.seen
        XCTAssertEqual(seen.count, 2, "100 + 50")
    }

    func testADimensionMismatchIsAnError() async {
        let transport = StubHTTPTransport { _ in
            (geminiAnswer(dimensions: 4, count: 1), probeHTTP(200))
        }
        do {
            _ = try await embedding(transport, dimensions: 3).embed(["甲"])
            XCTFail("expected a dimension mismatch")
        } catch let error as GeminiEmbeddingError {
            XCTAssertEqual(error, .dimensionMismatch(expected: 3, actual: 4))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnHTTPRefusalIsReported() async {
        let transport = StubHTTPTransport { _ in
            (Data(#"{"error":{"message":"API key not valid"}}"#.utf8), probeHTTP(401))
        }
        do {
            _ = try await embedding(transport).embedQuery("甲")
            XCTFail("expected a refusal")
        } catch let error as GeminiEmbeddingError {
            guard case let .status(code, detail) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(code, 401)
            XCTAssertTrue(detail.contains("API key not valid"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testTheRetrievalConfigCarriesTheBundlesSpace() {
        let config = GeminiEmbeddingConfig(
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
            model: "gemini-embedding-2",
            apiKey: "k",
            dimensions: 1536
        )
        let wrapped = RetrievalEmbeddingConfig.gemini(config)
        XCTAssertEqual(wrapped.model, "gemini-embedding-2")
        XCTAssertEqual(wrapped.dimensions, 1536)
    }
}


private func geminiAnswer(dimensions: Int, count: Int) -> Data {
    jsonData([
        "embeddings": (0..<count).map { _ in
            ["values": (0..<dimensions).map { _ in 0.1 }]
        },
    ])
}
