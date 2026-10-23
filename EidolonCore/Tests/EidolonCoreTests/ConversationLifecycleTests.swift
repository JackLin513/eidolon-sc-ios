import Foundation
import GRDB
import XCTest
@testable import EidolonCore

final class ConversationLifecycleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonLifecycle-\(UUID().uuidString)", isDirectory: true)
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

    private func reply(_ text: String = "うん") -> RecordingChatProvider {
        RecordingChatProvider(chunks: ["<ja>\(text)</ja><zh>嗯</zh>"])
    }

    private func say(
        _ text: String,
        to characterID: String = "mano",
        provider: any ChatProvider,
        judge: (any JudgeProvider)? = nil,
        on eidolon: Eidolon
    ) async throws -> TurnRecord? {
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: characterID,
            text: text,
            provider: provider,
            judge: judge
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        await eidolon.settleTitles()
        await eidolon.settleMemories()
        return record
    }

    private func endConversation(on eidolon: Eidolon, characterID: String = "mano") async throws {
        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        try await say("ひどいことを言う", to: characterID, provider: reply(), judge: harsh, on: eidolon)
        try await say("もう一度ひどいことを言う", to: characterID, provider: reply(), judge: harsh, on: eidolon)
    }

    func testAnEndedConversationRefusesTurnsUntilANewOneStarts() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let beforeEnd = try await eidolon.currentConversation(characterID: "mano")
        let ended = try XCTUnwrap(beforeEnd)
        try await endConversation(on: eidolon)

        do {
            _ = try await say("ねえ", provider: reply(), on: eidolon)
            XCTFail("an ended conversation should refuse turns")
        } catch let error as EidolonError {
            guard case .conversationEnded = error else {
                return XCTFail("expected conversationEnded, got \(error)")
            }
        }

        let fresh = try await eidolon.startConversation(characterID: "mano")
        let old = try await eidolon.startConversation(characterID: "mano")
        XCTAssertEqual(fresh, old, "while the new one is open, starting does nothing")

        try await say("はじめまして", provider: reply(), on: eidolon)
        let summaries = try await eidolon.conversations(characterID: "mano")
        XCTAssertEqual(summaries.count, 2)
        XCTAssertEqual(summaries[0].id, fresh)
        XCTAssertTrue(summaries[0].isCurrent)
        XCTAssertFalse(summaries[0].ended)
        XCTAssertEqual(summaries[1].id, ended.id)
        XCTAssertTrue(summaries[1].ended)
        XCTAssertFalse(summaries[1].isCurrent)
        XCTAssertEqual(summaries[1].lastPreview, "嗯")
    }

    func testAnEmptyConversationIsNotHistory() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations(id, character_id, created_at)
                    VALUES ('empty', 'mano', '2020-01-01T00:00:00Z')
                    """
            )
        }
        let summaries = try await eidolon.conversations(characterID: "mano")
        XCTAssertEqual(summaries.count, 1)
        XCTAssertFalse(summaries.contains { $0.id == "empty" })
    }

    func testDeletingAPastConversationKeepsHerMemories() async throws {
        let eidolon = try await installedEidolon()
        let remember = MemoryChatProvider(
            memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#
        )
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "猫を飼ってるんだ",
            provider: remember,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}
        await eidolon.settleMemories()
        try await say("またね", provider: reply(), judge: FixedJudge(judged: Judged(level: 3)), on: eidolon)
        try await endConversation(on: eidolon)
        let tierBefore = try await eidolon.affinityStatus(characterID: "mano").tier

        let past = try await eidolon.startConversation(characterID: "mano")
        let summaries = try await eidolon.conversations(characterID: "mano")
        let ended = try XCTUnwrap(summaries.first { $0.ended })
        XCTAssertNotEqual(ended.id, past)

        do {
            try await eidolon.deleteConversation(id: past)
            XCTFail("the current conversation should not be deleted")
        } catch let error as EidolonError {
            guard case .conversationIsCurrent = error else {
                return XCTFail("expected conversationIsCurrent, got \(error)")
            }
        }

        try await eidolon.deleteConversation(id: ended.id)
        let after = try await eidolon.conversations(characterID: "mano")
        XCTAssertEqual(after.map(\.id), [past])
        let gone = try await eidolon.conversation(id: ended.id)
        XCTAssertNil(gone)

        let memories = try await eidolon.memories()
        XCTAssertEqual(memories.map(\.text), ["制作人养了一只猫"])
        let source: String? = try await eidolon.userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT conversation_id FROM memories")
        }
        XCTAssertNil(source)
        let tierAfter = try await eidolon.affinityStatus(characterID: "mano").tier
        XCTAssertEqual(tierAfter, tierBefore)
        let jobs = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_jobs") ?? 0
        }
        XCTAssertEqual(jobs, 0)
    }

    func testDeletingOneConversationLeavesOthersAlone() async throws {
        let eidolon = try await installedEidolon()
        try await say("やあ", to: "mano", provider: reply(), on: eidolon)
        try await say("やあ", to: "hiori", provider: reply(), on: eidolon)
        try await endConversation(on: eidolon, characterID: "mano")
        let past = try await eidolon.startConversation(characterID: "mano")
        let manoConversations = try await eidolon.conversations(characterID: "mano")
        let ended = try XCTUnwrap(manoConversations.first { $0.ended })
        try await eidolon.deleteConversation(id: ended.id)

        let hiori = try await eidolon.currentConversation(characterID: "hiori")
        XCTAssertEqual(hiori?.messages.count, 2)
        let mano = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(mano?.id, past)
    }

    func testTheProfileReachesTheNextPrompt() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.updateProducerProfile(
            ProducerProfile(
                formOfAddress: "先輩",
                gender: .female,
                timezone: "America/New_York",
                birthdayMonth: 2,
                birthdayDay: 29
            )
        )
        let provider = reply()
        try await say("やあ", provider: provider, on: eidolon)

        let prompt = (try XCTUnwrap(provider.prompts.first)).map(\.content).joined(separator: "\n")
        XCTAssertTrue(prompt.contains("制作人希望你称呼对方为「先輩」"))
        XCTAssertTrue(prompt.contains("制作人是女性"))
        XCTAssertTrue(prompt.contains("制作人的生日是2月29日"))
        XCTAssertTrue(prompt.contains("America/New_York"), "the days go by the profile's time zone")

        try await eidolon.updateProducerProfile(ProducerProfile())
        let second = reply()
        try await say("元気？", provider: second, on: eidolon)
        let cleared = (try XCTUnwrap(second.prompts.first)).map(\.content).joined(separator: "\n")
        XCTAssertFalse(cleared.contains("先輩"))
        XCTAssertTrue(cleared.contains("制作人是男性，和原作一致。"))
    }

    func testSummariesCarryTheTitleOnceNamed() async throws {
        let eidolon = try await installedEidolon()
        let provider = KindChatProvider()
        provider.chat = "<ja>うん</ja><zh>嗯</zh>"
        provider.title = "猫の話"
        for turn in 0..<3 {
            try await say("猫の話その\(turn)", provider: provider, on: eidolon)
        }
        let summaries = try await eidolon.conversations(characterID: "mano")
        XCTAssertEqual(summaries.first?.title, "猫の話")
        XCTAssertEqual(summaries.first?.records, 6)
        XCTAssertEqual(summaries.first?.lastPreview, "嗯")
    }
}
