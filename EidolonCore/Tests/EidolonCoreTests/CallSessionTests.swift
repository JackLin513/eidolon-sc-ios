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
    /// What opening the microphone fails with: no permission, no input, a broken route.
    var startError: Error?
    var timeline: Timeline?
    private(set) var recoveries = 0
    /// Whether a recovery attempt opens the microphone: false is an input that stays shut.
    var recoverable = true
    private var disruption: AsyncStream<Void>.Continuation?

    func start() async throws {
        if let startError { throw startError }
        markStarted()
    }

    func stop() async {
        timeline?.add("mic-stop")
        markStopped()
    }

    func recover() async -> Bool {
        markRecovery()
        return isRecoverable()
    }

    private func isRecoverable() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recoverable
    }

    func disruptions() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock()
            disruption = continuation
            lock.unlock()
        }
    }

    /// The system taking the microphone away, as the capture reports it.
    func disrupt() {
        lock.lock()
        let disruption = self.disruption
        lock.unlock()
        disruption?.yield(())
    }

    private func markRecovery() {
        lock.lock()
        recoveries += 1
        lock.unlock()
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
    enum Step: Sendable {
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
    /// How long a connection takes to be ready, as a network handshake would.
    var connectDelay: Duration?
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
            let delay = connectDelay
            let task = Task {
                if let delay { try? await Task.sleep(for: delay) }
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }
                switch step {
                case let .events(events):
                    self.attach(continuation)
                    continuation.yield(.connected)
                    self.drainBacklog(continuation)
                    for event in events { continuation.yield(event) }
                case .fail:
                    continuation.finish(throwing: URLError(.networkConnectionLost))
                case .failService:
                    continuation.finish(throwing: SonioxError.service("401", "invalid api key"))
                case .hang:
                    self.attach(continuation)
                    continuation.yield(.connected)
                    self.drainBacklog(continuation)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                collector.cancel()
            }
        }
    }

    /// The live connection dropping as a network does, without the service failing.
    func drop() {
        lock.lock()
        let live = self.live
        self.live = nil
        lock.unlock()
        live?.finish(throwing: URLError(.networkConnectionLost))
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
        lock.unlock()
    }

    /// What was said before the connection was ready, delivered once it is.
    private func drainBacklog(
        _ continuation: AsyncThrowingStream<SpeechEvent, Error>.Continuation
    ) {
        lock.lock()
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
    /// The voice service itself refusing to work for a segment, as Fish Audio does with a
    /// refused key, an account out of credit, or a model it does not serve.
    var serviceFailure: (String) -> VoiceServiceFailure? = { _ in nil }
    /// Whether segments are voiced at all; false is the app's subtitles-only stand-in when
    /// no voice key is filled in.
    var providesVoice = true
    var delay: Duration?
    var timeline: Timeline?

    var texts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return spoken
    }

    func synthesize(_ text: String, voice: CallVoice) async throws -> Data {
        timeline?.add("synth-start:\(text)")
        let (fails, failure, delay) = record(text)
        if let delay { try await Task.sleep(for: delay) }
        if let failure { throw FakeSynthesisFailure.service(failure) }
        if fails { throw URLError(.cannotConnectToHost) }
        timeline?.add("synth-end:\(text)")
        return Data(text.utf8)
    }

    /// As the real Fish Audio adapter does: only an error of the service itself is one.
    func failure(_ error: any Error) -> VoiceServiceFailure? {
        guard case let FakeSynthesisFailure.service(failure) = error else { return nil }
        return failure
    }

    private func record(_ text: String) -> (Bool, VoiceServiceFailure?, Duration?) {
        lock.lock()
        defer { lock.unlock() }
        spoken.append(text)
        return (failing(text), serviceFailure(text), delay)
    }
}

enum FakeSynthesisFailure: Error {
    case service(VoiceServiceFailure)
}

final class FakePlayback: AudioPlayback, @unchecked Sendable {
    private let lock = NSLock()
    private var played: [Data] = []
    private(set) var stopped = false
    /// How many times the segment now playing was cut short, as 只看文字 does without
    /// ending the call.
    private(set) var silences = 0
    var delay: Duration?
    var timeline: Timeline?
    /// The segment being played waits here until it is cut: a test can turn 只看文字 on
    /// while the segment is still under way.
    var playsUntilSilenced = false
    private var held: CheckedContinuation<Void, Never>?

    var audio: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return played
    }

    func play(_ audio: Data) async throws {
        let text = String(decoding: audio, as: UTF8.self)
        timeline?.add("play-start:\(text)")
        if playsUntilSilenced {
            await withCheckedContinuation { continuation in
                hold(continuation)
            }
        } else if let delay {
            try await Task.sleep(for: delay)
        }
        record(audio)
        timeline?.add("play-end:\(text)")
    }

    func stop() async {
        timeline?.add("playback-stop")
        markStopped()
        resumeHeld()
    }

    /// As the real playback: the segment playing stops where it is, and the call goes on.
    func silence() async {
        timeline?.add("playback-silence")
        markSilence()
        resumeHeld()
    }

    private func markSilence() {
        lock.lock()
        silences += 1
        lock.unlock()
    }

    private func hold(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        held = continuation
        lock.unlock()
    }

    private func resumeHeld() {
        lock.lock()
        let continuation = held
        held = nil
        lock.unlock()
        continuation?.resume()
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

/// 铃声 as the call holds it: how much of its first loop is left, and whether it was stopped.
final class FakeRingback: Ringback, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Duration
    private var stopped = false
    var timeline: Timeline?

    init(remaining: Duration = .zero) {
        self.remaining = remaining
    }

    func left() -> Duration {
        lock.lock()
        defer { lock.unlock() }
        return stopped ? .zero : remaining
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        timeline?.add("ring-stop")
    }
}

/// The phone's own sounds, as the call asks for them.
final class FakeTones: CallTones, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    /// Whether `ring()` can play at all.
    var ringAvailable = true
    /// The ring it starts when one plays.
    var ringback: FakeRingback?
    /// Whether `hangUp()` waits to be released, as a tone still sounding would.
    var hangsUpUntilReleased = false
    var timeline: Timeline?

    func ring() -> (any Ringback)? {
        timeline?.add("tone-ring")
        return ringAvailable ? ringback : nil
    }

    func connect() {
        timeline?.add("tone-connect")
    }

    func silence() {
        timeline?.add("tone-silence")
    }

    func hangUp() async {
        timeline?.add("tone-hang-up-start")
        if waitsBeforeFinishing {
            await withCheckedContinuation { continuation in
                hold(continuation)
            }
        }
        timeline?.add("tone-hang-up-end")
    }

    /// Lets the hang-up tone finish.
    func releaseHangUp() {
        lock.lock()
        let gate = gate
        self.gate = nil
        lock.unlock()
        gate?.resume()
    }

    private var waitsBeforeFinishing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hangsUpUntilReleased
    }

    private func hold(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        gate = continuation
        lock.unlock()
    }
}

