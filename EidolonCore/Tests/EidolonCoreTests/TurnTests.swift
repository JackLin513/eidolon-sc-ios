import Foundation
import XCTest
@testable import EidolonCore

/// A chat provider that answers with fixed chunks and remembers the prompts it got.
final class RecordingChatProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PromptMessage]] = []

    let chunks: [String]
    let failure: Error?
    let delay: Duration?

    init(chunks: [String], failure: Error? = nil, delay: Duration? = nil) {
        self.chunks = chunks
        self.failure = failure
        self.delay = delay
    }

    var prompts: [[PromptMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let task = Task {
                if let failure {
                    continuation.finish(throwing: failure)
                    return
                }
                for chunk in chunks {
                    if let delay { try? await Task.sleep(for: delay) }
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class TurnTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonTurn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let bundle = try Fixture.makeBundle(in: root)
        try await eidolon.install(bundleAt: bundle)
        return eidolon
    }

    func testTurnStreamsAndPersists() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(
            chunks: ["<ja>こんにちは</ja>", "<zh>你好</zh>"]
        )

        var deltas: [String] = []
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "やあ",
            provider: provider
        ) {
            switch event {
            case let .delta(_, _, text):
                deltas.append(text)
            case .speechDelta:
                break
            case let .finished(finished):
                record = finished
            }
        }

        XCTAssertEqual(deltas.joined(), "こんにちは你好")
        let finished = try XCTUnwrap(record)
        XCTAssertEqual(finished.segments, [ReplySegment(ja: "こんにちは", zh: "你好")])

        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        let messages = try XCTUnwrap(snapshot?.messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, "user")
        XCTAssertEqual(messages[0].text, "やあ")
        XCTAssertEqual(messages[1].role, "character")
        XCTAssertEqual(messages[1].japanese, "こんにちは")
        XCTAssertEqual(messages[1].chinese, "你好")
    }

    func testSecondTurnCarriesTheSheetAndHistory() async throws {
        let eidolon = try await installedEidolon()
        let first = RecordingChatProvider(chunks: ["<ja>おはよう</ja><zh>早上好</zh>"])
        for try await _ in eidolon.sendTurn(characterID: "mano", text: "やあ", provider: first) {}

        let second = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(characterID: "mano", text: "元気？", provider: second) {}

        let prompt = try XCTUnwrap(second.prompts.first)
        XCTAssertEqual(prompt.first?.role, .system)
        XCTAssertTrue(prompt.first?.content.contains("# 真乃") ?? false)
        XCTAssertEqual(prompt[1].role, .system)
        XCTAssertEqual(prompt[1].content, ProducerProfile.default.prompt)
        XCTAssertEqual(prompt.suffix(2), [
            PromptMessage(.system, prompt[prompt.count - 2].content),
            PromptMessage(.user, "元気？"),
        ])
        XCTAssertTrue(prompt[prompt.count - 2].content.hasPrefix("# 此刻"))
        XCTAssertEqual(
            Array(prompt.suffix(4)).dropFirst(1),
            [
                PromptMessage(.assistant, "<ja>おはよう</ja><zh>早上好</zh>"),
                PromptMessage(.system, prompt[prompt.count - 2].content),
                PromptMessage(.user, "元気？"),
            ]
        )
    }

    func testACallTurnAsksHerToAnswerOnThePhone() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>もしもし</ja><zh>喂</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "もしもし",
            provider: provider,
            talking: .inCall,
            voicedBy: "s2.1-pro-free"
        ) {}

        let prompt = try XCTUnwrap(provider.prompts.first)
        let all = prompt.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        XCTAssertTrue(all.contains("制作人正在和你打电话"))
        XCTAssertFalse(all.contains("制作人正在用文字和你聊天"))
        XCTAssertTrue(try XCTUnwrap(prompt.first).content.hasSuffix(ReplyFormatInstructions.text))
    }

    func testADirectedVoiceModelGetsDirectedInstructions() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>もしもし</ja><zh>喂</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "もしもし",
            provider: provider,
            talking: .inCall,
            voicedBy: "drama-3"
        ) {}

        let shared = try XCTUnwrap(try XCTUnwrap(provider.prompts.first).first).content
        XCTAssertTrue(shared.hasSuffix(ReplyFormatInstructions.directed))
    }

    func testTheLastMessageIsWhatTheProducerSaid() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "今日は何してた？",
            provider: provider
        ) {}

        let prompt = try XCTUnwrap(provider.prompts.first)
        XCTAssertEqual(prompt.last, PromptMessage(.user, "今日は何してた？"))
        XCTAssertTrue(prompt[0].content.hasPrefix("# 真乃"))
    }

    func testFailureLeavesNoTurn() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(
            chunks: [],
            failure: ChatProviderError.status(500, "boom")
        )

        do {
            for try await _ in eidolon.sendTurn(characterID: "mano", text: "やあ", provider: provider) {
                XCTFail("a failing provider should not yield events")
            }
            XCTFail("expected the turn to fail")
        } catch {}

        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(snapshot)
    }

    /// A line of nothing but whitespace is refused before the model is asked, as
    /// upstream's `engine.turn` does.
    func testABlankLineIsRejected() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])

        do {
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "  \n\t ",
                provider: provider
            ) {
                XCTFail("a blank line is not answered")
            }
            XCTFail("expected the turn to be rejected")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .blankInput)
            XCTAssertEqual(error.localizedDescription, "没有收到要说的话。")
        }

        XCTAssertTrue(provider.prompts.isEmpty, "the model is not asked")
        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(snapshot)
    }

    /// More than 2000 characters is refused with the limit, as upstream's
    /// `MAX_INPUT_LENGTH` does, and nothing is written or sent.
    func testALineOverTheLimitIsRejectedWithTheLimit() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        let tooLong = String(repeating: "あ", count: 2001)

        do {
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: tooLong,
                provider: provider
            ) {
                XCTFail("an over-long line is not answered")
            }
            XCTFail("expected the turn to be rejected")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .inputTooLong(2000))
            XCTAssertEqual(error.localizedDescription, "这句话太长了，最多 2000 字。")
        }

        XCTAssertTrue(provider.prompts.isEmpty, "the model is not asked")
        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(snapshot)
    }

    /// Exactly the limit is allowed.
    func testALineOfExactlyTheLimitIsAccepted() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        let atLimit = String(repeating: "あ", count: 2000)

        var finished = false
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: atLimit,
            provider: provider
        ) {
            if case .finished = event { finished = true }
        }
        XCTAssertTrue(finished)
        XCTAssertEqual(provider.prompts.count, 1)
    }

    /// The history the settings name: what she is told of the turns before this one.
    func testHistoryTurnsLimitWhatSheIsTold() async throws {
        let eidolon = try await installedEidolon()
        for turn in 1...3 {
            let earlier = RecordingChatProvider(
                chunks: ["<ja>返事\(turn)</ja><zh>回复\(turn)</zh>"]
            )
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "質問\(turn)",
                provider: earlier
            ) {}
        }

        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "もう一つ",
            provider: provider,
            historyTurns: 1
        ) {}
        let prompt = try XCTUnwrap(provider.prompts.first)
        let history = Array(prompt.dropFirst(2).dropLast(2))
        XCTAssertEqual(history, [
            PromptMessage(.user, "質問3"),
            PromptMessage(.assistant, "<ja>返事3</ja><zh>回复3</zh>"),
        ])
    }

    func testStoppingKeepsWhatSheAlreadySaid() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(
            chunks: [
                "<ja>こんにちは</ja><zh>你好</zh>",
                "<ja>まだ話して</ja><zh>还在说</zh>",
            ],
            delay: .milliseconds(300)
        )

        var sawDelta = false
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "やあ",
            provider: provider
        ) {
            if case .delta = event {
                sawDelta = true
                break // the next message stops this reply
            }
        }
        XCTAssertTrue(sawDelta)

        var snapshot: ConversationSnapshot?
        for _ in 0..<40 where snapshot == nil {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = try await eidolon.currentConversation(characterID: "mano")
        }
        let messages = try XCTUnwrap(snapshot?.messages)
        XCTAssertEqual(messages.count, 2)
        XCTAssertFalse(messages[1].segments.isEmpty)
    }
}
