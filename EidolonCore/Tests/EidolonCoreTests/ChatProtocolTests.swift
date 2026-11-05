import Foundation
import XCTest
@testable import EidolonCore

final class ChatProtocolTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<ChatStreamEvent, Error>) async throws -> [ChatStreamEvent] {
        var events: [ChatStreamEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    // MARK: usage

    func testChatCompletionsAsksForAndReadsTheFinalUsageChunk() async throws {
        let transport = StubChatTransport(lines: [
            textChunk("嗯"),
            event([
                "choices": [],
                "usage": [
                    "prompt_tokens": 10,
                    "completion_tokens": 5,
                    "prompt_tokens_details": ["cached_tokens": 2],
                ],
            ]),
            "data: [DONE]",
        ])
        let provider = OpenAICompatibleChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.deepseek.com/v1")!,
                model: "deepseek-v4-pro",
                apiKey: "k"
            ),
            transport: transport
        )
        _ = try await collect(provider.stream(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        let seen = await transport.seen
        let sent = try body(try XCTUnwrap(seen.first))
        XCTAssertEqual((sent["stream_options"] as? [String: Any])?["include_usage"] as? Bool, true)
        let usage = await provider.takeUsage()
        XCTAssertEqual(usage, ChatUsage(input: 10, output: 5, cachedInput: 2))
        XCTAssertEqual(provider.usageProviderHost, "api.deepseek.com")
        XCTAssertEqual(provider.usageModel, "deepseek-v4-pro")
    }

    func testAnthropicReadsInputFromMessageStartAndOutputFromMessageDelta() async throws {
        let transport = StubChatTransport(lines: [
            event([
                "type": "message_start",
                "message": ["usage": [
                    "input_tokens": 10, "output_tokens": 1,
                    "cache_read_input_tokens": 3,
                ]],
            ]),
            event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "嗯"]]),
            event(["type": "message_delta", "usage": ["output_tokens": 5]]),
        ])
        let provider = AnthropicChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "claude-sonnet-5-5",
                apiKey: "k"
            ),
            transport: transport
        )
        _ = try await collect(provider.stream(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        let usage = await provider.takeUsage()
        XCTAssertEqual(usage, ChatUsage(input: 10, output: 5, cachedInput: 3))
    }

    func testResponsesReadsTheCompletedResponseUsage() async throws {
        let transport = StubChatTransport(lines: [
            event(["type": "response.output_text.delta", "delta": "嗯"]),
            event([
                "type": "response.completed",
                "response": ["usage": [
                    "input_tokens": 10, "output_tokens": 5,
                    "input_tokens_details": ["cached_tokens": 2],
                ]],
            ]),
        ])
        let provider = ResponsesChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.openai.com/v1")!,
                model: "gpt-6.1-sol",
                apiKey: "k"
            ),
            transport: transport
        )
        _ = try await collect(provider.stream(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        let usage = await provider.takeUsage()
        XCTAssertEqual(usage, ChatUsage(input: 10, output: 5, cachedInput: 2))
    }

    /// A history with a mid-conversation system message (the 现在 section) must name every
    /// item's type: LM Studio's Responses endpoint rejected untyped items outright.
    func testResponsesSendsTypedMessageItems() async throws {
        let transport = StubChatTransport(lines: [textChunk("嗯")])
        let provider = ResponsesChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://example.com/v1")!,
                model: "local",
                apiKey: "k"
            ),
            transport: transport
        )
        let messages: [PromptMessage] = [
            .init(.system, "人设"),
            .init(.user, "在吗"),
            .init(.assistant, "在"),
            .init(.system, "现在是晚上"),
            .init(.user, "发张照片"),
        ]
        _ = try await collect(provider.stream(messages: messages, tools: [], forbidCalls: false))
        let seen = await transport.seen
        let sent = try body(try XCTUnwrap(seen.first))
        XCTAssertEqual(sent["instructions"] as? String, "人设")
        let input = try XCTUnwrap(sent["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 4)
        for item in input {
            XCTAssertEqual(item["type"] as? String, "message")
        }
        XCTAssertEqual(input.map { $0["role"] as? String }, ["user", "assistant", "system", "user"])
    }

    // MARK: chat-completions

    func testChatCompletionsSendsTheReplyCapAndReasoningEffort() async throws {
        let transport = StubChatTransport(lines: [textChunk("嗯")])
        let provider = OpenAICompatibleChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://example.com/v1")!,
                model: "test-model",
                apiKey: "secret",
                maxTokens: 256,
                reasoningEffort: .low
            ),
            transport: transport
        )
        _ = try await collect(provider.stream(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/chat/completions")
        let sent = try body(request)
        XCTAssertEqual(sent["max_tokens"] as? Int, 256)
        XCTAssertEqual(sent["reasoning_effort"] as? String, "low")
    }

    func testNoReasoningEffortSendsNoParameter() async throws {
        let transport = StubChatTransport(lines: [textChunk("嗯")])
        let provider = OpenAICompatibleChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://example.com/v1")!,
                model: "m",
                apiKey: "k"
            ),
            transport: transport
        )
        _ = try await collect(provider.stream(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        let seen = await transport.seen
        let sent = try body(try XCTUnwrap(seen.first))
        XCTAssertNil(sent["reasoning_effort"])
    }

    func testExtraBodyMergesDeeplyAndLast() async throws {
        let transport = StubChatTransport(lines: [textChunk("嗯")])
        let provider = OpenAICompatibleChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://example.com/v1")!,
                model: "m",
                apiKey: "k",
                extraBody: [
                    "enable_thinking": .bool(false),
                    "thinking": .object(["type": .string("disabled")]),
                ]
            ),
            transport: transport
        )
        _ = try await collect(provider.stream(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        let seen = await transport.seen
        let sent = try body(try XCTUnwrap(seen.first))
        XCTAssertEqual(sent["enable_thinking"] as? Bool, false)
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
    }

    func testNestedExtraObjectsMerge() {
        let body: [String: Any] = [
            "reasoning": ["effort": "low", "summary": "auto"],
            "metadata": ["a": 1],
        ]
        let merged = ChatRequestExtras.merged(
            ["reasoning": .object(["effort": .string("high")])],
            into: body
        )
        let reasoning = try! XCTUnwrap(merged["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertEqual(reasoning["summary"] as? String, "auto")
        XCTAssertEqual((merged["metadata"] as? [String: Any])?["a"] as? Int, 1)
    }

    func testReservedExtraKeysAreRefused() {
        XCTAssertThrowsError(
            try ChatRequestExtras.decode(#"{"model":"other"}"#)
        ) { error in
            XCTAssertEqual(
                error as? ChatRequestExtras.ValidationError,
                .reserved("model")
            )
        }
        XCTAssertThrowsError(try ChatRequestExtras.decode("[1,2]"))
        XCTAssertThrowsError(try ChatRequestExtras.decode("{"))
        XCTAssertNil(try ChatRequestExtras.decode("  "))
    }

    // MARK: Responses

    func testResponsesRequestShape() async throws {
        let transport = StubChatTransport(lines: [
            event(["type": "response.output_text.delta", "delta": "好"]),
            event(["type": "response.completed", "response": [:]])
        ])
        let provider = ResponsesChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "gpt-test",
                apiKey: "secret",
                maxTokens: 128,
                apiProtocol: .responses,
                reasoningEffort: .medium
            ),
            transport: transport
        )
        let events = try await collect(provider.stream(
            messages: [
                .init(.system, "人格"),
                .init(.user, "在吗"),
            ],
            tools: [ChatTool(name: "ping", description: "d", parameters: .object([:]))],
            forbidCalls: false
        ))
        XCTAssertEqual(events, [.text("好")])

        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        let sent = try body(request)
        XCTAssertEqual(sent["store"] as? Bool, false)
        XCTAssertEqual(sent["instructions"] as? String, "人格")
        XCTAssertEqual(sent["max_output_tokens"] as? Int, 128)
        XCTAssertEqual((sent["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(sent["include"] as? [String], ["reasoning.encrypted_content"])
        let input = try XCTUnwrap(sent["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
        let tools = try XCTUnwrap(sent["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "ping")
    }

    func testResponsesStreamsCallsWithReasoning() async throws {
        let reasoningItem: [String: Any] = [
            "type": "reasoning", "id": "rs_1", "encrypted_content": "abc"
        ]
        let transport = StubChatTransport(lines: [
            event(["type": "response.output_item.done", "output_index": 0, "item": reasoningItem]),
            event(["type": "response.output_item.done", "output_index": 1, "item": [
                "type": "function_call", "call_id": "call_9", "name": "recall_story",
                "arguments": "",
            ]]),
            event(["type": "response.function_call_arguments.delta", "output_index": 1, "delta": #"{"query":"甲"}"#]),
        ])
        let provider = ResponsesChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "gpt-test",
                apiKey: "secret",
                apiProtocol: .responses
            ),
            transport: transport
        )
        let events = try await collect(provider.stream(
            messages: [.init(.user, "在吗")], tools: [], forbidCalls: false
        ))
        XCTAssertEqual(events, [
            .reasoning([.object(["type": .string("reasoning"), "id": .string("rs_1"), "encrypted_content": .string("abc")])]),
            .toolCalls([ToolCall(id: "call_9", name: "recall_story", arguments: #"{"query":"甲"}"#)]),
        ])
    }

    func testResponsesSendsReasoningAndToolResultsBack() throws {
        let provider = ResponsesChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.example.com/v1")!,
                model: "m", apiKey: "k", apiProtocol: .responses
            ),
            transport: StubChatTransport(lines: [])
        )
        let request = try provider.request(
            messages: [
                .init(.user, "在吗"),
                .init(.assistant, "", toolCalls: [ToolCall(id: "c1", name: "recall_story", arguments: #"{"query":"甲"}"#)], reasoning: [
                    .object(["type": .string("reasoning"), "encrypted_content": .string("abc")])
                ]),
                .init(.tool, "找到了", toolCallID: "c1"),
            ],
            tools: [],
            forbidCalls: false
        )
        let input = try XCTUnwrap(try body(request)["input"] as? [[String: Any]])
        XCTAssertEqual(input[1]["type"] as? String, "reasoning")
        XCTAssertEqual(input[2]["type"] as? String, "function_call")
        XCTAssertEqual(input[2]["call_id"] as? String, "c1")
        XCTAssertEqual(input[3]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[3]["call_id"] as? String, "c1")
    }

    // MARK: Anthropic

    func testAnthropicRequestShapeAndDefaultCap() async throws {
        let transport = StubChatTransport(lines: [
            event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "嗯"]]),
        ])
        let provider = AnthropicChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "claude-test",
                apiKey: "secret",
                apiProtocol: .anthropic,
                reasoningEffort: .high
            ),
            transport: transport
        )
        let events = try await collect(provider.stream(
            messages: [.init(.system, "人格"), .init(.user, "在吗")],
            tools: [ChatTool(name: "ping", description: "d", parameters: .object([:]))],
            forbidCalls: false
        ))
        XCTAssertEqual(events, [.text("嗯")])

        let seen = await transport.seen
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "secret")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let sent = try body(request)
        XCTAssertEqual(sent["max_tokens"] as? Int, 16384)
        XCTAssertEqual(sent["system"] as? String, "人格")
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
        XCTAssertEqual((sent["output_config"] as? [String: Any])?["effort"] as? String, "high")
        let tools = try XCTUnwrap(sent["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "ping")
        XCTAssertNotNil(tools.first?["input_schema"])
    }

    func testAnthropicThinkingNoneDisablesIt() throws {
        let provider = AnthropicChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "m", apiKey: "k", apiProtocol: .anthropic, reasoningEffort: .some(.none)
            ),
            transport: StubChatTransport(lines: [])
        )
        let sent = try body(provider.request(messages: [.init(.user, "hi")], tools: [], forbidCalls: false))
        XCTAssertEqual((sent["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertNil(sent["output_config"])
    }

    func testAnthropicStreamsThinkingAndCalls() async throws {
        let transport = StubChatTransport(lines: [
            event(["type": "content_block_start", "index": 0, "content_block": [
                "type": "thinking", "thinking": "", "signature": ""
            ]]),
            event(["type": "content_block_delta", "index": 0, "delta": [
                "type": "thinking_delta", "thinking": "想一想"
            ]]),
            event(["type": "content_block_delta", "index": 0, "delta": [
                "type": "signature_delta", "signature": "sig"
            ]]),
            event(["type": "content_block_start", "index": 1, "content_block": [
                "type": "tool_use", "id": "tool_1", "name": "recall_story", "input": [:]
            ]]),
            event(["type": "content_block_delta", "index": 1, "delta": [
                "type": "input_json_delta", "partial_json": #"{"query":"甲"}"#
            ]]),
        ])
        let provider = AnthropicChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "m", apiKey: "k", apiProtocol: .anthropic
            ),
            transport: transport
        )
        let events = try await collect(provider.stream(
            messages: [.init(.user, "hi")], tools: [], forbidCalls: false
        ))
        guard case let .reasoning(reasoning) = events[0] else {
            return XCTFail("expected reasoning first")
        }
        XCTAssertEqual(reasoning.first?.objectValue?["thinking"], .string("想一想"))
        XCTAssertEqual(reasoning.first?.objectValue?["signature"], .string("sig"))
        XCTAssertEqual(events[1], .toolCalls([
            ToolCall(id: "tool_1", name: "recall_story", arguments: #"{"query":"甲"}"#)
        ]))
    }

    func testAnthropicSendsThinkingBlocksAndToolResultsBack() throws {
        let provider = AnthropicChatProvider(
            config: ChatModelConfig(
                baseURL: URL(string: "https://api.anthropic.com/v1")!,
                model: "m", apiKey: "k", apiProtocol: .anthropic
            ),
            transport: StubChatTransport(lines: [])
        )
        let request = try provider.request(messages: [
            .init(.user, "在吗"),
            .init(.assistant, "", toolCalls: [ToolCall(id: "t1", name: "recall_story", arguments: #"{"query":"甲"}"#)], reasoning: [
                .object(["type": .string("thinking"), "thinking": .string("想一想"), "signature": .string("sig")])
            ]),
            .init(.tool, "找到了", toolCallID: "t1"),
        ], tools: [], forbidCalls: false)
        let turns = try XCTUnwrap(try body(request)["messages"] as? [[String: Any]])
        let assistant = try XCTUnwrap(turns[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant[0]["type"] as? String, "thinking")
        XCTAssertEqual(assistant[0]["signature"] as? String, "sig")
        XCTAssertEqual(assistant[1]["type"] as? String, "tool_use")
        let result = try XCTUnwrap(turns[2]["content"] as? [[String: Any]])
        XCTAssertEqual(result[0]["type"] as? String, "tool_result")
        XCTAssertEqual(result[0]["tool_use_id"] as? String, "t1")
    }

    // MARK: Background

    func testBackgroundFallsBackFieldByFieldExceptItsOwnThree() throws {
        let chat = ChatModelConfig(
            baseURL: URL(string: "https://chat.example/v1")!,
            model: "chat-model",
            apiKey: "chat-key",
            maxTokens: 999,
            apiProtocol: .chatCompletions,
            reasoningEffort: .high,
            extraBody: ["a": .bool(true)]
        )
        let background = BackgroundChatConfig(
            apiProtocol: .anthropic,
            model: "cheap-model",
            maxTokens: nil,
            reasoningEffort: nil,
            extraBody: nil
        )
        let resolved = try XCTUnwrap(background.config(inheriting: chat))
        XCTAssertEqual(resolved.apiProtocol, .anthropic)
        XCTAssertEqual(resolved.baseURL, chat.baseURL)
        XCTAssertEqual(resolved.apiKey, "chat-key")
        XCTAssertEqual(resolved.model, "cheap-model")
        XCTAssertNil(resolved.maxTokens, "the cap is the background model's own")
        XCTAssertNil(resolved.reasoningEffort, "the effort is the background model's own")
        XCTAssertNil(resolved.extraBody, "the extra body is the background model's own")
    }

    func testOnlyABackgroundModelKeepsTheChatService() throws {
        let chat = ChatModelConfig(
            baseURL: URL(string: "https://chat.example/v1")!,
            model: "chat-model", apiKey: "chat-key"
        )
        let resolved = try XCTUnwrap(
            BackgroundChatConfig(model: "cheap-model").config(inheriting: chat)
        )
        XCTAssertEqual(resolved.baseURL, chat.baseURL)
        XCTAssertEqual(resolved.apiKey, chat.apiKey)
        XCTAssertEqual(resolved.apiProtocol, chat.apiProtocol)
        XCTAssertEqual(resolved.model, "cheap-model")
    }

    func testABackgroundWithEveryFieldFilledUsesThemAll() throws {
        let chat = ChatModelConfig(
            baseURL: URL(string: "https://chat.example/v1")!,
            model: "chat", apiKey: "chat-key"
        )
        let background = BackgroundChatConfig(
            apiProtocol: .responses,
            baseURL: URL(string: "https://bg.example/v1")!,
            model: "bg", apiKey: "bg-key", maxTokens: 64,
            reasoningEffort: .some(.none), extraBody: ["b": .int(1)]
        )
        let resolved = try XCTUnwrap(background.config(inheriting: chat))
        XCTAssertEqual(resolved.baseURL, background.baseURL)
        XCTAssertEqual(resolved.apiKey, "bg-key")
        XCTAssertEqual(resolved.maxTokens, 64)
        XCTAssertEqual(resolved.reasoningEffort, ReasoningEffort.none)
        XCTAssertEqual(resolved.extraBody, ["b": .int(1)])
    }

    func testBlankBackgroundIsNil() {
        XCTAssertNil(BackgroundChatConfig().config(inheriting: ChatModelConfig(
            baseURL: URL(string: "https://chat.example/v1")!,
            model: "chat", apiKey: "key"
        )))
    }
}
