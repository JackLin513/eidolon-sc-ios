import Foundation
import GRDB
import XCTest
@testable import EidolonCore

// MARK: - Fakes

final class FakeCapture: AudioCapture, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var hearing = true
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

    /// Whether the microphone is feeding the call, as the last `setHearing` left it.
    var isHearing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hearing
    }

    func setHearing(_ hearing: Bool) async {
        setHearingNow(hearing)
    }

    private func setHearingNow(_ hearing: Bool) {
        lock.lock()
        self.hearing = hearing
        lock.unlock()
    }

    func chunks() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// One chunk of microphone audio, as the tap would deliver it. While the microphone is
    /// closed nothing reaches the recognizer, as with the real tap.
    func send(_ byte: UInt8) {
        lock.lock()
        let continuation = self.continuation
        let hearing = self.hearing
        lock.unlock()
        guard hearing else { return }
        continuation?.yield(Data([byte]))
    }
}

final class FakeRecognition: SpeechRecognition, @unchecked Sendable {
    enum Step {
        case events([SpeechEvent])
        case fail
        /// The service itself failing, as Soniox reports a refused key.
        case failService
        case hang
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var live: AsyncThrowingStream<SpeechEvent, Error>.Continuation?
    /// What was said before the call was listening yet.
    private var backlog: [SpeechEvent] = []
    /// The microphone audio the recognizer was actually fed.
    private var fed: [UInt8] = []
    private(set) var calls = 0

    init(_ steps: [Step] = []) {
        self.steps = steps
    }

    var heard: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return fed
    }

    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error> {
        lock.lock()
        calls += 1
        let step = steps.isEmpty ? .hang : steps.removeFirst()
        lock.unlock()
        // The recognizer takes the microphone for as long as its connection lasts; when
        // the connection ends, so does its reading (as canceling a task consuming the
        // stream would).
        let collector = Task.detached { [weak self] in
            do {
                for try await chunk in audio {
                    guard let self else { return }
                    self.recordHeard(chunk)
                }
            } catch {
                // The stream ended with the call.
            }
        }
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { @Sendable _ in collector.cancel() }
            switch step {
            case let .events(events):
                for event in events { continuation.yield(event) }
                self.attach(continuation)
            case .fail:
                continuation.finish(throwing: URLError(.networkConnectionLost))
            case .failService:
                continuation.finish(throwing: SonioxError.service("401", "invalid api key"))
            case .hang:
                self.attach(continuation)
            }
        }
    }

    /// Converts the error as the real recognizer does: only a service error is the
    /// service failing, a dropped connection is reconnected.
    func failure(_ error: any Error) -> VoiceServiceFailure? {
        guard case let SonioxError.service(code, message) = error else { return nil }
        return VoiceServiceFailure(service: "Soniox", detail: "\(code) \(message)")
    }

    /// The live connection failing as the service itself would.
    func failService() {
        lock.lock()
        let live = self.live
        lock.unlock()
        live?.finish(throwing: SonioxError.service("401", "invalid api key"))
    }

    private func recordHeard(_ chunk: Data) {
        lock.lock()
        fed.append(contentsOf: chunk)
        lock.unlock()
    }

    private func attach(_ continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation) {
        lock.lock()
        live = continuation
        let backlog = self.backlog
        self.backlog = []
        lock.unlock()
        for event in backlog { continuation.yield(event) }
    }

    /// What the producer says into the live listening stream.
    func say(_ text: String) {
        lock.lock()
        if let live {
            lock.unlock()
            live.yield(.final(text))
            return
        }
        backlog.append(.final(text))
        lock.unlock()
    }
}

/// What happened in what order, across the fakes that voice and play.
final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func add(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func index(of entry: String) -> Int? {
        all.firstIndex(of: entry)
    }
}

