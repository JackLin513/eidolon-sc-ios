import Foundation

enum APIError: LocalizedError {
    case status(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case let .status(code, detail):
            return detail.isEmpty ? "请求失败（\(code)）" : detail
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        }
    }
}

private struct APIErrorBody: Decodable {
    let detail: String?
}

/// The backend's HTTP API. The session is kept in a cookie, exactly as the browser keeps it;
/// every request carries an `Origin` because the backend refuses writes without one.
final class APIClient {
    private(set) var baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL = Backend.url) {
        self.baseURL = baseURL

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration)

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder
    }

    /// The origin the backend checks writes against (`sessions.py`). In development any
    /// localhost origin is accepted; a real deployment wants exactly its public origin.
    var origin: String {
        let scheme = baseURL.scheme ?? "http"
        let host = baseURL.host ?? "127.0.0.1"
        if let port = baseURL.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    func absoluteURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.scheme != nil { return url }
        return URL(string: path, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - Accounts

    func account() async throws -> Account {
        let body = try await data(for: request("/api/account"))
        return try decoder.decode(Account.self, from: body)
    }

    func signIn(name: String) async throws {
        var request = request("/api/auth/dev-login", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": name])
        _ = try await data(for: request)
    }

    func agreeToTerms() async throws {
        var request = request("/api/account/consent", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "agree_to_terms": true,
            "at_least_13": true,
        ])
        _ = try await data(for: request)
    }

    func signOut() async throws {
        _ = try await data(for: request("/api/auth/logout", method: "POST"))
    }

    // MARK: - Characters and conversations

    func characters() async throws -> [Character] {
        let body = try await data(for: request("/api/characters"))
        return try decoder.decode([Character].self, from: body)
    }

    func latestConversations() async throws -> [LatestConversation] {
        let body = try await data(for: request("/api/conversations/latest"))
        return try decoder.decode([LatestConversation].self, from: body)
    }

    func createConversation(characterID: String) async throws -> Conversation {
        var request = request("/api/conversations", method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["character_id": characterID])
        let body = try await data(for: request)
        return try decoder.decode(Conversation.self, from: body)
    }

    func messages(conversationID: String) async throws -> [RecordItem] {
        let path = "/api/conversations/\(conversationID)/messages"
        let body = try await data(for: request(path))
        return try decoder.decode([RecordItem].self, from: body)
    }

    /// Sends one text turn and yields its server-sent events as they arrive.
    func sendTurn(conversationID: String, text: String) -> AsyncThrowingStream<TurnEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = request(
                        "/api/conversations/\(conversationID)/turns",
                        method: "POST"
                    )
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(["text": text])

                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError.invalidResponse
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                        }
                        let detail = (try? JSONDecoder().decode(APIErrorBody.self, from: body))?.detail
                            ?? String(data: body, encoding: .utf8)
                            ?? ""
                        throw APIError.status(http.statusCode, detail)
                    }

                    var dataLines: [String] = []
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            if !dataLines.isEmpty {
                                let payload = dataLines.joined(separator: "\n")
                                if let data = payload.data(using: .utf8),
                                   let event = try? decoder.decode(TurnEvent.self, from: data) {
                                    continuation.yield(event)
                                }
                                dataLines.removeAll()
                            }
                        } else if line.hasPrefix("data: ") {
                            dataLines.append(String(line.dropFirst(6)))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Plumbing

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        let url = URL(string: path, relativeTo: baseURL)?.absoluteURL ?? baseURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIErrorBody.self, from: data))?.detail
                ?? String(data: data, encoding: .utf8)
                ?? ""
            throw APIError.status(http.statusCode, detail)
        }
        return data
    }
}
