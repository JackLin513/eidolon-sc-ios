import Foundation

public protocol EmbeddingProvider: Sendable {
    /// The model the vectors are stored under; changing it leaves older vectors unused.
    var model: String { get }
    func embed(_ texts: [String]) async throws -> [[Float]]
    func embedQuery(_ text: String) async throws -> [Float]
}

public protocol RerankProvider: Sendable {
    /// Every document's relevance to `query`, best first.
    func rerank(query: String, documents: [String]) async throws -> [(index: Int, score: Double)]
}

public struct EmbeddingConfig: Sendable, Hashable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public init(baseURL: URL, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public struct RerankConfig: Sendable, Hashable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String

    public init(baseURL: URL, model: String, apiKey: String) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }
}

public enum RetrievalServiceError: LocalizedError, Equatable {
    case status(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .status(let code, let detail):
            return "检索服务返回 \(code)：\(detail)"
        case .invalidResponse(let reason):
            return "检索服务的返回无法解析：\(reason)"
        }
    }
}

/// SiliconFlow's `/embeddings` and `/rerank`, the services upstream uses.
public struct SiliconFlowEmbedding: EmbeddingProvider {
    private let config: EmbeddingConfig
    private let session: URLSession

    public init(config: EmbeddingConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public var model: String { config.model }

    public func embedQuery(_ text: String) async throws -> [Float] {
        guard let vector = try await embed([text]).first else {
            throw RetrievalServiceError.invalidResponse("没有返回向量")
        }
        return vector
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let body: [String: Any] = [
            "model": config.model,
            "input": texts,
            "encoding_format": "float",
        ]
        let data = try await post("embeddings", body: body)
        struct Response: Decodable {
            struct Item: Decodable { let embedding: [Float] }
            let data: [Item]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let items = response.data,
              items.count == texts.count
        else {
            throw RetrievalServiceError.invalidResponse("向量数量不符")
        }
        return items.map(\.embedding)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: config.baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RetrievalServiceError.status(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        return data
    }
}

public struct SiliconFlowRerank: RerankProvider {
    private let config: RerankConfig
    private let session: URLSession

    public init(config: RerankConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func rerank(query: String, documents: [String]) async throws -> [(index: Int, score: Double)] {
        guard !documents.isEmpty else { return [] }
        let body: [String: Any] = [
            "model": config.model,
            "query": query,
            "documents": documents,
            "top_n": documents.count,
            "return_documents": false,
        ]
        var request = URLRequest(url: config.baseURL.appendingPathComponent("rerank"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw RetrievalServiceError.status(code, String(decoding: data.prefix(200), as: UTF8.self))
        }
        struct Response: Decodable {
            struct Item: Decodable {
                let index: Int
                let relevanceScore: Double
                enum CodingKeys: String, CodingKey {
                    case index
                    case relevanceScore = "relevance_score"
                }
            }
            let results: [Item]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let results = response.results
        else {
            throw RetrievalServiceError.invalidResponse("没有返回重排结果")
        }
        return results
            .filter { (0..<documents.count).contains($0.index) }
            .map { (index: $0.index, score: $0.relevanceScore) }
            .sorted { $0.score > $1.score }
    }
}
