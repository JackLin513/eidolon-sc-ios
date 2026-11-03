import Foundation
import XCTest
@testable import EidolonCore

final class ModelCatalogTests: XCTestCase {
    func testOpenAICompatibleListUsesBearerAndDeduplicates() async throws {
        let transport = StubHTTPTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer key")
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/models")
            return (jsonData(["data": [
                ["id": "model-b"], ["id": "model-a"], ["id": "model-b"], [],
            ]]), probeHTTP(200))
        }
        let models = try await ModelCatalog.fetch(
            baseURL: URL(string: "https://api.example.com/v1/")!,
            apiKey: "key",
            service: .openAICompatible,
            transport: transport
        )
        XCTAssertEqual(models, ["model-b", "model-a"])
    }

    func testAnthropicListUsesItsHeadersAndPaginates() async throws {
        let transport = StubHTTPTransport { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "key")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "anthropic-version"),
                AnthropicChatProvider.apiVersion
            )
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if query.contains(where: { $0.name == "after_id" }) {
                return (jsonData([
                    "data": [["id": "second"]],
                    "has_more": false,
                ]), probeHTTP(200, url: url.absoluteString))
            }
            XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "1000")))
            return (jsonData([
                "data": [["id": "first"]],
                "has_more": true,
                "last_id": "first",
            ]), probeHTTP(200, url: url.absoluteString))
        }
        let models = try await ModelCatalog.fetch(
            baseURL: URL(string: "https://api.anthropic.com/v1")!,
            apiKey: "key",
            service: .anthropic,
            transport: transport
        )
        XCTAssertEqual(models, ["first", "second"])
        let seen = await transport.seen
        XCTAssertEqual(seen.count, 2)
    }

    func testAnHTTPErrorBecomesTheServicesOwnWords() async {
        let transport = StubHTTPTransport { _ in
            (jsonData(["error": ["message": "invalid key"]]), probeHTTP(401))
        }
        do {
            _ = try await ModelCatalog.fetch(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "key",
                service: .openAICompatible,
                transport: transport
            )
            XCTFail("expected an error")
        } catch let error as ModelListError {
            XCTAssertEqual(error, .status(401, "invalid key"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAnUnreadableListIsAnError() async {
        let transport = StubHTTPTransport { _ in
            (Data("nope".utf8), probeHTTP(200))
        }
        do {
            _ = try await ModelCatalog.fetch(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "key",
                service: .openAICompatible,
                transport: transport
            )
            XCTFail("expected an error")
        } catch let error as ModelListError {
            guard case .invalidResponse = error else { return XCTFail("unexpected: \(error)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testATimeoutIsItsOwnError() async {
        let transport = StubHTTPTransport { _ in throw URLError(.timedOut) }
        do {
            _ = try await ModelCatalog.fetch(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: "key",
                service: .openAICompatible,
                transport: transport
            )
            XCTFail("expected an error")
        } catch let error as ModelListError {
            XCTAssertEqual(error, .timeout)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAMissingKeyIsRefusedBeforeAnyRequest() async {
        let transport = StubHTTPTransport { _ in
            XCTFail("should not send")
            return (Data(), probeHTTP(200))
        }
        do {
            _ = try await ModelCatalog.fetch(
                baseURL: URL(string: "https://api.example.com/v1")!,
                apiKey: " ",
                service: .openAICompatible,
                transport: transport
            )
            XCTFail("expected an error")
        } catch let error as ModelListError {
            XCTAssertEqual(error, .notConfigured("密钥"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
