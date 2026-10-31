import EidolonCore
import SwiftUI

struct ChatView: View {
    let character: CharacterConfig
    /// A past conversation to look at; nil shows the current one.
    var conversationID: String? = nil

    @Environment(AppModel.self) private var app
    @State private var store: ChatStore?
    @State private var didAutoSend = false
    @State private var showHistory = false
    @State private var showCall = false
    /// Her stand, only so the toolbar can offer her clothes from here (spec #35): the chat
    /// page draws none of it. Nil while it has not been read, or when she has none.
    @State private var outfitsStand: CharacterStand?
    @State private var outfitsChecked = false
    @State private var showsOutfits = false

    var body: some View {
        Group {
            if let store {
                VStack(spacing: 0) {
                    transcript(store)
                    if store.isPast {
                        pastBar
                    } else if store.affinity.cooling {
                        coolingBar(store)
                    } else if store.ended {
                        endedBar(store)
                    }
                    if let error = store.errorMessage {
                        errorBar(store, error)
                    }
                    if !store.readOnly {
                        inputBar(store)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if outfitsStand != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsOutfits = true
                    } label: {
                        Image(systemName: "tshirt")
                    }
                    .accessibilityLabel("换衣装")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCall = true
                } label: {
                    Image(systemName: "phone")
                }
                .disabled(store?.readOnly == true || store?.affinity.cooling == true)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHistory = true
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(character.name)
                        .font(.headline)
                    if let store {
                        Text(store.affinity.tier.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: showCall) { _, isCalling in
            // A call has her voice; 朗读 lets go of it the moment one starts.
            if isCalling { app.readAloud.stop() }
        }
        .onChange(of: conversationID) { app.readAloud.stop() }
        .onDisappear {
            app.readAloud.stop()
            // Leaving the chat page also lets the call's sounds go (spec #35).
            app.callTones.silence()
        }
        .fullScreenCover(isPresented: $showsOutfits) {
            if let stand = outfitsStand {
                OutfitPickerView(
                    character: character,
                    stand: stand,
                    contentRoot: stand.root ?? app.core.location.contentDirectory,
                    contentVersion: app.standInfo?.installedAt ?? app.bundleInfo?.installedAt ?? "current",
                    onWear: { _ in },
                    onClose: { showsOutfits = false }
                )
            }
        }
        .fullScreenCover(isPresented: $showCall, onDismiss: {
            // What the call wrote is shown at once: its turns, her hang-up, the affinity and
            // any cooldown (spec「返回刷新」).
            Task { await store?.load() }
        }) {
            CallView(character: character)
                .environment(app)
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ConversationHistoryView(character: character)
            }
            .environment(app)
        }
        .task {
            guard store == nil else { return }
            let created = ChatStore(
                character: character,
                core: app.core,
                conversationID: conversationID
            )
            await created.load()
            store = created
            autoSendIfRequested(created)
            #if DEBUG
            if app.debugShowsHistory { showHistory = true }
            if app.debugOpensCall, !created.readOnly { showCall = true }
            #endif
        }
        .task {
            // The clothes button only exists for a character who has a stand to dress
            // (spec #35); reading it is no use on the chat page otherwise.
            guard !outfitsChecked else { return }
            outfitsChecked = true
            outfitsStand = await app.core.stand(for: character.id)
        }
    }

    /// Development aid: `SIMCTL_CHILD_EIDOLON_SEND_TEXT` sends one line on opening, so
    /// the simulator can show a real turn without the keyboard.
    private func autoSendIfRequested(_ store: ChatStore) {
        #if DEBUG
        guard conversationID == nil,
              !didAutoSend,
              let text = app.debugSendText,
              !text.isEmpty,
              let provider = app.chatProvider
        else { return }
        didAutoSend = true
        store.input = text
        Task { await store.send(
                            provider: provider,
                            judge: app.judgeProvider,
                            embedder: app.embeddingProvider,
                            reranker: app.rerankProvider,
                            historyTurns: app.chatSettings.historyTurns,
                            tracing: app.tracing
                        ) }
        #endif
    }

    // MARK: - Transcript

    private func transcript(_ store: ChatStore) -> some View {
        let now = Date()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.transcript.isEmpty && store.streaming.isEmpty {
                        Text("从一句问候开始吧。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(entries(store, now: now)) { entry in
                        if let day = entry.day {
                            dayPill(day)
                        }
                        switch entry.line {
                        case let .message(message):
                            bubble(message, clock: entry.clock)
                        case let .event(event):
                            conversationEvent(event, clock: entry.clock)
                        }
                    }
                    if let pending = store.pendingUser {
                        HStack {
                            Spacer(minLength: 40)
                            Text(pending)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    Color.accentColor.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 16)
                                )
                        }
                        .id("pending")
                    }
                    if !store.streaming.isEmpty {
                        characterBubble(store.streaming)
                            .id("streaming")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.transcript.count) {
                proxy.scrollTo(store.transcript.last?.id, anchor: .bottom)
            }
            .onChange(of: store.streaming) {
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: store.pendingUser) {
                proxy.scrollTo("pending", anchor: .bottom)
            }
        }
    }

    /// One transcript line as the page shows it: the day pill it hangs under (nil when the
    /// pill is still up from the line before) and its moment (spec #35).
    private struct TranscriptEntry: Identifiable {
        let line: ConversationLine
        let day: String?
        let clock: String