final class FakeSynthesis: SpeechSynthesis, @unchecked Sendable {
    private let lock = NSLock()
    private var spoken: [String] = []
    var failing: (String) -> Bool = { _ in false }
    var delay: Duration?
    var timeline: Timeline?

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return spoken
    }

    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        timeline?.add("synth-start:\(text)")
        let (fails, delay) = record(text)
        if let delay { try await Task.sleep(for: delay) }
        if fails { throw URLError(.cannotConnectToHost) }
        timeline?.add("synth-end:\(text)")
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
    var timeline: Timeline?

    var audio: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return played
    }

    func play(_ audio: Data) async throws {
        let text = String(decoding: audio, as: UTF8.self)
        timeline?.add("play-start:\(text)")
        if let delay { try await Task.sleep(for: delay) }
        record(audio)
        timeline?.add("play-end:\(text)")
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

/// A chat provider that says part of a reply and then waits to be cancelled: the call is
/// hung up while the turn is still being answered.
final class HeldReplyProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var said = false

    var hasSaidPart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return said
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("<ja>まだ話して</ja><zh>还在说</zh>")
            lock.lock()
            said = true
            lock.unlock()
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// A segment emotion judge answering each call's segments from a script, and noting what
/// it was asked.
actor ScriptedEmotionJudge: SegmentEmotionJudge {
    private var answers: [SegmentEmotion?]
    private(set) var asked: [SegmentToJudge] = []

    init(_ answers: [SegmentEmotion?]) {
        self.answers = answers
    }

    func emotion(in segment: SegmentToJudge) async -> SegmentEmotion? {
        asked.append(segment)
        return answers.isEmpty ? nil : answers.removeFirst()
    }

    func askedSegments() -> [SegmentToJudge] { asked }
}

/// A segment emotion judge that takes long enough for the call to end first, and says
/// whether its work was cancelled.
actor SlowEmotionJudge: SegmentEmotionJudge {
    private var asked = 0
    private var cancelled = false

    var askedCount: Int { asked }
    var wasCancelled: Bool { cancelled }

    func emotion(in segment: SegmentToJudge) async -> SegmentEmotion? {
        asked += 1
        do {
            try await Task.sleep(for: .seconds(10))
        } catch {
            cancelled = true
            return nil
        }
        return SegmentEmotion(emotion: .happy)
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

// MARK: - Reading the call's segments

/// One of her segments as the call reported it: which reply, which segment, and the two
/// subtitles.
private struct ShownSegment {
    var reply: Int
    var segment: Int
    var ja: String
    var zh: String
}

private func segments(of log: EventLog) -> [ShownSegment] {
    log.all.compactMap { event in
        guard case let .segment(reply, segment, ja, zh) = event else { return nil }
        return ShownSegment(reply: reply, segment: segment, ja: ja, zh: zh)
    }
}

/// Her segments' voice starting and stopping, as the call reported them, in order.
private func played(of log: EventLog) -> [String] {
    log.all.compactMap { event in
        switch event {
        case let .segmentStarted(reply, segment): return "start:\(reply):\(segment)"
        case let .segmentStopped(reply, segment): return "stop:\(reply):\(segment)"
        default: return nil
        }
    }
}

/// Her segments' judged emotions, as the call reported them, in order.
private func emotions(
    of log: EventLog
) -> [(reply: Int, segment: Int, emotion: StandEmotion, nod: StandNod.Kind?)] {
    log.all.compactMap { event in
        guard case let .emotion(reply, segment, emotion, nod) = event else { return nil }
        return (reply, segment, emotion, nod)
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
        judge: (any JudgeProvider)? = nil,
        emotionJudge: (any SegmentEmotionJudge)? = nil,
        limits: CallLimits = .standard,
        historyTurns: Int = 20,
        voiceModel: String = "s2.1-pro-free"
    ) async throws -> (CallSession, EventLog, FakeCapture) {
        let capture = FakeCapture()
        let setup = CallSetup(
            capture: capture,
            playback: playback,
            recognition: recognition,
            synthesis: synthesis,
            voiceModel: voiceModel,
            provider: provider,
            judge: judge,
            emotionJudge: emotionJudge,
            limits: limits,
            historyTurns: historyTurns,
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

    /// How many rows `table` holds in the user library; the table names come from the
    /// tests themselves, never from what is being tested.
    private func rowCount(_ table: String, on eidolon: Eidolon) async throws -> Int {
        try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    /// The traces a turn left: the call's own ending is traced too, without a prompt.
    private func turnTraceCount(on eidolon: Eidolon) async throws -> Int {
        try await eidolon.turnTraces().filter { !$0.trace.prompts.isEmpty }.count
    }

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

        let segments = log.all.compactMap { event -> (Int, Int, String, String)? in
            if case let .segment(reply, index, ja, zh) = event {
                return (reply, index, ja, zh)
            }
            return nil
        }
        XCTAssertEqual(segments.map(\.2), ["もしもし", "聞こえてる"])
        XCTAssertEqual(segments.map(\.3), ["喂", "听得见"])
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

    /// The voice is given the words with her delivery cues, and paired tags only on the
    /// model that reads them (upstream `spoken_by`); what people see has no cues at all.
    func testTheVoiceGetsItsCuesAsTheModelReadsThem() async throws {
        let line = "[shyly] これは<whisper>内緒</whisper>だよ"
        for (model, spoken) in [
            ("s2.1-pro-free", "[shyly]これは内緒だよ"),
            ("drama-3", "[shyly]これは<whisper>内緒</whisper>だよ"),
        ] {
            let eidolon = try await installedEidolon()
            let recognition = FakeRecognition([.hang])
            let provider = ReplyScriptProvider([["<ja>\(line)</ja><zh>这个要保密</zh>"]])
            let synthesis = FakeSynthesis()
            let (session, log, _) = try await begin(
                on: eidolon,
                provider: provider,
                recognition: recognition,
                synthesis: synthesis,
                voiceModel: model
            )
            try await waitFor("listening") { await session.currentState() == .listening }
            recognition.say("ねえ")
            try await waitFor("the segment spoken") { synthesis.texts.count == 1 }
            XCTAssertEqual(synthesis.texts, [spoken], "voiced with \(model)")

            let captions = log.all.compactMap { event -> String? in
                if case let .segment(_, _, ja, _) = event { return ja }
                return nil
            }
            XCTAssertEqual(captions, ["これは内緒だよ"], "the caption has no cues")
            await session.hangUp()
        }
    }

    /// A segment's number is the reply it is said in (spec「通话事件」): every answer she
    /// gives is one reply, from 0, and its segments are numbered from 0 inside it.
    func testSegmentsCarryTheReplyTheyAreSaidIn() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
            ["<ja>三つ目</ja><zh>第三句</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("一度目")
        try await waitFor("her first reply") { segments(of: log).count == 2 }
        try await waitFor("listening after the first reply") {
            await session.currentState() == .listening
        }
        recognition.say("二度目")
        try await waitFor("her second reply") { segments(of: log).count == 3 }

        let said = segments(of: log)
        XCTAssertEqual(said.map(\.reply), [0, 0, 1])
        XCTAssertEqual(said.map(\.segment), [0, 1, 0])
        XCTAssertEqual(said.map(\.ja), ["一つ目", "二つ目", "三つ目"])
        await session.hangUp()
    }

    /// Each segment's voice says when it starts and stops playing, so her mouth moves with
    /// it (spec「通话事件」「立绘指令」). A segment starts after its subtitle is shown.
    func testSegmentsSayWhenTheirVoiceStartsAndStops() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("both segments said") { segments(of: log).count == 2 }
        try await waitFor("both segments played") {
            played(of: log).count == 4
        }

        XCTAssertEqual(
            played(of: log),
            ["start:0:0", "stop:0:0", "start:0:1", "stop:0:1"]
        )
        let events = log.all
        let subtitle = try XCTUnwrap(events.firstIndex { event in
            if case .segment = event { return true } else { return false }
        })
        let start = try XCTUnwrap(events.firstIndex { event in
            if case .segmentStarted = event { return true } else { return false }
        })
        XCTAssertLessThan(subtitle, start, "her subtitle is shown before her voice starts")
        await session.hangUp()
    }

    /// Each complete segment is judged on its own, the moment its Japanese and subtitle are
    /// in — not after its voice has played — and the result is reported for her stand with
    /// the reply and segment it is of (spec「情绪判断」).
    func testEachCompleteSegmentIsJudgedBeforeItsVoiceIsDone() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let judge = ScriptedEmotionJudge([
            SegmentEmotion(emotion: .happy, nod: .yes),
            SegmentEmotion(emotion: .shy),
        ])
        let playback = FakePlayback()
        playback.delay = .milliseconds(300)
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback,
            emotionJudge: judge
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("both segments judged") { emotions(of: log).count == 2 }
        try await waitFor("both segments played") { played(of: log).count == 4 }

        XCTAssertEqual(
            emotions(of: log).map(\.segment),
            [0, 1]
        )
        XCTAssertEqual(emotions(of: log).map(\.reply), [0, 0])
        XCTAssertEqual(emotions(of: log).map(\.emotion), [.happy, .shy])
        XCTAssertEqual(emotions(of: log).map(\.nod), [.yes, nil])

        // What the judge was told: the producer's words, the segments before it, and the
        // segment itself — Japanese with its cues, subtitle in Chinese.
        let asked = await judge.askedSegments()
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(asked[0].characterName, "櫻木真乃")
        XCTAssertEqual(asked[0].said, "ねえ")
        XCTAssertTrue(asked[0].before.isEmpty)
        XCTAssertEqual(asked[0].segment, SaidSegment(ja: "一つ目", zh: "第一句"))
        XCTAssertEqual(asked[1].before, [SaidSegment(ja: "一つ目", zh: "第一句")])
        XCTAssertEqual(asked[1].segment, SaidSegment(ja: "二つ目", zh: "第二句"))

        // Judged while the voice is still playing: the emotion is reported before the
        // first segment stops.
        let events = log.all
        let firstEmotion = try XCTUnwrap(events.firstIndex { event in
            if case .emotion = event { return true } else { return false }
        })
        let firstStop = try XCTUnwrap(events.firstIndex { event in
            if case .segmentStopped = event { return true } else { return false }
        })
        XCTAssertLessThan(firstEmotion, firstStop, "judging does not wait for the voice")
        await session.hangUp()
    }

    /// A judgement that fails or takes too long leaves no emotion at all, and the call
    /// goes on as if nothing had happened: same state, same conversation.
    func testAFailedJudgementLeavesTheCallAsItWas() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            emotionJudge: ScriptedEmotionJudge([nil])
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her answer") { segments(of: log).count == 1 }
        try await waitFor("the answer played") {
            log.all.contains { event in
                if case .segmentStopped = event { return true } else { return false }
            }
        }
        try await waitFor("listening again") { await session.currentState() == .listening }

        XCTAssertEqual(emotions(of: log).count, 0, "no emotion is invented")
        XCTAssertFalse(log.all.contains { event in
            if case .failed = event { return true } else { return false }
        })
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.messages.count, 2, "the judgement is not a message")
        await session.hangUp()
    }

    /// Hanging up cancels the judgements still out: nothing is reported after the end.
    func testHangingUpCancelsUnfinishedJudgements() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let judge = SlowEmotionJudge()
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            emotionJudge: judge
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the judgement started") { await judge.askedCount == 1 }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        try await waitFor("the judgement cancelled") { await judge.wasCancelled }
        XCTAssertEqual(emotions(of: log).count, 0)
    }

    /// The judgement stays out of the conversation and out of the turn's trace: only her
    /// stand hears of it.
    func testAJudgedEmotionStaysOutOfTheConversationAndTheTrace() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            emotionJudge: ScriptedEmotionJudge([SegmentEmotion(emotion: .surprised, nod: .no)])
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the emotion reported") { emotions(of: log).count == 1 }

        let conversation = try await eidolon.currentConversation(characterID: "mano")
        let conversationID = try XCTUnwrap(conversation?.id)
        XCTAssertEqual(conversation?.messages.count, 2)
        XCTAssertFalse(
            conversation?.messages.contains { ($0.text ?? "").contains("surprised") } ?? true
        )
        let timeline = try await eidolon.timeline(conversationID: conversationID)
        XCTAssertFalse(timeline.contains { ($0.text ?? "").contains("surprised") })
        await session.hangUp()
    }

    /// Her stand hears the call end, so the next call starts from scratch (spec「通话事件」):
    /// the call's last event is the ended state, after whatever was being said.
    func testTheCallSaysWhenItIsOver() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]]),
            recognition: recognition
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        try await waitFor("the ended event reaches the stream") {
            log.all.contains { event in
                if case .state(.ended(.hungUpByProducer)) = event { return true }
                return false
            }
        }
        XCTAssertEqual(log.all.last, .state(.ended(.hungUpByProducer)))
    }

    /// The second out-of-line turn of one call is the one she hangs up on (upstream
    /// `ends`). The conversation it happened in stays open: a call's hang-up is not the
    /// chat's ending.
    func testTwoOutOfLineTurnsMakeHerHangUpTheCall() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>"],
            ["<ja>い</ja><zh>呀</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 0, outOfLine: true))
        )
        let segments: @Sendable () -> Int = {
            log.all.filter { event in
                if case .segment = event { return true }
                return false
            }.count
        }

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ひどい")
        try await waitFor("the first answer") { segments() >= 1 }
        try await waitFor("listening after the first") { await session.currentState() == .listening }
        recognition.say("またひどい")

        try await waitFor("ended by her") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .sheHungUp(cooldownUntil: nil))
        XCTAssertEqual(reason?.message, "她挂断了电话。")
        // What she said last was played before the call ended.
        XCTAssertEqual(segments(), 2)

        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.ended, false)
        XCTAssertEqual(conversation?.messages.count, 4)
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, ["hung_up"], "only her own hang-up is written into the conversation")

        // The call takes no new turns once it has ended.
        recognition.say("もしもし")
        try await Task.sleep(for: .milliseconds(100))
        let after = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(after?.messages.count, 4)
    }

    /// A turn that takes her to the bottom begins a cooldown, and the hang-up carries when
    /// she is willing to talk again (upstream `cooldown_until`).
    func testACooldownHangUpCarriesItsDeadline() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES ('mano', 1, 0, ?, 0, NULL)
                    """,
                arguments: [Eidolon.timestamp(Date())]
            )
        }
        let recognition = FakeRecognition([.hang])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]]),
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 0, outOfLine: true))
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ひどい")
        try await waitFor("ended by her") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        guard case let .sheHungUp(until) = await session.currentStateIfEnded else {
            return XCTFail("expected her to hang up")
        }
        let deadline = try XCTUnwrap(until)
        XCTAssertGreaterThan(deadline, Date())

        // While she is cooling down, a new call is refused as the chat already is.
        do {
            _ = try await eidolon.beginCall(characterID: "mano", setup: setup(on: eidolon))
            XCTFail("a cooling character should not answer")
        } catch let error as EidolonError {
            guard case .coolingDown = error else {
                return XCTFail("expected coolingDown, got \(error)")
            }
        }
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

    /// Hanging up stops the voice; the producer's own hang-up is not a conversation event
    /// (upstream writes only her own hang-up), though the trace says why the call ended.
    func testHangingUpStopsTheVoiceWithoutWritingAnEvent() async throws {
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
        XCTAssertEqual(events, [])
        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(traces.first?.trace.degradation.first, "通话结束：hung_up_by_producer")
    }

    /// A call that connected and ended is a contact, whichever way it ended: "when did we
    /// last talk" counts it (upstream's `calls` table).
    func testTheEndOfACallIsKeptForLastContact() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her answer") {
            log.all.contains { event in
                if case .segment = event { return true }
                return false
            }
        }
        try await waitFor("listening again") { await session.currentState() == .listening }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }

        let characters = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT character_id FROM call_ends")
        }
        XCTAssertEqual(characters, ["mano"])
    }

    /// The settings' numbers become limits; 0 is no limit on that dimension, as upstream
    /// reads its environment (`config.py`'s `_limit`).
    func testZeroInTheSettingsMeansNoLimitOnThatDimension() {        XCTAssertEqual(
            CallLimits(minutes: 0, turns: 0),
            CallLimits(duration: nil, turns: nil)
        )
        XCTAssertEqual(
            CallLimits(minutes: 10, turns: 0),
            CallLimits(duration: .seconds(600), turns: nil)
        )
        XCTAssertEqual(
            CallLimits(minutes: 0, turns: 40),
            CallLimits(duration: nil, turns: 40)
        )
        XCTAssertEqual(
            CallLimits(minutes: 10, turns: 40),
            CallLimits(duration: .seconds(600), turns: 40)
        )
    }

    /// Upstream's defaults (`DEFAULT_CALL_MINUTES`, `DEFAULT_TURNS_PER_CALL`): ten minutes
    /// and forty of her turns.
    func testTheStandardLimitsAreUpstreamsDefaults() {
        XCTAssertEqual(CallLimits.standard.duration, .seconds(600))
        XCTAssertEqual(CallLimits.standard.turns, 40)
    }

    /// The timer waking with nothing being said ends the call, and both the record and the
    /// trace say why (upstream `call.py` checks `limit_reached` on the timer too).
    func testTheCallEndsAtTheTimeLimit() async throws {
        let eidolon = try await installedEidolon()
        let limit: Duration = .milliseconds(80)
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang]),
            limits: CallLimits(duration: limit, turns: nil)
        )
        try await waitFor("ended by time limit") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .durationLimit(limit: limit))

        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(traces.first?.trace.degradation.first, "通话结束：duration_limit")
        XCTAssertEqual(traces.first?.trace.degradation.count, 2)
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(conversation)
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, [], "the time limit is traced, not written into the conversation")
    }

    func testAVoiceServiceThatFailsBeforeATurnNeverConnects() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.failService])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition
        )

        try await waitFor("ended, never connected") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .notConnected(service: "Soniox", detail: "401 invalid api key"))
        XCTAssertEqual(reason?.message, "语音服务出了故障，通话没能接通")
        XCTAssertEqual(recognition.calls, 1, "a service failure is not reconnected")

        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(
            traces.first?.trace.degradation,
            ["通话结束：not_connected", "Soniox：401 invalid api key"]
        )
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(conversation)
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, [], "a call that never connected leaves no conversation event")
    }

    func testAVoiceServiceThatFailsMidCallBreaksItOff() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]]),
            recognition: recognition
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the answer") {
            log.all.contains { event in
                if case .segment = event { return true }
                return false
            }
        }
        recognition.failService()

        try await waitFor("ended, broke off") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .dropped(service: "Soniox", detail: "401 invalid api key"))
        XCTAssertEqual(reason?.message, "语音服务出了故障，通话中断了")
        XCTAssertEqual(recognition.calls, 1, "a service failure is not reconnected")

        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.ended, false)
        XCTAssertEqual(conversation?.messages.count, 2)
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, [], "a dropped call is traced, not written into the conversation")

        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(
            traces.first?.trace.degradation,
            ["通话结束：dropped", "Soniox：401 invalid api key"]
        )
    }

    func testTheTurnLimitEndsTheCallAfterThatManyOfHerTurns() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>"],
            ["<ja>い</ja><zh>呀</zh>"],
        ])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            limits: CallLimits(duration: nil, turns: 1)
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("ended by turns") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .turnLimit(turns: 1))
        XCTAssertEqual(
            reason?.message,
            "这次通话已经说了 1 轮了，先挂断啦。想接着聊可以重新拨打。"
        )
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, [], "the turn limit is traced, not written into the conversation")

        // The call takes no new turns once it has ended.
        recognition.say("もう一回")
        try await Task.sleep(for: .milliseconds(100))
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.ended, false)
        XCTAssertEqual(conversation?.messages.count, 2)
    }

    /// 0 and 0 in the settings: neither the timer nor the turn count ends the call, so a
    /// turn goes through and she listens again (upstream `call.py` with no limits).
    func testACallWithNoLimitsDoesNotEndAfterATurn() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]]),
            recognition: recognition,
            limits: CallLimits(minutes: 0, turns: 0)
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her answer") {
            log.all.contains { event in
                if case .segment = event { return true }
                return false
            }
        }
        try await waitFor("listening again after the turn") {
            if case .ended = await session.currentState() { return true }
            let conversation = try? await eidolon.currentConversation(characterID: "mano")
            return await session.currentState() == .listening && conversation != nil
        }
        let reason = await session.currentStateIfEnded
        XCTAssertNil(reason)
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.ended, false)
        XCTAssertEqual(conversation?.messages.count, 2)
        let events = try await eidolon.userQueue.read { db in
            try String.fetchAll(db, sql: "SELECT kind FROM conversation_events")
        }
        XCTAssertEqual(events, [])
    }

    /// A call that reaches both ends at once ends by the duration: she hangs up first,
    /// then the duration, then the turns (upstream `_should_end`).
    func testTheDurationComesBeforeTheTurnLimit() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let playback = FakePlayback()
        playback.delay = .milliseconds(200)
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]]),
            recognition: recognition,
            playback: playback,
            limits: CallLimits(duration: .milliseconds(50), turns: 1)
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("ended by time") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .durationLimit(limit: .milliseconds(50)))
    }

    /// She hanging up on the last turn wins over a duration that ran out during her
    /// speech: the call ends by her, with the time-up reason still on record as ignored.
    func testSheHangingUpWinsOverTheDurationLimit() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let playback = FakePlayback()
        playback.delay = .milliseconds(800)
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([
                ["<ja>あ</ja><zh>啊</zh>"],
                ["<ja>い</ja><zh>呀</zh>"],
            ]),
            recognition: recognition,
            playback: playback,
            judge: FixedJudge(judged: Judged(level: 0, outOfLine: true)),
            limits: CallLimits(duration: .milliseconds(1_200), turns: nil)
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ひどい")
        try await waitFor("listening after the first", timeout: .seconds(3)) {
            await session.currentState() == .listening
        }
        recognition.say("またひどい")

        try await waitFor("ended by her", timeout: .seconds(4)) {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .sheHungUp(cooldownUntil: nil))
    }

    func testAnEndedCallSaysInWordsWhatItEndedBy() {
        XCTAssertEqual(
            CallEnd.notConnected(service: "Soniox", detail: "401").message,
            "语音服务出了故障，通话没能接通"
        )
        XCTAssertEqual(
            CallEnd.dropped(service: "Soniox", detail: "401").message,
            "语音服务出了故障，通话中断了"
        )
        XCTAssertEqual(
            CallEnd.durationLimit(limit: .seconds(600)).message,
            "这次通话已经满 10 分钟了，先挂断啦。想接着聊可以重新拨打。"
        )
        XCTAssertEqual(
            CallEnd.turnLimit(turns: 40).message,
            "这次通话已经说了 40 轮了，先挂断啦。想接着聊可以重新拨打。"
        )
        XCTAssertEqual(CallEnd.sheHungUp(cooldownUntil: nil).message, "她挂断了电话。")
        XCTAssertEqual(CallEnd.hungUpByProducer.message, "通话已结束")

        // Minutes as Python's `{minutes:g}` writes them.
        XCTAssertEqual(CallEnd.minutes(.seconds(600)), "10")
        XCTAssertEqual(CallEnd.minutes(.seconds(90)), "1.5")
    }

    func testAnEndedCallKeepsTheBackendsReason() {
        XCTAssertEqual(
            CallEnd.notConnected(service: "Soniox", detail: "").reason,
            "not_connected"
        )
        XCTAssertEqual(CallEnd.dropped(service: "Soniox", detail: "").reason, "dropped")
        XCTAssertEqual(CallEnd.durationLimit(limit: .seconds(600)).reason, "duration_limit")
        XCTAssertEqual(CallEnd.turnLimit(turns: 40).reason, "turn_limit")
        XCTAssertEqual(CallEnd.sheHungUp(cooldownUntil: nil).reason, "she_hung_up")
        XCTAssertEqual(CallEnd.sheHungUp(cooldownUntil: Date()).reason, "cooldown")
        XCTAssertEqual(CallEnd.hungUpByProducer.reason, "hung_up_by_producer")
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

    func testTheMicrophoneIsStillHeardAfterAReconnect() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.fail, .hang])
        let provider = ReplyScriptProvider([["<ja>うん</ja><zh>嗯</zh>"]])
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("reconnecting") { log.states().contains(.reconnecting) }
        try await waitFor("listening again") {
            await session.currentState() == .listening
        }
        capture.send(0x05)
        try await waitFor("the new connection hears the microphone") {
            recognition.heard == [0x05]
        }
        await session.hangUp()
    }

    func testTheNextSegmentIsSynthesizedWhileTheCurrentOnePlays() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let timeline = Timeline()
        let synthesis = FakeSynthesis()
        synthesis.timeline = timeline
        let playback = FakePlayback()
        playback.timeline = timeline
        playback.delay = .milliseconds(300)
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("both segments played") { playback.audio.count == 2 }

        let entries = timeline.all
        let synthStart = try XCTUnwrap(entries.firstIndex(of: "synth-start:二つ目"))
        let playStart = try XCTUnwrap(entries.firstIndex(of: "play-start:一つ目"))
        let playEnd = try XCTUnwrap(entries.firstIndex(of: "play-end:一つ目"))
        XCTAssertGreaterThan(synthStart, playStart, "the next segment is prefetched while the first plays")
        XCTAssertLessThan(synthStart, playEnd, "the prefetch starts before the first segment finishes")
        XCTAssertEqual(playback.audio.map { String(decoding: $0, as: UTF8.self) }, ["一つ目", "二つ目"])
        await session.hangUp()
    }

    /// Her own hang-up is recorded where the call ended, after the last turn, and stays out
    /// of the prompt: the chat's history reads only turns.
    func testHerHangUpIsRecordedAfterTheLastTurnButStaysOutOfThePrompt() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>"],
            ["<ja>い</ja><zh>呀</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 0, outOfLine: true))
        )
        let segments: @Sendable () -> Int = {
            log.all.filter { event in
                if case .segment = event { return true }
                return false
            }.count
        }
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ひどい")
        try await waitFor("the first answer") { segments() >= 1 }
        try await waitFor("listening after the first") { await session.currentState() == .listening }
        recognition.say("またひどい")
        try await waitFor("ended by her") {
            if case .ended = await session.currentState() { return true }
            return false
        }

        let conversation = try await eidolon.currentConversation(characterID: "mano")
        let conversationID = try XCTUnwrap(conversation?.id)
        let events = try await eidolon.conversationEvents(conversationID: conversationID)
        XCTAssertEqual(events.map(\.kind), ["hung_up"])

        let record = try await eidolon.conversationRecord(conversationID: conversationID)
        XCTAssertEqual(record.count, 5, "the call event is not a turn")
        guard case let .event(event) = record.last else {
            return XCTFail("her hang-up is the last thing in the record")
        }
        XCTAssertEqual(event.kind, "hung_up")

        let timeline = try await eidolon.timeline(conversationID: conversationID)
        XCTAssertEqual(timeline.count, 4, "the call event is not a turn")
        XCTAssertFalse(timeline.contains { $0.text?.contains("hung_up") == true })
    }

    /// Coming back to the chat from a call reads the turns, the hang-up, the affinity and
    /// the cooldown it left, with nothing carried over from before the call
    /// (spec「返回刷新」).
    func testTheChatSeesWhatTheCallLeftWhenItComesBack() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES ('mano', 10.5, 0, ?, 0, NULL)
                    """,
                arguments: [Eidolon.timestamp(Date())]
            )
        }
        let before = try await eidolon.affinityStatus(characterID: "mano")
        XCTAssertEqual(before.tier, .cold)
        XCTAssertFalse(before.cooling)
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>"],
            ["<ja>い</ja><zh>呀</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 0, outOfLine: true))
        )
        let segments: @Sendable () -> Int = {
            log.all.filter { event in
                if case .segment = event { return true }
                return false
            }.count
        }
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ひどい")
        try await waitFor("the first answer") { segments() >= 1 }
        try await waitFor("listening after the first") { await session.currentState() == .listening }
        recognition.say("またひどい")
        try await waitFor("ended by her") {
            if case .ended = await session.currentState() { return true }
            return false
        }

        // What the chat page reads when it comes back: the turns, the event and the affinity.
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        let conversationID = try XCTUnwrap(conversation?.id)
        XCTAssertEqual(conversation?.messages.count, 4, "the call's turns are in the chat")
        let events = try await eidolon.conversationEvents(conversationID: conversationID)
        XCTAssertEqual(events.map(\.kind), ["hung_up"])
        let after = try await eidolon.affinityStatus(characterID: "mano")
        XCTAssertNotEqual(after, before, "the call's turns moved her")
        XCTAssertEqual(after.tier, .cold)
        XCTAssertTrue(after.cooling)
        XCTAssertNotNil(after.cooldownUntil)
    }

    func testThePrefetchedSegmentIsDroppedOnHangUp() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        synthesis.delay = .milliseconds(200)
        let playback = FakePlayback()
        playback.delay = .milliseconds(400)
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the first segment plays") { await session.currentState() == .speaking }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let stopped = capture.stopped
        XCTAssertTrue(stopped)
        XCTAssertTrue(playback.stopped)
        let played = playback.audio.count
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(playback.audio.count, played, "nothing is played after hanging up")
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
            if case let .segment(_, _, ja, _) = event { return ja }
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

    /// A line the recognizer heard that is over the limit is refused with the limit, and
    /// the call goes on as after any turn that could not be answered.
    func testTheCallRefusesAnOverLongLineWithTheLimit() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>うん</ja><zh>嗯</zh>"]])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say(String(repeating: "あ", count: 2001))
        try await waitFor("the rejection shown") {
            log.all.contains { event in
                guard case let .failed(message) = event else { return false }
                return message == "这句话太长了，最多 2000 字。"
            }
        }
        try await waitFor("listening again") { await session.currentState() == .listening }
        let messages = try await rowCount("messages", on: eidolon)
        XCTAssertEqual(messages, 0)
        await session.hangUp()
    }

    /// The call takes the history the settings name, as a text turn does.
    func testTheCallsHistoryTurnsReachTheTurn() async throws {
        let eidolon = try await installedEidolon()
        for turn in 1...2 {
            let earlier = RecordingChatProvider(
                chunks: ["<ja>返事\(turn)</ja><zh>回复\(turn)</zh>"]
            )
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "質問\(turn)",
                provider: earlier
            ) {}
        }

        let recognition = FakeRecognition([.hang])
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            historyTurns: 1
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("もしもし")
        try await waitFor("answered") {
            let answered = (try? await eidolon.currentConversation(characterID: "mano")) ?? nil
            return answered?.messages.count == 6
        }

        let prompt = try XCTUnwrap(provider.prompts.first)
        let history = Array(prompt.dropFirst(2).dropLast(2))
        XCTAssertEqual(history, [
            PromptMessage(.user, "質問2"),
            PromptMessage(.assistant, "<ja>返事2</ja><zh>回复2</zh>"),
        ])
        await session.hangUp()
    }

    /// Hanging up while she is still thinking drops the turn as upstream's `left` does:
    /// what the producer said is not written, she says nothing, and nothing moves.
    func testHangingUpWhileSheThinksLeavesNoTurn() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = RecordingChatProvider(
            chunks: ["<ja>うん</ja><zh>嗯</zh>"],
            delay: .seconds(5)
        )
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("thinking") { await session.currentState() == .thinking }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        // The cancelled turn has to notice; give it time to write anything it would.
        try await Task.sleep(for: .milliseconds(300))

        let messages = try await rowCount("messages", on: eidolon)
        let affinities = try await rowCount("affinities", on: eidolon)
        let traces = try await turnTraceCount(on: eidolon)
        XCTAssertEqual(messages, 0, "the user's line and her reply are not written")
        XCTAssertEqual(affinities, 0, "affinity does not move")
        XCTAssertEqual(traces, 0, "the dropped turn leaves no trace")
    }

    /// The same when she had already started saying the reply: a half-said answer is not
    /// a turn.
    func testHangingUpWhileSheIsMidReplyLeavesNoTurn() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = HeldReplyProvider()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her first words") { provider.hasSaidPart }
        try await Task.sleep(for: .milliseconds(100))
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        try await Task.sleep(for: .milliseconds(300))

        let messages = try await rowCount("messages", on: eidolon)
        let affinities = try await rowCount("affinities", on: eidolon)
        let traces = try await turnTraceCount(on: eidolon)
        XCTAssertEqual(messages, 0)
        XCTAssertEqual(affinities, 0)
        XCTAssertEqual(traces, 0)
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

    func testHerOwnVoiceFromTheSpeakerIsNotHeardAsTheProducer() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let timeline = Timeline()
        let playback = FakePlayback()
        playback.delay = .milliseconds(200)
        playback.timeline = timeline
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        capture.send(0x01)
        try await waitFor("the microphone reaches the recognizer") {
            recognition.heard == [0x01]
        }

        recognition.say("ねえ")
        try await waitFor("her voice starts") { timeline.index(of: "play-start:あ") != nil }
        XCTAssertFalse(capture.isHearing, "the microphone is closed while she speaks")
        capture.send(0xEE) // her own voice, back through the speaker
        try await waitFor("her voice ends") { timeline.index(of: "play-end:あ") != nil }
        try await waitFor("listening again") { await session.currentState() == .listening }
        XCTAssertTrue(capture.isHearing, "the microphone is open again once she is done")

        capture.send(0x02)
        try await waitFor("the microphone reaches the recognizer again") {
            recognition.heard == [0x01, 0x02]
        }
        XCTAssertEqual(recognition.heard, [0x01, 0x02], "her echo was never fed to the recognizer")
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
        // As upstream `voiced` has it: the cue stays, the whitespace after it does not.
        XCTAssertEqual(synthesis.texts, ["[shyly]あのね"])
        let captions = log.all.compactMap { event -> String? in
            if case let .segment(_, _, ja, _) = event { return ja }
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
