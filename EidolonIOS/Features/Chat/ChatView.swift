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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if store.transcript.isEmpty && store.streaming.isEmpty {
                        Text("从一句问候开始吧。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(store.transcript) { line in
                        switch line {
                        case let .message(message):
                            bubble(message)
                        case let .event(event):
                            conversationEvent(event)
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

    /// A call that ended is part of the conversation: it is shown here, and nowhere in
    /// the prompt.
    private func conversationEvent(_ event: ConversationEventRecord) -> some View {
        HStack(spacing: 6) {
            Image(systemName: eventIcon(event.kind))
                .font(.caption2)
            Text(eventText(event.kind))
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 2)
        .id("event-\(event.id)")
    }

    private func eventIcon(_ kind: String) -> String {
        switch kind {
        case "ended":
            "moon.zzz"
        case "call_failed", "call_unconnected", "call_dropped":
            "phone.down.circle"
        default:
            "phone.down"
        }
    }

    private func eventText(_ kind: String) -> String {
        switch kind {
        case "ended": "她结束了对话"
        case "hung_up", "she_hung_up": "她挂断了电话"
        case "call_failed", "call_dropped": "通话中断"
        case "call_unconnected": "通话没能接通"
        case "call_duration_limit": "通话到了时限"
        case "call_turn_limit": "通话到了回合上限"
        default: "通话结束"
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessageRecord) -> some View {
        if message.isFromCharacter {
            characterBubble(message.segments)
        } else {
            HStack {
                Spacer(minLength: 40)
                Text(message.text ?? "")
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func characterBubble(_ segments: [ReplySegment]) -> some View {
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Color(hex: character.color ?? "#888888").opacity(0.18),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
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
