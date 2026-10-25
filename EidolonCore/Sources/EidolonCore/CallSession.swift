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

/// Real-time speech to text over a live audio stream. A stream that ends or throws is a
/// connection lost; the call reconnects and listens again.
public protocol SpeechRecognition: Sendable {
    func listen(_ audio: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SpeechEvent, Error>
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

public enum CallEnd: Sendable, Hashable {
    case hungUpByProducer
    case timeLimit
    case failed(String)
}

public enum CallEvent: Sendable, Hashable {
    case state(CallState)
    /// What the producer is saying, as the recognizer revises it; each replaces the last,
    /// and an empty one clears it.
    case hearing(String)
    /// What the producer said, when the recognizer found the end of it.
    case recognized(String)
    /// One of her segments, for the subtitle. Delivery cues are stripped.
    case segment(index: Int, ja: String, zh: String)
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
    public var embedder: (any EmbeddingProvider)?
    public var reranker: (any RerankProvider)?
    public var tracing: TurnTracing
    public var timeLimit: Duration
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
        embedder: (any EmbeddingProvider)? = nil,
        reranker: (any RerankProvider)? = nil,
        tracing: TurnTracing = .on,
        timeLimit: Duration = .seconds(3600),
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
        self.embedder = embedder
        self.reranker = reranker
        self.tracing = tracing
        self.timeLimit = timeLimit
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
    private var queue: [(index: Int, speech: String)] = []
    /// The segment after the one playing, being made while it plays.
    private var prefetch: (index: Int, task: Task<Data, Error>)?
    /// The segment whose audio is playing, if any.
    private var speakingIndex: Int?
    private var speaking: Task<Void, Never>?
    private var turnActive = false

    init(eidolon: Eidolon, characterID: String, voice: CallVoice, setup: CallSetup) {
        self.eidolon = eidolon
        self.characterID = characterID
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
            await finish(.failed(error.localizedDescription))
            return
        }
        setState(.listening)
        tasks.append(Task { await self.listenLoop() })
        tasks.append(Task { await self.timeLimitLoop() })
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
                setState(.reconnecting)
                try? await Task.sleep(for: setup.reconnectDelay)
            }
        }
    }

    private func timeLimitLoop() async {
        try? await Task.sleep(for: setup.timeLimit)
        if !Task.isCancelled, !finished {
            await finish(.timeLimit)
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
        speech.removeAll()
        captions.removeAll()
        lastFinalized = -1
        var failure: String?
        do {
            for try await event in eidolon.sendTurn(
                characterID: characterID,
                text: text,
                provider: setup.provider,
                judge: setup.judge,
                embedder: setup.embedder,
                reranker: setup.reranker,
                now: setup.now(),
                tracing: setup.tracing,
                talking: .inCall,
                voicedBy: setup.voiceModel
            ) {
                if finished || Task.isCancelled { break }
                switch event {
                case let .speechDelta(segment, spoken):
                    appendSpoken(segment, spoken)
                case let .delta(segment, language, shown):
                    appendCaption(segment, language, shown)
                case .finished:
                    break
                }
            }
        } catch is CancellationError {
            // The call ended while she was answering.
        } catch {
            failure = error.localizedDescription
        }
        if !finished {
            finalize(from: 0, before: Int.max)
            if let failure {
                emit(.failed("她那边没声音：\(failure)"))
            }
        }
        turnActive = false
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
                index: index,
                ja: caption.ja.trimmingCharacters(in: .whitespacesAndNewlines),
                zh: caption.zh.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            let spoken = speech[index] ?? ""
            if !spoken.isEmpty {
                queue.append((index: index, speech: spoken))
                ensureSpeaking()
                startPrefetch()
            }
        }
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
                await playWhileDeaf(audio)
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

    private func finish(_ reason: CallEnd) async {
        guard !finished else { return }
        finished = true
        for task in tasks { task.cancel() }
        turnTask?.cancel()
        speaking?.cancel()
        prefetch?.task.cancel()
        prefetch = nil
        await setup.capture.stop()
        await setup.playback.stop()
        record(reason)
        setState(.ended(reason))
        continuation.finish()
    }

    /// The call is kept in the conversation's record (GLOSSARY.md「对话事件」): it is not
    /// a turn, and she is not told of it.
    private func record(_ reason: CallEnd) {
        guard let conversationID = try? eidolon.currentConversationIDNow(characterID) else {
            return
        }
        let kind = switch reason {
        case .hungUpByProducer, .timeLimit: "hung_up"
        case .failed: "call_failed"
        }
        try? eidolon.recordConversationEvent(
            conversationID: conversationID,
            kind: kind,
            at: setup.now()
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
