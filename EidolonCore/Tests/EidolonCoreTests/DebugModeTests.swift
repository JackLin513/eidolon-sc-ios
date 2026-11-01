import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// The in-app debug mode's core operations (spec #62): they deliberately cross rules the
/// normal paths enforce, and leave no story behind.
final class DebugModeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonDebug-\(UUID().uuidString)", isDirectory: true)
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
        embedder: (any EmbeddingProvider)? = nil,
        reranker: (any RerankProvider)? = nil,
        on eidolon: Eidolon
    ) async throws -> TurnRecord? {
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: characterID,
            text: text,
            provider: provider,
            judge: judge,
            embedder: embedder,
            reranker: reranker
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

    // MARK: - Affinity

    func testDebugSettingAffinityWritesTheValueAndClearsTheDaysGain() async throws {
        let eidolon = try await installedEidolon()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await eidolon.debugSetAffinity(characterID: "mano", value: 87, now: now)

        let affinity = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(affinity.value, 87, accuracy: 0.001)
        XCTAssertEqual(affinity.tier, .intimate)
        XCTAssertFalse(affinity.cooling)

        let saved = try await eidolon.userQueue.read { db -> (updatedAt: String?, gainedToday: Double?, gainedOn: String?) in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT updated_at, gained_today, gained_on
                    FROM affinities WHERE character_id = 'mano'
                    """
            )
            return (row?["updated_at"], row?["gained_today"], row?["gained_on"])
        }
        XCTAssertEqual(saved.updatedAt, Eidolon.timestamp(now))
        XCTAssertEqual(saved.gainedToday ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(saved.gainedOn)
    }

    func testDebugAffinityClampsAndDerivesTheCooldownFromTheValue() async throws {
        let eidolon = try await installedEidolon()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try await eidolon.debugSetAffinity(characterID: "mano", value: 120, now: now)
        let highest = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(highest.value, 100, accuracy: 0.001)
        XCTAssertEqual(highest.tier, .intimate)

        try await eidolon.debugSetAffinity(characterID: "mano", value: -12, now: now)
        let lowest = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(lowest.value, 0, accuracy: 0.001)
        XCTAssertEqual(lowest.tier, .cold)
        XCTAssertTrue(lowest.cooling)
        let until = try XCTUnwrap(lowest.cooldownUntil)
        XCTAssertEqual(until.timeIntervalSince(now), 86_400, accuracy: 1)

        try await eidolon.debugSetAffinity(characterID: "mano", value: 50, now: now)
        let normal = try await eidolon.debugAffinity(characterID: "mano", now: now)
        XCTAssertEqual(normal.value, 50, accuracy: 0.001)
        XCTAssertEqual(normal.tier, .trust)
        XCTAssertFalse(normal.cooling)
        XCTAssertNil(normal.cooldownUntil)
    }

    // MARK: - Memories

    func testDebugMemoriesListsOnlyThatConversationsWritesNewestFirst() async throws {
        let eidolon = try await installedEidolon()
        let embedder = FakeEmbedding(vector: [1, 0, 0, 0])
        let reranker = FakeRerank(scores: [0.9])
        try await say(
            "猫を飼ってるんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#),
            embedder: embedder,
            reranker: reranker,
            on: eidolon
        )
        let firstSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let first = try XCTUnwrap(firstSnapshot)
        try await say(
            "コーヒーも好きなんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人喜欢咖啡"}]}"#),
            embedder: embedder,
            reranker: reranker,
            on: eidolon
        )
        let secondID = try await eidolon.beginNewConversation(characterID: "mano")
        try await say(
            "引っ越したんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人搬到了东京"}]}"#),
            embedder: embedder,
            reranker: reranker,
            on: eidolon
        )

        let firstMemories = try await eidolon.debugMemories(conversationID: first.id)
        XCTAssertEqual(firstMemories.map(\.text), ["制作人喜欢咖啡", "制作人养了一只猫"])
        let secondMemories = try await eidolon.debugMemories(conversationID: secondID)
        XCTAssertEqual(secondMemories.map(\.text), ["制作人搬到了东京"])
        XCTAssertEqual(firstMemories.first?.sourceCharacterID, "mano")
        XCTAssertTrue(firstMemories.allSatisfy(\.holds))

        let empty = try await eidolon.debugMemories(conversationID: "no-such-conversation")
        XCTAssertTrue(empty.isEmpty)
    }

    func testDebugDeleteMemoriesRemovesOnlyTheChosenOnes() async throws {
        let eidolon = try await installedEidolon()
        let embedder = FakeEmbedding(vector: [1, 0, 0, 0])
        let reranker = FakeRerank(scores: [0.9])
        try await say(
            "猫を飼ってるんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#),
            embedder: embedder,
            reranker: reranker,
            on: eidolon
        )
        try await say(
            "コーヒーも好きなんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人喜欢咖啡"}]}"#),
            embedder: embedder,
            reranker: reranker,
            on: eidolon
        )
        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(snapshot)
        let memories = try await eidolon.debugMemories(conversationID: conversation.id)
        let cat = try XCTUnwrap(memories.first { $0.text == "制作人养了一只猫" })
        let coffee = try XCTUnwrap(memories.first { $0.text == "制作人喜欢咖啡" })

        let deleted = try await eidolon.debugDeleteMemories(ids: [cat.id])
        XCTAssertEqual(deleted, 1)

        let left = try await eidolon.memories()
        XCTAssertEqual(left.map(\.text), ["制作人喜欢咖啡"])
        XCTAssertEqual(left.first?.id, coffee.id)
        let vectors = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vectors") ?? 0
        }
        XCTAssertEqual(vectors, 1)

        let unknown = try await eidolon.debugDeleteMemories(ids: ["no-such-memory"])
        XCTAssertEqual(unknown, 0)
        let stillLeft = try await eidolon.memories()
        XCTAssertEqual(stillLeft.map(\.text), ["制作人喜欢咖啡"])
    }

    // MARK: - Conversations

    func testDebugReopenMakesAnEndedConversationWritableAgain() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        try await endConversation(on: eidolon)

        let endedSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let ended = try XCTUnwrap(endedSnapshot)
        XCTAssertTrue(ended.ended)
        let before = try await eidolon.conversationRecord(conversationID: ended.id)
        XCTAssertTrue(before.contains { line in
            if case let .event(event) = line { return event.kind == "ended" }
            return false
        })
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(conversation_id, kind, created_at)
                    VALUES (?, 'hung_up', '2030-01-01T00:00:00.000000Z')
                    """,
                arguments: [ended.id]
            )
        }

        let didReopen = try await eidolon.debugReopenConversation(id: ended.id)
        XCTAssertTrue(didReopen)

        let reopenedSnapshot = try await eidolon.conversation(id: ended.id)
        let reopened = try XCTUnwrap(reopenedSnapshot)
        XCTAssertFalse(reopened.ended)
        let after = try await eidolon.conversationRecord(conversationID: ended.id)
        XCTAssertFalse(after.contains { line in
            if case let .event(event) = line { return event.kind == "ended" }
            return false
        })
        XCTAssertTrue(after.contains { line in
            if case let .event(event) = line { return event.kind == "hung_up" }
            return false
        })

        try await say("ただいま", provider: reply(), on: eidolon)
        let writtenSnapshot = try await eidolon.conversation(id: ended.id)
        let written = try XCTUnwrap(writtenSnapshot)
        XCTAssertEqual(written.messages.count, ended.messages.count + 2)
        let current = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(current?.id, ended.id)
    }

    func testDebugSetCurrentMovesThePointerAndKeepsTheOtherConversation() async throws {
        let eidolon = try await installedEidolon()
        try await say("最初の話", provider: reply(), on: eidolon)
        let firstSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let first = try XCTUnwrap(firstSnapshot)
        let secondID = try await eidolon.beginNewConversation(characterID: "mano")
        try await say("二番目の話", provider: reply(), on: eidolon)

        let moved = try await eidolon.debugSetCurrentConversation(characterID: "mano", id: first.id)
        XCTAssertTrue(moved)

        let currentSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let current = try XCTUnwrap(currentSnapshot)
        XCTAssertEqual(current.id, first.id)
        let summaries = try await eidolon.conversations(characterID: "mano")
        XCTAssertEqual(summaries.first?.id, first.id)
        XCTAssertTrue(summaries.first?.isCurrent == true)
        XCTAssertEqual(summaries.first { $0.id == secondID }?.isCurrent, false)
        let secondSnapshot = try await eidolon.conversation(id: secondID)
        XCTAssertEqual(secondSnapshot?.messages.count, 2)
        XCTAssertFalse(secondSnapshot?.ended == true)

        try await say("続き", provider: reply(), on: eidolon)
        let firstAfter = try await eidolon.conversation(id: first.id)
        XCTAssertEqual(firstAfter?.messages.count, 4)
        let secondAfter = try await eidolon.conversation(id: secondID)
        XCTAssertEqual(secondAfter?.messages.count, 2)

        let reopened = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let reopenedCurrent = try await reopened.currentConversation(characterID: "mano")
        XCTAssertEqual(reopenedCurrent?.id, first.id)

        do {
            try await eidolon.deleteConversation(id: first.id)
            XCTFail("the pointed conversation should not be deleted")
        } catch let error as EidolonError {
            guard case .conversationIsCurrent = error else {
                return XCTFail("expected conversationIsCurrent, got \(error)")
            }
        }
        try await eidolon.deleteConversation(id: secondID)
        let gone = try await eidolon.conversation(id: secondID)
        XCTAssertNil(gone)
    }

    func testDebugSetCurrentReopensAnEndedPastConversation() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        try await endConversation(on: eidolon)
        let endedSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let ended = try XCTUnwrap(endedSnapshot)
        let fresh = try await eidolon.beginNewConversation(characterID: "mano")

        let moved = try await eidolon.debugSetCurrentConversation(
            characterID: "mano", id: ended.id, reopen: true
        )
        XCTAssertTrue(moved)

        let reopenedSnapshot = try await eidolon.conversation(id: ended.id)
        let reopened = try XCTUnwrap(reopenedSnapshot)
        XCTAssertFalse(reopened.ended)
        let current = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(current?.id, ended.id)
        let freshSnapshot = try await eidolon.conversation(id: fresh)
        XCTAssertEqual(freshSnapshot?.messages.count, 0)
        try await say("また話そう", provider: reply(), on: eidolon)
        let written = try await eidolon.conversation(id: ended.id)
        XCTAssertEqual(written?.messages.count, ended.messages.count + 2)
    }
}
