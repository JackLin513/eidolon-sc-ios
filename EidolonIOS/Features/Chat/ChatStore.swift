import EidolonCore
import Foundation
import Observation

/// One conversation with one character: the recorded turns, the reply being streamed,
/// how she feels about the producer, and what to show when something fails.
@MainActor
@Observable
final class ChatStore {
    let character: CharacterConfig
    private let core: Eidolon

    private(set) var messages: [ChatMessageRecord] = []
    /// The conversation in the database's order: turns, her reach-outs and what happened
    /// around them (GLOSSARY.md「对话事件」). Nothing here is reordered.
    private(set) var lines: [ConversationLine] = []
    private(set) var streaming: [ReplyBlock] = []
    /// The line being answered; recorded only when the turn finishes, but shown at once.
    private(set) var pendingUser: String?
    private(set) var isStreaming = false
    private(set) var affinity = AffinityStatus(tier: .trust, cooldownUntil: nil)
    /// The change the last turn made, shown on the badge for a moment (spec #38).
    private(set) var affinityCue: AffinityCue?
    /// She ended this conversation: it can only be read, until a new one starts.
    private(set) var ended = false
    /// A past conversation, opened to look at: read-only, always.
    private(set) var isPast = false
    /// The past conversation this store was opened with; nil for the current one.
    private let pastConversationID: String?
    /// The conversation the page is actually on: the past one it was opened with, or the
    /// current one it resolved. nil before there has ever been a conversation. The debug
    /// page works on this one (spec #62).
    private(set) var activeConversationID: String?
    var input = ""
    var errorMessage: String?
    /// When she was asked for a picture this hour's allowance was gone: the feed says so
    /// until the next turn (ticket #102).
    private(set) var photoRetryAt: Date?
    /// This conversation is spoken face to face rather than as messages. It belongs to
    /// the conversation and is kept on this phone.
    private(set) var faceToFace = false
    /// What a finished turn unlocked, for the toast (spec #69).
    var onRewards: (([AchievementReward]) -> Void)?

    private var task: Task<Void, Never>?
    private var cueTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var cueKey = 0

    init(character: CharacterConfig, core: Eidolon, conversationID: String? = nil) {
        self.character = character
        self.core = core
        self.pastConversationID = conversationID
    }

    var readOnly: Bool { isPast || ended }

    /// The conversation in order: turns and what happened around them.
    var transcript: [ConversationLine] { lines }

    func load() async {
        guard let reading = await read() else { return }
        apply(reading)
        // A turn that could not read its record leaves her words on screen as they are; a
        // later read that does find them takes their place (spec #42). While a turn is
        // running, the streaming text is live and stays.
        if !isStreaming {
            streaming = []
            pendingUser = nil
        }
        watchPendingPhotos()
    }

    /// One reading of everything the store shows: the turns, the record and how she feels.
    private struct Snapshot {
        var messages: [ChatMessageRecord] = []
        var lines: [ConversationLine] = []
        var ended = false
        var isPast = false
        var affinity = AffinityStatus(tier: .trust, cooldownUntil: nil)
        var conversationID: String?
        /// nil when there is no conversation yet, so the page's pending choice stays.
        var faceToFace: Bool?
    }

