import Foundation
import GRDB

/// The voice a call speaks in: the character's Fish Audio voice, on a model.
public struct CallVoice: Sendable, Hashable {
    public var id: String
    public var model: String

    public init(id: String, model: String) {
        self.id = id
        self.model = model
    }
}

/// The microphone, as the call hears it: 16 kHz mono PCM16 chunks, one stream per call.
public protocol AudioCapture: Sendable {
    func start() async throws
    func stop() async
    /// Whether the microphone feeds the call. The call closes it while her own voice plays
    /// from the speaker: with the microphone open, she would hear herself (ADR-0015).
    func setHearing(_ hearing: Bool) async
    /// A fresh stream for each listening connection. The recognizer reads it for as long
    /// as its connection lasts, and a stream that one connection stopped reading must not
    /// keep the next one silent: every call gets its own.
    func chunks() -> AsyncThrowingStream<Data, Error>
    /// The system stopped or rerouted the microphone — a phone call, Siri, headphones
    /// plugged or pulled, media services resetting, or the app coming back from the
    /// background. Open it again if it went quiet; the call's listening stream stays the
    /// same. Says whether the input feeds the call after the attempt: false only when this
    /// attempt left it shut. A capture that is not running, or one whose attempt is already
    /// under way, says true — it has nothing to report here, and the attempt under way
    /// reports its own result.
    func recover() async -> Bool
    /// The same, after the app came back to the foreground. A real return is not the echo of
    /// a recovery's own route change, so it is not held off by the quiet window that keeps
    /// route changes from asking for recovery over and over.
    func recoverAfterForeground() async -> Bool
    /// Each system action that can take the microphone away, as one event: an interruption
    /// ending, a route change, media services resetting. The call asks the microphone to
    /// come back for each; a capture with nothing to watch yields none.
    func disruptions() -> AsyncStream<Void>
}

extension AudioCapture {
    /// A capture with nothing to recover keeps working as it did.
    public func recover() async -> Bool { true }
    public func recoverAfterForeground() async -> Bool { await recover() }
    public func disruptions() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

/// The speaker, as the call uses it: one segment's audio at a time.
public protocol AudioPlayback: Sendable {
    func play(_ audio: Data) async throws
    func stop() async
    /// Cuts the segment playing now, without ending the call: switching to 只看文字 while she
    /// is being heard leaves her words on the card but takes her voice away at once. Unlike
    /// `stop`, a later segment may still be played.
    func silence() async
}

extension AudioPlayback {
    /// A playback with one segment at a time has nothing to cut between plays.
    public func silence() async {}
}

/// What the recognizer heard.
public enum SpeechEvent: Sendable, Hashable {
    /// The connection is up and its configuration accepted: from here on it hears. A call
    /// is connected when this first comes, not when the microphone opened (spec「接通」).
    case connected
    /// Words still being said, replaced as they are corrected.
    case partial(String)
    /// What the producer said, when the recognizer found the end of it.
    case final(String)
}

/// A voice service failing as a service — a key missing or refused, an account out of
/// credit — rather than a connection that dropped: the call ends instead of listening
/// again (upstream `service_failed`).
public struct VoiceServiceFailure: Sendable, Hashable {
    /// How the service is named: `Soniox`.
    public var service: String
    /// What it said: `401 invalid api key`.
    public var detail: String

    public init(service: String, detail: String) {
        self.service = service
        self.detail = detail
    }
}

/// Real-time speech to text over a live audio stream. A stream that ends or throws is a
/// connection lost; the call reconnects and listens again, unless the service itself
/// failed.
public protocol SpeechRecognition: Sendable {
    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error>
    /// Why the error is the service itself failing, if it is; nil for a connection that
    /// dropped, which the call reconnects from.
    func failure(_ error: any Error) -> VoiceServiceFailure?
}

extension SpeechRecognition {
    /// A recognizer that cannot tell a service failure from a dropped connection keeps
    /// reconnecting, as the call always did.
    public func failure(_ error: any Error) -> VoiceServiceFailure? { nil }
}

/// Text to speech: one segment's Japanese (delivery cues included) to audio the call plays.
public protocol SpeechSynthesis: Sendable {
    /// Whether her segments are voiced at all. A voiced call moves its line card as each
    /// segment's voice starts, so a segment it could not make does not turn the card; a
    /// synthesizer with no voice (no key filled in) shows every caption as it arrives.
    var providesVoice: Bool { get }
    func synthesize(_ text: String, voice: CallVoice) async throws -> Data
    /// Why the error is the voice service itself failing — a key missing or refused, an
    /// account out of credit, a model it does not serve, audio it could not make — if it
    /// is; nil for a segment that merely could not be made, which the call skips as it goes
    /// on (upstream `service_failed`, ADR-0011).
    func failure(_ error: any Error) -> VoiceServiceFailure?
}

extension SpeechSynthesis {
    public var providesVoice: Bool { true }

    /// A synthesizer that cannot tell a service failure from a segment that was lost skips
    /// the segment, as the call always did.
    public func failure(_ error: any Error) -> VoiceServiceFailure? { nil }
}

public enum CallState: Sendable, Hashable {
    case connecting
    case listening
    case thinking
    case speaking
    /// The recognizer's connection dropped; the call is still up.
    case reconnecting
    case ended(CallEnd)
}

/// Something about the microphone the call tells the producer while it goes on
/// (upstream `MicNotice`): the input went away and could not be opened again.
public enum MicNotice: Sendable, Hashable {
    /// The microphone is gone and no other input can be opened; she cannot hear anything.
    case lost

    public var message: String {
        switch self {
        case .lost:
            "麦克风断开了，也没有别的麦克风可用"
        }
    }
}

/// Why a call ended: the backend's reasons and its own words, and the one ending told apart
/// on the device — a microphone that would not open (upstream `call_outcome.py`,
/// `callEnd.ts`).
public enum CallEnd: Sendable, Hashable {
    /// The voice service failed before a turn was recorded: the call never connected.
    case notConnected(service: String, detail: String)
    /// The voice service failed after at least one turn: the call broke off.
    case dropped(service: String, detail: String)
    /// The microphone could not be opened — no permission, no input, a route it cannot use.
    /// It is told apart from a voice service failing, which is not the producer's to fix
    /// (upstream `mic_denied`).
    case micDenied(detail: String)
    /// It has lasted `limit`.
    case durationLimit(limit: Duration)
    /// It has taken `turns` of her turns.
    case turnLimit(turns: Int)
    /// She hung up herself; a cooldown she fell into carries when it ends.
    case sheHungUp(cooldownUntil: Date?)
    /// The producer hung up. Every key on the phone is the producer's own, so there is no
    /// separate "own key" reason (upstream has one for the hosted service's keys).
    case hungUpByProducer

