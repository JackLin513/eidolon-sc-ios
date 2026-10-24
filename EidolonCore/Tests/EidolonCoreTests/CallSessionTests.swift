import Foundation
import GRDB
import XCTest
@testable import EidolonCore

// MARK: - Fakes

final class FakeCapture: AudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private(set) var started = false
    private(set) var stopped = false

    func start() async throws {
        markStarted()
    }

    func stop() async {
        markStopped()
    }

    private func markStarted() {
        lock.lock()
        defer { lock.unlock() }
        started = true
    }

    private func markStopped() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }

    func chunks() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }
}

final class FakeRecognition: SpeechRecognition, @unchecked Sendable {
    enum Step {
        case events([SpeechEvent])
        case fail
        case hang
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var live: AsyncThrowingStream<SpeechEvent, Error>.Continuation?
    private(set) var calls = 0

    init(_ steps: [Step] = []) {
        self.steps = steps
    }

    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error> {
        lock.lock()
        calls += 1
        let step = steps.isEmpty ? .hang : steps.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            switch step {
            case let .events(events):
                for event in events { continuation.yield(event) }
                self.lock.lock()
                self.live = continuation
                self.lock.unlock()
            case .fail:
                continuation.finish(throwing: URLError(.networkConnectionLost))
            case .hang:
                self.lock.lock()
                self.live = continuation
                self.lock.unlock()
            }
        }
    }

    /// What the producer says into the live listening stream.
    func say(_ text: String) {
        lock.lock()
        let live = self.live
        lock.unlock()
        live?.yield(.final(text))
    }
}

final class FakeSynthesis: SpeechSynthesis, @unchecked Sendable {
    private let lock = NSLock()
    private var spoken: [String] = []
    var failing: (String) -> Bool = { _ in false }
    var delay: Duration?

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return spoken
    }

    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        let (fails, delay) = record(text)
        if let delay { try await Task.sleep(for: delay) }
        if fails { throw URLError(.cannotConnectToHost) }
        return Data(text.utf8)
    }

    private func record(_ text: String) -> (Bool, Duration?) {
        lock.lock()
        defer { lock.unlock() }
        spoken.append(text)
        return (failing(text), delay)
    }
}

final class FakePlayback: AudioPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private var played: [Data] = []
    private(set) var stopped = false
    var delay: Duration?

    var audio: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return played
    }

    func play(_ audio: Data) async throws {
        if let delay { try await Task.sleep(for: delay) }
        record(audio)
    }

    func stop() async {
        markStopped()
    }

    private func record(_ audio: Data) {
        lock.lock()
        defer { lock.unlock() }
        played.append(audio)
    }

    private func markStopped() {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
    }
}

