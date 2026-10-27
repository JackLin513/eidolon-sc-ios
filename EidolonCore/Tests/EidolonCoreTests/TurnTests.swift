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

    /// Upstream's `chat_history`: once the history reaches half as many turns again, it is
    /// cut back to whole turns that many at a time, not one at a time, so what she reads
    /// opens the same way from turn to turn in between.
    func testHistoryFallsBackToWholeTurnsInChunks() async throws {
        let eidolon = try await installedEidolon()
        for turn in 1...7 {
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
            historyTurns: 4
        ) {}
        let prompt = try XCTUnwrap(provider.prompts.first)
        let history = Array(prompt.dropFirst(2).dropLast(2))
        // Four turns would open at 質問4; the chunk keeps the fifth last, 質問3.
        XCTAssertEqual(history.first, PromptMessage(.user, "質問3"))
        XCTAssertEqual(history.count, 10)
    }

    private let moment = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09T08:53:20Z
    private var tokyo: TimeZone { TimeZone(identifier: "Asia/Tokyo")! }

    private func say(
        _ text: String,
        at when: Date,
        on eidolon: Eidolon,
        judge: (any JudgeProvider)? = nil,
        provider: RecordingChatProvider = RecordingChatProvider(
            chunks: ["<ja>うん</ja><zh>嗯</zh>"]
        )
    ) async throws -> RecordingChatProvider {
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: text,
            provider: provider,
            judge: judge,
            now: when,
            timeZone: tokyo
        ) {}
        return provider
    }

    /// She is told of her own hang-up as narration, before what he says next (upstream
    /// `engine._narration`).
    func testHerHangUpIsNarratedBeforeWhatHeSaysNext() async throws {
        let eidolon = try await installedEidolon()
        _ = try await say("おはよう", at: moment, on: eidolon)
        let current = try await eidolon.currentConversationID("mano")
        let conversationID = try XCTUnwrap(current)
        try eidolon.recordConversationEvent(
            conversationID: conversationID,
            kind: "hung_up",
            at: moment.addingTimeInterval(60)
        )

        let provider = try await say("そうなんだ", at: moment.addingTimeInterval(120), on: eidolon)
        XCTAssertEqual(
            provider.prompts.first?.last,
            PromptMessage(.user, "（你挂断了制作人的电话。）そうなんだ")
        )
    }

    /// Her reach-out is narrated as what she said first, with when (upstream
    /// `engine._reached_out`), and is not an assistant turn of the history.
    func testHerReachOutIsNarratedAsWhatSheSaidFirst() async throws {
        let eidolon = try await installedEidolon()
        _ = try await say("おはよう", at: moment, on: eidolon)
        let reach = try await eidolon.reachOutIfDue(
            characterID: "mano",
            provider: RecordingChatProvider(chunks: ["<ja>ねえ</ja><zh>喂</zh>"]),
            hours: 6,
            // In the morning: she does not reach out between 22:00 and 08:00 (upstream
            // `reach_outs`), and by then she is past the six hours since they spoke.
            now: moment.addingTimeInterval(16 * 3600),
            timeZone: tokyo
        )
        XCTAssertNotNil(reach)

        let provider = try await say(
            "そうなんだ",
            at: moment.addingTimeInterval(16 * 3600 + 60),
            on: eidolon
        )
        XCTAssertEqual(
            provider.prompts.first?.last,
            PromptMessage(
                .user,
                "（10月10日 09:53，你先给制作人发了：）<ja>ねえ</ja><zh>喂</zh>そうなんだ"
            )
        )
        XCTAssertFalse(
            provider.prompts.first?.contains(PromptMessage(.assistant, "<ja>ねえ</ja><zh>喂</zh>")) ?? true
        )
    }

    /// "Last time we talked" is across conversations, not only this one: a new conversation
    /// still knows when they last spoke (upstream `read_last_contact`).
    func testLastContactIsAcrossConversations() async throws {
        let eidolon = try await installedEidolon()
        _ = try await say("おはよう", at: moment, on: eidolon)
        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        _ = try await say("ひどい", at: moment.addingTimeInterval(60), on: eidolon, judge: harsh)
        _ = try await say("またひどい", at: moment.addingTimeInterval(120), on: eidolon, judge: harsh)
        let ended = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(ended?.ended, true)
        _ = try await eidolon.startConversation(
            characterID: "mano",
            now: moment.addingTimeInterval(3600)
        )

        let provider = try await say("元気？", at: moment.addingTimeInterval(3600), on: eidolon)
        let system = provider.prompts.first?
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n") ?? ""
        XCTAssertTrue(system.contains("上次和制作人说话是 10月9日 17:55，"), system)
    }

    /// The end of a call that connected counts as the last contact (upstream's `calls`).
    func testTheEndOfACallCountsAsLastContact() async throws {
        let eidolon = try await installedEidolon()
        _ = try await say("おはよう", at: moment, on: eidolon)
        let current = try await eidolon.currentConversationID("mano")
        let conversationID = try XCTUnwrap(current)
        try eidolon.recordCallEnd(
            conversationID: conversationID,
            characterID: "mano",
            at: moment.addingTimeInterval(1800)
        )

        let provider = try await say("元気？", at: moment.addingTimeInterval(3600), on: eidolon)
        let system = provider.prompts.first?
            .filter { $0.role == .system }
            .map(\.content)
            .joined(separator: "\n") ?? ""
        XCTAssertTrue(system.contains("上次和制作人说话是 10月9日 18:23，"), system)
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

    /// A reply stopped before she says anything is not recorded at all: no empty bubble,
    /// and no blank assistant line in the history (upstream raises `EmptyReply` before the
    /// turn is kept).
    func testStoppingBeforeAnythingIsSaidLeavesNoTurn() async throws {
        let eidolon = try await installedEidolon()
        let provider = SilentChatProvider()

        let stream = eidolon.sendTurn(characterID: "mano", text: "やあ", provider: provider)
        let consuming = Task {
            for try await _ in stream {}
        }
        for _ in 0..<100 where !provider.started {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(provider.started, "her stream was asked")
        consuming.cancel()
        _ = try? await consuming.value

        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(snapshot, "the line and the empty reply are both left out")
    }

    /// An answer with nothing she could say reads as upstream's `FAILED`, not as a parse
    /// error of the app's own.
    func testAnEmptyReplyShowsTheUpstreamFailure() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(chunks: [])

        do {
            for try await _ in eidolon.sendTurn(characterID: "mano", text: "やあ", provider: provider) {
                XCTFail("an empty reply is not a turn")
            }
            XCTFail("expected the turn to fail")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .turnFailed)
            XCTAssertEqual(error.localizedDescription, "角色暂时无法回复，请稍后再试。")
        }

        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(snapshot)
    }

    /// A model that fails reads the same: upstream tells the producer `FAILED` and keeps
    /// the details in the server log, as here they stay in the trace.
    func testAModelFailureShowsTheUpstreamFailure() async throws {
        let eidolon = try await installedEidolon()
        let provider = RecordingChatProvider(
            chunks: [],
            failure: ChatProviderError.status(500, "boom")
        )

        do {
            for try await _ in eidolon.sendTurn(characterID: "mano", text: "やあ", provider: provider) {
                XCTFail("a failed model is not a turn")
            }
            XCTFail("expected the turn to fail")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .turnFailed)
            XCTAssertEqual(error.localizedDescription, "角色暂时无法回复，请稍后再试。")
        }

        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(snapshot)
        let trace = try await eidolon.turnTraces().first
        XCTAssertTrue(trace?.trace.error?.contains("对话模型失败") == true)
    }

    /// The 1.3 MB `world.json` is read and parsed once, not on every turn: the next turn
    /// still has the world even after the file on disk was broken.
    func testWorldSettingIsReadOnceAndReused() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.world = .valid
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root, options: options))

        let first = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(characterID: "mano", text: "やあ", provider: first) {}
        XCTAssertTrue(
            first.prompts.first?.map(\.content).joined().contains("# 世界设定") ?? false
        )

        let world = eidolon.location.contentDirectory
            .appendingPathComponent("characters/world.json")
        try Data("{".utf8).write(to: world)

        let second = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(characterID: "mano", text: "元気？", provider: second) {}
        XCTAssertTrue(
            second.prompts.first?.map(\.content).joined().contains("# 世界设定") ?? false,
            "the world was not read again"
        )
    }
}

/// A provider that never answers and says when it was asked: the reply can be stopped
/// before its first segment.
final class SilentChatProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false

    var started: Bool {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        asked = true
        lock.unlock()
        return AsyncThrowingStream { _ in }
    }
}
