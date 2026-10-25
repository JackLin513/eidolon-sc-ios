import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// A provider that answers extraction, naming and turns apart, and remembers its prompts.
final class KindChatProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PromptMessage]] = []

    var chat = "<ja>ねえ、聞いて</ja><zh>喂，听我说</zh>"
    var memory: String?
    var title: String?
    var failure: Error?

    var prompts: [[PromptMessage]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        lock.unlock()
        let system = messages.first?.content ?? ""
        let answer: String?
        if system.contains("你负责替") {
            answer = memory
        } else if system.contains("你负责给") {
            answer = title
        } else {
            answer = chat
        }
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            good: do {
                guard let answer else { break good }
                continuation.yield(answer)
            }
            continuation.finish()
        }
    }
}

final class ReachOutTests: XCTestCase {
    private var root: URL!
    private let start = Date(timeIntervalSince1970: 1_760_000_000) // 2025-10-09T08:53:20Z

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonReachOut-\(UUID().uuidString)", isDirectory: true)
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

    @discardableResult
    private func say(_ text: String, at when: Date, on eidolon: Eidolon) async throws -> TurnRecord {
        let provider = KindChatProvider()
        provider.chat = "<ja>うん</ja><zh>嗯</zh>"
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: text,
            provider: provider,
            now: when,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        await eidolon.settleTitles()
        return try XCTUnwrap(record)
    }

