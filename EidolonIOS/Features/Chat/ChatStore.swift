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
    /// Calls hung up or failed in this conversation; shown between the turns.
    private(set) var events: [ConversationEventRecord] = []
    private(set) var streaming: [ReplySegment] = []
    /// The line being answered; recorded only when the turn finishes, but shown at once.
    private(set) var pendingUser: String?
    private(set) var isStreaming = false
    private(set) var affinity = AffinityStatus(tier: .trust, cooldownUntil: nil)
    /// She ended this conversation: it can only be read, until a new one starts.
    private(set) var ended = false
    /// A past conversation, opened to look at: read-only, always.
    private(set) var isPast = false
    /// The conversation this store shows; nil for the current one.
    private let conversationID: String?
    var input = ""
    var errorMessage: String?

    private var task: Task<Void, Never>?

    init(character: CharacterConfig, core: Eidolon, conversationID: String? = nil) {
        self.character = character
        self.core = core
        self.conversationID = conversationID
    }

    var readOnly: Bool { isPast || ended }

    /// The conversation in order: turns and what happened around them.
    var transcript: [ChatLine] {
        let lines = messages.map(ChatLine.message) + events.map(ChatLine.event)
        return lines.sorted { left, right in
            if left.createdAt == right.createdAt { return left.id < right.id }
            return left.createdAt < right.createdAt
        }
    }

    func load() async {
        do {
            if let conversationID, let past = try await core.conversation(id: conversationID) {
                messages = past.messages
                ended = past.ended
                isPast = true
                events = try await core.conversationEvents(conversationID: conversationID)
            } else if let current = try await core.currentConversation(characterID: character.id) {
                messages = current.messages
                ended = current.ended
                isPast = false
                events = try await core.conversationEvents(conversationID: current.id)
                if !ended {
                    try await core.markReachOutsSeen(conversationID: current.id)
                }
            } else {
                messages = []
                ended = false
                isPast = false
                events = []
            }
            affinity = try await core.affinityStatus(characterID: character.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Starts a new conversation after she ended the last one, and shows it.
    func startNewConversation() async {
        guard !isPast else { return }
        do {
            try await core.startConversation(characterID: character.id)
            ended = false
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Sends the input as a turn. If she is still speaking, the reply is cut off and
    /// what she already said is kept, as upstream does when the producer types again.
    func send(
        provider: any ChatProvider,
        judge: (any JudgeProvider)?,
        embedder: (any EmbeddingProvider)?,
        reranker: (any RerankProvider)?,
        tracing: TurnTracing = .on
    ) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !affinity.cooling, !readOnly else { return }

        if isStreaming {
            let countBefore = messages.count
            task?.cancel()
            await task?.value
            await waitForPersisted(above: countBefore)
        }

        input = ""
        errorMessage = nil
        streaming = []
        pendingUser = text
        isStreaming = true

        let stream = core.sendTurn(
            characterID: character.id,
            text: text,
            provider: provider,
            judge: judge,
            embedder: embedder,
            reranker: reranker,
            tracing: tracing
        )
        let turn = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    switch event {
                    case let .delta(segment, language, shown):
                        append(segment: segment, language: language, text: shown)
                    case .speechDelta:
                        break
                    case let .finished(record):
                        affinity = AffinityStatus(
                            tier: record.affinityTier,
                            cooldownUntil: record.cooldownUntil
                        )
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
            self.isStreaming = false
            self.streaming = []
            self.pendingUser = nil
            await self.load()
        }
        task = turn
        await turn.value
    }

    func stop() {
        task?.cancel()
    }

    private func append(segment: Int, language: ReplyLanguage, text: String) {
        while streaming.count <= segment {
            streaming.append(ReplySegment())
        }
        switch language {
        case .ja: streaming[segment].ja += text
        case .zh: streaming[segment].zh += text
        }
    }

    /// The engine persists a stopped reply after the consumer goes away; give it a
    /// moment before the next turn reads the history back.
    private func waitForPersisted(above count: Int) async {
        for _ in 0..<20 {
            if let snapshot = try? await core.currentConversation(characterID: character.id),
               snapshot.messages.count > count {
                messages = snapshot.messages
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
