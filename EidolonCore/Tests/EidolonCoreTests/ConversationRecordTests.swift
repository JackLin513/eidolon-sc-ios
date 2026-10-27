import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// The conversation as the chat page shows it: the database's own timeline, not a reordering
/// by ids (upstream `read_record`; spec「排序的唯一来源」).
final class ConversationRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonRecord-\(UUID().uuidString)", isDirectory: true)
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
    ) async throws {
        for try await _ in eidolon.sendTurn(
            characterID: characterID,
            text: text,
            provider: provider,
            judge: judge
        ) {}
        await eidolon.settleTitles()
    }

    /// What a line is, for an order assertion.
    private func labels(_ record: [ConversationLine]) -> [String] {
        record.map { line in
            switch line {
            case let .message(message): "\(message.role):\(message.text ?? message.japanese)"
            case let .event(event): "event:\(event.kind)"
            }
        }
    }

    private func conversationID(_ eidolon: Eidolon, characterID: String = "mano") async throws -> String {
        let snapshot = try await eidolon.currentConversation(characterID: characterID)
        return try XCTUnwrap(snapshot?.id)
    }

    /// The roster's preview can be something that happened, not only something said: after
    /// a call that ended there, the last thing in the conversation is the event (upstream
    /// `previewOfOne`).
    func testTheLatestActivityCanBeAnEvent() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversations(id, character_id, created_at) VALUES ('c1', 'mano', ?)",
                arguments: ["2026-10-27T12:00:00.000000Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, ja, zh, segments, created_at)
                    VALUES ('r', 'c1', 'character', 'うん', '嗯', '[{"ja":"うん","zh":"嗯"}]', ?)
                    """,
                arguments: ["2026-10-27T12:00:01.000000Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(conversation_id, kind, created_at)
                    VALUES ('c1', 'hung_up', '2026-10-27T12:00:02.000000Z')
                    """
            )
        }

        let activity = try await eidolon.latestActivities()["mano"]
        XCTAssertEqual(activity?.lastMessageRole, "event")
        XCTAssertEqual(activity?.lastEventKind, "hung_up")
        XCTAssertEqual(activity?.lastMessageAt, "2026-10-27T12:00:02.000000Z")
        XCTAssertNil(activity?.lastMessagePreview)
    }

    /// The roster is ordered by the latest activity, from the newest; ties and characters
    /// never talked to keep the content's own order (upstream `arrange`).
    func testTheRosterIsOrderedByTheLatestActivity() {
        let mano = CharacterConfig(id: "mano", name: "櫻木真乃")
        let hiori = CharacterConfig(id: "hiori", name: "風野灯織")
        let latest = [
            "mano": LatestActivity(
                lastMessagePreview: "嗯",
                lastMessageRole: "character",
                lastMessageAt: "2026-10-27T12:00:00.000000Z"
            ),
            "hiori": LatestActivity(
                lastMessagePreview: "这样啊",
                lastMessageRole: "character",
                lastMessageAt: "2026-10-27T13:00:00.000000Z"
            ),
        ]
        XCTAssertEqual(
            ConversationOrder.byRecency([mano, hiori], latest: latest).map(\.id),
            ["hiori", "mano"]
        )
        XCTAssertEqual(
            ConversationOrder.byRecency([mano, hiori], latest: [:]).map(\.id),
            ["mano", "hiori"]
        )
        let sameTime = [
            "mano": LatestActivity(lastMessageAt: "2026-10-27T12:00:00.000000Z"),
            "hiori": LatestActivity(lastMessageAt: "2026-10-27T12:00:00.000000Z"),
        ]
        XCTAssertEqual(
            ConversationOrder.byRecency([mano, hiori], latest: sameTime).map(\.id),
            ["mano", "hiori"]
        )
    }

    // MARK: - Sub-second stamps and write order

    func testHerReplyIsStampedBelowTheSecondAndFollowsTheQuestion() async throws {
        let eidolon = try await installedEidolon()
        try await say("やあ", provider: reply(), on: eidolon)

        let current = try await eidolon.currentConversation(characterID: "mano")
        let snapshot = try XCTUnwrap(current)
        XCTAssertEqual(snapshot.messages.map(\.role), ["user", "character"])
        let question = snapshot.messages[0]
        let answer = snapshot.messages[1]
        XCTAssertTrue(question.createdAt.contains("."), "the turn's stamp carries sub-second precision")
        XCTAssertTrue(answer.createdAt.contains("."), "her reply's stamp carries sub-second precision")
        XCTAssertLessThan(question.createdAt, answer.createdAt, "the reply is written after the question")
    }

    /// The two rows of a turn are ordered by the rowid they were written with, never by their
    /// ids: a random id once put the reply above the question about half the time.
    func testATurnsRowsAreOrderedByWhenTheyWereWrittenNotByTheirIds() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversations(id, character_id, created_at) VALUES ('c1', 'mano', ?)",
                arguments: ["2026-10-27T12:00:00.000000Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES ('zzzz-question', 'c1', 'user', 'やあ', ?)
                    """,
                arguments: ["2026-10-27T12:00:00.000000Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, ja, zh, segments, created_at)
                    VALUES ('aaaa-answer', 'c1', 'character', 'うん', '嗯', '[{"ja":"うん","zh":"嗯"}]', ?)
                    """,
                arguments: ["2026-10-27T12:00:00.000000Z"]
            )
        }

        let record = try await eidolon.conversationRecord(conversationID: "c1")
        XCTAssertEqual(labels(record), ["user:やあ", "character:うん"])
    }

    /// A call event recorded in the same second as the turn is not moved in between the
    /// question and the reply: it comes after what was already written (upstream `read_record`
    /// only places an event before a user message stamped strictly later).
    func testAnEventInTheSameSecondStaysAfterTheTurn() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversations(id, character_id, created_at) VALUES ('c1', 'mano', ?)",
                arguments: ["2026-10-27T12:00:00Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES ('u', 'c1', 'user', 'やあ', '2026-10-27T12:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, ja, zh, segments, created_at)
                    VALUES ('r', 'c1', 'character', 'うん', '嗯', '[{"ja":"うん","zh":"嗯"}]', '2026-10-27T12:00:00Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(conversation_id, kind, created_at)
                    VALUES ('c1', 'hung_up', '2026-10-27T12:00:00Z')
                    """
            )
        }

        let record = try await eidolon.conversationRecord(conversationID: "c1")
        XCTAssertEqual(labels(record), ["user:やあ", "character:うん", "event:hung_up"])
    }

    func testAnEventWrittenBetweenTurnsComesAfterTheTurnBeforeIt() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: "INSERT INTO conversations(id, character_id, created_at) VALUES ('c1', 'mano', ?)",
                arguments: ["2026-10-27T12:00:00.000000Z"]
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES ('u1', 'c1', 'user', 'やあ', '2026-10-27T12:00:00.100000Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, ja, zh, segments, created_at)
                    VALUES ('r1', 'c1', 'character', 'うん', '嗯', '[{"ja":"うん","zh":"嗯"}]', '2026-10-27T12:00:00.200000Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(conversation_id, kind, created_at)
                    VALUES ('c1', 'hung_up', '2026-10-27T12:00:30.000000Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, text, created_at)
                    VALUES ('u2', 'c1', 'user', 'またね', '2026-10-27T12:01:00.000000Z')
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO messages(id, conversation_id, role, ja, zh, segments, created_at)
                    VALUES ('r2', 'c1', 'character', 'うん', '嗯', '[{"ja":"うん","zh":"嗯"}]', '2026-10-27T12:01:00.100000Z')
                    """
            )
        }

        let record = try await eidolon.conversationRecord(conversationID: "c1")
        XCTAssertEqual(
            labels(record),
            ["user:やあ", "character:うん", "event:hung_up", "user:またね", "character:うん"]
        )
    }

    /// Her ending a typed conversation is written after the reply it ends, and is the last
    /// thing in the record.
    func testTheEndingIsRecordedAfterTheReplyItEnds() async throws {
        let eidolon = try await installedEidolon()
        let harsh = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        try await say("こんにちは", provider: reply(), on: eidolon)
        try await say("ひどいことを言う", provider: reply(), judge: harsh, on: eidolon)
        try await say("もう一度ひどいことを言う", provider: reply(), judge: harsh, on: eidolon)

        let id = try await conversationID(eidolon)
        let record = try await eidolon.conversationRecord(conversationID: id)
        XCTAssertEqual(
            labels(record),
            [
                "user:こんにちは", "character:うん",
                "user:ひどいことを言う", "character:うん",
                "user:もう一度ひどいことを言う", "character:うん",
                "event:ended",
            ]
        )
        let events = try await eidolon.conversationEvents(conversationID: id)
        let ended = try XCTUnwrap(events.last)
        XCTAssertEqual(ended.kind, "ended")
        let before = try XCTUnwrap(record.dropLast().last?.createdAt)
        XCTAssertGreaterThan(ended.createdAt, before)
    }
}
