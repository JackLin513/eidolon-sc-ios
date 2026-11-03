import Foundation

/// What a test button found: whether the service answered, how long it took, the HTTP
/// status when there was one, and — for the chat model — a short account of what came
/// back. A failed probe never changes a setting.
public struct ProbeResult: Sendable, Hashable {
    public var ok: Bool
    public var milliseconds: Int
    public var statusCode: Int?
    public var model: String?
    public var detail: String
    public var dimensionMismatch: Bool

    public init(
        ok: Bool,
        milliseconds: Int,
        statusCode: Int? = nil,
        model: String? = nil,
        detail: String = "",
        dimensionMismatch: Bool = false
    ) {
        self.ok = ok
        self.milliseconds = milliseconds
        self.statusCode = statusCode
        self.model = model
        self.detail = detail
        self.dimensionMismatch = dimensionMismatch
    }
}

public enum ProbeError: LocalizedError, Equatable {
    case notConfigured(String)
    case timeout
    case status(Int, String)
    case invalidResponse(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case let .notConfigured(detail): "还差：\(detail)"
        case .timeout: "请求超时"
        case let .status(code, detail):
            detail.isEmpty ? "服务返回 \(code)" : "服务返回 \(code)：\(detail)"
        case let .invalidResponse(reason): "返回无法解析：\(reason)"
        case let .transport(detail): detail
        }
    }
}

private actor StatusBox {
    private(set) var value: Int?

    func set(_ status: Int) { value = status }
}

/// Keeps the status of the streaming request so a probe can show it beside the result.
private struct CapturingChatTransport: ChatTransport {
    let inner: any ChatTransport
    let status: StatusBox

    func send(_ request: URLRequest) async throws -> ChatHTTPResponse {
        let response = try await inner.send(request)
        await status.set(response.statusCode)
        return response
    }
}

/// The test buttons' real, minimal requests. Each uses the values on the page, not the
/// saved settings, and writes nothing.
public struct ServiceProbe: Sendable {
    private let http: any HTTPTransport
    private let chat: any ChatTransport
    private static let pingTool = ChatTool(
        name: "ping",
        description: "A test tool. No need to call it.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    public init(
        http: any HTTPTransport = URLSessionHTTPTransport(),
        chat: any ChatTransport = URLSessionChatTransport()
    ) {
        self.http = http
        self.chat = chat
    }

    /// A tiny streamed request with a `ping` tool offered: it proves the key, the address,
    /// the protocol's streaming shape and that the service accepts tools in one go.
    public func chatModel(_ config: ChatModelConfig) async -> ProbeResult {
        var probe = config
        // Small enough to be quick, but otherwise exactly what the page will use.
        probe.maxTokens = 16
        return await stream(
            probe,
            messages: [
                PromptMessage(.system, "Reply with one short word."),
                PromptMessage(.user, "ping"),
            ],
            model: config.model
        )
    }

    /// The background model only has to write text: no tool round.
    public func backgroundModel(_ config: ChatModelConfig) async -> ProbeResult {
        var probe = config
        probe.maxTokens = 16
        return await stream(
            probe,
            messages: [
                PromptMessage(.system, "Reply with one short word."),
                PromptMessage(.user, "ping"),
            ],
            model: config.model,
            tools: false
        )
    }

    private func stream(
        _ config: ChatModelConfig,
        messages: [PromptMessage],
        model: String,
        tools: Bool = true
    ) async -> ProbeResult {
        let started = ContinuousClock.now
        let status = StatusBox()
        do {
            let provider = ChatProviderFactory.make(
                config: config,
                transport: CapturingChatTransport(inner: chat, status: status)
            )
            try await withTimeout(seconds: 25) {
                for try await event in provider.stream(
                    messages: messages,
                    tools: tools ? [Self.pingTool] : [],
                    forbidCalls: false
                ) {
                    if case let .text(text) = event, !text.isEmpty { break }
                }
            }
            return ProbeResult(
                ok: true,
                milliseconds: milliseconds(since: started),
                statusCode: await status.value,
                model: model,
                detail: tools ? "流式请求与工具声明都可用" : "流式请求可用"
            )
        } catch {
            return failure(error, since: started, model: model)
        }
    }

