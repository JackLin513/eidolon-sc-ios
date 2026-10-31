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
    }

    /// One reading of everything the store shows: the turns, the record and how she feels.
    private struct Snapshot {
        var messages: [ChatMessageRecord] = []
        var lines: [ConversationLine] = []
        var ended = false
        var isPast = false
        var affinity = AffinityStatus(tier: .trust, cooldownUntil: nil)
    }

    /// Reads the sources into a snapshot instead of putting them on screen: a turn takes the
    /// result and drops its streaming bubble in one step, so no frame shows neither (spec #42).
    /// A failed read says so and returns nothing, leaving what is shown as it is.
    private func read() async -> Snapshot? {
        var reading = Snapshot()
        do {
            var conversation: String?
            if let conversationID, let past = try await core.conversation(id: conversationID) {
                reading.messages = past.messages
                reading.ended = past.ended
                reading.isPast = true
                conversation = past.id
            } else if let current = try await core.currentConversation(characterID: character.id) {
                reading.messages = current.messages
                reading.ended = current.ended
                reading.isPast = false
                conversation = current.id
            }
            if let conversation {
                reading.lines = try await core.conversationRecord(conversationID: conversation)
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
        historyTurns: Int = 20,
        tracing: TurnTracing = .on
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
            historyTurns: historyTurns,
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
            // The recorded line is put in place first and the bubbles go in the same unsuspended
            // step, so no frame shows the turn gone from both (spec #42). Success, failure and
            // being cut off by the next line all end here. A read that fails takes nothing away:
            // her words stay on screen, and the next read that works replaces them.
            if let reading = await self.read() {
                self.apply(reading)
                self.streaming = []
                self.pendingUser = nil
            }
            self.isStreaming = false
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
                lines = (try? await core.conversationRecord(conversationID: snapshot.id)) ?? lines
                return
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
