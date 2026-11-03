import Foundation
import XCTest
@testable import EidolonCore

/// An HTTP transport that answers from a closure and keeps every request it saw.
private actor RequestLog {
    private(set) var items: [URLRequest] = []
    func add(_ request: URLRequest) { items.append(request) }
    func all() -> [URLRequest] { items }
}

final class StubHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let requests = RequestLog()
    private let handler: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    init(_ handler: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await requests.add(request)
        return try await handler(request)
    }

    var seen: [URLRequest] {
        get async { await requests.all() }
    }
}

/// A chat transport that answers with scripted SSE lines and keeps the request.
final class StubChatTransport: ChatTransport, @unchecked Sendable {
    private let requests = RequestLog()
    private let status: Int
    private let lines: [String]
    private let error: (any Error)?

    init(status: Int = 200, lines: [String], error: (any Error)? = nil) {
        self.status = status
        self.lines = lines
        self.error = error
    }

    func send(_ request: URLRequest) async throws -> ChatHTTPResponse {
        await requests.add(request)
        let lines = self.lines
        let error = self.error
        let stream = AsyncThrowingStream<String, Error> { continuation in
            Task {
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                }
            }
        }
        return ChatHTTPResponse(statusCode: status, lines: stream)
    }

    var seen: [URLRequest] {
        get async { await requests.all() }
    }
}

func probeHTTP(_ status: Int, url: String = "https://example.com") -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: url)!, statusCode: status, httpVersion: nil, headerFields: nil)!
}

func body(_ request: URLRequest) throws -> [String: Any] {
    try XCTUnwrap(
        JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
    )
}

func jsonData(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func event(_ object: [String: Any]) -> String {
    "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

func textChunk(_ text: String) -> String {
    event([
        "choices": [["delta": ["content": text]]],
    ])
}
