import Foundation

public struct PromptMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    public var role: Role
    public var content: String
    /// What the model asked to call in this assistant message, if it called anything.
    public var toolCalls: [ToolCall]
    /// The call this tool message answers.
    public var toolCallID: String?

    public init(
        _ role: Role,
        _ content: String,
        toolCalls: [ToolCall] = [],
        toolCallID: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// A call the chat model made to one of the offered tools.
public struct ToolCall: Sendable, Hashable {
    public var id: String
    public var name: String
    /// The arguments as the model wrote them: a JSON object string, not yet read.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }

    /// The `query` argument of a recall-story call, if it has a usable one.
    public var query: String? {
        guard let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = object["query"] as? String
        else { return nil }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// A tool offered to the chat model, in the OpenAI function-calling shape.
public struct ChatTool: Sendable, Hashable {
    public var name: String
    public var description: String
    public var parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// What a streaming chat call yields: her words, and the tool calls it made when it
/// ended without answering.
public enum ChatStreamEvent: Sendable, Hashable {
    case text(String)
    case toolCalls([ToolCall])
}

/// How the app talks to the chat model. The turn engine only needs this, so tests can
/// answer without a network (ADR-0012).
public protocol ChatProvider: Sendable {
    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error>
}

/// A provider that can also be offered tools. The turn engine offers the recall-story
/// tool on every turn when retrieval is configured, and this is what answers.
public protocol ToolChatProvider: ChatProvider {
    func stream(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool
    ) -> AsyncThrowingStream<ChatStreamEvent, Error>
}

public struct ChatModelConfig: Sendable, Hashable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    public var historyTurns: Int
    public var maxTokens: Int?
    /// Extra fields merged into the request body, as upstream's `CHAT_LLM_EXTRA_BODY`
    /// does (for example `{"enable_thinking": false}`).
    public var extraBody: [String: JSONValue]?

    public init(
        baseURL: URL,
        model: String,
        apiKey: String,
        historyTurns: Int = 20,
        maxTokens: Int? = nil,
        extraBody: [String: JSONValue]? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.historyTurns = historyTurns
        self.maxTokens = maxTokens
        self.extraBody = extraBody
    }
}

public enum ChatProviderError: LocalizedError, Equatable {
    case notConfigured
    case status(Int, String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有填写对话模型"
        case .status(let code, let detail):
            let body = detail.isEmpty ? "对话模型返回 \(code)" : "对话模型返回 \(code)：\(detail)"
            return body
        case .invalidResponse(let reason):
            return "对话模型的回复无法解析：\(reason)"
        }
    }
}

/// An OpenAI-compatible `/chat/completions` streaming client.
public struct OpenAICompatibleChatProvider: ChatProvider {
    private let config: ChatModelConfig
    private let session: URLSession
    /// Some OpenAI-compatible services (SiliconFlow among them) accept only one system
    /// message and only at the front. Merging the leading system blocks keeps the text
    /// and its order exactly as upstream sends it, just as one message.
    private let mergeLeadingSystemMessages: Bool

    public init(
        config: ChatModelConfig,
        session: URLSession = .shared,
        mergeLeadingSystemMessages: Bool = true
    ) {
        self.config = config
        self.session = session
        self.mergeLeadingSystemMessages = mergeLeadingSystemMessages
    }

    public func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        let events = stream(messages: messages, tools: [], forbidCalls: false)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case let .text(text) = event {
                            continuation.yield(text)
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

    /// Services that take one system message only get every system block, in order, at the
    /// front. Upstream puts the per-turn section after the history; the content is the same,
    /// its position is not.
    private func prepared(_ messages: [PromptMessage]) -> [PromptMessage] {
        guard mergeLeadingSystemMessages else { return messages }
        let system = messages.filter { $0.role == .system }
        guard system.count > 1 else { return messages }
        let merged = PromptMessage(.system, system.map(\.content).joined(separator: "\n\n"))
        return [merged] + messages.filter { $0.role != .system }
    }

    private func encoded(_ message: PromptMessage) -> [String: Any] {
        var object: [String: Any] = [
            "role": message.role.rawValue,
            "content": message.content,
        ]
        if !message.toolCalls.isEmpty {
            object["tool_calls"] = message.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": ["name": call.name, "arguments": call.arguments],
                ] as [String: Any]
            }
        }
        if let toolCallID = message.toolCallID {
            object["tool_call_id"] = toolCallID
        }
        return object
    }

    private func run(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool,
        _ emit: (ChatStreamEvent) -> Void
    ) async throws {
        guard !config.apiKey.isEmpty, !config.model.isEmpty else {
            throw ChatProviderError.notConfigured
        }
        let url = config.baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            "messages": prepared(messages).map(encoded),
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters.jsonObject,
                    ],
                ] as [String: Any]
            }
            // The last round of a turn is offered the same tools, so that the prompt
            // stays the same from turn to turn, but is told not to call them.
            if forbidCalls {
                body["tool_choice"] = "none"
            }
        }
        if let maxTokens = config.maxTokens {
            body["max_tokens"] = maxTokens
        }
        if let extraBody = config.extraBody {
            for (key, value) in extraBody {
                body[key] = value.jsonObject
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ChatProviderError.invalidResponse("没有收到 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            var detail = ""
            for try await line in bytes.lines {
                detail += line
                if detail.count > 400 { break }
            }
            throw ChatProviderError.status(http.statusCode, detail)
        }

        var calls = ToolCallAssembly()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard !payload.isEmpty else { continue }
            guard let data = payload.data(using: .utf8) else { continue }
            guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                continue
            }
            guard let delta = chunk.choices?.first?.delta else { continue }
            if let text = delta.content, !text.isEmpty {
                emit(.text(text))
            }
            for call in delta.toolCalls ?? [] {
                calls.add(call)
            }
        }
        if !calls.done.isEmpty {
            emit(.toolCalls(calls.done))
        }
    }
}

extension OpenAICompatibleChatProvider: ToolChatProvider {
    public func stream(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        messages: messages,
                        tools: tools,
                        forbidCalls: forbidCalls
                    ) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Collects streamed tool calls: the name and identifier arrive with the first piece of a
/// call, the arguments a fragment at a time, and calls are told apart by `index`.
struct ToolCallAssembly {
    private var partial: [Int: (id: String, name: String, arguments: String)] = [:]

    mutating func add(_ delta: StreamChunk.Delta.ToolCall) {
        var call = partial[delta.index] ?? (id: "", name: "", arguments: "")
        if let id = delta.id, !id.isEmpty { call.id = id }
        if let name = delta.function?.name, !name.isEmpty { call.name = name }
        if let arguments = delta.function?.arguments {
            call.arguments += arguments
        }
        partial[delta.index] = call
    }

    /// The calls in the order the model made them, finished with what arrived.
    var done: [ToolCall] {
        partial.keys.sorted().compactMap { index in
            guard let call = partial[index], !call.name.isEmpty else { return nil }
            let id = call.id.isEmpty ? "call_\(index)" : call.id
            return ToolCall(id: id, name: call.name, arguments: call.arguments)
        }
    }
}

struct StreamChunk: Decodable {
    struct Delta: Decodable {
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }

        struct ToolCall: Decodable {
            let index: Int
            let id: String?
            let function: Function?
        }

        let content: String?
        let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case content
            case toolCalls = "tool_calls"
        }
    }

    struct Choice: Decodable {
        let delta: Delta?
    }

    let choices: [Choice]?
}
