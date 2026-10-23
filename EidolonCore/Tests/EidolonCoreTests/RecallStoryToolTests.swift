import Foundation
import XCTest
@testable import EidolonCore

/// A chat provider that can be offered tools, answering from a script and remembering
/// what each round got.
final class ToolRecordingProvider: ToolChatProvider, @unchecked Sendable {
    struct Round {
        var messages: [PromptMessage]
        var tools: [ChatTool]
        var forbidCalls: Bool
    }

    private let lock = NSLock()
    private var recorded: [Round] = []
    private let script: [[ChatStreamEvent]]

    init(script: [[ChatStreamEvent]]) {
        self.script = script
    }

    var rounds: [Round] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        let events = stream(messages: messages, tools: [], forbidCalls: false)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in events {
                        if case let .text(text) = event { continuation.yield(text) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stream(
        messages: [PromptMessage],
        tools: [ChatTool],
        forbidCalls: Bool
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        lock.lock()
        let index = recorded.count
        recorded.append(Round(messages: messages, tools: tools, forbidCalls: forbidCalls))
        lock.unlock()

        let events = index < script.count ? script[index] : []
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

final class RecallStoryToolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonRecallTool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    func testTheToolIsLookedUpAndAnsweredInASecondRound() async throws {
        let eidolon = try await installedEidolon()
        let provider = ToolRecordingProvider(script: [
            [.toolCalls([
                ToolCall(id: "call_1", name: RecallStoryTool.name, arguments: #"{"query": "写真集"}"#),
            ])],
            [.text("<ja>そういえば</ja><zh>说起来</zh>")],
        ])
        let embedding = FakeEmbedding(vector: [1, 0, 0, 0])

        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "あの写真集のとき、どうだったっけ？",
            provider: provider,
            embedder: embedding,
            reranker: FakeRerank(scores: [0.9, 0, 0])
        ) {
            if case let .finished(finished) = event { record = finished }
        }

        let rounds = provider.rounds
        XCTAssertEqual(rounds.count, 2)
        XCTAssertEqual(rounds[0].tools.map(\.name), [RecallStoryTool.name])
        XCTAssertFalse(rounds[0].forbidCalls)
        XCTAssertTrue(rounds[1].forbidCalls)

        let followUp = rounds[1].messages
        let assistant = try XCTUnwrap(followUp.dropLast().last)
        XCTAssertEqual(assistant.role, .assistant)
        XCTAssertEqual(assistant.toolCalls.map(\.id), ["call_1"])
        let result = try XCTUnwrap(followUp.last)
        XCTAssertEqual(result.role, .tool)
        XCTAssertEqual(result.toolCallID, "call_1")
        XCTAssertTrue(result.content.hasPrefix("# 回顾剧情：写真集"))
        XCTAssertTrue(result.content.contains("ほわっ（呼哇）"))
        XCTAssertTrue(result.content.hasSuffix(RecallStoryTool.lastRoundNote))

        XCTAssertEqual(record?.segments, [ReplySegment(ja: "そういえば", zh: "说起来")])
    }

    func testTheToolIsForbiddenOnceTheJudgeRecalled() async throws {
        let eidolon = try await installedEidolon()
        let provider = ToolRecordingProvider(script: [
            [
                .text("<ja>そうだね</ja><zh>是啊</zh>"),
                .toolCalls([ToolCall(id: "call_1", name: RecallStoryTool.name, arguments: #"{"query": "写真集"}"#)]),
            ],
        ])

        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "あの写真集のとき、どうだったっけ？",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .recall),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9, 0, 0])
        ) {
            if case let .finished(finished) = event { record = finished }
        }

        let rounds = provider.rounds
        XCTAssertEqual(rounds.count, 1)
        XCTAssertTrue(rounds[0].forbidCalls)
        XCTAssertEqual(record?.segments, [ReplySegment(ja: "そうだね", zh: "是啊")])
    }

    func testACallToAnUnknownToolIsAnswered() async throws {
        let eidolon = try await installedEidolon()
        let provider = ToolRecordingProvider(script: [
            [.toolCalls([ToolCall(id: "call_9", name: "send_money", arguments: "{}")])],
            [.text("<ja>えっと</ja><zh>那个</zh>")],
        ])

        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "やあ",
            provider: provider,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0])
        ) {}

        let result = try XCTUnwrap(provider.rounds.last?.messages.last)
        XCTAssertEqual(result.role, .tool)
        XCTAssertTrue(result.content.hasPrefix("没有 send_money 这个工具。"))
    }

    func testTheStreamedToolCallIsAssembled() throws {
        let pieces = [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"recall_story","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\": "}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"写真集\"}"}}]}}]}"#,
        ]
        var assembly = ToolCallAssembly()
        for piece in pieces {
            let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(piece.utf8))
            for call in chunk.choices?.first?.delta?.toolCalls ?? [] {
                assembly.add(call)
            }
        }
        XCTAssertEqual(
            assembly.done,
            [ToolCall(id: "call_1", name: "recall_story", arguments: #"{"query": "写真集"}"#)]
        )
        XCTAssertEqual(assembly.done.first?.query, "写真集")
    }
}