/// A chat provider answering each turn with the next scripted reply.
final class ReplyScriptProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[String]]
    private var asked = 0
    let failure: Error?

    init(_ replies: [[String]], failure: Error? = nil) {
        self.replies = replies
        self.failure = failure
    }

    /// How many turns were asked of her, in order: one per reply she gives.
    var turnsAsked: Int {
        lock.lock()
        defer { lock.unlock() }
        return asked
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        asked += 1
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
    private var lines: [String] = []

    var hasSaidPart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return said
    }

    /// The producer's line each turn was asked with, in order.
    var saidTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("<ja>まだ話して</ja><zh>还在说</zh>")
            lock.lock()
            said = true
            lines.append(messages.last(where: { $0.role == .user })?.content ?? "")
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

/// A chat provider that says two segments and then waits to be cancelled: her first segment
/// is voiced while the turn is still being made, before it is recorded.
final class HeldHalfReplyProvider: ChatProvider, @unchecked Sendable {
    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("<ja>一つ目</ja><zh>第一句</zh>")
            continuation.yield("<ja>二つ目</ja><zh>第二句</zh>")
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

/// The microphone notices in order, including the nil that takes one away.
private func micNotices(of log: EventLog) -> [MicNotice?] {
    log.all.flatMap { event -> [MicNotice?] in
        guard case let .micNotice(notice) = event else { return [] }
        return [notice]
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
        capture: FakeCapture = FakeCapture(),
        synthesis: FakeSynthesis = FakeSynthesis(),
        playback: FakePlayback = FakePlayback(),
        judge: (any JudgeProvider)? = nil,
        emotionJudge: (any SegmentEmotionJudge)? = nil,
        limits: CallLimits = .standard,
        historyTurns: Int = 20,
        connectTimeout: Duration = .seconds(30),
        tones: any CallTones = SilentTones(),
        voiceModel: String = "s2.1-pro-free",
        prepare: (@Sendable (CallSession) async -> Void)? = nil
    ) async throws -> (CallSession, EventLog, FakeCapture) {
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
            reconnectDelay: .milliseconds(10),
            connectTimeout: connectTimeout,
            tones: tones
        )
        let session = try await eidolon.beginCall(characterID: "mano", setup: setup)
        let log = EventLog()
        let stream = session.events()
        Task.detached {
            for await event in stream { log.append(event) }
        }
        // What the app sets while dialing, before the call connects.
        if let prepare { await prepare(session) }
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

    /// Every ending after dialing plays the hang-up tone, and exactly once (spec #35).
    private func assertOneHangUpTone(_ timeline: Timeline) async throws {
        try await waitFor("the hang-up tone") { timeline.index(of: "tone-hang-up-start") != nil }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            timeline.all.filter { $0 == "tone-hang-up-start" }.count, 1,
            "exactly one hang-up tone"
        )
    }

    private func states(_ log: EventLog) -> [CallState] { log.states() }