    private func reachOut(
        at when: Date,
        on eidolon: Eidolon,
        provider: KindChatProvider = KindChatProvider()
    ) async throws -> ReachOutRecord? {
        try await eidolon.reachOutIfDue(
            characterID: "mano",
            provider: provider,
            hours: 6,
            now: when,
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
    }

    func testNothingIsSaidBeforeTheThreshold() async throws {
        let eidolon = try await installedEidolon()
        try await say("おはよう", at: start, on: eidolon)

        let r1 = try await reachOut(at: start.addingTimeInterval(6 * 3600 - 1), on: eidolon)
        XCTAssertNil(r1)
        let due = start.addingTimeInterval(6 * 3600 + 1)
        let reached = try await reachOut(at: due, on: eidolon)
        let record = try XCTUnwrap(reached)
        XCTAssertFalse(record.seen)
        XCTAssertEqual(record.segments.first?.zh, "喂，听我说")
    }

    func testTheThresholdIsNotCrossedAtExactly() async throws {
        let eidolon = try await installedEidolon()
        try await say("おはよう", at: start, on: eidolon)
        let r2 = try await reachOut(at: start.addingTimeInterval(6 * 3600), on: eidolon)
        XCTAssertNil(r2)
    }

    func testSheReachesOutOnlyOncePerStretchOfAbsence() async throws {
        let eidolon = try await installedEidolon()
        try await say("おはよう", at: start, on: eidolon)
        let r3 = try await reachOut(at: start.addingTimeInterval(7 * 3600), on: eidolon)
        XCTAssertNotNil(r3)
        let r4 = try await reachOut(at: start.addingTimeInterval(9 * 3600), on: eidolon)
        XCTAssertNil(r4)

        // Saying something starts a new stretch of absence.
        try await say("ただいま", at: start.addingTimeInterval(10 * 3600), on: eidolon)
        let r5 = try await reachOut(at: start.addingTimeInterval(13 * 3600), on: eidolon)
        XCTAssertNil(r5)
        let r6 = try await reachOut(at: start.addingTimeInterval(17 * 3600), on: eidolon)
        XCTAssertNotNil(r6)
    }

    func testAnEndedConversationIsNotReachedOutIn() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        for turn in 0..<2 {
            let provider = KindChatProvider()
            provider.chat = "<ja>もういい</ja><zh>够了</zh>"
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "ひどいことを言う",
                provider: provider,
                judge: judge,
                now: start.addingTimeInterval(Double(turn) * 60),
                timeZone: TimeZone(identifier: "Asia/Tokyo")!
            ) {}
        }
        await eidolon.settleTitles()
        let current = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(current?.ended, true)
        let r7 = try await reachOut(at: start.addingTimeInterval(10 * 3600), on: eidolon)
        XCTAssertNil(r7)
    }

    func testTheReachOutReadsAsHersAndIsUnseenUntilOpened() async throws {
        let eidolon = try await installedEidolon()
        try await say("またね", at: start, on: eidolon)
        let provider = KindChatProvider()
        let due = start.addingTimeInterval(8 * 3600)
        _ = try await reachOut(at: due, on: eidolon, provider: provider)

        let prompt = try XCTUnwrap(provider.prompts.last)
        let system = prompt.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
        XCTAssertTrue(system.contains("# 此刻"))
        XCTAssertTrue(system.contains("你们这会儿没在说话"))
        XCTAssertTrue(system.contains("# 先开口"))
        XCTAssertTrue(system.contains("其次是你这周的工作（如果有）"))
        XCTAssertTrue(system.contains("已经过去的只当回忆说，先对照现在的年份"))
        XCTAssertEqual(prompt.last, PromptMessage(.user, ReachOutRules.wantsToReachOut))

        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        XCTAssertEqual(conversation.messages.map(\.role), ["user", "character", "character"])
        XCTAssertTrue(conversation.messages.last?.text == nil)
        XCTAssertEqual(conversation.messages.last?.chinese, "喂，听我说")

        let unseen = try await eidolon.latestActivities()["mano"]?.unseenReachOut
        XCTAssertEqual(unseen, true)
        try await eidolon.markReachOutsSeen(conversationID: conversation.id)
        let seen = try await eidolon.latestActivities()["mano"]?.unseenReachOut
        XCTAssertEqual(seen, false)
    }

    func testTheReachOutRulesAreUpstreamsWordForWord() {
        // Upstream backend/src/eidolon/engine.py REACH_OUT_RULES.
        let upstream = """
            # 先开口
            制作人这会儿没在和你说话，你想先给他发几句。
            - 由头你自己挑：先接着你们最近聊过的事，或者他最近的近况；其次是你这周的工作（如果有）；再其次才是现在的时间、他的生日。
            - 不要只发一句空的问候，比如「早安」「在吗」「想你了」，要有具体想说的事。
            - 写一到两段。
            - 别和你前几次先开口时用一样的开头、一样的由头。
            - 说到你自己那边：日程里有的就说日程里的；没有的话只说练习、拍摄、事务所的工作这类平常的事，或者世界设定里快到的 live 和新歌，已经过去的只当回忆说，先对照现在的年份；不要编具体的剧情，也不要说别的偶像做了什么。
            - 不发照片，也不说要给他发照片、要给他打电话。
            - 让他好接话，但不必用问句结尾。
            """
        XCTAssertEqual(ReachOutRules.rules, upstream)
    }

    func testTheThirdTurnNamesTheConversationOnce() async throws {
        let eidolon = try await installedEidolon()
        try await say("猫を飼ってるんだ", at: start, on: eidolon)
        try await say("名前は小白", at: start.addingTimeInterval(60), on: eidolon)
        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        var title = try await eidolon.title(conversationID: conversation.id)
        XCTAssertNil(title)

        let provider = KindChatProvider()
        provider.title = "猫の話と名前"
        // The naming provider is the one the third turn began with: hand it to sendTurn.
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "三匹目もいるんだ",
            provider: provider,
            now: start.addingTimeInterval(120),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        await eidolon.settleTitles()
        _ = record

        title = try await eidolon.title(conversationID: conversation.id)
        XCTAssertEqual(title, "猫の話と名前")

        let naming = try XCTUnwrap(provider.prompts.first { $0.first?.content.contains("你负责给") == true })
        let body = naming.last?.content ?? ""
        XCTAssertTrue(body.contains("制作人：猫を飼ってるんだ"))
        XCTAssertTrue(body.contains("制作人：三匹目もいるんだ"))
        XCTAssertFalse(body.contains("四"))

        // A later turn leaves it as it is.
        provider.title = "别のタイトル"
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "もう一匹増えた",
            provider: provider,
            now: start.addingTimeInterval(180),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        ) {}
        await eidolon.settleTitles()
        title = try await eidolon.title(conversationID: conversation.id)
        XCTAssertEqual(title, "猫の話と名前")
    }

    func testTitleFromCutsWhatTheModelWrites() {
        XCTAssertEqual(ConversationTitles.title(from: "标题：猫の話"), "猫の話")
        XCTAssertEqual(ConversationTitles.title(from: "「猫と試験」\n其余的话"), "猫と試験")
        XCTAssertEqual(ConversationTitles.title(from: "  \n  新しい部屋  \n"), "新しい部屋")
        XCTAssertEqual(ConversationTitles.title(from: "。"), nil)
        XCTAssertEqual(ConversationTitles.title(from: String(repeating: "あ", count: 30))?.count, 16)
        XCTAssertEqual(ConversationTitles.title(from: "引っ越しの話。"), "引っ越しの話")
    }
}