    /// How the call ended, in the backend's names (upstream `_ENDED_BY`).
    public var reason: String {
        switch self {
        case .notConnected: "not_connected"
        case .dropped: "dropped"
        case .micDenied: "mic_denied"
        case .durationLimit: "duration_limit"
        case .turnLimit: "turn_limit"
        case let .sheHungUp(cooldownUntil): cooldownUntil == nil ? "she_hung_up" : "cooldown"
        case .hungUpByProducer: "hung_up_by_producer"
        }
    }

    /// The sentence the call shows when it ends, as the backend says it.
    public var message: String {
        switch self {
        case .notConnected:
            "语音服务出了故障，通话没能接通"
        case .dropped:
            "语音服务出了故障，通话中断了"
        case .micDenied:
            "用不了麦克风。没有允许使用麦克风，或者找不到麦克风。在系统设置里允许后，再拨一次。"
        case let .durationLimit(limit):
            "这次通话已经满 \(Self.minutes(limit)) 分钟了，先挂断啦。想接着聊可以重新拨打。"
        case let .turnLimit(turns):
            "这次通话已经说了 \(turns) 轮了，先挂断啦。想接着聊可以重新拨打。"
        case .sheHungUp:
            "她挂断了电话。"
        case .hungUpByProducer:
            "通话已结束"
        }
    }

    /// What the call's trace adds to the reason: the service that failed, the limit that
    /// was reached, or when she is willing to talk again.
    public var detail: String? {
        switch self {
        case let .notConnected(service, detail), let .dropped(service, detail):
            "\(service)：\(detail)"
        case let .micDenied(detail):
            "麦克风：\(detail)"
        case let .durationLimit(limit):
            "时长上限 \(Self.minutes(limit)) 分钟"
        case let .turnLimit(turns):
            "回合上限 \(turns) 轮"
        case let .sheHungUp(cooldownUntil):
            cooldownUntil.map { "冷却到 \(Self.moment($0))" }
        case .hungUpByProducer:
            nil
        }
    }

    /// Minutes as Python's `{minutes:g}` writes them: `10`, `1.5`, no trailing zeros.
    public static func minutes(_ duration: Duration) -> String {
        return String(
            format: "%g",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [duration.inSeconds / 60]
        )
    }

    /// A moment as the app writes it, the same style as the chat's cooling notice.
    public static func moment(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
    }
}

/// How long a call may last and how many of her turns it may take; nil is no limit
/// (upstream `CallLimits`). The count starts when the call connects.
public struct CallLimits: Sendable, Hashable {
    public var duration: Duration?
    public var turns: Int?

    public init(duration: Duration?, turns: Int?) {
        self.duration = duration
        self.turns = turns
    }

    /// From the settings' numbers: 0 is no limit on that dimension, as upstream reads its
    /// environment (`config.py`'s `_limit`).
    public init(minutes: Int, turns: Int) {
        self.duration = minutes > 0 ? .seconds(minutes * 60) : nil
        self.turns = turns > 0 ? turns : nil
    }

    /// Upstream's defaults (`DEFAULT_CALL_MINUTES`, `DEFAULT_TURNS_PER_CALL`): ten minutes
    /// or forty of her turns, about what ten minutes of talking takes.
    public static let standard = CallLimits(minutes: 10, turns: 40)
}

public enum CallEvent: Sendable, Hashable {
    case state(CallState)
    /// What the producer is saying, as the recognizer revises it; each replaces the last,
    /// and an empty one clears it.
    case hearing(String)
    /// What the producer said, when the recognizer found the end of it.
    case recognized(String)
    /// One of her segments, for the line card and the subtitle. Delivery cues are stripped.
    /// `reply` numbers her replies in the call from 0 (each answer she gives is one);
    /// `segment` numbers its segments from 0. In a voiced call it comes as that segment's
    /// voice starts, so the card follows what is heard and never shows a segment whose voice
    /// was skipped; with no voice at all it comes as the text does.
    case segment(reply: Int, segment: Int, ja: String, zh: String)
    /// A segment's voice started playing: her mouth moves from here until it stops.
    case segmentStarted(reply: Int, segment: Int)
    /// A segment's voice stopped playing.
    case segmentStopped(reply: Int, segment: Int)
    /// A segment's emotion and nod, judged while the reply was being said. Only her stand
    /// takes it: it is not part of the conversation, nor of the turn's trace.
    case emotion(reply: Int, segment: Int, emotion: StandEmotion, nod: StandNod.Kind?)
    /// The turn could not be answered; the call goes on.
    case failed(String)
    /// What the microphone is doing that the producer should know; nil takes the notice
    /// away. Never comes after the call ended.
    case micNotice(MicNotice?)
    /// Her last turn changed her affinity; the status line says it for a moment (spec #38).
    case affinity(AffinityChange)
}

/// Everything a call is made of: the platform's audio and voice services, the chat model,
/// and how long one may last. The app builds it; tests build it with fakes (ADR-0015).
public struct CallSetup: Sendable {
    public var capture: any AudioCapture
    public var playback: any AudioPlayback
    public var recognition: any SpeechRecognition
    public var synthesis: any SpeechSynthesis
    /// The Fish Audio model her voice is spoken on; `drama-3` reads delivery cues.
    public var voiceModel: String
    public var provider: any ChatProvider
    public var judge: (any JudgeProvider)?
    /// Judges each segment's emotion for her stand; nil when the judge is the chat model,
    /// which has no probabilities to read (spec「情绪判断」).
    public var emotionJudge: (any SegmentEmotionJudge)?
    public var embedder: (any EmbeddingProvider)?
    public var reranker: (any RerankProvider)?
    public var tracing: TurnTracing
    /// How long the call may last and how many of her turns it may take.
    public var limits: CallLimits
    /// How many turns of the conversation she is told before each one, from the settings.
    public var historyTurns: Int
    /// How long to wait before listening again after the recognizer's connection dropped.
    public var reconnectDelay: Duration
    /// How long the recognizer may take to become ready; a call that never does is given up
    /// as one that could not connect (upstream `CONNECT_TIMEOUT`, 30 seconds).
    public var connectTimeout: Duration
    /// The sounds the phone itself makes: 铃声 while dialing, 接通音 at the connect, 挂断音 at
    /// any ending after dialing.
    public var tones: any CallTones
    public var now: @Sendable () -> Date