    /// How many rows `table` holds in the user library; the table names come from the
    /// tests themselves, never from what is being tested.
    /// Typing with no turn under way is a turn of its own, recorded as a call turn.
    func testTypingWithNoTurnUnderWayStartsAndRecordsOne() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>こんばんは</ja><zh>晚上好</zh>"],
        ])
        let playback = FakePlayback()
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        await session.say("こんばんは")

        try await waitFor("her answer played") {
            playback.audio == [Data("こんばんは".utf8)]
        }
        XCTAssertTrue(log.all.contains(.typed("こんばんは")))
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.messages.map(\.role), ["user", "character"])
        XCTAssertEqual(conversation?.messages.first?.text, "こんばんは")
        let typed = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT typed FROM messages WHERE role = 'character'") ?? -1
        }
        XCTAssertEqual(typed, 0, "a typed line in a call is still a call turn")
        await session.hangUp()
    }

    /// Typing works while the microphone is muted: mute is about her hearing the voice.
    func testTypingWorksWhileTheMicrophoneIsMuted() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>はい</ja><zh>好</zh>"],
        ])
        let playback = FakePlayback()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        await session.setMuted(true)

        await session.say("聞こえる")

        try await waitFor("her answer played") { playback.audio.count == 1 }
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.messages.first?.text, "聞こえる")
        await session.hangUp()
    }

    /// Typing while she is still thinking is a follow-on: the reply being written leaves no
    /// trace, and the turn is answered again with the typed line joined on.
    func testTypingBeforeSheIsHeardMergesIntoTheTurnAsAFollowOn() async throws {
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

        await session.say("もう一度")

        try await waitFor("the joined turn") { provider.saidTexts.count == 2 }
        XCTAssertEqual(provider.saidTexts, ["ねえ", "ねえ\nもう一度"])
        let messages = try await rowCount("messages", on: eidolon)
        XCTAssertEqual(messages, 0, "the dropped reply is not written")
        await session.hangUp()
    }

    /// Once she has started a complete segment, typing interrupts her: the complete segment
    /// is kept, and the typed line starts a new turn.
    func testTypingAfterSheHasSaidASegmentInterruptsAndKeepsIt() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = HeldHalfReplyProvider()
        let playback = FakePlayback()
        playback.playsUntilSilenced = true
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her first segment starts") {
            log.all.contains(.segmentStarted(reply: 0, segment: 0))
        }

        await session.say("割り込み")

        try await waitFor("the typed turn starts") {
            log.all.contains(.segmentStarted(reply: 1, segment: 0))
        }
        XCTAssertGreaterThanOrEqual(playback.silences, 1)
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        let messages = conversation?.messages ?? []
        XCTAssertEqual(messages.map(\.role), ["user", "character"])
        XCTAssertEqual(messages.first?.text, "ねえ")
        XCTAssertEqual(
            messages.last?.segments.map(\.ja), ["一つ目"],
            "only the complete segment is kept"
        )
        await session.hangUp()
    }

    /// Typed while still dialing, the line waits for the call to enter.
    func testTypingWhileDialingWaitsForTheCallToEnter() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        recognition.connectDelay = .seconds(1)
        let provider = ReplyScriptProvider([
            ["<ja>もしもし</ja><zh>喂</zh>"],
        ])
        let playback = FakePlayback()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )

        await session.say("もしもし")
        XCTAssertEqual(provider.turnsAsked, 0, "nothing is answered before the call enters")

        try await waitFor("the queued line answered") { playback.audio.count == 1 }
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.messages.first?.text, "もしもし")
        await session.hangUp()
    }

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
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 0, outOfLine: true)),
            tones: tones
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
        try await assertOneHangUpTone(timeline)
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

    /// Hanging up stops her voice before it closes the microphone, and the segment playing
    /// stops where it is rather than finishing (upstream hangs up the pipeline, which stops
    /// the speaker at once).
    func testHangingUpStopsTheVoiceBeforeTheMicrophone() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let timeline = Timeline()
        let capture = FakeCapture()
        capture.timeline = timeline
        let playback = FakePlayback()
        playback.delay = .seconds(5)
        playback.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            capture: capture,
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
        try await waitFor("the microphone released") { capture.stopped }

        let entries = timeline.all
        let voiceStopped = try XCTUnwrap(entries.firstIndex(of: "playback-stop"))
        let micClosed = try XCTUnwrap(entries.firstIndex(of: "mic-stop"))
        XCTAssertLessThan(voiceStopped, micClosed, "the voice stops before the microphone closes")
        XCTAssertTrue(playback.audio.isEmpty, "the segment playing is cut off, not finished")
    }

    // MARK: - The phone's own sounds (spec #35)

    /// 拨号后立刻响铃，上一通残留的声音先被掐掉；铃声响起时她听不见用户。
    func testDialingRingsAndClosesTheMicrophoneToHer() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.ringback = FakeRingback(remaining: .seconds(5))
        tones.timeline = timeline
        let capture = FakeCapture()
        capture.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            capture: capture,
            tones: tones
        )

        try await waitFor("the ring going out") { timeline.index(of: "tone-ring") != nil }
        XCTAssertEqual(timeline.all.first, "tone-silence", "a tone left over from the last call is cut first")
        XCTAssertFalse(capture.isHearing, "she cannot hear the producer while the phone rings")
        XCTAssertNil(timeline.index(of: "tone-connect"))
        let dialing = await session.currentState()
        XCTAssertEqual(dialing, .connecting)

        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
    }

    /// 接通时第一遍铃声还没响完：界面还是「正在拨号」，她听不见；响完才放接通音、
    /// 打开麦克风、进入聆听。
    func testTheCallWaitsOutTheFirstRingLoopBeforeEntering() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.ringback = FakeRingback(remaining: .milliseconds(400))
        tones.timeline = timeline
        let capture = FakeCapture()
        capture.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            capture: capture,
            tones: tones
        )

        try await waitFor("the ring going out") { timeline.index(of: "tone-ring") != nil }
        try await Task.sleep(for: .milliseconds(100))
        let stillDialing = await session.currentState()
        XCTAssertEqual(stillDialing, .connecting)
        XCTAssertFalse(capture.isHearing)
        XCTAssertNil(timeline.index(of: "tone-connect"))

        try await waitFor("listening") { await session.currentState() == .listening }
        XCTAssertTrue(capture.isHearing)
        let ring = try XCTUnwrap(timeline.index(of: "tone-ring"))
        let connect = try XCTUnwrap(timeline.index(of: "tone-connect"))
        XCTAssertLessThan(ring, connect, "the connect tone comes after the ring")

        await session.hangUp()
    }

    /// 铃声已经完整响过一遍：接通时不再等。
    func testAFinishedRingEntersAtOnce() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.ringback = FakeRingback(remaining: .zero)
        tones.timeline = timeline
        let capture = FakeCapture()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            capture: capture,
            tones: tones
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        XCTAssertTrue(capture.isHearing)
        XCTAssertNotNil(timeline.index(of: "tone-connect"))

        await session.hangUp()
    }

    /// 铃声放不出来：不等，也不放接通音，通话照常进行。
    func testACallWhoseRingCannotPlayEntersAtOnce() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.ringAvailable = false
        tones.timeline = timeline
        let capture = FakeCapture()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            capture: capture,
            tones: tones
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        XCTAssertTrue(capture.isHearing)
        XCTAssertNil(timeline.index(of: "tone-connect"))

        await session.hangUp()
    }

    /// 挂断音恰好放一次；结束状态在它放完之前已经可见，麦克风也还被这通电话占着。
    func testTheEndShowsBeforeTheHangUpToneFinishes() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.ringAvailable = false
        tones.hangsUpUntilReleased = true
        tones.timeline = timeline
        let capture = FakeCapture()
        capture.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            capture: capture,
            tones: tones
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        // The hang-up itself waits for the tone, which this fake holds until the test lets
        // it go: the ending has to show before then.
        let hangingUp = Task { await session.hangUp() }
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        XCTAssertNotNil(timeline.index(of: "tone-hang-up-start"))
        XCTAssertNil(timeline.index(of: "tone-hang-up-end"))
        XCTAssertFalse(capture.stopped, "the microphone is held until the tone is done")

        tones.releaseHangUp()
        try await waitFor("the microphone released") { capture.stopped }
        await hangingUp.value
        let tone = try XCTUnwrap(timeline.index(of: "tone-hang-up-end"))
        let mic = try XCTUnwrap(timeline.index(of: "mic-stop"))
        XCTAssertLessThan(tone, mic)
        XCTAssertEqual(
            timeline.all.filter { $0 == "tone-hang-up-start" }.count, 1,
            "exactly one hang-up tone"
        )
    }

    /// 麦克风打不开也是拨号之后的结束：放一次挂断音。
    func testAMicrophoneThatWillNotOpenStillGetsTheHangUpTone() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let capture = FakeCapture()
        capture.startError = NSError(domain: "test", code: 1)
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            capture: capture,
            tones: tones
        )

        guard case let .ended(reason) = await session.currentState() else {
            return XCTFail("the call did not end")
        }
        guard case .micDenied = reason else {
            return XCTFail("not a microphone failure: \(reason)")
        }
        XCTAssertNotNil(timeline.index(of: "tone-hang-up-start"))
    }

    /// 等铃期间挂断：按已接通的通话结束（原因不是「没接通」），也照样有挂断音。
    func testHangingUpWhileWaitingForTheRingCountsAsConnected() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.ringback = FakeRingback(remaining: .seconds(5))
        tones.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([[]]),
            recognition: FakeRecognition([.hang]),
            tones: tones
        )

        try await waitFor("the ring going out") { timeline.index(of: "tone-ring") != nil }
        try await Task.sleep(for: .milliseconds(100))
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }

        guard case let .ended(reason) = await session.currentState() else {
            return XCTFail("the call did not end")
        }
        XCTAssertEqual(reason, .hungUpByProducer)
        XCTAssertNotNil(timeline.index(of: "tone-hang-up-start"))
    }

    /// 从未开始拨号：没有铃声，也没有挂断音。
    func testACallThatNeverStartedMakesNoSound() async throws {
        let eidolon = try await installedEidolon()
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let setup = CallSetup(
            capture: FakeCapture(),
            playback: FakePlayback(),
            recognition: FakeRecognition(),
            synthesis: FakeSynthesis(),
            voiceModel: "s2.1-pro-free",
            provider: ReplyScriptProvider([[]]),
            tones: tones
        )
        let session = try await eidolon.beginCall(characterID: "mano", setup: setup)

        await session.hangUp()
        XCTAssertTrue(timeline.all.isEmpty)
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
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang]),
            limits: CallLimits(duration: limit, turns: nil),
            tones: tones
        )
        try await waitFor("ended by time limit") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .durationLimit(limit: limit))
        try await assertOneHangUpTone(timeline)

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

    /// The microphone failing is its own ending, not a voice service's: the producer is told
    /// they cannot use the microphone (upstream `mic_denied`), and the recognizer never runs.
    func testAMicrophoneThatWillNotOpenIsItsOwnEnding() async throws {
        let eidolon = try await installedEidolon()
        let capture = FakeCapture()
        capture.startError = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "没有麦克风权限，请在系统设置里允许"]
        )
        let recognition = FakeRecognition([.hang])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition,
            capture: capture
        )

        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .micDenied(detail: "没有麦克风权限，请在系统设置里允许"))
        XCTAssertEqual(reason?.reason, "mic_denied")
        XCTAssertEqual(
            reason?.message,
            "用不了麦克风。没有允许使用麦克风，或者找不到麦克风。在系统设置里允许后，再拨一次。"
        )
        XCTAssertEqual(recognition.calls, 0, "the call never listens without a microphone")
        let contacts = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_ends") ?? 0
        }
        XCTAssertEqual(contacts, 0, "a call that never connected is no contact")

        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(
            traces.first?.trace.degradation,
            ["通话结束：mic_denied", "麦克风：没有麦克风权限，请在系统设置里允许"]
        )
    }

    func testAVoiceServiceThatFailsBeforeATurnNeverConnects() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.failService])
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition,
            tones: tones
        )

        try await waitFor("ended, never connected") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .notConnected(service: "Soniox", detail: "401 invalid api key"))
        XCTAssertEqual(reason?.message, "语音服务出了故障，通话没能接通")
        try await assertOneHangUpTone(timeline)
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
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]]),
            recognition: recognition,
            tones: tones
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
        try await assertOneHangUpTone(timeline)
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

    /// Fish Audio failing as a service ends the call as Soniox does: before her first turn
    /// is recorded the call never connected (upstream `service_failed`), and the producer is
    /// told so instead of a call that looks fine but has only subtitles.
    func testFishAudioFailingBeforeHerFirstTurnNeverConnects() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let synthesis = FakeSynthesis()
        synthesis.serviceFailure = { _ in
            VoiceServiceFailure(service: "Fish Audio", detail: "401 unauthorized")
        }
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: HeldHalfReplyProvider(),
            recognition: recognition,
            synthesis: synthesis
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("ended, never connected") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(
            reason,
            .notConnected(service: "Fish Audio", detail: "401 unauthorized")
        )
        XCTAssertEqual(reason?.message, "语音服务出了故障，通话没能接通")
        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(
            traces.first?.trace.degradation,
            ["通话结束：not_connected", "Fish Audio：401 unauthorized"]
        )
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNil(conversation, "the turn never finished, so nothing was written")
    }

    /// Once a turn is recorded the same failure breaks the call off instead, and nothing
    /// more is voiced (upstream `dropped`).
    func testFishAudioFailingMidCallBreaksItOff() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let synthesis = FakeSynthesis()
        synthesis.serviceFailure = { text in
            text.contains("だめ")
                ? VoiceServiceFailure(service: "Fish Audio", detail: "402 insufficient credit")
                : nil
        }
        let playback = FakePlayback()
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>"],
            ["<ja>だめ</ja><zh>不行</zh>", "<ja>まだ</ja><zh>还有</zh>"],
        ])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the first turn is said") { playback.audio.count == 1 }
        recognition.say("もう一回")
        try await waitFor("ended, broke off") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(
            reason,
            .dropped(service: "Fish Audio", detail: "402 insufficient credit")
        )
        XCTAssertEqual(reason?.message, "语音服务出了故障，通话中断了")
        XCTAssertEqual(
            playback.audio,
            [Data("あ".utf8)],
            "the segments after the failure are not voiced"
        )
        let traces = try await eidolon.turnTraces()
        XCTAssertEqual(
            traces.first?.trace.degradation,
            ["通话结束：dropped", "Fish Audio：402 insufficient credit"]
        )
    }

    func testTheTurnLimitEndsTheCallAfterThatManyOfHerTurns() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>"],
            ["<ja>い</ja><zh>呀</zh>"],
        ])
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            limits: CallLimits(duration: nil, turns: 1),
            tones: tones
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
        try await assertOneHangUpTone(timeline)
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
            CallEnd.micDenied(detail: "没有权限").message,
            "用不了麦克风。没有允许使用麦克风，或者找不到麦克风。在系统设置里允许后，再拨一次。"
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
        XCTAssertEqual(CallEnd.micDenied(detail: "没有权限").reason, "mic_denied")
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

    /// A websocket can die while the app is suspended without ever reporting it: the call
    /// looks connected and the microphone is open, but nothing it hears arrives. Coming back
    /// to the foreground must not keep the old connection.
    func testComingBackToTheForegroundReconnectsEvenIfTheOldConnectionNeverSaidItDied() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang, .hang])
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        XCTAssertEqual(recognition.calls, 1)

        await session.appDidBecomeActive()

        try await waitFor("a fresh connection") { recognition.calls == 2 }
        await session.hangUp()
    }

    /// A connection becoming ready while nothing of hers is playing means the microphone
    /// should be open; a system interruption can leave it shut, with no way to know.
    func testAReadyConnectionOpensTheMicrophoneLeftShut() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang, .hang])
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        await capture.setHearing(false)

        await session.appDidBecomeActive()

        try await waitFor("the microphone open again") { capture.isHearing }
        await session.hangUp()
    }

    /// Her line card moves with her voice, not with her text: the next segment's caption is
    /// not shown until the segment before it has finished being said (upstream
    /// `linePacing.ts`, spec「通话层的台词卡按她说话的节奏换段」).
    func testTheLineCardFollowsTheVoice() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let playback = FakePlayback()
        playback.delay = .milliseconds(200)
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("both segments played") { playback.audio.count == 2 }

        let events = log.all
        let firstShown = try XCTUnwrap(events.firstIndex(of: .segment(
            reply: 0, segment: 0, ja: "一つ目", zh: "第一句"
        )))
        let firstStarted = try XCTUnwrap(events.firstIndex(of: .segmentStarted(reply: 0, segment: 0)))
        XCTAssertEqual(firstShown + 1, firstStarted, "the card turns as the voice starts")
        let firstStopped = try XCTUnwrap(events.firstIndex(of: .segmentStopped(reply: 0, segment: 0)))
        let secondShown = try XCTUnwrap(events.firstIndex(of: .segment(
            reply: 0, segment: 1, ja: "二つ目", zh: "第二句"
        )))
        XCTAssertGreaterThan(
            secondShown,
            firstStopped,
            "the second line is not shown before the first has finished being said"
        )
        await session.hangUp()
    }

    /// Without a voice at all (no key filled in) her words are subtitles as they come: every
    /// segment shows, none is held back for a voice that will never play (ADR-0011).
    func testASubtitlesOnlyCallShowsEverySegment() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        synthesis.providesVoice = false
        synthesis.failing = { _ in true }
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
        try await waitFor("both lines shown") { segments(of: log).count == 2 }
        XCTAssertEqual(segments(of: log).map(\.ja), ["一つ目", "二つ目"])
        XCTAssertTrue(playback.audio.isEmpty)
        await session.hangUp()
    }

    /// The call is connected once the recognizer can hear, not when the microphone opens:
    /// until then it is still connecting, and it says so on the screen (spec「接通」).
    func testTheCallConnectsOnlyWhenTheRecognizerCanHear() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        recognition.connectDelay = .milliseconds(300)
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition
        )

        try await Task.sleep(for: .milliseconds(120))
        let early = await session.currentState()
        XCTAssertEqual(early, .connecting, "the microphone is open, but nobody can hear yet")
        XCTAssertFalse(states(log).contains(.listening))

        try await waitFor("connected when the recognizer is") {
            await session.currentState() == .listening
        }
        await session.hangUp()
    }

    /// The call is given up when the recognizer never becomes ready: the producer would
    /// otherwise talk into a screen that says it is listening (upstream `CONNECT_TIMEOUT`).
    func testARecognitionThatNeverConnectsTimesOut() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        recognition.connectDelay = .seconds(10)
        let timeline = Timeline()
        let tones = FakeTones()
        tones.timeline = timeline
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition,
            connectTimeout: .milliseconds(150),
            tones: tones
        )

        try await waitFor("given up") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .notConnected(service: "识别", detail: "连接超时"))
        try await assertOneHangUpTone(timeline)
        XCTAssertTrue(capture.stopped, "the microphone is closed when the call is given up")
    }

    /// The time limit counts from when the recognizer can hear, as the clock on the screen
    /// does: a slow connection never eats into the call's length.
    func testTheDurationLimitCountsFromWhenRecognitionIsReady() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        recognition.connectDelay = .milliseconds(300)
        let limit: Duration = .milliseconds(300)
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition,
            limits: CallLimits(duration: limit, turns: nil)
        )

        // The connection at 300 ms, the limit 300 ms after it: at 450 ms it is still going.
        try await Task.sleep(for: .milliseconds(450))
        var ended = false
        if case .ended = await session.currentState() { ended = true }
        XCTAssertFalse(ended, "the limit did not start before the connection")

        try await waitFor("ended by the limit after connecting") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        let reason = await session.currentStateIfEnded
        XCTAssertEqual(reason, .durationLimit(limit: limit))
    }

    /// A connection dropping while she speaks does not put「重连中…」over her state: the
    /// screen keeps saying she is speaking, and listening comes back once she is done.
    func testADroppedConnectionDoesNotHideThatSheIsSpeaking() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang, .hang])
        let provider = ReplyScriptProvider([["<ja>あ</ja><zh>啊</zh>"]])
        let playback = FakePlayback()
        playback.delay = .milliseconds(500)
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("speaking") { await session.currentState() == .speaking }
        recognition.drop()

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(states(log).contains(.reconnecting), "her state is not covered")
        let whileSpeaking = await session.currentState()
        XCTAssertEqual(whileSpeaking, .speaking)
        XCTAssertEqual(recognition.calls, 2, "the recognizer is connected again meanwhile")

        try await waitFor("listening after her segment") {
            await session.currentState() == .listening
        }
        await session.hangUp()
    }

    /// The same while she is thinking: the reconnect happens behind the scenes.
    func testADroppedConnectionDoesNotHideThatSheIsThinking() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang, .hang])
        let provider = RecordingChatProvider(
            chunks: ["<ja>あ</ja><zh>啊</zh>"],
            delay: .milliseconds(500)
        )
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("thinking") { await session.currentState() == .thinking }
        recognition.drop()

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(states(log).contains(.reconnecting), "her state is not covered")
        let whileThinking = await session.currentState()
        XCTAssertEqual(whileThinking, .thinking)
        await session.hangUp()
    }

    func testATurnThatChangesHerAffinityIsAnnouncedInTheCall() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>うん</ja><zh>嗯</zh>"]]),
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 4))
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        recognition.say("ありがとう")
        try await waitFor("the affinity cue") {
            log.all.contains { if case .affinity = $0 { return true }; return false }
        }
        let change = log.all.compactMap { event -> AffinityChange? in
            if case let .affinity(change) = event { return change }
            return nil
        }.first
        XCTAssertEqual(change?.up, true)
        XCTAssertEqual(change?.tier, .trust)
        await session.hangUp()
    }

    func testACancelledTurnDoesNotAnnounceAnAffinityChange() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: SilentChatProvider(),
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 4))
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        recognition.say("ありがとう")
        try await waitFor("thinking") { await session.currentState() == .thinking }
        await session.hangUp()
        try await waitFor("the end") {
            log.states().contains { if case .ended = $0 { return true }; return false }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(log.all.contains { if case .affinity = $0 { return true }; return false })
    }

    func testANeutralCallTurnHasNoAffinityCue() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([["<ja>うん</ja><zh>嗯</zh>"]]),
            recognition: recognition,
            judge: FixedJudge(judged: Judged(level: 2))
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        recognition.say("ふうん")
        try await waitFor("her reply") { !segments(of: log).isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(log.all.contains { if case .affinity = $0 { return true }; return false })
        await session.hangUp()
    }

    func testTheMicrophoneNoticeSaysWhatHappened() {
        XCTAssertEqual(MicNotice.lost.message, "麦克风断开了，也没有别的麦克风可用")
    }

    /// Coming back from a phone call, Siri or the background asks the microphone to open
    /// again; after the call ended there is nothing to recover.
    func testRecoveringAudioAsksTheMicrophoneToComeBack() async throws {
        let eidolon = try await installedEidolon()
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        await session.recoverAudio()
        XCTAssertEqual(capture.recoveries, 1)

        await session.hangUp()
        await session.recoverAudio()
        XCTAssertEqual(capture.recoveries, 1, "a call that ended has no microphone to recover")
    }

    func testALostMicrophoneIsNoticedOnceAndClearedWhenItComesBack() async throws {
        let eidolon = try await installedEidolon()
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        capture.recoverable = false
        await session.recoverAudio()
        try await waitFor("the notice") { micNotices(of: log) == [.lost] }

        await session.recoverAudio()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(micNotices(of: log), [.lost], "the same loss is not said twice")

        capture.recoverable = true
        await session.recoverAudio()
        try await waitFor("the notice taken away") { micNotices(of: log) == [.lost, nil] }
        await session.hangUp()
    }

    func testARecoveredMicrophoneNeverNotices() async throws {
        let eidolon = try await installedEidolon()
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        await session.recoverAudio()
        await session.recoverAudio()

        XCTAssertEqual(capture.recoveries, 2)
        XCTAssertTrue(micNotices(of: log).isEmpty)
        await session.hangUp()
    }

    func testADialingCallDoesNotNoticeALostMicrophone() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        recognition.connectDelay = .seconds(3)
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: recognition
        )

        capture.recoverable = false
        await session.recoverAudio()
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(micNotices(of: log).isEmpty, "nothing is being heard yet")
        XCTAssertEqual(capture.recoveries, 1)
        XCTAssertFalse(log.states().contains { if case .ended = $0 { return true }; return false })
        await session.hangUp()
    }

    func testMutingTakesTheMicrophoneNoticeAway() async throws {
        let eidolon = try await installedEidolon()
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        capture.recoverable = false
        await session.recoverAudio()
        try await waitFor("the notice") { micNotices(of: log) == [.lost] }

        await session.setMuted(true)
        try await waitFor("the notice gone while muted") { micNotices(of: log) == [.lost, nil] }
        await session.hangUp()
    }

    func testAMutedMicrophoneIsNotNoticedUntilItIsUnmuted() async throws {
        let eidolon = try await installedEidolon()
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        await session.setMuted(true)
        capture.recoverable = false
        await session.recoverAudio()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(micNotices(of: log).isEmpty, "the microphone was closed on purpose")

        await session.setMuted(false)
        try await waitFor("the notice after unmuting") { micNotices(of: log) == [.lost] }
        await session.hangUp()
    }

    func testASystemDisruptionAsksTheMicrophoneToComeBack() async throws {
        let eidolon = try await installedEidolon()
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        capture.disrupt()
        try await waitFor("the recovery") { capture.recoveries == 1 }
        await session.hangUp()
    }

    func testEndingClearsTheMicrophoneNoticeBeforeTheEndState() async throws {
        let eidolon = try await installedEidolon()
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: ReplyScriptProvider([]),
            recognition: FakeRecognition([.hang])
        )
        try await waitFor("listening") { await session.currentState() == .listening }

        capture.recoverable = false
        await session.recoverAudio()
        try await waitFor("the notice") { micNotices(of: log) == [.lost] }
        await session.hangUp()
        try await waitFor("the end") { log.states().contains { if case .ended = $0 { return true }; return false } }

        XCTAssertEqual(micNotices(of: log), [.lost, nil])
        let cleared = log.all.firstIndex { event in
            if case .micNotice(nil) = event { return true }
            return false
        }
        let ended = log.all.firstIndex { event in
            if case .state(.ended) = event { return true }
            return false
        }
        XCTAssertLessThan(cleared ?? Int.max, ended ?? Int.max, "no notice outlives the call")
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

    /// A segment that could not be made does not stop the rest of the reply being prefetched:
    /// the segment after it is made while it plays, so the gap between them stays short
    /// (ADR-0011).
    func testPrefetchResumesAfterASegmentFails() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            [
                "<ja>一</ja><zh>一</zh>", "<ja>二</ja><zh>二</zh>",
                "<ja>三</ja><zh>三</zh>", "<ja>四</ja><zh>四</zh>",
            ],
        ])
        let timeline = Timeline()
        let synthesis = FakeSynthesis()
        synthesis.failing = { $0 == "二" }
        synthesis.timeline = timeline
        let playback = FakePlayback()
        playback.delay = .milliseconds(300)
        playback.timeline = timeline
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("every segment that could be voiced played") {
            playback.audio.count == 3
        }

        let entries = timeline.all
        let fourthMade = try XCTUnwrap(entries.firstIndex(of: "synth-start:四"))
        let thirdPlayed = try XCTUnwrap(entries.firstIndex(of: "play-end:三"))
        XCTAssertLessThan(
            fourthMade,
            thirdPlayed,
            "the segment after the failed one is still prefetched while the previous one plays"
        )
        XCTAssertEqual(
            playback.audio.map { String(decoding: $0, as: UTF8.self) },
            ["一", "三", "四"]
        )
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
        // A segment whose voice could not be made does not turn the card: the line shown is
        // the next one actually said (upstream `linePacing.ts` skips what it never plays).
        XCTAssertEqual(segments(of: log).map(\.ja), ["だいじょうぶ"])
        await session.hangUp()
    }

    /// Her voice never comes — refused, timed out, or a connection that will not open — so
    /// the reply is shown at her pace instead: a blank card while she is not heard is the one
    /// thing the call must not do (upstream `linePacing.ts`, `VOICE_WAIT_MS`).
    func testTheLineCardFallsBackToHerWordsWhenHerVoiceNeverComes() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        synthesis.failing = { _ in true }
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
        try await waitFor("both lines shown", timeout: .seconds(8)) {
            segments(of: log).count == 2
        }
        XCTAssertEqual(segments(of: log).map(\.ja), ["一つ目", "二つ目"])
        XCTAssertTrue(playback.audio.isEmpty)
        await session.hangUp()
    }

    /// A voice still being made (a slow network, a hanging TLS handshake) must not hold the
    /// card on nothing: it shows her words while the voice is on its way, and jumps to the
    /// voice if it does come.
    func testTheLineCardShowsHerWordsWhileHerVoiceIsStillBeingMade() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        synthesis.delay = .seconds(10)
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
        try await waitFor("the first line shown", timeout: .seconds(6)) {
            !segments(of: log).isEmpty
        }
        XCTAssertEqual(segments(of: log).first?.ja, "一つ目")
        XCTAssertTrue(playback.audio.isEmpty, "no voice has been made yet")
        try await waitFor("the second line shown", timeout: .seconds(3)) {
            segments(of: log).count == 2
        }
        XCTAssertEqual(segments(of: log).map(\.ja), ["一つ目", "二つ目"])
        await session.hangUp()
    }

    /// The call's own trace says how long her reply and her first voice took: from the end
    /// of the producer's line to the reply, to the first line, and to the first voice.
    func testTheCallTraceSaysHowLongTheReplyAndVoiceTook() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>うん</ja><zh>嗯</zh>"]])
        let synthesis = FakeSynthesis()
        synthesis.delay = .milliseconds(120)
        let playback = FakePlayback()
        let (session, _, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )
        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her voice played") { playback.audio.count == 1 }
        await session.hangUp()

        let records = try await eidolon.turnTraces()
        let record = try XCTUnwrap(records.first)
        let turns = try XCTUnwrap(record.trace.callTimings?.turns)
        XCTAssertEqual(turns.count, 1)
        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turn.reply, 0)
        XCTAssertNotNil(turn.replyDelay)
        XCTAssertNotNil(turn.firstLine)
        XCTAssertGreaterThanOrEqual(turn.voiceWait ?? 0, 0.1)
        XCTAssertGreaterThanOrEqual(turn.firstVoice ?? 0, 0.1)
        XCTAssertGreaterThanOrEqual(turn.firstLine ?? 0, 0)
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

    // MARK: - 只看文字 and 麦克风静音

    /// 只看文字: her reply goes on the card at her pace and the voice service is never
    /// asked; the microphone stays open, her emotions are judged and the turn is recorded
    /// as any other (spec #43).
    func testTextOnlyPutsHerWordsOnTheCardWithoutAVoice() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>もしもし</ja><zh>喂</zh>", "<ja>聞こえてるよ</ja><zh>听得见哦</zh>"],
        ])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        let judge = ScriptedEmotionJudge([
            SegmentEmotion(emotion: .happy), SegmentEmotion(emotion: .happy),
        ])
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback,
            emotionJudge: judge,
            prepare: { await $0.setTextOnly(true) }
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("both segments on the card", timeout: .seconds(10)) {
            segments(of: log).count == 2
        }
        try await waitFor("listening again", timeout: .seconds(5)) {
            await session.currentState() == .listening
        }

        XCTAssertEqual(synthesis.texts, [], "no voice is made in 只看文字")
        XCTAssertEqual(playback.audio, [], "nothing is played")
        XCTAssertEqual(played(of: log), [], "her mouth does not move")
        XCTAssertTrue(capture.isHearing, "the microphone stays open")
        XCTAssertEqual(segments(of: log).map(\.ja), ["もしもし", "聞こえてるよ"])
        let asked = await judge.askedSegments()
        XCTAssertEqual(asked.count, 2, "her emotions are still judged")
        let conversation = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(conversation?.messages.count, 2, "the turn is recorded as any other")
        await session.hangUp()
    }

    /// Each line stays up about as long as she would take to say it: five Japanese
    /// characters a second, never shorter than 1.5 seconds (upstream `CHARACTERS_PER_SECOND`,
    /// `SHORTEST_LINE_MS`). The first line is on the card as soon as it arrives.
    func testTextOnlyKeepsEachLineForAsLongAsSheWouldSayIt() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>あ</ja><zh>啊</zh>", "<ja>ああああああああああ</ja><zh>啊啊啊啊啊啊啊啊啊啊</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            prepare: { await $0.setTextOnly(true) }
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        let clock = ContinuousClock()
        let saidAt = clock.now
        recognition.say("ねえ")

        let deadline = saidAt + .seconds(10)
        while segments(of: log).isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstShownAt = clock.now
        while segments(of: log).count < 2, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondShownAt = clock.now
        XCTAssertEqual(segments(of: log).count, 2, "both lines reached the card")
        XCTAssertLessThan(
            firstShownAt - saidAt, .seconds(1),
            "the first line is shown as it arrives, not after a wait"
        )
        XCTAssertGreaterThanOrEqual(
            secondShownAt - firstShownAt, .milliseconds(1400),
            "the second line waits out the first line's 1.5s floor"
        )
        await session.hangUp()
    }

    /// The pace the card keeps a line for, from the Japanese as she says it: punctuation
    /// counts, whitespace does not.
    func testHerTextPaceIsFiveCharactersASecondWithAShortestLine() {
        XCTAssertEqual(CallSession.lineTime("もしもし"), .milliseconds(1500))
        XCTAssertEqual(CallSession.lineTime(String(repeating: "あ", count: 10)), .milliseconds(2000))
        XCTAssertEqual(CallSession.lineTime(String(repeating: "あ", count: 20)), .milliseconds(4000))
        XCTAssertEqual(CallSession.lineTime("あ あ\nあ"), .milliseconds(1500), "whitespace does not count")
    }

    /// 只看文字 turned on while she is being heard stops the segment playing, reads the
    /// rest of that reply on the card, and leaves the calls after it unvoiced too.
    func testTurningTextOnlyOnMidAnswerCutsHerVoiceAndReadsTheRest() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>", "<ja>二つ目</ja><zh>第二句</zh>"],
            ["<ja>三つ目</ja><zh>第三句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        playback.playsUntilSilenced = true
        let timeline = Timeline()
        playback.timeline = timeline
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her voice starts") { timeline.index(of: "play-start:一つ目") != nil }

        await session.setTextOnly(true)
        try await waitFor("the rest on the card", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 && $0.segment == 1 }
        }
        XCTAssertEqual(playback.silences, 1, "the segment playing is cut")
        XCTAssertEqual(playback.audio.count, 1, "nothing after it is played")
        XCTAssertEqual(played(of: log), ["start:0:0", "stop:0:0"], "no mouth for the rest")

        try await waitFor("listening again", timeout: .seconds(5)) {
            await session.currentState() == .listening
        }
        recognition.say("二度目")
        try await waitFor("the next reply on the card", timeout: .seconds(10)) {
            segments(of: log).contains { $0.reply == 1 }
        }
        XCTAssertFalse(synthesis.texts.contains("三つ目"), "the next reply is read, not voiced")
        XCTAssertEqual(playback.audio.count, 1)
        await session.hangUp()
    }

    /// A reply that began as text stays text to its end even if 只看文字 is turned off
    /// midway; her voice comes back on the next reply.
    func testATextReplyStaysTextWhenTextOnlyIsTurnedOffMidAnswer() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>もしもし</ja><zh>喂</zh>", "<ja>聞こえてるよ</ja><zh>听得见哦</zh>"],
            ["<ja>三つ目</ja><zh>第三句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback,
            prepare: { await $0.setTextOnly(true) }
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the first line", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 && $0.segment == 0 }
        }

        await session.setTextOnly(false)
        try await waitFor("the second line", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 && $0.segment == 1 }
        }
        try await waitFor("listening again", timeout: .seconds(5)) {
            await session.currentState() == .listening
        }
        XCTAssertEqual(synthesis.texts, [], "the reply that began as text stays text")
        XCTAssertEqual(playback.audio, [])

        recognition.say("二度目")
        try await waitFor("her voice is back", timeout: .seconds(5)) {
            playback.audio.count == 1
        }
        XCTAssertEqual(synthesis.texts, ["三つ目"], "the next reply is voiced")
        await session.hangUp()
    }

    /// A reply cut over to text stays text to its end even if 只看文字 is turned off again
    /// before the reply is done: the shape is latched per reply, so one reply is never half
    /// voiced and half read, and the next reply is the first to start fresh (spec #43).
    func testAReplyTurnedToTextStaysTextWhenTextOnlyIsTurnedOffAgain() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            [
                "<ja>一つ目</ja><zh>第一句</zh>",
                "<ja>二つ目</ja><zh>第二句</zh>",
                "<ja>三つ目</ja><zh>第三句</zh>",
            ],
        ])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        playback.playsUntilSilenced = true
        let timeline = Timeline()
        playback.timeline = timeline
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her voice starts") { timeline.index(of: "play-start:一つ目") != nil }

        await session.setTextOnly(true)
        try await waitFor("the second line on the card", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 && $0.segment == 1 }
        }
        await session.setTextOnly(false)
        try await waitFor("the third line on the card", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 && $0.segment == 2 }
        }

        XCTAssertFalse(synthesis.texts.contains("三つ目"), "the reply stays text to its end")
        XCTAssertEqual(playback.audio.count, 1, "only the line that had already started was played")
        await session.hangUp()
    }

    /// Her reply read as text holds the call for as long as it takes to read: the next
    /// turn does not begin until the last line has had its time, as with her voice.
    func testTheNextTurnWaitsForATextReplysPaceToFinish() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>もしもし</ja><zh>喂</zh>", "<ja>聞こえてるよ</ja><zh>听得见哦</zh>"],
            ["<ja>三つ目</ja><zh>第三句</zh>"],
        ])
        let (session, log, _) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            prepare: { await $0.setTextOnly(true) }
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("the first line", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 && $0.segment == 0 }
        }
        recognition.say("二度目")
        try await waitFor("her whole reply", timeout: .seconds(10)) {
            segments(of: log).filter { $0.reply == 0 }.count == 2
        }
        XCTAssertEqual(
            provider.turnsAsked, 1,
            "the next turn does not begin while her words are still being read out"
        )
        try await waitFor("the second turn", timeout: .seconds(10)) {
            segments(of: log).contains { $0.reply == 1 }
        }
        XCTAssertEqual(provider.turnsAsked, 2)
        await session.hangUp()
    }

    /// 麦克风静音 closes the microphone for the call and leaves the recognizer connected: her
    /// reply goes on, and unmuting hears at once without a reconnect (spec #43).
    func testMutingClosesTheMicrophoneWithoutDroppingTheConnection() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>"],
            ["<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let playback = FakePlayback()
        playback.delay = .milliseconds(200)
        let timeline = Timeline()
        playback.timeline = timeline
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        recognition.say("ねえ")
        try await waitFor("her voice starts") { timeline.index(of: "play-start:一つ目") != nil }

        await session.setMuted(true)
        XCTAssertFalse(capture.isHearing, "the microphone is closed")
        capture.send(0x01)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(recognition.heard, [], "nothing the microphone hears while muted")
        XCTAssertEqual(recognition.calls, 1, "the recognizer stays connected")

        try await waitFor("her reply goes on", timeout: .seconds(5)) {
            timeline.index(of: "play-end:一つ目") != nil
        }
        try await waitFor("listening again", timeout: .seconds(5)) {
            await session.currentState() == .listening
        }
        XCTAssertFalse(capture.isHearing, "still muted once her reply is done")

        await session.setMuted(false)
        XCTAssertTrue(capture.isHearing, "unmuting hears again at once")
        XCTAssertEqual(recognition.calls, 1, "no reconnection")
        capture.send(0x02)
        try await waitFor("the microphone reaches the recognizer") { recognition.heard == [0x02] }
        recognition.say("二度目")
        try await waitFor("the next turn", timeout: .seconds(5)) { playback.audio.count == 2 }
        await session.hangUp()
    }

    /// The two switches are independent: she can be read as text while the microphone is
    /// muted, and unmuting does not voice her.
    func testTextOnlyAndMuteDoNotAffectEachOther() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([
            ["<ja>一つ目</ja><zh>第一句</zh>"],
            ["<ja>二つ目</ja><zh>第二句</zh>"],
        ])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        let (session, log, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback,
            prepare: { await $0.setTextOnly(true) }
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        await session.setMuted(true)
        XCTAssertFalse(capture.isHearing)
        recognition.say("ねえ")
        try await waitFor("read while muted", timeout: .seconds(5)) {
            segments(of: log).contains { $0.reply == 0 }
        }
        XCTAssertFalse(capture.isHearing, "text-only does not open the microphone")

        await session.setMuted(false)
        XCTAssertTrue(capture.isHearing)
        try await waitFor("listening again", timeout: .seconds(5)) {
            await session.currentState() == .listening
        }
        recognition.say("二度目")
        try await waitFor("the next reply", timeout: .seconds(10)) {
            segments(of: log).contains { $0.reply == 1 }
        }
        XCTAssertEqual(synthesis.texts, [], "text-only goes on after unmuting")
        XCTAssertEqual(playback.audio, [])
        await session.hangUp()
    }

    /// Once the call has ended the switches do nothing: the microphone stays closed and
    /// nothing is made or played.
    func testTheSwitchesDoNothingOnceTheCallHasEnded() async throws {
        let eidolon = try await installedEidolon()
        let recognition = FakeRecognition([.hang])
        let provider = ReplyScriptProvider([["<ja>一つ目</ja><zh>第一句</zh>"]])
        let synthesis = FakeSynthesis()
        let playback = FakePlayback()
        let (session, _, capture) = try await begin(
            on: eidolon,
            provider: provider,
            recognition: recognition,
            synthesis: synthesis,
            playback: playback
        )

        try await waitFor("listening") { await session.currentState() == .listening }
        await session.hangUp()
        try await waitFor("ended") {
            if case .ended = await session.currentState() { return true }
            return false
        }
        XCTAssertFalse(capture.isHearing)

        await session.setMuted(false)
        await session.setTextOnly(true)
        XCTAssertFalse(capture.isHearing, "the microphone stays closed")
        let state = await session.currentState()
        guard case .ended = state else {
            return XCTFail("the call stays ended, not \(state)")
        }
        XCTAssertEqual(synthesis.texts, [])
        XCTAssertEqual(playback.audio, [])
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
