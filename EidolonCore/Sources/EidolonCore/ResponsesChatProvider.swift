import Foundation

/// OpenAI's Responses interface (upstream `llm/responses.py`): `{base}/responses`, no stored
/// state, the opening system as `instructions`, the rest as input items, and the calls of a
/// tool round handed back with the reasoning that came with them.
public struct ResponsesChatProvider: ChatProvider {
    private let config: ChatModelConfig
    private let transport: any ChatTransport
    private let usageBox = ChatUsageBox()

    public init(config: ChatModelConfig, session: URLSession = .shared) {
        self.init(config: config, transport: URLSessionChatTransport(session: session))
    }

    public init(config: ChatModelConfig, transport: any ChatTransport) {
        self.config = config
        self.transport = transport
    }

    private static func value(_ object: Any) -> JSONValue? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func items(_ message: PromptMessage) -> [[String: Any]] {
        if message.role == .tool {
            return [[
                "type": "function_call_output",
                "call_id": message.toolCallID ?? "",
                "output": message.content,
            ]]
        }
        var items: [[String: Any]] = message.reasoning.compactMap { item -> [String: Any]? in
            guard let object = item.objectValue else { return nil }
            return object.mapValues(\.jsonObject)
        }
        if !message.content.isEmpty {
            // Every message item names its type: OpenAI infers it from the role, but
            // LM Studio's Responses endpoint refuses the whole request without it
            // ("Cannot determine type of 'item'"), which broke every turn after the first.
            items.append([
                "type": "message",
                "role": message.role.rawValue,
                "content": message.content,
            ])
        }
        for call in message.toolCalls {
            items.append([
                "type": "function_call",
                "call_id": call.id,
                "name": call.name,
                "arguments": call.arguments.isEmpty ? "{}" : call.arguments,
            ])
        }
        return items
    }

    func request(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let (opening, rest) = ChatStreamSupport.openingSystem(messages)
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            // Every request carries the whole conversation.
            "store": false,
            "input": rest.flatMap(Self.items),
        ]
        let system = opening.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty { body["instructions"] = system }
        if let maxTokens = config.maxTokens {
            body["max_output_tokens"] = maxTokens
        }
        if let effort = config.reasoningEffort {
            body["reasoning"] = ["effort": effort.rawValue]
            if effort != .none {
                // With `store` off this is all the service keeps of what the model
                // thought, and a tool round has to send it back.
                body["include"] = ["reasoning.encrypted_content"]
            }
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.jsonObject,
                ] as [String: Any]
            }
            if forbidCalls { body["tool_choice"] = "none" }
        }
        body = ChatRequestExtras.merged(config.extraBody, into: body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
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
        let request = try request(messages: messages, tools: tools, forbidCalls: forbidCalls)
        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw await ChatStreamSupport.failure(response.statusCode, lines: response.lines)
        }

        var calls: [Int: (id: String, name: String, arguments: String)] = [:]
        var reasoning: [Int: JSONValue] = [:]
        for try await line in response.lines {
            try Task.checkCancellation()
            guard let payload = SSE.payload(line),
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = event["type"] as? String
            else { continue }
            switch kind {
            case "response.output_text.delta":
                if let delta = event["delta"] as? String, !delta.isEmpty {
                    emit(.text(delta))
                }
            case "response.output_item.added", "response.output_item.done":
                guard let item = event["item"] as? [String: Any] else { break }
                let index = event["output_index"] as? Int ?? calls.count
                if item["type"] as? String == "reasoning", kind == "response.output_item.done" {
                    reasoning[index] = Self.value(item)
                } else if item["type"] as? String == "function_call" {
                    var call = calls[index] ?? ("", "", "")
                    call.id = item["call_id"] as? String ?? call.id
                    call.name = item["name"] as? String ?? call.name
                    // The done item carries the arguments in full.
                    if let arguments = item["arguments"] as? String, !arguments.isEmpty {
                        call.arguments = arguments
                    }
                    calls[index] = call
                }
            case "response.function_call_arguments.delta":
                guard let index = event["output_index"] as? Int,
                      var call = calls[index]
                else { break }
                call.arguments += event["delta"] as? String ?? ""
                calls[index] = call
            case "response.completed", "response.incomplete":
                if let usage = (event["response"] as? [String: Any])?["usage"] as? [String: Any] {
                    usageBox.add(
                        input: usage["input_tokens"] as? Int ?? 0,
                        output: usage["output_tokens"] as? Int ?? 0,
                        cachedInput: (usage["input_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
                    )
                }
            case "error":
                let message = event["message"] as? String ?? "\(event)"
                throw ChatProviderError.invalidResponse("模型在流式输出中报错：\(message)")
            case "response.failed":
                let failure = (event["response"] as? [String: Any])?["error"] ?? event
                throw ChatProviderError.invalidResponse("模型生成失败：\(failure)")
            default:
                break
            }
        }
        if !reasoning.isEmpty {
            emit(.reasoning(reasoning.keys.sorted().compactMap { reasoning[$0] }))
        }
        if !calls.isEmpty {
            emit(.toolCalls(calls.keys.sorted().compactMap { index in
                guard let call = calls[index], !call.name.isEmpty else { return nil }
                return ToolCall(
                    id: call.id.isEmpty ? "call_\(index)" : call.id,
                    name: call.name,
                    arguments: call.arguments
                )
            }))
        }
    }
}

extension ResponsesChatProvider: ChatUsageReporting {
    public var usageProviderHost: String { config.baseURL.host ?? config.baseURL.absoluteString }
    public var usageModel: String { config.model }

    public func takeUsage() async -> ChatUsage? { usageBox.take() }
}

extension ResponsesChatProvider: ToolChatProvider {
    public func stream(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(messages: messages, tools: tools, forbidCalls: forbidCalls) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