    public init(
        capture: any AudioCapture,
        playback: any AudioPlayback,
        recognition: any SpeechRecognition,
        synthesis: any SpeechSynthesis,
        voiceModel: String,
        provider: any ChatProvider,
        judge: (any JudgeProvider)? = nil,
        emotionJudge: (any SegmentEmotionJudge)? = nil,
        embedder: (any EmbeddingProvider)? = nil,
        reranker: (any RerankProvider)? = nil,
        tracing: TurnTracing = .on,
        limits: CallLimits = .standard,
        historyTurns: Int = 20,
        reconnectDelay: Duration = .seconds(1),
        connectTimeout: Duration = .seconds(30),
        tones: any CallTones = SilentTones(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capture = capture
        self.playback = playback
        self.recognition = recognition
        self.synthesis = synthesis
        self.voiceModel = voiceModel
        self.provider = provider
        self.judge = judge
        self.emotionJudge = emotionJudge
        self.embedder = embedder
        self.reranker = reranker
        self.tracing = tracing
        self.limits = limits
        self.historyTurns = historyTurns
        self.reconnectDelay = reconnectDelay
        self.connectTimeout = connectTimeout
        self.tones = tones
        self.now = now
    }
}

/// One call with her (GLOSSARY.md「通话」): the microphone, the recognizer, her turns and
/// her voice, from the silent connection to the hang-up. The app only feeds it audio
/// services and shows what it says; everything else is here (ADR-0007, ADR-0015).
public actor CallSession {
    public nonisolated let characterID: String
    /// How long this call may last, if it has a limit: the call screen counts down the last
    /// minute of it (upstream `callTime.ts`).
    public nonisolated let durationLimit: Duration?

    private let eidolon: Eidolon
    private let characterName: String
    private let setup: CallSetup
    private let voice: CallVoice
    private let stream: AsyncStream<CallEvent>
    private let continuation: AsyncStream<CallEvent>.Continuation

    private var state: CallState = .connecting
    private var started = false
    private var finished = false
    /// Whether the recognizer's connection is up right now.
    private var connectedNow = false
    /// Whether it has ever been up: the call counts as connected from the first time.
    private var everConnected = false
    private var tasks: [Task<Void, Never>] = []
    /// The recognizer's current connection loop; it is replaced on foreground, since a
    /// socket can die while the app is away without reporting it.
    private var listenTask: Task<Void, Never>?
    private var turnTask: Task<Void, Never>?
    private var connectTimeoutTask: Task<Void, Never>?

    /// The ring going out, while the call waits out its first loop.
    private var ringback: (any Ringback)?
    /// The task waiting out the rest of the first loop.
    private var holdTask: Task<Void, Never>?
    /// Whether the ring went out at all: a ring that could not play is not followed by a
    /// connect tone either.
    private var ringPlayed = false
    /// Whether the call has entered: the connect tone played and the microphone opened to
    /// her. A reconnect must not play the connect tone again.
    private var enteredCall = false
    /// 只看文字: her words are put on the card at her pace and no voice is made (upstream
    /// `muted`). It can change while the call is up, and a reply that started while it was on
    /// stays text to its end.
    private var textOnly = false
    /// The reply that began while 只看文字 was on: her voice comes back on the next reply,
    /// as upstream latches whether a reply is voiced when it starts.
    private var textStartedReply: Int?
    /// 麦克风静音: the producer's microphone is closed for the rest of this call.
    private var muted = false
    /// The microphone notice showing now, if any.
    private var micNotice: MicNotice?
    /// One recovery at a time: the foreground and a system action can arrive together, and
    /// the second must not clear what the first is about to report.
    private var recoveringAudio = false

    /// What the producer said while she was answering; answered once she is done.
    private var pending: [String] = []
    /// Her Japanese being said, by segment, delivery cues kept, for the voice.
    private var speech: [Int: String] = [:]
    /// Her segments as shown, by segment, for the subtitle.
    private var captions: [Int: (ja: String, zh: String)] = [:]
    private var lastFinalized = -1
    /// The last segment the line card has shown for the reply being answered: her voice and
    /// the fallback below both move it, and it only ever moves forward (upstream `shownUpTo`).
    private var shownThrough = -1
    /// Whether her voice has started on the reply being answered.
    private var voiceStarted = false
    /// Counts the reply whose line card is being paced: a task for an earlier reply must not
    /// put its words on the card after the next one has started.
    private var linePacingReply = -1
    /// Moves the line card at her pace while her voice does not come (upstream
    /// `linePacing.ts`): a reply that cannot be voiced still has to be read.
    private var lineFallback: Task<Void, Never>?
    /// When each reply's producer line ended, her reply was recorded, her first line showed,
    /// and her first voice started: what the call's trace says about latency (ADR-0012).
    private var replyRecognizedAt: [Int: ContinuousClock.Instant] = [:]
    private var replyRecordedAt: [Int: ContinuousClock.Instant] = [:]
    private var replyFirstLineAt: [Int: ContinuousClock.Instant] = [:]
    private var replyFirstVoiceAt: [Int: ContinuousClock.Instant] = [:]
    /// Which of her replies the segments being said belong to, from 0: every answer she
    /// gives in the call is one reply (spec「通话事件」).
    private var reply = -1
    /// What the producer said for the reply being answered, which its segments' emotions
    /// are judged with.
    private var said = ""
    /// The segments' emotions still being judged, by reply and segment, cancelled when the
    /// call ends (spec「情绪判断」).
    private var emotionTasks: [String: Task<Void, Never>] = [:]
    private var queue: [(reply: Int, index: Int, speech: String)] = []
    /// The segment after the one playing, being made while it plays.
    private var prefetch: (index: Int, task: Task<Data, Error>)?
    /// The segment whose audio is playing, if any.
    private var speakingIndex: Int?
    private var speaking: Task<Void, Never>?
    /// The segment `drain` has taken off the queue, being made or read: 只看文字 turning on
    /// mid-answer must not queue it a second time.
    private var drainingIndex: Int?
    /// The last reply whose segments have all been streamed: `drain` reading a reply as text
    /// waits for its later segments until this reply has been settled.
    private var settledReply = -1
    /// Wakes `drain` when a reply read as text gets another segment, or is settled.
    private var segmentWaiter: CheckedContinuation<Void, Never>?
    private var turnActive = false
    /// What the call's turns have come to, told to the next one: the call keeps its own
    /// count, apart from the conversation's typed turns (upstream `InCall`).
    private var callOutOfLine = 0
    private var callHurts: [Double] = []
    /// Her turns the call has recorded: the turn limit counts these, and a voice service
    /// failure before the first is a call that never connected (upstream `_recorded`).
    private var recordedTurns = 0
    /// The duration has run out; the call ends once the turn in progress is done.
    private var timeUp = false
    /// The turn just recorded was one she ended the call with, and a cooldown it began.
    private var pendingHangUp = false
    private var pendingCooldownUntil: Date?

    init(
        eidolon: Eidolon,
        characterID: String,
        characterName: String,
        voice: CallVoice,
        setup: CallSetup
    ) {
        self.eidolon = eidolon
        self.characterID = characterID
        self.characterName = characterName
        self.voice = voice
        self.setup = setup
        durationLimit = setup.limits.duration
        (stream, continuation) = AsyncStream.makeStream(of: CallEvent.self)
    }

    /// Everything the call shows and says, in order; ends when the call does.
    public nonisolated func events() -> AsyncStream<CallEvent> {
        stream
    }

    public func currentState() -> CallState {
        state
    }

    /// Connects: the microphone starts, and the call listens. This is silent: she says
    /// nothing until the producer speaks, and the call is not connected until the
    /// recognizer can hear (spec「接通」).
    public func start() async {
        guard !started, !finished else { return }
        started = true
        setState(.connecting)
        do {
            try await setup.capture.start()
        } catch {
            await finish(.micDenied(detail: error.localizedDescription))
            return
        }
        // 铃声 starts with the microphone open, and she cannot hear the producer until the
        // call has entered (GLOSSARY.md「铃声」). A ring left over from the last call is cut
        // first (spec #35).
        setup.tones.silence()
        if let ringback = setup.tones.ring() {
            self.ringback = ringback
            ringPlayed = true
            await hear(false)
        }
        let listening = Task { await self.listenLoop() }
        listenTask = listening
        tasks.append(listening)
        // The system taking the microphone away is the session's to notice and answer, so
        // that a failure can reach the screen (spec #41).
        let disruptions = setup.capture.disruptions()
        tasks.append(Task {
            for await _ in disruptions {
                await self.recoverAudio()
            }
        })
        if setup.connectTimeout > .zero {
            let timeout = setup.connectTimeout
            connectTimeoutTask = Task { await self.connectTimedOut(after: timeout) }
        }
    }

    /// A recognizer that never becomes ready would leave the producer talking into a screen
    /// that says it is listening; the call is given up instead (upstream `CONNECT_TIMEOUT`).
    private func connectTimedOut(after timeout: Duration) async {
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled, !finished, !everConnected else { return }
        await finish(.notConnected(service: "识别", detail: "连接超时"))
    }

    public func hangUp() async {
        await finish(.hungUpByProducer)
    }

    /// The app came back to the foreground or the system took the microphone away: open it
    /// again if it went quiet, and say so when it cannot be opened (spec #41). A failure
    /// while the call is still dialing is not shown — nothing is being heard yet — and a
    /// muted microphone is not the system's doing. Nothing happens once the call has ended.
    public func recoverAudio() async {
        await recoverAudio(afterForeground: false)
    }

    private func recoverAudio(afterForeground: Bool) async {
        guard !finished, !muted, !recoveringAudio else { return }
        recoveringAudio = true
        defer { recoveringAudio = false }
        let recovered = afterForeground
            ? await setup.capture.recoverAfterForeground()
            : await setup.capture.recover()
        if recovered {
            setMicNotice(nil)
        } else if everConnected {
            setMicNotice(.lost)
        }
    }

    /// The app came back to the foreground. The microphone and the recognizer's connection
    /// may both have died while it was away, and a websocket can die without reporting it:
    /// the microphone is asked to open again, and the connection is replaced rather than
    /// trusted until it says something.
    public func appDidBecomeActive() async {
        guard !finished else { return }
        await recoverAudio(afterForeground: true)
        restartListening()
    }

    /// Replaces the recognizer's connection with a fresh one. The old loop is cancelled,
    /// which closes its socket and its audio stream; the new one asks for a new stream of
    /// the microphone and opens a new connection.
    private func restartListening() {
        guard started, !finished else { return }
        listenTask?.cancel()
        listenTask = Task { await self.listenLoop() }
    }

    /// Shows a notice once, and takes it away once: the screen hears only about changes.
    private func setMicNotice(_ notice: MicNotice?) {
        guard micNotice != notice else { return }
        micNotice = notice
        emit(.micNotice(notice))
    }

    /// 只看文字: her words go on the card at her pace and no voice service is called at all
    /// (upstream `muted`). A reply that starts while it is on stays text to its end; turning
    /// it on mid-reply cuts the segment being heard and reads the rest.
    public func setTextOnly(_ on: Bool) async {
        guard !finished, textOnly != on else { return }
        textOnly = on
        guard on else {
            // A reply that started voiced may go on with its voice: let `drain` look at
            // its queue again instead of sleeping until the reply settles.
            wakeSegments()
            return
        }
        // Her voice belongs to the mode the reply started in: stop making or playing it, and
        // read what the voice path never reached. The reply under way turns text for good —
        // turning 只看文字 off again must not put a voice back on its remaining segments —
        // and the next reply is the first to start fresh.
        textStartedReply = reply
        lineFallback?.cancel()
        lineFallback = nil
        prefetch?.task.cancel()
        prefetch = nil
        if speakingIndex != nil {
            await setup.playback.silence()
        }
        queueUnreadSegments()
    }

    /// 麦克风静音: the producer's microphone is closed for the rest of this call. The recognizer's
    /// connection stays up, so unmuting hears again without reconnecting. It is not
    /// remembered past the call.
    public func setMuted(_ on: Bool) async {
        guard !finished, muted != on else { return }
        muted = on
        if on {
            setMicNotice(nil)
            await hear(false)
        } else {
            // Back to what it would be: open once the call has entered, but not while her
            // own voice is playing (ADR-0015) — that segment reopens it when it is done.
            await hear(enteredCall && speakingIndex == nil)
            // A microphone lost while muted can come back here; if it cannot, say so
            // (spec #41). Before the call connects there is nothing to notice yet.
            await recoverAudio()
        }
    }

    // MARK: - Listening

    private func listenLoop() async {
        while !finished, !Task.isCancelled {
            // The microphone feeds this connection only: the previous connection closed
            // its stream when it closed, and that ended stream would hear nothing.
            let audio = setup.capture.chunks()
            do {
                for try await event in setup.recognition.listen(audio) {
                    if finished || Task.isCancelled { return }
                    switch event {
                    case .connected:
                        await connectionReady()
                    case let .partial(text):
                        let saying = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !saying.isEmpty { emit(.hearing(saying)) }
                    case let .final(text):
                        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        emit(.hearing(""))
                        if !said.isEmpty { heard(said) }
                    }
                }
                if finished || Task.isCancelled { return }
                connectionLost()
                try? await Task.sleep(for: setup.reconnectDelay)
            } catch is CancellationError {
                return
            } catch {
                if finished || Task.isCancelled { return }
                if let failure = setup.recognition.failure(error) {
                    await serviceFailed(failure)
                    return
                }
                connectionLost()
                try? await Task.sleep(for: setup.reconnectDelay)
            }
        }
    }

    /// The recognizer's connection is up: the call is connected from the first time, and its
    /// clock and limits start then. A reconnect does not put listening over her own state
    /// when she is speaking or thinking (spec「接通」).
    ///
    /// The call does not start talking until 铃声 has played once in full: the screen keeps
    /// dialing, and she still cannot hear the producer, until the first loop is over
    /// (GLOSSARY.md「铃声」, spec #35).
    private func connectionReady() async {
        guard !finished else { return }
        connectedNow = true
        if !everConnected {
            everConnected = true
            connectTimeoutTask?.cancel()
            connectTimeoutTask = nil
            if setup.limits.duration != nil {
                tasks.append(Task { await self.timeLimitLoop() })
            }
        }
        guard !enteredCall else {
            if !turnActive, speaking == nil {
                setState(.listening)
            }
            // Nothing of hers is playing, so the microphone should be feeding this
            // connection: a system interruption can have left it shut, and a reconnect is
            // the moment to open it again.
            if speakingIndex == nil {
                await hear(true)
            }
            return
        }
        guard ringPlayed else {
            await enterCall()
            return
        }
        let left = ringback?.left() ?? .zero
        if left <= .zero {
            await enterCall()
        } else if holdTask == nil {
            let task = Task { await self.holdRing(left) }
            holdTask = task
            tasks.append(task)
        }
    }

    /// Waits out what is left of the ring's first loop, then enters the call. A connection
    /// that drops while waiting reconnects as any other does; the waiting goes on, and the
    /// ring keeps looping.
    private func holdRing(_ left: Duration) async {
        try? await Task.sleep(for: left)
        guard !Task.isCancelled, !finished else { return }
        holdTask = nil
        await enterCall()
    }

    /// Enters the call: the ring gives way to the connect tone, and the microphone opens to
    /// her. Once only — a reconnect must not replay it.
    private func enterCall() async {
        guard !finished, !enteredCall else { return }
        enteredCall = true
        ringback = nil
        if ringPlayed { setup.tones.connect() }
        await hear(true)
        if !turnActive, speaking == nil {
            setState(connectedNow ? .listening : .reconnecting)
        }
    }

    /// The connection is gone; she may be in the middle of a reply, and that is what the
    /// screen keeps saying until she is done.
    private func connectionLost() {
        connectedNow = false
        if !turnActive, speaking == nil {
            setState(.reconnecting)
        }
    }

    /// A voice service that failed as a service ends the call: before a turn was recorded
    /// it never connected, after one it broke off (upstream `service_failed`).
    private func serviceFailed(_ failure: VoiceServiceFailure) async {
        let end: CallEnd = recordedTurns == 0
            ? .notConnected(service: failure.service, detail: failure.detail)
            : .dropped(service: failure.service, detail: failure.detail)
        await finish(end)
    }

    private func timeLimitLoop() async {
        guard let limit = setup.limits.duration else { return }
        try? await Task.sleep(for: limit)
        if !Task.isCancelled, !finished {
            timeUp = true
            await checkEnding()
        }
    }

    /// What she heard: answered now, or once her answer is done.
    private func heard(_ text: String) {
        pending.append(text)
        goOn()
    }

    // MARK: - Turns

    /// Answers what is pending when nothing is being said or answered.
    private func goOn() {
        guard !finished, !turnActive, speaking == nil else { return }
        guard !pending.isEmpty else {
            if queue.isEmpty { setState(connectedNow ? .listening : .reconnecting) }
            return
        }
        let text = pending.joined(separator: "\n")
        pending.removeAll()
        turnActive = true
        turnTask = Task { await self.answer(text) }
    }

    private func answer(_ text: String) async {
        guard !finished else {
            turnActive = false
            return
        }
        setState(.thinking)
        emit(.recognized(text))
        reply += 1
        replyRecognizedAt[reply] = ContinuousClock.now
        // Whether this reply is voiced is decided as it starts: turning 只看文字 off midway
        // does not put a voice back on a reply that began without one.
        textStartedReply = textOnly ? reply : nil
        said = text
        speech.removeAll()
        captions.removeAll()
        lastFinalized = -1
        shownThrough = -1
        voiceStarted = false
        lineFallback?.cancel()
        lineFallback = nil
        linePacingReply = reply
        var failure: String?
        var rejection: String?
        do {
            for try await event in eidolon.sendTurn(
                characterID: characterID,
                text: text,
                provider: setup.provider,
                judge: setup.judge,
                embedder: setup.embedder,
                reranker: setup.reranker,
                historyTurns: setup.historyTurns,
                now: setup.now(),
                tracing: setup.tracing,
                talking: .inCall,
                inCall: CallScope(outOfLine: callOutOfLine, hurts: callHurts),
                voicedBy: setup.voiceModel
            ) {
                if finished || Task.isCancelled { break }
                switch event {
                case let .speechDelta(segment, spoken):
                    appendSpoken(segment, spoken)
                case let .delta(segment, language, shown):
                    appendCaption(segment, language, shown)
                case let .finished(record):
                    replyRecordedAt[reply] = ContinuousClock.now
                    recordedTurns += 1
                    callOutOfLine += record.outOfLine ? 1 : 0
                    callHurts.append(record.hurt)
                    if let change = record.affinityChange {
                        emit(.affinity(change))
                    }
                    if record.hangUp != nil {
                        pendingHangUp = true
                        pendingCooldownUntil = record.cooldownUntil
                    }
                }
            }
        } catch is CancellationError {
            // The call ended while she was answering.
        } catch let error as EidolonError where error.isInputRejection {
            // The turn was refused for what it heard; the message is the whole of it.
            rejection = error.localizedDescription
        } catch {
            failure = error.localizedDescription
        }
        if !finished {
            finalize(from: 0, before: Int.max)
            // Everything this reply will say has been streamed: a reply being read as text
            // no longer has to wait for more segments.
            settledReply = reply
            wakeSegments()
            // A reply whose voice has not started a while after it was recorded is shown at
            // her pace instead (upstream `linePacing.ts`, `VOICE_WAIT_MS`).
            scheduleLineFallback()
            if let rejection {
                emit(.failed(rejection))
            } else if let failure {
                emit(.failed("她那边没声音：\(failure)"))
            }
        }
        turnActive = false
        if !finished {
            await checkEnding()
        }
        if !finished {
            goOn()
        }
    }

    private func appendSpoken(_ segment: Int, _ text: String) {
        finalize(from: lastFinalized + 1, before: segment)
        speech[segment, default: ""] += text
    }

    private func appendCaption(_ segment: Int, _ language: ReplyLanguage, _ text: String) {
        finalize(from: lastFinalized + 1, before: segment)
        var caption = captions[segment] ?? (ja: "", zh: "")
        switch language {
        case .ja: caption.ja += text
        case .zh: caption.zh += text
        }
        captions[segment] = caption
    }

    /// Segments below `segment` have all they will get: their captions go out, and their
    /// Japanese joins the queue to be voiced. A voiced segment's caption goes out with its
    /// voice (see `drain`), so the line card never runs ahead of what is heard, and a segment
    /// whose voice could not be made leaves the card where it was; a call with no voice at
    /// all shows each caption as it arrives. When a recorded reply's voice does not come,
    /// `scheduleLineFallback` reads it at her pace instead of leaving the card blank.
    private func finalize(from: Int, before segment: Int) {
        // Only segments that were actually heard of: `segment` is Int.max at the end.
        let indices = Set(captions.keys).union(speech.keys).sorted()
        for index in indices where index > lastFinalized && index < segment {
            lastFinalized = index
            let caption = captions[index] ?? (ja: "", zh: "")
            guard !(caption.ja.isEmpty && caption.zh.isEmpty) else { continue }
            judgeEmotion(segment: index)
            let spoken = ReplyCues.spoken(speech[index] ?? "", by: setup.voiceModel)
            if readsAsText(reply) {
                // 只看文字: the card reads every segment at her pace, and no voice is made.
                queue.append((reply: reply, index: index, speech: spoken))
                ensureSpeaking()
                wakeSegments()
            } else if !spoken.isEmpty {
                queue.append((reply: reply, index: index, speech: spoken))
                if !setup.synthesis.providesVoice { showSegment(reply: reply, index: index) }
                ensureSpeaking()
                startPrefetch()
            } else {
                showSegment(reply: reply, index: index)
            }
        }
    }

    /// Her caption for one segment, as the line card shows it. The card only moves forward:
    /// her voice and the fallback may both reach for the same segment, and the one that gets
    /// there second must not turn it again (upstream `shownUpTo`).
    private func showSegment(reply: Int, index: Int) {
        guard index > shownThrough else { return }
        shownThrough = index
        if replyFirstLineAt[reply] == nil { replyFirstLineAt[reply] = ContinuousClock.now }
        let caption = captions[index] ?? (ja: "", zh: "")
        emit(.segment(
            reply: reply,
            segment: index,
            ja: caption.ja.trimmingCharacters(in: .whitespacesAndNewlines),
            zh: caption.zh.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
    }

    // MARK: - The line card when her voice does not come

    /// How long her voice may be missing before the card reads the reply at her pace: as long
    /// as upstream waits after a reply is recorded, and after her voice falls quiet
    /// (`VOICE_WAIT_MS`).
    static let voiceWait = Duration.seconds(3)
    /// Her pace: about five Japanese characters a second, with a line never shorter than this
    /// (`CHARACTERS_PER_SECOND`, `SHORTEST_LINE_MS`).
    static let shortestLineMilliseconds = 1500

    /// Starts the card's fallback when a reply is recorded without her voice having started:
    /// a voice that cannot be made (a refused key, a TLS or network failure, a timeout) must
    /// not leave the producer with a blank card. Her voice starting cancels it; if the voice
    /// starts later, the card jumps to it and stays there (upstream `linePacing.ts`).
    private func scheduleLineFallback() {
        guard !finished, lineFallback == nil, !readsAsText(reply) else { return }
        guard (Set(captions.keys).union(speech.keys)).contains(where: { $0 > shownThrough }) else {
            return
        }
        let answer = reply
        lineFallback = Task { [weak self] in
            try? await Task.sleep(for: Self.voiceWait)
            guard !Task.isCancelled else { return }
            await self?.paceLineCard(reply: answer)
        }
    }

    /// Moves the card through the segments of `answer` at her pace, one at a time, unless her
    /// voice has started and is heard: her voice wins wherever it comes.
    private func paceLineCard(reply answer: Int) async {
        defer {
            if linePacingReply == answer { lineFallback = nil }
        }
        guard !finished, !Task.isCancelled, reply == answer, linePacingReply == answer else {
            return
        }
        for index in (Set(captions.keys).union(speech.keys)).sorted() where index > shownThrough {
            if finished || Task.isCancelled || reply != answer { return }
            // Her voice is being heard: the card follows it instead.
            if voiceStarted, speaking != nil { return }
            let caption = captions[index] ?? (ja: "", zh: "")
            guard !(caption.ja.isEmpty && caption.zh.isEmpty) else { continue }
            showSegment(reply: answer, index: index)
            do {
                try await Task.sleep(for: Self.lineTime(caption.ja))
            } catch {
                return
            }
        }
    }

    /// How long the card keeps one line when it plays out her words at her pace.
    static func lineTime(_ japanese: String) -> Duration {
        let characters = japanese.filter { !$0.isWhitespace }.count
        let milliseconds = max(
            Self.shortestLineMilliseconds,
            Int((Double(characters) / 5 * 1000).rounded())
        )
        return .milliseconds(milliseconds)
    }

    // MARK: - Her segments' emotions

    /// Judges a complete segment's emotion in a task of its own, while it is voiced: the
    /// answer is reported as soon as it comes, and a segment that cannot be judged is
    /// simply left unjudged, never asked again (spec「情绪判断」).
    private func judgeEmotion(segment: Int) {
        guard let judge = setup.emotionJudge, !finished else { return }
        let key = "\(reply):\(segment)"
        guard emotionTasks[key] == nil else { return }
        let caption = captions[segment] ?? (ja: "", zh: "")
        let before = (0..<max(0, segment)).map { index in
            SaidSegment(
                ja: speech[index] ?? captions[index]?.ja ?? "",
                zh: captions[index]?.zh ?? ""
            )
        }
        let question = SegmentToJudge(
            characterName: characterName,
            said: said,
            before: before,
            segment: SaidSegment(ja: speech[segment] ?? caption.ja, zh: caption.zh)
        )
        let reply = reply
        let task = Task { [weak self] in
            let judged = await judge.emotion(in: question)
            await self?.emotionJudged(judged, key: key, reply: reply, segment: segment)
        }
        emotionTasks[key] = task
    }

    /// Reports a segment's emotion for her stand, unless the call has ended or the
    /// judgement was cancelled with it.
    private func emotionJudged(
        _ judged: SegmentEmotion?,
        key: String,
        reply: Int,
        segment: Int
    ) {
        emotionTasks[key] = nil
        guard let judged, !finished, !Task.isCancelled else { return }
        emit(.emotion(
            reply: reply,
            segment: segment,
            emotion: judged.emotion,
            nod: judged.nod
        ))
    }

    // MARK: - Voicing

    /// Whether her reply is read as text rather than voiced: 只看文字 is on now, or it was on
    /// when the reply started (upstream latches whether a reply is voiced as it starts).
    private func readsAsText(_ reply: Int) -> Bool {
        textOnly || textStartedReply == reply
    }

    /// Opens or closes the microphone to the producer: 麦克风静音 keeps it closed for the call, and
    /// it is closed while her own voice plays (ADR-0015).
    private func hear(_ open: Bool) async {
        await setup.capture.setHearing(open && !muted)
    }

    /// Wakes `drain` if it is waiting for the reply being read as text to go on.
    private func wakeSegments() {
        segmentWaiter?.resume()
        segmentWaiter = nil
    }

    /// Waits for the reply being read as text to get another segment or to settle. The
    /// continuation is stored before the suspension, and every path that can end the wait —
    /// `finalize`, the end of `answer`, `finish` — wakes it.
    private func waitForSegment() async {
        guard !finished, reply != settledReply else { return }
        await withCheckedContinuation { continuation in
            segmentWaiter = continuation
        }
    }

    /// Queues the segments of the reply being answered that were finalized but never put on
    /// the card, so 只看文字 turning on mid-answer reads them instead of leaving them lost.
    private func queueUnreadSegments() {
        var added = false
        let indices = Set(captions.keys).union(speech.keys).sorted()
        for index in indices where index > shownThrough && index <= lastFinalized {
            guard index != drainingIndex else { continue }
            guard !queue.contains(where: { $0.reply == reply && $0.index == index }) else {
                continue
            }
            let caption = captions[index] ?? (ja: "", zh: "")
            guard !(caption.ja.isEmpty && caption.zh.isEmpty) else { continue }
            let spoken = ReplyCues.spoken(speech[index] ?? "", by: setup.voiceModel)
            queue.append((reply: reply, index: index, speech: spoken))
            added = true
        }
        if added { ensureSpeaking() }
        wakeSegments()
    }

    private func ensureSpeaking() {
        guard speaking == nil, !finished else { return }
        speaking = Task { await self.drain() }
    }

    /// Voices the queued segments one at a time; one that cannot be voiced is skipped.
    /// The next one is made while the current one plays, so the gap between them stays
    /// short (ADR-0011). A reply being read as text has its segments put on the card at her
    /// pace instead, and no voice is made for it.
    private func drain() async {
        while !finished, !Task.isCancelled {
            if queue.isEmpty {
                // A reply read as text is paced as it arrives: the rest of it may still be
                // on its way, and listening again would cut it short.
                if readsAsText(reply), reply != settledReply {
                    await waitForSegment()
                    continue
                }
                break
            }
            let item = queue.removeFirst()
            drainingIndex = item.index
            setState(.speaking)
            if readsAsText(item.reply) {
                await paceSegment(item)
                drainingIndex = nil
                continue
            }
            do {
                let audio: Data
                if let held = prefetch, held.index == item.index {
                    // The held segment is this one, so it is no longer a prefetch either
                    // way: a failed one must not block the next segment from being made
                    // while this one plays (ADR-0011).
                    prefetch = nil
                    audio = try await held.task.value
                } else {
                    audio = try await setup.synthesis.synthesize(item.speech, voice: voice)
                }
                if finished || Task.isCancelled { break }
                // 只看文字 turned on while this segment was being made: it is read, not
                // played, and the rest of the reply follows it as text.
                if readsAsText(item.reply) {
                    await paceSegment(item)
                    drainingIndex = nil
                    continue
                }
                voiceStarted = true
                lineFallback?.cancel()
                lineFallback = nil
                speakingIndex = item.index
                startPrefetch()
                // Her line card moves as her voice starts on the segment (upstream
                // `linePacing.ts`): a segment skipped above never gets here, so the card
                // does not turn for what was not said.
                if setup.synthesis.providesVoice {
                    showSegment(reply: item.reply, index: item.index)
                }
                if replyFirstVoiceAt[item.reply] == nil {
                    replyFirstVoiceAt[item.reply] = ContinuousClock.now
                }
                emit(.segmentStarted(reply: item.reply, segment: item.index))
                await playWhileDeaf(audio)
                emit(.segmentStopped(reply: item.reply, segment: item.index))
            } catch is CancellationError {
                break
            } catch {
                // A voice service that failed as a service — a refused key, no credit, a
                // model it does not serve — ends the call as the recognizer's failure does,
                // before the producer is left talking into silence. A segment that merely
                // could not be made is lost; the reply goes on (ADR-0011).
                if let failure = setup.synthesis.failure(error) {
                    await serviceFailed(failure)
                    break
                }
            }
            speakingIndex = nil
            drainingIndex = nil
        }
        prefetch?.task.cancel()
        prefetch = nil
        speaking = nil
        if !finished, !Task.isCancelled {
            // Her voice stopped short of the reply, or never started: after a while the card
            // goes on without it (upstream `linePacing.ts`).
            scheduleLineFallback()
        }
        if !finished, !Task.isCancelled {
            await checkEnding()
        }
        if !finished, !Task.isCancelled {
            goOn()
        }
    }

    /// Reads one segment on the card at her pace, with the microphone left open: there is
    /// no voice of hers to echo, and upstream keeps hearing in 只看文字.
    private func paceSegment(_ item: (reply: Int, index: Int, speech: String)) async {
        showSegment(reply: item.reply, index: item.index)
        let caption = captions[item.index] ?? (ja: "", zh: "")
        let line = caption.ja.isEmpty ? item.speech : caption.ja
        try? await Task.sleep(for: Self.lineTime(line))
    }

    /// Plays one segment with the microphone closed: her own voice comes out of the
    /// speaker, and an open microphone would feed it back to the recognizer, where it
    /// would be heard as something the producer said and she would answer herself.
    private func playWhileDeaf(_ audio: Data) async {
        await hear(false)
        do {
            try await setup.playback.play(audio)
        } catch {
            // This segment is lost; the reply goes on.
        }
        await hear(true)
    }

    /// Starts making the next segment while the current one plays, unless there is
    /// nothing next yet; `finalize` calls this again when a later segment arrives.
    private func startPrefetch() {
        guard prefetch == nil, speakingIndex != nil, !finished, !Task.isCancelled,
              let next = queue.first
        else {
            return
        }
        let text = next.speech
        let voice = voice
        let synthesis = setup.synthesis
        prefetch = (next.index, Task.detached {
            try await synthesis.synthesize(text, voice: voice)
        })
    }

    // MARK: - Ending

    /// Ends the call if it has come to an end, in the backend's order: she hangs up, then
    /// the duration, then the turns (upstream `call.py`). Checked after each turn and when
    /// the timer wakes with nothing being said; while she is still speaking it waits for
    /// the drain, so what she has already said is played before the call ends.
    private func checkEnding() async {
        guard !finished, !turnActive, speaking == nil else { return }
        if pendingHangUp {
            pendingHangUp = false
            let until = pendingCooldownUntil
            pendingCooldownUntil = nil
            await finish(.sheHungUp(cooldownUntil: until))
        } else if timeUp, let limit = setup.limits.duration {
            await finish(.durationLimit(limit: limit))
        } else if let limit = setup.limits.turns, recordedTurns >= limit {
            await finish(.turnLimit(turns: recordedTurns))
        }
    }

    private func finish(_ reason: CallEnd) async {
        guard !finished else { return }
        finished = true
        pending.removeAll()
        // She hears nothing more of the producer, and her voice stops at once: hanging up
        // must not leave her talking out of a call that is over.
        await hear(false)
        await setup.playback.stop()
        for task in tasks { task.cancel() }
        listenTask?.cancel()
        listenTask = nil
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        turnTask?.cancel()
        speaking?.cancel()
        wakeSegments()
        lineFallback?.cancel()
        lineFallback = nil
        prefetch?.task.cancel()
        prefetch = nil
        for task in emotionTasks.values { task.cancel() }
        emotionTasks.removeAll()
        record(reason)
        recordCallEnd(reason)
        await trace(reason)
        // The end card speaks for itself; no microphone notice outlives the call.
        setMicNotice(nil)
        // The end card and the record show at once; 挂断音 plays after them, and the
        // microphone and its audio session are held until it is done, so the route does not
        // jump away early (spec #35).
        setState(.ended(reason))
        continuation.finish()
        if started {
            await setup.tones.hangUp()
        }
        await setup.capture.stop()
    }

    /// A call she hung up is kept in the conversation's record (GLOSSARY.md「对话事件」); it
    /// is not a turn, and she is told of it as narration from the next thing said. No other
    /// ending is written there: the producer's own hang-up, a limit, a dropped line or a
    /// call that never connected are only traced, as upstream records them (upstream
    /// `call.py`, `store.py`).
    private func record(_ reason: CallEnd) {
        guard case .sheHungUp = reason else { return }
        guard let conversationID = (try? eidolon.currentConversationIDNow(characterID)) ?? nil else {
            return
        }
        try? eidolon.recordConversationEvent(
            conversationID: conversationID,
            kind: ConversationEventKind.hungUp.rawValue,
            at: setup.now()
        )
    }

    /// When a call that connected ended: "when did we last talk" counts it, as upstream's
    /// `calls` table does. A call that never connected was no contact.
    private func recordCallEnd(_ reason: CallEnd) {
        switch reason {
        case .notConnected, .micDenied: return
        default: break
        }
        guard let conversationID = (try? eidolon.currentConversationIDNow(characterID)) ?? nil else {
            return
        }
        try? eidolon.recordCallEnd(
            conversationID: conversationID,
            characterID: characterID,
            at: setup.now()
        )
    }

    /// How the call ended is kept in the traces too (ADR-0012): the reason, and what else
    /// the end says — the failing voice service, the limit, or when a cooldown ends.
    private func trace(_ reason: CallEnd) async {
        guard setup.tracing.enabled else { return }
        var notes = ["通话结束：\(reason.reason)"]
        if let detail = reason.detail { notes.append(detail) }
        let conversationID = (try? eidolon.currentConversationIDNow(characterID)) ?? nil
        try? await eidolon.writeTrace(
            TurnTrace(
                characterID: characterID,
                degradation: notes,
                callTimings: callTimingSummary()
            ),
            conversationID: conversationID,
            createdAt: Eidolon.timestamp(setup.now()),
            tracing: setup.tracing
        )
    }

    /// Each reply's latency, as the call's trace keeps it: from the end of the producer's
    /// line to her reply, to the first line on the card, and to the first voice.
    private func callTimingSummary() -> CallTimings? {
        let replies = replyRecognizedAt.keys.sorted()
        guard !replies.isEmpty else { return nil }
        let turns = replies.compactMap { reply -> CallTimings.Turn? in
            guard let recognized = replyRecognizedAt[reply] else { return nil }
            let recorded = replyRecordedAt[reply]
            let line = replyFirstLineAt[reply]
            let voice = replyFirstVoiceAt[reply]
            let wait: Double?
            if let recorded, let voice {
                wait = (voice - recorded).inSeconds
            } else {
                wait = nil
            }
            return CallTimings.Turn(
                reply: reply,
                replyDelay: recorded.map { ($0 - recognized).inSeconds },
                voiceWait: wait,
                firstVoice: voice.map { ($0 - recognized).inSeconds },
                firstLine: line.map { ($0 - recognized).inSeconds }
            )
        }
        return CallTimings(turns: turns)
    }

    private func setState(_ next: CallState) {
        guard state != next else { return }
        state = next
        emit(.state(next))
    }

    private func emit(_ event: CallEvent) {
        continuation.yield(event)
    }
}

extension Eidolon {
    /// Begins a call with her: she must not be cooling down, and her conversation must
    /// not be one she ended (a new conversation has to be started first).
    public func beginCall(
        characterID: String,
        setup: CallSetup,
        now: Date = Date()
    ) async throws -> CallSession {
        guard let character = try characters().first(where: { $0.id == characterID }) else {
            throw EidolonError.invalidContent("找不到角色 \(characterID)")
        }
        guard let voiceID = character.voiceID, !voiceID.isEmpty else {
            throw EidolonError.invalidContent("角色 \(characterID) 没有音色")
        }
        let affinity = try readAffinity(characterID: characterID, now: now)
        if let until = affinity.cooldownUntil {
            throw EidolonError.coolingDown(until)
        }
        if let current = try currentConversationID(characterID),
           try isEnded(conversationID: current) {
            throw EidolonError.conversationEnded
        }
        return CallSession(
            eidolon: self,
            characterID: characterID,
            characterName: character.name,
            voice: CallVoice(id: voiceID, model: setup.voiceModel),
            setup: setup
        )
    }

    /// The current conversation's id, read without hopping through the actor from a call's
    /// ending: `currentConversationID` is actor-isolated, and a call is an actor of its own.
    nonisolated func currentConversationIDNow(_ characterID: String) throws -> String? {
        try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT id FROM conversations WHERE character_id = ?
                    ORDER BY created_at DESC, rowid DESC LIMIT 1
                    """,
                arguments: [characterID]
            )
        }
    }

    nonisolated func recordConversationEvent(
        conversationID: String,
        kind: String,
        at moment: Date
    ) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation_events(conversation_id, kind, created_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [conversationID, kind, Self.timestamp(moment)]
            )
        }
    }

    nonisolated func recordCallEnd(
        conversationID: String,
        characterID: String,
        at moment: Date
    ) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO call_ends(conversation_id, character_id, ended_at)
                    VALUES (?, ?, ?)
                    """,
                arguments: [conversationID, characterID, Self.timestamp(moment)]
            )
        }
    }
}