    /// Reads the sources into a snapshot instead of putting them on screen: a turn takes the
    /// result and drops its streaming bubble in one step, so no frame shows neither (spec #42).
    /// A failed read says so and returns nothing, leaving what is shown as it is.
    private func read() async -> Snapshot? {
        var reading = Snapshot()
        do {
            var conversation: String?
            if let pastConversationID, let past = try await core.conversation(id: pastConversationID) {
                reading.messages = past.messages
                reading.ended = past.ended
                reading.isPast = true
                reading.faceToFace = past.faceToFace
                conversation = past.id
            } else if let current = try await core.currentConversation(characterID: character.id) {
                reading.messages = current.messages
                reading.ended = current.ended
                reading.isPast = false
                reading.faceToFace = current.faceToFace
                conversation = current.id
            }
            if let conversation {
                reading.lines = try await core.conversationRecord(conversationID: conversation)
                reading.conversationID = conversation
            }
            reading.affinity = try await core.affinityStatus(characterID: character.id)
            if let conversation, !reading.isPast, !reading.ended {
                try await core.markReachOutsSeen(conversationID: conversation)
            }
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
        return reading
    }

    private func apply(_ reading: Snapshot) {
        messages = reading.messages
        lines = reading.lines
        ended = reading.ended
        isPast = reading.isPast
        affinity = reading.affinity
        activeConversationID = reading.conversationID
        if let faceToFace = reading.faceToFace {
            self.faceToFace = faceToFace
        }
    }

    /// Whether 新对话 can be used: there is something in this conversation to leave
    /// behind, and no reply is being written. The page adds its own call condition
    /// (spec #37).
    var canStartNewConversation: Bool {
        !lines.isEmpty && !isStreaming
    }

    /// Starts another conversation and leaves this one behind — not ended, not touched;
    /// it falls into the history. In a past conversation the new one is the current one,
    /// and the page that opened it closes (spec #37). Says whether it was written.
    @discardableResult
    func startNewConversation() async -> Bool {
        guard canStartNewConversation else { return false }
        do {
            try await core.beginNewConversation(characterID: character.id)
            if !isPast {
                ended = false
                input = ""
                await load()
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Sends the input as a turn. If she is still speaking, the reply is cut off and
    /// what she already said is kept, as upstream does when the producer types again.
    func send(
        provider: any ChatProvider,
        background: (any ChatProvider)? = nil,
        judge: (any JudgeProvider)?,
        embedder: (any EmbeddingProvider)?,
        reranker: (any RerankProvider)?,
        historyTurns: Int = 20,
        tracing: TurnTracing = .on,
        replyStyle: ReplyStyle = .text,
        adultMode: Bool = false,
        photo: PhotoTurnContext? = nil,
        faceToFace: Bool = false
    ) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !affinity.cooling, !readOnly else { return }
        // A line the turn refuses is refused before her current reply is cut off for it.
        do {
            _ = try TurnInput.checked(text)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        if isStreaming {
            let countBefore = messages.count
            task?.cancel()
            await task?.value
            await waitForPersisted(above: countBefore)
        }

        input = ""
        errorMessage = nil
        photoRetryAt = nil
        streaming = []
        pendingUser = text
        isStreaming = true

        let stream = core.sendTurn(
            characterID: character.id,
            text: text,
            provider: provider,
            background: background,
            judge: judge,
            embedder: embedder,
            reranker: reranker,
            historyTurns: historyTurns,
            tracing: tracing,
            replyStyle: replyStyle,
            adultMode: adultMode,
            faceToFace: faceToFace,
            photo: photo
        )
        let turn = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    switch event {
                    case let .delta(block, language, shown):
                        append(block: block, language: language, text: shown)
                    case let .sceneDelta(block, shown):
                        appendScene(block: block, text: shown)
                    case .speechDelta:
                        break
                    case .photo:
                        // The photo's row is written with the reply; what is still
                        // pending after the turn is followed until it lands (see
                        // `watchPendingPhotos`).
                        break
                    case let .photosUsedUp(retryAt):
                        photoRetryAt = retryAt
                    case let .finished(record):
                        affinity = AffinityStatus(
                            tier: record.affinityTier,
                            cooldownUntil: record.cooldownUntil
                        )
                        if let change = record.affinityChange {
                            showAffinityCue(change)
                        }
                        onRewards?(record.achievements)
                        ended = record.ended
                    }
                }
            } catch let error as EidolonError {
                if case let .coolingDown(until) = error {
                    affinity = AffinityStatus(tier: affinity.tier, cooldownUntil: until)
                }
                self.errorMessage = error.localizedDescription
                self.input = text
            } catch {
                self.errorMessage = error.localizedDescription
                self.input = text // keep it for the retry
            }
            // The recorded line is put in place first and the bubbles go in the same unsuspended
            // step, so no frame shows the turn gone from both (spec #42). Success, failure and
            // being cut off by the next line all end here. A read that fails takes nothing away:
            // her words stay on screen, and the next read that works replaces them.
            if let reading = await self.read() {
                self.apply(reading)
                self.streaming = []
                self.pendingUser = nil
                self.watchPendingPhotos()
            }
            self.isStreaming = false
        }
        task = turn
        await turn.value
    }

    func stop() {
        task?.cancel()
    }

    /// The toolbar's 面对面 switch. It changes the context of the next turn and is kept on
    /// the conversation; with no conversation yet, the next turn creates one with it.
    func toggleFaceToFace() async {
        guard !readOnly else { return }
        faceToFace.toggle()
        guard let activeConversationID else { return }
        do {
            try await core.setFaceToFace(faceToFace, conversationID: activeConversationID)
        } catch {
            faceToFace.toggle()
            errorMessage = error.localizedDescription
        }
    }

    /// A photo strays from its reply while the turn is still being read: the image is made
    /// after the reply is recorded, so the row says pending until it lands. This looks
    /// again until nothing is pending, so the picture appears without leaving the page.
    private func watchPendingPhotos() {
        photoTask?.cancel()
        guard hasPendingPhoto else { return }
        photoTask = Task { @MainActor [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                guard self.hasPendingPhoto else { return }
                if let reading = await self.read() {
                    self.apply(reading)
                }
            }
        }
    }

    private var hasPendingPhoto: Bool {
        messages.contains { $0.photo?.status == .pending }
    }

    /// Shows the change on the badge for about 2.6 seconds; a second one replaces it and
    /// starts the time over (spec #38).
    private func showAffinityCue(_ change: AffinityChange) {
        cueTask?.cancel()
        cueKey += 1
        affinityCue = AffinityCue(change: change, key: cueKey)
        cueTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            self?.affinityCue = nil
        }
    }

    private func append(block: Int, language: ReplyLanguage, text: String) {
        while streaming.count <= block {
            streaming.append(.line(ReplySegment()))
        }
        guard case var .line(line) = streaming[block] else { return }
        switch language {
        case .ja: line.ja += text
        case .zh: line.zh += text
        }
        streaming[block] = .line(line)
    }

    private func appendScene(block: Int, text: String) {
        while streaming.count <= block {
            streaming.append(.line(ReplySegment()))
        }
        switch streaming[block] {
        case var .scene(scene):
            scene += text
            streaming[block] = .scene(scene)
        case .line:
            streaming[block] = .scene(text)
        }
    }

    /// The engine persists a stopped reply after the consumer goes away; give it a
    /// moment before the next turn reads the history back.
    private func waitForPersisted(above count: Int) async {
        for _ in 0..<20 {
            if let snapshot = try? await core.currentConversation(characterID: character.id),
               snapshot.messages.count > count {
                messages = snapshot.messages
                lines = (try? await core.conversationRecord(conversationID: snapshot.id)) ?? lines
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