    public func embedding(
        _ config: EmbeddingConfig,
        expectedDimensions: Int?
    ) async -> ProbeResult {
        let started = ContinuousClock.now
        do {
            var url = config.baseURL.absoluteString
            while url.hasSuffix("/") { url.removeLast() }
            guard let endpoint = URL(string: url + "/embeddings") else {
                throw ProbeError.notConfigured("接口地址")
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "input": ["检索测试"],
                "encoding_format": "float",
            ])
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw ProbeError.status(response.statusCode, ModelCatalog.said(data))
            }
            struct Answer: Decodable {
                struct Item: Decodable { let embedding: [Double] }
                let data: [Item]?
            }
            guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
                  let vector = answer.data?.first?.embedding,
                  !vector.isEmpty
            else {
                throw ProbeError.invalidResponse("没有返回向量")
            }
            let latency = milliseconds(since: started)
            if let expected = expectedDimensions, vector.count != expected {
                return ProbeResult(
                    ok: false,
                    milliseconds: latency,
                    statusCode: response.statusCode,
                    model: config.model,
                    detail: "模型维度与内容包不符：返回 \(vector.count)，内容包 \(expected)",
                    dimensionMismatch: true
                )
            }
            return ProbeResult(
                ok: true,
                milliseconds: latency,
                statusCode: response.statusCode,
                model: config.model,
                detail: "返回 \(vector.count) 维向量"
            )
        } catch {
            return failure(error, since: started, model: config.model)
        }
    }

    public func rerank(_ config: RerankConfig) async -> ProbeResult {
        let started = ContinuousClock.now
        do {
            var url = config.baseURL.absoluteString
            while url.hasSuffix("/") { url.removeLast() }
            guard let endpoint = URL(string: url + "/rerank") else {
                throw ProbeError.notConfigured("接口地址")
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": config.model,
                "query": "检索测试",
                "documents": ["甲", "乙"],
                "top_n": 2,
                "return_documents": false,
            ])
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw ProbeError.status(response.statusCode, ModelCatalog.said(data))
            }
            guard let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = answer["results"] as? [Any], !results.isEmpty
            else {
                throw ProbeError.invalidResponse("没有返回重排结果")
            }
            return ProbeResult(
                ok: true,
                milliseconds: milliseconds(since: started),
                statusCode: response.statusCode,
                model: config.model,
                detail: "返回 \(results.count) 条分数"
            )
        } catch {
            return failure(error, since: started, model: config.model)
        }
    }

    /// Soniox's model list costs nothing and says whether the key works.
    public func soniox(apiKey: String) async -> ProbeResult {
        await get(
            URL(string: "https://api.soniox.com/v1/models")!,
            apiKey: apiKey,
            model: nil,
            name: "Soniox"
        )
    }

    /// Fish Audio's balance endpoint needs no synthesis and refuses a bad key.
    public func fish(apiKey: String) async -> ProbeResult {
        await get(
            URL(string: "https://api.fish.audio/wallet/self/api-credit")!,
            apiKey: apiKey,
            model: nil,
            name: "Fish Audio"
        )
    }

    private func get(
        _ url: URL,
        apiKey: String,
        model: String?,
        name: String
    ) async -> ProbeResult {
        let started = ContinuousClock.now
        do {
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProbeError.notConfigured("\(name) 密钥")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 15
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await send(request)
            guard (200..<300).contains(response.statusCode) else {
                throw ProbeError.status(response.statusCode, ModelCatalog.said(data))
            }
            return ProbeResult(
                ok: true,
                milliseconds: milliseconds(since: started),
                statusCode: response.statusCode,
                model: model,
                detail: "\(name) 可达"
            )
        } catch {
            return failure(error, since: started, model: model)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await http.send(request)
        } catch let error as URLError where error.code == .timedOut {
            throw ProbeError.timeout
        } catch {
            throw ProbeError.transport(error.localizedDescription)
        }
    }

    private func failure(_ error: any Error, since: ContinuousClock.Instant, model: String?) -> ProbeResult {
        let status: Int?
        if case let ChatProviderError.status(code, _) = error {
            status = code
        } else if case let ProbeError.status(code, _) = error {
            status = code
        } else {
            status = nil
        }
        return ProbeResult(
            ok: false,
            milliseconds: milliseconds(since: since),
            statusCode: status,
            model: model,
            detail: error.localizedDescription
        )
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds) * 1000
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Runs `operation`, failing with `ProbeError.timeout` if it has not finished in time.
    private func withTimeout(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProbeError.timeout
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}
