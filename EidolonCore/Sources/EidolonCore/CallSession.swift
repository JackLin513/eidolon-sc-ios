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
}

/// The speaker, as the call uses it: one segment's audio at a time.
public protocol AudioPlayback: Sendable {
    func play(_ audio: Data) async throws
    func stop() async
}

/// What the recognizer heard.
public enum SpeechEvent: Sendable, Hashable {
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
    func synthesize(_ text: String, voice: CallVoice) async throws -> Data
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

/// Why a call ended: the backend's reasons and its own words (upstream
/// `call_outcome.py`).
public enum CallEnd: Sendable, Hashable {
    /// The voice service failed before a turn was recorded: the call never connected.
    case notConnected(service: String, detail: String)
    /// The voice service failed after at least one turn: the call broke off.
    case dropped(service: String, detail: String)
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
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(
            format: "%g",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [seconds / 60]
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
    /// One of her segments, for the subtitle. Delivery cues are stripped. `reply` numbers
    /// her replies in the call from 0 (each answer she gives is one); `segment` numbers its
    /// segments from 0.
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
        self.now = now
    }
}

/// One call with her (GLOSSARY.md「通话」): the microphone, the recognizer, her turns and
/// her voice, from the silent connection to the hang-up. The app only feeds it audio
/// services and shows what it says; everything else is here (ADR-0007, ADR-0015).
public actor CallSession {
    public nonisolated let characterID: String

    private let eidolon: Eidolon
    private let characterName: String
    private let setup: CallSetup
    private let voice: CallVoice
    private let stream: AsyncStream<CallEvent>
    private let continuation: AsyncStream<CallEvent>.Continuation

    private var state: CallState = .connecting
    private var started = false
    private var finished = false
    private var tasks: [Task<Void, Never>] = []
    private var turnTask: Task<Void, Never>?

    /// What the producer said while she was answering; answered once she is done.
    private var pending: [String] = []
    /// Her Japanese being said, by segment, delivery cues kept, for the voice.
    private var speech: [Int: String] = [:]
    /// Her segments as shown, by segment, for the subtitle.
    private var captions: [Int: (ja: String, zh: String)] = [:]
    private var lastFinalized = -1
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
    /// nothing until the producer speaks.
    public func start() async {
        guard !started, !finished else { return }
        started = true
        setState(.connecting)
        do {
            try await setup.capture.start()
        } catch {
            await finish(.notConnected(service: "麦克风", detail: error.localizedDescription))
            return
        }
        setState(.listening)
        tasks.append(Task { await self.listenLoop() })
        if setup.limits.duration != nil {
            tasks.append(Task { await self.timeLimitLoop() })
        }
    }

    public func hangUp() async {
        await finish(.hungUpByProducer)
    }

    // MARK: - Listening

    private func listenLoop() async {
        var listeningAgain = false
        while !finished, !Task.isCancelled {
            if listeningAgain {
                // The recognizer took a new connection: it hears again.
                setState(.listening)
            }
            listeningAgain = true
            // The microphone feeds this connection only: the previous connection closed
            // its stream when it closed, and that ended stream would hear nothing.
            let audio = setup.capture.chunks()
            do {
                for try await event in setup.recognition.listen(audio) {
                    if finished || Task.isCancelled { return }
                    switch event {
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
                setState(.reconnecting)
                try? await Task.sleep(for: setup.reconnectDelay)
            } catch is CancellationError {
                return
            } catch {
                if finished || Task.isCancelled { return }
                if let failure = setup.recognition.failure(error) {
                    await serviceFailed(failure)
                    return
                }
                setState(.reconnecting)
                try? await Task.sleep(for: setup.reconnectDelay)
            }
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
            if queue.isEmpty { setState(.listening) }
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
        said = text
        speech.removeAll()
        captions.removeAll()
        lastFinalized = -1
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
                    recordedTurns += 1
                    callOutOfLine += record.outOfLine ? 1 : 0
                    callHurts.append(record.hurt)
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
    /// Japanese joins the queue to be voiced.
    private func finalize(from: Int, before segment: Int) {
        // Only segments that were actually heard of: `segment` is Int.max at the end.
        let indices = Set(captions.keys).union(speech.keys).sorted()
        for index in indices where index > lastFinalized && index < segment {
            lastFinalized = index
            let caption = captions[index] ?? (ja: "", zh: "")
            guard !(caption.ja.isEmpty && caption.zh.isEmpty) else { continue }
            emit(.segment(
                reply: reply,
                segment: index,
                ja: caption.ja.trimmingCharacters(in: .whitespacesAndNewlines),
                zh: caption.zh.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            judgeEmotion(segment: index)
            let spoken = ReplyCues.spoken(speech[index] ?? "", by: setup.voiceModel)
            if !spoken.isEmpty {
                queue.append((reply: reply, index: index, speech: spoken))
                ensureSpeaking()
                startPrefetch()
            }
        }
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

    private func ensureSpeaking() {
        guard speaking == nil, !finished else { return }
        speaking = Task { await self.drain() }
    }

    /// Voices the queued segments one at a time; one that cannot be voiced is skipped.
    /// The next one is made while the current one plays, so the gap between them stays
    /// short (ADR-0011).
    private func drain() async {
        while !finished, !Task.isCancelled, !queue.isEmpty {
            let item = queue.removeFirst()
            setState(.speaking)
            do {
                let audio: Data
                if let held = prefetch, held.index == item.index {
                    audio = try await held.task.value
                    if prefetch?.index == held.index { prefetch = nil }
                } else {
                    audio = try await setup.synthesis.synthesize(item.speech, voice: voice)
                }
                if finished || Task.isCancelled { break }
                speakingIndex = item.index
                startPrefetch()
                emit(.segmentStarted(reply: item.reply, segment: item.index))
                await playWhileDeaf(audio)
                emit(.segmentStopped(reply: item.reply, segment: item.index))
            } catch is CancellationError {
                break
            } catch {
                // This segment is lost; the reply goes on.
            }
            speakingIndex = nil
        }
        prefetch?.task.cancel()
        prefetch = nil
        speaking = nil
        if !finished, !Task.isCancelled {
            await checkEnding()
        }
        if !finished, !Task.isCancelled {
            goOn()
        }
    }

    /// Plays one segment with the microphone closed: her own voice comes out of the
    /// speaker, and an open microphone would feed it back to the recognizer, where it
    /// would be heard as something the producer said and she would answer herself.
    private func playWhileDeaf(_ audio: Data) async {
        await setup.capture.setHearing(false)
        do {
            try await setup.playback.play(audio)
        } catch {
            // This segment is lost; the reply goes on.
        }
        await setup.capture.setHearing(true)
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
        for task in tasks { task.cancel() }
        turnTask?.cancel()
        speaking?.cancel()
        prefetch?.task.cancel()
        prefetch = nil
        for task in emotionTasks.values { task.cancel() }
        emotionTasks.removeAll()
        await setup.capture.stop()
        await setup.playback.stop()
        record(reason)
        await trace(reason)
        setState(.ended(reason))
        continuation.finish()
    }

    /// A call she hung up is kept in the conversation's record (GLOSSARY.md「对话事件」); it
    /// is not a turn, and she is not told of it. No other ending is written there: the
    /// producer's own hang-up, a limit, a dropped line or a call that never connected are
    /// only traced, as upstream records them (upstream `call.py`, `store.py`).
    private func record(_ reason: CallEnd) {
        guard case .sheHungUp = reason else { return }
        guard let conversationID = (try? eidolon.currentConversationIDNow(characterID)) ?? nil else {
            return
        }
        try? eidolon.recordConversationEvent(
            conversationID: conversationID,
            kind: "hung_up",
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
            TurnTrace(characterID: characterID, degradation: notes),
            conversationID: conversationID,
            createdAt: Eidolon.timestamp(setup.now()),
            tracing: setup.tracing
        )
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
}
