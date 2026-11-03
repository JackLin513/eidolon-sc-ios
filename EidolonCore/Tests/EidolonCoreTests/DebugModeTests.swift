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

    // MARK: - Keeping a conversation open

    func testDebugNoEndingKeepsAnOffendedConversationOpen() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let snapshotValue = try await eidolon.currentConversation(characterID: "mano")
        let snapshot = try XCTUnwrap(snapshotValue)
        try await eidolon.setDebugNoEnding(conversationID: snapshot.id, on: true)

        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        let first = try await say("ひどい", provider: reply(), judge: harsh, on: eidolon)
        XCTAssertFalse(first?.ended == true)
        let second = try await say("もう一度ひどい", provider: reply(), judge: harsh, on: eidolon)
        XCTAssertFalse(second?.ended == true)
        XCTAssertNil(second?.hangUp)

        let afterValue = try await eidolon.conversation(id: snapshot.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertFalse(after.ended)
        let record = try await eidolon.conversationRecord(conversationID: snapshot.id)
        XCTAssertFalse(record.contains { line in
            if case let .event(event) = line { return event.kind == "ended" }
            return false
        })
        let status = try await eidolon.affinityStatus(characterID: "mano")
        XCTAssertFalse(status.cooling)

        let third = try await say("まだ話せる", provider: reply(), on: eidolon)
        XCTAssertNotNil(third)
        XCTAssertFalse(third?.ended == true)
    }

    func testDebugNoEndingSuppressesTheCooldownThatWouldStopTheTurn() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let snapshotValue = try await eidolon.currentConversation(characterID: "mano")
        let snapshot = try XCTUnwrap(snapshotValue)
        try await eidolon.debugSetAffinity(characterID: "mano", value: 5)
        try await eidolon.setDebugNoEnding(conversationID: snapshot.id, on: true)

        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        let record = try await say("ひどい", provider: reply(), judge: harsh, on: eidolon)

        XCTAssertFalse(record?.ended == true)
        XCTAssertNil(record?.hangUp)
        let status = try await eidolon.affinityStatus(characterID: "mano")
        XCTAssertFalse(status.cooling)
        XCTAssertNil(status.cooldownUntil)
        let afterValue = try await eidolon.conversation(id: snapshot.id)
        XCTAssertFalse(afterValue?.ended == true)
    }

    func testDebugNoEndingReplacesTheOutOfLineFeelingInThePrompt() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let snapshotValue = try await eidolon.currentConversation(characterID: "mano")
        let snapshot = try XCTUnwrap(snapshotValue)
        try await eidolon.setDebugNoEnding(conversationID: snapshot.id, on: true)

        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        _ = try await say("ひどい", provider: reply(), judge: harsh, on: eidolon)

        let prompt = try await latestPrompt(on: eidolon)
        XCTAssertTrue(prompt.contains("有点不舒服，但你还愿意继续听"), prompt)
        XCTAssertFalse(prompt.contains(AffinityPrompt.outOfLineFeeling), prompt)
        XCTAssertFalse(prompt.contains(AffinityPrompt.warnings[.parts]!), prompt)
        XCTAssertFalse(prompt.contains(AffinityPrompt.partings[.parts]!), prompt)
    }

    func testWithoutTheShieldTheOutOfLineTurnWarns() async throws {
        let eidolon = try await installedEidolon()
        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        _ = try await say("ひどい", provider: reply(), judge: harsh, on: eidolon)

        let prompt = try await latestPrompt(on: eidolon)
        XCTAssertTrue(prompt.contains(AffinityPrompt.outOfLineFeeling), prompt)
        XCTAssertTrue(prompt.contains(AffinityPrompt.warnings[.parts]!), prompt)
        XCTAssertFalse(prompt.contains(AffinityPrompt.shieldedOutOfLineFeeling), prompt)
    }

    func testDebugNoEndingIsPerConversationAndPersists() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let firstValue = try await eidolon.currentConversation(characterID: "mano")
        let first = try XCTUnwrap(firstValue)
        try await eidolon.setDebugNoEnding(conversationID: first.id, on: true)
        let firstShielded = try await eidolon.debugNoEnding(conversationID: first.id)
        XCTAssertTrue(firstShielded)

        let secondID = try await eidolon.beginNewConversation(characterID: "mano")
        let secondShielded = try await eidolon.debugNoEnding(conversationID: secondID)
        XCTAssertFalse(secondShielded)

        let reopened = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let firstAfterReopen = try await reopened.debugNoEnding(conversationID: first.id)
        XCTAssertTrue(firstAfterReopen)
        let secondAfterReopen = try await reopened.debugNoEnding(conversationID: secondID)
        XCTAssertFalse(secondAfterReopen)

        try await reopened.setDebugNoEnding(conversationID: first.id, on: false)
        let cleared = try await reopened.debugNoEnding(conversationID: first.id)
        XCTAssertFalse(cleared)
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

    // MARK: - Current pointer

    func testCreatingAConversationPointsAtIt() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let firstSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let first = try XCTUnwrap(firstSnapshot)
        let firstPointer: String? = try await eidolon.userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT conversation_id FROM current_conversations WHERE character_id = 'mano'"
            )
        }
        XCTAssertEqual(firstPointer, first.id)

        let secondID = try await eidolon.beginNewConversation(characterID: "mano")
        let secondPointer: String? = try await eidolon.userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT conversation_id FROM current_conversations WHERE character_id = 'mano'"
            )
        }
        XCTAssertEqual(secondPointer, secondID)
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

        let callPath = try eidolon.currentConversationIDNow("mano")
        XCTAssertEqual(callPath, first.id, "the call path reads the same pointer")

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

    func testDebugAffinityLeavesTheStoryAlone() async throws {
        let eidolon = try await installedEidolon()
        try await say("こんにちは", provider: reply(), on: eidolon)
        let snapshotValue = try await eidolon.currentConversation(characterID: "mano")
        let snapshot = try XCTUnwrap(snapshotValue)
        let beforeMessages = snapshot.messages.count
        let beforeRecord = try await eidolon.conversationRecord(conversationID: snapshot.id)
        let beforeEvents = beforeRecord.filter { line in
            if case .event = line { return true }
            return false
        }.count
        let beforeTraces = try await eidolon.turnTraces().count

        try await eidolon.debugSetAffinity(characterID: "mano", value: 90)

        let afterValue = try await eidolon.conversation(id: snapshot.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(after.messages.count, beforeMessages)
        let afterRecord = try await eidolon.conversationRecord(conversationID: snapshot.id)
        let afterEvents = afterRecord.filter { line in
            if case .event = line { return true }
            return false
        }.count
        XCTAssertEqual(afterEvents, beforeEvents)
        let afterTraces = try await eidolon.turnTraces().count
        XCTAssertEqual(afterTraces, beforeTraces)
    }

    func testANewConversationAfterADebugMoveBecomesCurrent() async throws {
        let eidolon = try await installedEidolon()
        try await say("最初の話", provider: reply(), on: eidolon)
        let firstSnapshot = try await eidolon.currentConversation(characterID: "mano")
        let first = try XCTUnwrap(firstSnapshot)
        let secondID = try await eidolon.beginNewConversation(characterID: "mano")

        let moved = try await eidolon.debugSetCurrentConversation(characterID: "mano", id: first.id)
        XCTAssertTrue(moved)
        let thirdID = try await eidolon.beginNewConversation(characterID: "mano")

        XCTAssertNotEqual(thirdID, secondID)
        let current = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(current?.id, thirdID)
        let summaries = try await eidolon.conversations(characterID: "mano")
        XCTAssertEqual(summaries.first?.id, thirdID)
        XCTAssertTrue(summaries.first?.isCurrent == true)
        XCTAssertEqual(summaries.first { $0.id == first.id }?.isCurrent, false)
    }

    func testDebugSetCurrentRefusesAConversationOfAnotherCharacter() async throws {
        let eidolon = try await installedEidolon()
        try await say("やあ", to: "mano", provider: reply(), on: eidolon)
        let handoverValue = try await eidolon.currentConversation(characterID: "mano")
        let handover = try XCTUnwrap(handoverValue)

        let moved = try await eidolon.debugSetCurrentConversation(
            characterID: "hiori", id: handover.id
        )
        XCTAssertFalse(moved)
        let current = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(current?.id, handover.id)
    }

    func testDebugMemoriesWaitsForAMemoryStillBeingWritten() async throws {
        let eidolon = try await installedEidolon()
        let provider = SlowMemoryChatProvider(
            memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#,
            delay: .milliseconds(200)
        )
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "猫を飼ってるんだ",
            provider: provider,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}
        let snapshotValue = try await eidolon.currentConversation(characterID: "mano")
        let snapshot = try XCTUnwrap(snapshotValue)

        // Nothing settles the job first: the debug list's own wait has to bring it in.
        let memories = try await eidolon.debugMemories(conversationID: snapshot.id)
        XCTAssertEqual(memories.map(\.text), ["制作人养了一只猫"])
    }
}

/// Answers the chat at once and the background memory only after `delay`, so a test can
/// catch the memory while it is still being written.
private final class SlowMemoryChatProvider: ChatProvider, @unchecked Sendable {
    private let memory: String
    private let delay: Duration

    init(memory: String, delay: Duration) {
        self.memory = memory
        self.delay = delay
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        let extraction = messages.contains {
            $0.role == .system && $0.content.contains("你负责替")
        }
        let text = extraction ? memory : "<ja>うん</ja><zh>嗯</zh>"
        return AsyncThrowingStream { continuation in
            let task = Task {
                if extraction {
                    try? await Task.sleep(for: delay)
                }
                continuation.yield(text)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