        var id: String { line.id }
    }

    /// The transcript with its day breaks worked out. The first line always gets a pill;
    /// after that only a change of calendar day does. The day is judged when the page is
    /// drawn, so a conversation left open across midnight gains its new pill on the next
    /// redraw.
    private func entries(_ store: ChatStore, now: Date) -> [TranscriptEntry] {
        let instants = store.transcript.map { Eidolon.parseTimestamp($0.createdAt) ?? now }
        let days = ConversationTime.dayPills(for: instants, now: now)
        return store.transcript.enumerated().map { index, line in
            TranscriptEntry(
                line: line,
                day: days[index],
                clock: ConversationTime.clock(of: instants[index])
            )
        }
    }

    private func dayPill(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color(.secondarySystemBackground), in: Capsule())
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// A line's moment: small and quiet, below and to its own side.
    private func clockText(_ clock: String) -> some View {
        Text(clock)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    /// A call that ended is part of the conversation: it is shown here, and nowhere in
    /// the prompt.
    private func conversationEvent(_ event: ConversationEventRecord, clock: String) -> some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: eventIcon(event.kind))
                    .font(.caption2)
                Text(eventText(event.kind))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            clockText(clock)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .id("event-\(event.id)")
    }

    private func eventIcon(_ kind: String) -> String {
        ConversationEventKind(stored: kind).icon
    }

    private func eventText(_ kind: String) -> String {
        ConversationEventKind(stored: kind).displayText
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessageRecord, clock: String) -> some View {
        if message.isFromCharacter {
            VStack(alignment: .leading, spacing: 2) {
                characterBubble(message.segments, line: message.id)
                clockText(clock)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Spacer(minLength: 40)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.text ?? "")
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
                    clockText(clock)
                }
            }
        }
    }

    /// Her words. `line` is the message's, when it is one that has all arrived: what 朗读 is
    /// for. The line still being written has none.
    private func characterBubble(_ segments: [ReplySegment], line: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ReplyCues.shown(segment.ja))
                        .font(.body)
                    if !segment.zh.isEmpty {
                        Text(ReplyCues.shown(segment.zh))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let line, let speech = ReadAloud.speech(
                of: segments, model: app.chatSettings.fishModel
            ), let voice = app.readAloudVoice(for: character) {
                readAloudButton(speech, line: line, voice: voice)
                    .id(line)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color(hex: character.color ?? "#888888").opacity(0.18),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 朗读: one tap voices the line, a second stops it; preparing wears a spinner, and a
    /// failure says so and can be tapped again (spec #32).
    private func readAloudButton(_ speech: String, line: String, voice: CallVoice) -> some View {
        let phase = app.readAloud.phase(of: line)
        return HStack(spacing: 6) {
            Button {
                app.readAloud.tap(line, speech: speech, voice: voice) { text, voice in
                    try await app.readAloud(text, voice: voice)
                }
            } label: {
                if phase == .synthesizing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: phase == .playing ? "stop.circle" : "speaker.wave.2")
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(readAloudLabel(phase))

            if phase == .failed {
                Text("朗读没成功，再点一次")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func readAloudLabel(_ phase: ReadAloudPlayback.Phase?) -> String {
        switch phase {
        case .playing: "停止朗读"
        case .synthesizing: "正在合成朗读"
        case .failed, nil: "朗读"
        }
    }

    // MARK: - Input

    private func inputBar(_ store: ChatStore) -> some View {
        @Bindable var store = store
        return VStack(spacing: 8) {
            if !app.chatSettings.isConfigured {
                Text("先在设置里填写对话模型，才能开始对话。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("说点什么", text: $store.input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .disabled(store.affinity.cooling)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    if store.isStreaming {
                        store.stop()
                    } else if let provider = app.chatProvider {
                        Task { await store.send(
                            provider: provider,
                            judge: app.judgeProvider,
                            embedder: app.embeddingProvider,
                            reranker: app.rerankProvider,
                            historyTurns: app.chatSettings.historyTurns,
                            tracing: app.tracing
                        ) }
                    }
                } label: {
                    Image(systemName: store.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(
                    !store.isStreaming
                        && (store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !app.chatSettings.isConfigured
                            || store.affinity.cooling)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func coolingBar(_ store: ChatStore) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "snowflake")
                .foregroundStyle(.blue)
            Text(coolingText(store))
                .font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.1))
    }

    private func coolingText(_ store: ChatStore) -> String {
        guard let until = store.affinity.cooldownUntil else {
            return "她现在不想说话，晚些时候再来吧。"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "她现在不想说话，晚些时候再来吧（大约到 \(formatter.string(from: until))）。"
    }

    private var pastBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "book")
                .foregroundStyle(.secondary)
            Text("这是过去的对话，只能翻看。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func endedBar(_ store: ChatStore) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .foregroundStyle(.secondary)
            Text("这段对话结束了，只能翻看。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("开始新对话") {
                Task { await store.startNewConversation() }
            }
            .font(.footnote)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func errorBar(_ store: ChatStore, _ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let provider = app.chatProvider, !store.input.isEmpty {
                Button("重试") {
                    Task { await store.send(
                            provider: provider,
                            judge: app.judgeProvider,
                            embedder: app.embeddingProvider,
                            reranker: app.rerankProvider,
                            historyTurns: app.chatSettings.historyTurns,
                            tracing: app.tracing
                        ) }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
