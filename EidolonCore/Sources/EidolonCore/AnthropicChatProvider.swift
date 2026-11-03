import Foundation

/// Anthropic's Messages interface (upstream `llm/anthropic.py`): `{base}/messages`,
/// `x-api-key` with a pinned version, a reply cap the interface requires, the opening
/// system as `system`, and thinking blocks handed back with the calls they came with.
public struct AnthropicChatProvider: ChatProvider {
    public static let apiVersion = "2023-06-01"
    /// The Messages interface requires a cap; a reply may run to several thousand tokens
    /// of prose and thinking.
    public static let defaultMaxTokens = 16384

    private let config: ChatModelConfig
    private let transport: any ChatTransport

    public init(config: ChatModelConfig, session: URLSession = .shared) {
        self.init(config: config, transport: URLSessionChatTransport(session: session))
    }

    public init(config: ChatModelConfig, transport: any ChatTransport) {
        self.config = config
        self.transport = transport
    }

    private static func arguments(_ text: String) -> Any {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return [String: Any]() }
        return object
    }

    private static func blocks(_ message: PromptMessage) -> [[String: Any]] {
        var blocks: [[String: Any]] = message.reasoning.compactMap {
            $0.objectValue.map { $0.mapValues(\.jsonObject) } as? [String: Any]
        }
        if !message.content.isEmpty {
            blocks.append(["type": "text", "text": message.content])
        }
        blocks += message.toolCalls.map { call in
            ["type": "tool_use", "id": call.id, "name": call.name, "input": arguments(call.arguments)]
        }
        return blocks
    }

    /// Messages turns; the results of one round of calls go back together in the user turn
    /// that follows. A system message after the opening goes as a user turn of its own.
    private static func messages(_ messages: [PromptMessage]) -> [[String: Any]] {
        var turns: [[String: Any]] = []
        for message in messages {
            if message.role == .tool {
                let result: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": message.toolCallID ?? "",
                    "content": message.content,
                ]
                if var last = turns.last, last["role"] as? String == "user",
                   var content = last["content"] as? [[String: Any]] {
                    content.append(result)
                    last["content"] = content
                    turns[turns.count - 1] = last
                } else {
                    turns.append(["role": "user", "content": [result]])
                }
                continue
            }
            if message.toolCalls.isEmpty && message.reasoning.isEmpty {
                guard !message.content.isEmpty else { continue }
                if message.role == .system {
                    turns.append(["role": "user", "content": [["type": "text", "text": message.content]]])
                } else {
                    turns.append(["role": message.role.rawValue, "content": message.content])
                }
            } else {
                let role = message.role == .system ? "user" : message.role.rawValue
                turns.append(["role": role, "content": blocks(message)])
            }
        }
        return turns
    }

    func request(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool
    ) throws -> URLRequest {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let (opening, rest) = ChatStreamSupport.openingSystem(messages)
        var body: [String: Any] = [
            "model": config.model,
            "stream": true,
            // The Messages interface requires a cap; a reply may run to several thousand
            // tokens of prose and thinking.
            "max_tokens": config.maxTokens ?? Self.defaultMaxTokens,
            "messages": Self.messages(rest),
        ]
        let system = opening.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !system.isEmpty { body["system"] = system }
        if let effort = config.reasoningEffort {
            if effort == .none {
                body["thinking"] = ["type": "disabled"]
            } else {
                body["thinking"] = ["type": "adaptive", "display": "omitted"]
                body["output_config"] = ["effort": effort.rawValue]
            }
        }
        if !tools.isEmpty {
            body["tools"] = tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": tool.parameters.jsonObject,
                ] as [String: Any]
            }
            if forbidCalls { body["tool_choice"] = ["type": "none"] }
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

        var calls: [Int: (id: String, name: String, json: String, input: Any?)] = [:]
        var thinking: [Int: [String: Any]] = [:]
        for try await line in response.lines {
            try Task.checkCancellation()
            guard let payload = SSE.payload(line),
                  let data = payload.data(using: .utf8),
                  let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let kind = event["type"] as? String
            else { continue }
            switch kind {
            case "content_block_start":
                guard let block = event["content_block"] as? [String: Any] else { break }
                let index = event["index"] as? Int ?? thinking.count + calls.count
                switch block["type"] as? String {
                case "thinking", "redacted_thinking":
                    thinking[index] = block
                case "tool_use":
                    calls[index] = (
                        block["id"] as? String ?? "",
                        block["name"] as? String ?? "",
                        "",
                        block["input"]
                    )
                default:
                    break
                }
            case "content_block_delta":
                guard let delta = event["delta"] as? [String: Any] else { break }
                let index = event["index"] as? Int ?? -1
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        emit(.text(text))
                    }
                case "input_json_delta":
                    if var call = calls[index] {
                        call.json += delta["partial_json"] as? String ?? ""
                        calls[index] = call
                    }
                case "thinking_delta":
                    if var block = thinking[index] {
                        block["thinking"] = (block["thinking"] as? String ?? "")
                            + (delta["thinking"] as? String ?? "")
                        thinking[index] = block
                    }
                case "signature_delta":
                    if var block = thinking[index] {
                        block["signature"] = (block["signature"] as? String ?? "")
                            + (delta["signature"] as? String ?? "")
                        thinking[index] = block
                    }
                default:
                    break
                }
            case "error":
                let error = event["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "\(event)"
                throw ChatProviderError.invalidResponse("模型在流式输出中报错：\(message)")
            default:
                break
            }
        }
        if !thinking.isEmpty {
            let values = thinking.keys.sorted().compactMap { key -> JSONValue? in
                guard let block = thinking[key],
                      let data = try? JSONSerialization.data(withJSONObject: block)
                else { return nil }
                return try? JSONDecoder().decode(JSONValue.self, from: data)
            }
            if !values.isEmpty { emit(.reasoning(values)) }
        }
        if !calls.isEmpty {
            emit(.toolCalls(calls.keys.sorted().compactMap { index in
                guard let call = calls[index], !call.name.isEmpty else { return nil }
                let arguments: String
                if !call.json.isEmpty {
                    arguments = call.json
                } else if let input = call.input,
                          let data = try? JSONSerialization.data(withJSONObject: input) {
                    arguments = String(decoding: data, as: UTF8.self)
                } else {
                    arguments = "{}"
                }
                return ToolCall(
                    id: call.id.isEmpty ? "call_\(index)" : call.id,
                    name: call.name,
                    arguments: arguments
                )
            }))
        }
    }
}

extension AnthropicChatProvider: ToolChatProvider {
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