/// A chat provider answering each turn with the next scripted reply.
final class ReplyScriptProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[String]]
    let failure: Error?

    init(_ replies: [[String]], failure: Error? = nil) {
        self.replies = replies
        self.failure = failure
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        let chunks = replies.isEmpty ? [] : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if let failure {
                continuation.finish(throwing: failure)
                return
            }
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [CallEvent] = []

    func append(_ event: CallEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var all: [CallEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func states() -> [CallState] {
        all.compactMap { if case let .state(state) = $0 { return state } else { return nil } }
    }
}

// MARK: - Tests

final class CallSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCall-\(UUID().uuidString)", isDirectory: true)
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

    private func begin(
        on eidolon: Eidolon,
        provider: any ChatProvider,
        recognition: FakeRecognition,
        synthesis: FakeSynthesis = FakeSynthesis(),
        playback: FakePlayback = FakePlayback(),
        timeLimit: Duration = .seconds(3600)
    ) async throws -> (CallSession, EventLog, FakeCapture) {
        let capture = FakeCapture()
        let setup = CallSetup(
            capture: capture,
            playback: playback,
            recognition: recognition,
            synthesis: synthesis,
            voiceModel: "s2.1-pro-free",
            provider: provider,
            timeLimit: timeLimit,
            reconnectDelay: .milliseconds(10)
        )
        let session = try await eidolon.beginCall(characterID: "mano", setup: setup)
        let log = EventLog()
        let stream = session.events()
        Task.detached {
            for await event in stream { log.append(event) }
        }
        await session.start()
        return (session, log, capture)
    }

    private func waitFor(
        _ description: String,
        timeout: Duration = .seconds(2),
        _ check: @Sendable () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out waiting for \(description)")
    }

    private func states(_ log: EventLog) -> [CallState] { log.states() }

    func testACallAnswersWhatItHears() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>もしもし</ja><zh>喂</zh>", "<ja>聞こえてる</ja><zh>听得见</zh>"],
        ])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("もしもし、聞こえる？")

        try await waitFor("speaking") {
            log.states().contains(.speaking)
        }
        try await waitFor("both segments played") { playback.audio.count == 2 }
        try await waitFor("back to listening") {
            let state = await session.currentState()
            return state == .listening
        }

        let segments = log.all.compactMap { event -> (Int, String, String)? in
            if case let .segment(index, ja, zh) = event { return (index, ja, zh) }
            return nil
        }
        XCTAssertEqual(segments.map(\.1), ["もしもし", "聞こえてる"])
        XCTAssertEqual(segments.map(\.2), ["喂", "听得见"])
        XCTAssertEqual(synthesis.texts, ["もしもし", "聞こえてる"])

        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.messages.count, 2)
        XCTAssertEqual(conversation?.messages.first?.text, "もしもし、聞こえる？")

        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .hungUpByProducer)
    }

    func testWhatIsBeingSaidIsShownAsItIsHeard() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([
            .events([.partial("もし"), .partial("もしもし")]),
            .hang,
        ])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )

        try await waitFor("the revision shown") { log.all.contains(.hearing("もしもし")) }
        try await waitFor("listening again") { await session.currentState() == .listening }
        recognition.say("もしもし")
        try await waitFor("cleared when the sentence ends") {
            guard let index = log.all.lastIndex(of: .recognized("もしもし")) else { return false }
            return log.all[..<index].contains(.hearing(""))
        }
        await session.hangUp()
    }

    func testHangingUpStopsTheVoiceAndRecordsTheEvent() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let playback = FakePlayback()
        playback.delay = .milliseconds(500)
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("speaking") { await session.currentState() == .speaking }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }

        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .hungUpByProducer)
        let stopped = capture.stopped
        XCTAssertTrue(stopped)
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, ["hung_up"])
    }

    func testTheCallEndsAtTheTimeLimit() async throws {
        let eidolon = try await installedEidolon()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang]),
            timeLimit: .milliseconds(80)
        )
        try await waitFor("ended by time limit") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .timeLimit)
    }

    func testCoolingRefusesTheCall() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES ('mano', 0, 1, ?, 0, NULL)
                    """,
                arguments: [Eidolon.timestamp(Date())]
            )
        }
        do {
            _ = try await eidolon.beginCall(characterID: "mano", setup: setup(on: eidolon))
            XCTFail("a cooling character should not answer")
        } catch let error as EidolonError {
            guard case .coolingDown = error else {
                return XCTFail("expected coolingDown, got \(error)")
            }
        }
    }

    func testAnEndedConversationRefusesTheCall() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversations(id, character_id, created_at, ended_at)
                    VALUES ('ended', 'mano', '2026-10-01T00:00:00Z', '2026-10-01T01:00:00Z')
                    """
            )
        }
        do {
            _ = try await eidolon.beginCall(characterID: "mano", setup: setup(on: eidolon))
            XCTFail("an ended conversation should not take a call")
        } catch let error as EidolonError {
            guard case .conversationEnded = error else {
                return XCTFail("expected conversationEnded, got \(error)")
            }
        }
    }

    func testTheRecognizerReconnectsAndTheCallGoesOn() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.fail, .hang])
        let provider = ReplyScriptProvider([["<ja>うん</ja><zh>嗯</zh>"]])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("reconnecting") { log.states().contains(.reconnecting) }
        try await waitFor("listening again") {
            await session.currentState() == .listening
        }
        recognition.say("もしもし")
        try await waitFor("answered") {
            log.states().contains(.speaking)
        }
        await session.hangUp()
    }

    func testASegmentThatCannotBeVoicedIsSkipped() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>だめ</ja><zh>不行</zh>", "<ja>だいじょうぶ</ja><zh>没事</zh>"],
        ])
        let synthesis = FakeSynthesis()
        synthesis.failing = { $0.contains("だめ") }
        let playback = FakePlayback()
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the good segment played") { playback.audio.count == 1 }
        XCTAssertEqual(playback.audio.first, Data("だいじょうぶ".utf8))
        let captions = log.all.compactMap { event -> String? in
            if case let .segment(_, ja, _) = event { return ja }
            return nil
        }
        XCTAssertEqual(captions, ["だめ", "だいじょうぶ"])
        await session.hangUp()
    }

    func testAFailedTurnKeepsTheCall() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([], failure: ChatProviderError.status(500, "boom"))
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("failure reported") {
            log.all.contains { if case .failed = $0 { return true } else { return false } }
        }
        try await waitFor("listening again") { await session.currentState() == .listening }
        let messages = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
        }
        XCTAssertEqual(messages, 0)
        await session.hangUp()
    }

    func testWhatSheHearsWhileSheSpeaksIsAnsweredAfterwards() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>そうだね</ja><zh>是啊</zh>"],
            ["<ja>うん</ja><zh>嗯</zh>"],
        ])
        let playback = FakePlayback()
        playback.delay = .milliseconds(150)
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("一つ目")
        try await waitFor("speaking") { await session.currentState() == .speaking }
        recognition.say("二つ目")
        try await waitFor("the second answer played") { playback.audio.count == 2 }
        let heard = log.all.compactMap { event -> String? in
            if case let .recognized(text) = event { return text }
            return nil
        }
        XCTAssertEqual(heard, ["一つ目", "二つ目"])
        await session.hangUp()
    }

    func testCaptionsDropDeliveryCuesAndTheVoiceKeepsThem() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>[shyly] あのね</ja><zh>那个</zh>"]])
        let synthesis = FakeSynthesis()
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("voiced") { !synthesis.texts.isEmpty }
        XCTAssertEqual(synthesis.texts, ["[shyly] あのね"])
        let captions = log.all.compactMap { event -> String? in
            if case let .segment(_, ja, _) = event { return ja }
            return nil
        }
        XCTAssertEqual(captions, ["あのね"])
        await session.hangUp()
    }

    private func setup(on eidolon: Eidolon) -> CallSetup {
        CallSetup(
            capture: FakeCapture(),
            playback: FakePlayback(),
            recognition: FakeRecognition([.hang]),
            synthesis: FakeSynthesis(),
            voiceModel: "s2.1-pro-free",
            provider: ReplyScriptProvider([])
        )
    }
}

extension CallSession {
    /// The reason the call ended, for tests; nil while it is going on.
    var currentStateIfEnded: CallEnd? {
        get async {
            if case let .ended(reason) = await currentState() { return reason }
            return nil
        }
    }
}
