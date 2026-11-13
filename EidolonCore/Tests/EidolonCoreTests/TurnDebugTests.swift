import Foundation
import XCTest
@testable import EidolonCore

final class TurnDebugTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonTurnDebug-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installed() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.world = .valid
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root, options: options))
        return eidolon
    }

    private func send(
        _ eidolon: Eidolon,
        provider: any ChatProvider,
        judge: (any JudgeProvider)? = FixedJudge(judged: Judged(level: 3)),
        captureDebug: Bool = true
    ) async throws {
        do {
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "やあ",
                provider: provider,
                judge: judge,
                captureDebug: captureDebug
            ) {}
        } catch {
            // A failed test turn still leaves a partial debug snapshot; callers that need
            // the failure assert on it.
        }
    }

    func testCompleteTurnSnapshotHasJudgeRetrievalAndSections() async throws {
        let eidolon = try await installed()
        let provider = RecordingChatProvider(chunks: ["<ja>こんにちは</ja><zh>你好</zh>"])
        try await send(eidolon, provider: provider)

        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        let records = try await eidolon.debugSnapshots(conversationID: conversation.id)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.snapshot.status, .complete)
        XCTAssertEqual(record.snapshot.characterID, "mano")
        XCTAssertEqual(record.snapshot.conversationID, conversation.id)
        XCTAssertNotNil(record.snapshot.userMessageID)
        XCTAssertNotNil(record.snapshot.replyMessageID)
        XCTAssertNotNil(record.snapshot.judge)
        XCTAssertNotNil(record.snapshot.retrieval)
        XCTAssertEqual(record.snapshot.requests.count, 1)
        XCTAssertEqual(record.snapshot.requests.first?.rawResponse, "<ja>こんにちは</ja><zh>你好</zh>")
        XCTAssertTrue(record.snapshot.sections.contains { $0.kind == "persona" })
        XCTAssertTrue(record.snapshot.sections.contains { $0.kind == "world" })
        XCTAssertEqual(record.snapshot.timings?.total != nil, true)
        XCTAssertNotNil(record.snapshot.inputTokens)
        XCTAssertNotNil(record.snapshot.outputTokens)
    }

    func testJudgeFailureIsShownWhileTheReplyStillCompletes() async throws {
        let eidolon = try await installed()
        try await send(
            eidolon,
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            judge: FailingJudge()
        )
        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        let snapshots = try await eidolon.debugSnapshots(conversationID: conversation.id)
        let record = try XCTUnwrap(snapshots.first)
        XCTAssertEqual(record.snapshot.status, .complete)
        XCTAssertNotNil(record.snapshot.judge)
        XCTAssertFalse(record.snapshot.judge?.failure?.isEmpty ?? true)
    }

    func testNoSnapshotWhenCaptureIsOff() async throws {
        let eidolon = try await installed()
        try await send(
            eidolon,
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            captureDebug: false
        )
        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        let snapshots = try await eidolon.debugSnapshots(conversationID: conversation.id)
        XCTAssertTrue(snapshots.isEmpty)
    }

    func testFailedTurnKeepsPartialSnapshot() async throws {
        let eidolon = try await installed()
        let provider = RecordingChatProvider(
            chunks: [],
            failure: ChatProviderError.invalidResponse("boom")
        )
        try await send(eidolon, provider: provider)
        let failed = try await eidolon.latestFailedDebugSnapshot(characterID: "mano")
        let record = try XCTUnwrap(failed)
        XCTAssertEqual(record.snapshot.status, .failed)
        XCTAssertFalse(record.snapshot.error?.isEmpty ?? true)
    }

    func testRetentionKeepsTwentyAndClearRemovesThem() async throws {
        let eidolon = try await installed()
        try await send(eidolon, provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]))
        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)

        for index in 0..<25 {
            let snapshot = TurnDebugSnapshot(
                characterID: "mano",
                conversationID: conversation.id,
                replyMessageID: "r\(index)",
                status: .complete,
                createdAt: Eidolon.timestamp(Date())
            )
            try await eidolon.writeDebugSnapshot(snapshot)
        }
        let kept = try await eidolon.debugSnapshots(conversationID: conversation.id)
        XCTAssertEqual(kept.count, 20)
        try await eidolon.clearDebugSnapshots(conversationID: conversation.id)
        let cleared = try await eidolon.debugSnapshots(conversationID: conversation.id)
        XCTAssertTrue(cleared.isEmpty)
    }

    func testSnapshotRoundTripsWithoutNewFields() throws {
        let old = """
            {"characterID":"mano","status":"failed","createdAt":"2026-01-01T00:00:00Z",
             "sections":[],"requests":[],"toolCalls":[],"degradation":[]}
            """
        let snapshot = try JSONDecoder().decode(
            TurnDebugSnapshot.self,
            from: Data(old.utf8)
        )
        XCTAssertEqual(snapshot.characterID, "mano")
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertNil(snapshot.model)
        XCTAssertNil(snapshot.timings)
    }
}
