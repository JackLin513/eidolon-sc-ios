import Foundation

/// A plain request and its answer, injected so listings and probes can be tested without
/// a network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

public enum ModelListService: Sendable, Hashable {
    case openAICompatible
    case anthropic
}

public enum ModelListError: LocalizedError, Equatable {
    case notConfigured(String)
    case status(Int, String)
    case invalidResponse(String)
    case tooMany
    case timeout
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(detail):
            return "还差：\(detail)"
        case let .status(code, detail):
            return detail.isEmpty ? "服务商返回 \(code)" : "服务商返回 \(code)：\(detail)"
        case let .invalidResponse(reason):
            return "模型列表无法解析：\(reason)"
        case .tooMany:
            return "服务返回的模型列表太大了"
        case .timeout:
            return "获取模型列表超时"
        case let .transport(detail):
            return "请求模型列表失败：\(detail)"
        }
    }
}

/// `GET {base}/models`, as upstream `llm/listing.py` reads it: OpenAI's `Bearer` shape and
/// Anthropic's `x-api-key` shape, deduplicated, capped, with a short timeout.
public enum ModelCatalog {
    public static let maxModels = 2000
    public static let maxPages = 3
    public static let maxModelLength = 200
    public static let timeout: TimeInterval = 10

    /// The models the app and upstream use by default; marked 推荐 in the picker.
    public static let recommended: Set<String> = [
        "Qwen/Qwen3-Embedding-0.6B",
        "Qwen/Qwen3-Reranker-0.6B",
        "typesafe/jev-1.13",
        "clef-flash",
        "decision-model-preview",
        "stt-rt-v5",
        "s2.1-pro-free",
    ]

    public static func fetch(
        baseURL: URL,
        apiKey: String,
        service: ModelListService,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) async throws -> [String] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelListError.notConfigured("密钥")
        }
        var url = baseURL.absoluteString
        while url.hasSuffix("/") { url.removeLast() }
        guard let endpoint = URL(string: url + "/models") else {
            throw ModelListError.notConfigured("接口地址")
        }

        let anthropic = service == .anthropic
        var ids: [String] = []
        var query: [String: String] = anthropic ? ["limit": "1000"] : [:]
        for _ in 0..<maxPages {
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
            if !query.isEmpty {
                components?.queryItems = query
                    .sorted { $0.key < $1.key }
                    .map { URLQueryItem(name: $0.key, value: $0.value) }
            }
            guard let pageURL = components?.url else { break }
            var request = URLRequest(url: pageURL)
            request.httpMethod = "GET"
            request.timeoutInterval = timeout
            if anthropic {
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue(AnthropicChatProvider.apiVersion, forHTTPHeaderField: "anthropic-version")
            } else {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }

            let (data, response) = try await send(request, transport: transport)
            guard (200..<300).contains(response.statusCode) else {
                throw ModelListError.status(
                    response.statusCode,
                    said(data)
                )
            }
            guard data.count <= 2_000_000 else { throw ModelListError.tooMany }
            guard let page = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let listed = page["data"] as? [Any]
            else {
                throw ModelListError.invalidResponse("服务没有按 OpenAI 或 Anthropic 的格式列出模型")
            }
            for case let model as [String: Any] in listed {
                guard let id = model["id"] as? String,
                      !id.isEmpty,
                      id.count <= maxModelLength,
                      !ids.contains(id)
                else { continue }
                ids.append(id)
            }
            if ids.count >= maxModels { break }
            guard page["has_more"] as? Bool == true,
                  let last = page["last_id"] as? String, !last.isEmpty
            else { break }
            query = anthropic
                ? ["limit": "1000", "after_id": last]
                : ["after": last]
        }
        return Array(ids.prefix(maxModels))
    }

    private static func send(
        _ request: URLRequest,
        transport: any HTTPTransport
    ) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw ModelListError.timeout
        } catch {
            throw ModelListError.transport(error.localizedDescription)
        }
    }

    /// What a service said in refusing: its usual `error.message` / `message` / `detail`,
    /// else the start of what it answered.
    static func said(_ data: Data) -> String {
        if let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = answer["error"] as? [String: Any],
               let message = error["message"] as? String, !message.isEmpty {
                return String(message.prefix(300))
            }
            for key in ["message", "detail"] {
                if let said = answer[key] as? String, !said.isEmpty {
                    return String(said.prefix(300))
                }
            }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
