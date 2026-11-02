import EidolonCore
import SwiftUI

struct ChatView: View {
    let character: CharacterConfig
    /// A past conversation to look at; nil shows the current one.
    var conversationID: String? = nil
    /// Whether the page this history was opened from is still waiting on a reply. A past
    /// page cannot start another conversation then, since the current page would reload
    /// mid-turn (spec #37).
    var currentTurnInFlight: Bool = false

    @Environment(AppModel.self) private var app
    @State private var store: ChatStore?
    @State private var didAutoSend = false
    @State private var showHistory = false
    /// Her stand, read only to open the outfit picker (spec #35). Whether the button exists
    /// is decided by the already-published snapshot, never by this on-page read (spec #44).
    @State private var outfitsStand: CharacterStand?
    @State private var outfitsChecked = false
    @State private var showsOutfits = false
    @State private var showsAffinity = false
    @State private var showsSchedule = false
    @State private var showsDebug = false
    @State private var scheduleBook = ScheduleDraftBook()

    var body: some View {
        Group {
            if let store {
                VStack(spacing: 0) {
                    // Her conversation keeps the folded call's bar under the navigation bar,
                    // without repeating her name (spec #46).
                    CallBar(showsName: !app.call.isCalling(character.id))
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
                    // Her call is already under way: this key brings the layer back.
                    // Otherwise it dials her (spec #46).
                    if app.call.isCalling(character.id) {
                        app.call.expand()
                    } else {
                        app.readAloud.stop()
                        Task { await app.call.start(character) }
                    }
                } label: {
                    Image(systemName: showsReturnToCall ? "phone.fill" : "phone")
                }
                .disabled(phoneDisabled)
                .accessibilityLabel(showsReturnToCall ? "回到通话" : "打电话")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Upstream's order: 新对话, 历史对话, 换衣装. Items are greyed, never
                // hidden; 换衣装 only exists when she has a stand (spec #37).
                Menu {
                    Button("新对话") {
                        startNewConversation()
                    }
                    .disabled(!newConversationIsEnabled)
                    Button("历史对话") {
                        showHistory = true
                    }
                    if app.hasStand(for: character.id) {
                        Button("换衣装") {
                            openOutfits()
                        }
                    }
                    Button("送她一件礼物") {
                        app.openGifts(characterID: character.id)
                    }
                    .accessibilityIdentifier("chat.gifts")
                    Button("她的日程") {
                        showsSchedule = true
                    }
                    .disabled(!app.hasJobList)
                    if app.debugMode {
                        Divider()
                        Button("调试") {
                            showsDebug = true
                        }
                        .accessibilityIdentifier("chat.debug")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(character.name)
                        .font(.headline)
                        .lineLimit(1)
                    if let store {
                        AffinityBadgeView(
                            badge: AffinityBadge.of(
                                store.affinity,
                                name: character.name,
                                now: Date()
                            ),
                            color: Color(hex: character.color ?? "#888888"),
                            cue: store.affinityCue,
                            showsDetails: $showsAffinity
                        )
                        // The badge keeps its 44pt tap area, but the toolbar title must not
                        // grow with it: a 44pt badge under the name made the stack taller
                        // than the bar, pushing the name up into the Dynamic Island.
                        .frame(height: 16)
                    }
                }
            }
        }
        .onChange(of: conversationID) { app.readAloud.stop() }
        // What the call wrote is shown at once: its turns, her hang-up, the affinity and
        // any cooldown (spec「返回刷新」, spec #46).
        .onChange(of: app.call.state) { _, next in
            guard case .ended = next else { return }
            Task { await store?.load() }
        }
        .onChange(of: app.conversationRevision) {
            Task { await store?.load() }
        }
        .onDisappear {
            app.readAloud.stop()
        }
        .sheet(isPresented: $showsSchedule) {
            ScheduleBoardView(
                initialCharacterID: character.id, book: $scheduleBook
            )
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
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ConversationHistoryView(
                character: character,
                currentTurnInFlight: store?.isStreaming == true
            )
            }
            .environment(app)
        }
        .sheet(isPresented: $showsDebug) {
            if let store {
                DebugView(
                    character: character,
                    store: store,
                    currentTurnInFlight: currentTurnInFlight
                )
                .environment(app)
            }
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
            if app.debugOpensCall, !created.readOnly {
                Task { await app.call.start(character) }
            }
            #endif
        }
        .task {
            // This prefetch only feeds the outfit picker now. Whether the button exists
            // comes from the snapshot AppModel published before this page was built
            // (spec #44).
            guard !outfitsChecked else { return }
            outfitsChecked = true
            await loadOutfitsStand()
        }
    }

    /// Opens her clothes. If the prefetch has not landed yet, it is finished first so a
    /// quick tap never shows an empty cover (spec #44).
    private func openOutfits() {
        if outfitsStand != nil {
            showsOutfits = true
            return
        }
        Task {
            await loadOutfitsStand()
            if outfitsStand != nil { showsOutfits = true }
        }
    }

    /// Reads her stand for the picker; whether the button exists comes from AppModel's
    /// snapshot, not from this lookup (spec #44).
    private func loadOutfitsStand() async {
        outfitsStand = await app.core.stand(for: character.id)
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
                            tracing: app.tracing,
                            replyStyle: app.replyStyle,
                            adultMode: app.adultMode(for: character)
                        ) }
        #endif
    }

    /// Her own call is the one this page's phone key opens again.
    private var showsReturnToCall: Bool {
        app.call.isCalling(character.id) && !(store?.readOnly ?? true)
    }

    /// A call is under way with someone else, or this conversation can no longer be called:
    /// the key does nothing. In her own live call it is the way back to it.
    private var phoneDisabled: Bool {
        guard let store else { return true }
        if store.readOnly || store.affinity.cooling { return true }
        guard app.call.isLive else { return false }
        return !showsReturnToCall
    }

    /// 新对话 is unusable with nothing to leave behind, while a reply is being written,
    /// or during a call. In a past conversation it is usable unless the current page is
    /// still waiting on a reply: it goes back to the current one and starts another
    /// (spec #37).
    private var newConversationIsEnabled: Bool {
        guard let store, !app.call.isCalling(character.id), store.canStartNewConversation else { return false }
        return !store.isPast || !currentTurnInFlight
    }

    /// The one action both the menu and the ended bar call: from a past conversation it
    /// also closes the history sheet and brings the current page to the new one.
    private func startNewConversation() {
        guard let store else { return }
        Task {
            if await store.startNewConversation(), store.isPast {
                app.noteConversationChanged()
            }
        }
    }

    // MARK: - Transcript

    private func transcript(_ store: ChatStore) -> some View {
        let now = Date()
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    // The reply being written is covered by the pending line it answers, so this
                    // page can stop reading the streaming text and leave the bubble to itself
                    // (spec #42).
                    if store.transcript.isEmpty && store.pendingUser == nil {
                        Text("从一句问候开始吧。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 40)
                    }
                    ForEach(ConversationTranscript.rows(
                        of: store.transcript,
                        now: now,
                        // A reply that changed her affinity puts its capsule after it and
                        // starts a new group (spec #38, the seam left in spec #40).
                        splitsAfter: { line in
                            guard case let .message(message) = line else { return false }
                            return message.affinityChange != nil
                        }
                    )) { row in
                        VStack(alignment: .leading, spacing: 16) {
                            if let day = row.day {
                                dayPill(day)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                switch row.line {
                                case let .message(message):
                                    messageRow(message, row: row)
                                case let .event(event):
                                    conversationEvent(event, clock: row.clock)
                                }
                                if let change = row.cue {
                                    AffinityCueCapsule(change: change, name: character.name)
                                }
                            }
                        }
                        // Eight inside a group, sixteen between groups and around a pill.
                        .padding(.top, row.day != nil || row.first ? 8 : 0)
                    }
                    if let pending = store.pendingUser {
                        HStack {
                            Spacer(minLength: 40)
                            producerBubble(pending)
                        }
                        .id("pending")
                        .padding(.top, 8)
                    }
                    // The reply being written draws itself, so a new piece of text does not
                    // rework the whole transcript (spec #42). It is her next group's first
                    // line, so it carries her avatar and name (spec #40).
                    StreamingReply(store: store, character: character)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            // One way to follow the bottom, never two: the anchor is what carries the view along
            // as the content grows. With nothing measuring a bubble's own bottom any more, the
            // list's vertical padding is just padding. The only explicit scroll left is the one
            // the producer asks for by sending a line (spec #42).
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: store.pendingUser) { _, text in
                guard text != nil else { return }
                proxy.scrollTo("pending", anchor: .bottom)
            }
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

    /// One message as the bubble-group rule draws it: her group's first line carries her
    /// avatar and name, the group's last line carries the time beside it, and the corners
    /// that meet another line of the same group are smaller (spec #40).
    @ViewBuilder
    private func messageRow(_ message: ChatMessageRecord, row: ConversationTranscript.Row) -> some View {
        if message.isFromCharacter {
            HerMessageRow(character: character, first: row.first) {
                HStack(alignment: .bottom, spacing: 6) {
                    ReplyBubble(
                        blocks: message.replyBlocks,
                        character: character,
                        line: message.id,
                        joinsPrevious: !row.first,
                        joinsNext: !row.last
                    )
                    if row.last {
                        clockText(row.clock)
                    }
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 6) {
                Spacer(minLength: 40)
                if row.last {
                    clockText(row.clock)
                }
                producerBubble(message.text ?? "", first: row.first, last: row.last)
            }
        }
    }

    /// What the producer's own line looks like, and the line still being sent.
    private func producerBubble(_ text: String, first: Bool = true, last: Bool = true) -> some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color.accentColor.opacity(0.15),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: 16,
                    bottomLeadingRadius: 16,
                    bottomTrailingRadius: last ? 16 : 8,
                    topTrailingRadius: first ? 16 : 8
                )
            )
    }

    /// The reply being written. It reads the streaming segments itself, so a new piece of text
    /// redraws this one bubble and leaves the recorded transcript alone (spec #42).
    private struct StreamingReply: View {
        let store: ChatStore
        let character: CharacterConfig

        var body: some View {
            if !store.streaming.isEmpty {
                HerMessageRow(character: character) {
                    ReplyBubble(blocks: store.streaming, character: character, cuesShown: true)
                }
                .padding(.top, 8)
            }
        }
    }

    /// Her side of a bubble group: the avatar on the left, and her name above the group's
    /// first line. Every line of the group keeps the avatar's width so the bubbles align
    /// (spec #40).
    private struct HerMessageRow<Content: View>: View {
        let character: CharacterConfig
        var first = true
        @ViewBuilder var content: Content

        var body: some View {
            HStack(alignment: .top, spacing: 8) {
                BubbleAvatar(character: character, shown: first)
                VStack(alignment: .leading, spacing: 4) {
                    if first {
                        Text(character.name)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                    }
                    content
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Her avatar at the top of a bubble group: the picture when there is one, otherwise
    /// her colour and the first letter of her name. A line after the group's first keeps
    /// the same width so the bubbles stay aligned (spec #40).
    private struct BubbleAvatar: View {
        let character: CharacterConfig
        var shown = true

        @Environment(AppModel.self) private var app

        var body: some View {
            if shown {
                if let image = app.avatar(for: character.id) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                } else {
                    Circle()
                        .fill(Color(hex: character.color ?? "#888888").opacity(0.35))
                        .frame(width: 36, height: 36)
                        .overlay {
                            Text(String(character.name.prefix(1)))
                                .font(.footnote)
                        }
                }
            } else {
                Color.clear
                    .frame(width: 36, height: 36)
            }
        }
    }

    /// Her words in one bubble. `line` is the message's, when it is one that has all arrived:
    /// what 朗读 is for. The line still being written has none, and it arrives with its cues
    /// already taken out, so it is shown as it is rather than filtered a second time (spec #42).
    private struct ReplyBubble: View {
        let blocks: [ReplyBlock]
        let character: CharacterConfig
        var line: String? = nil
        var cuesShown = false
        /// Another line of her group sits above / below: the meeting corner is smaller.
        var joinsPrevious = false
        var joinsNext = false

        @Environment(AppModel.self) private var app

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case let .line(segment):
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shown(segment.ja))
                                .font(.body)
                            if !segment.zh.isEmpty {
                                Text(shown(segment.zh))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    case let .scene(scene):
                        Text(scene)
                            .font(.callout)
                            .italic()
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("reply.scene")
                    }
                }
                // Her voice is the call's while one is up; 朗读 waits for it to end.
                if let line, !app.call.isLive, let speech = ReadAloud.speech(
                    of: blocks, model: app.chatSettings.fishModel
                ), let voice = app.readAloudVoice(for: character) {
                    readAloudButton(speech, line: line, voice: voice)
                        .id(line)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Color(hex: character.color ?? "#888888").opacity(0.18),
                in: UnevenRoundedRectangle(
                    topLeadingRadius: joinsPrevious ? 8 : 16,
                    bottomLeadingRadius: joinsNext ? 8 : 16,
                    bottomTrailingRadius: 16,
                    topTrailingRadius: 16
                )
            )
        }

        /// What the reader sees. A recorded line keeps its cues in the store, so they are taken
        /// out here; a line still being written arrives without them.
        private func shown(_ text: String) -> String {
            cuesShown ? text : ReplyCues.shown(text)
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
    }

    // MARK: - Input

    private func inputBar(_ store: ChatStore) -> some View {
        @Bindable var store = store
        let calling = app.call.isCalling(character.id)
        return VStack(spacing: 8) {
            if !app.chatSettings.isConfigured {
                Text("先在设置里填写对话模型，才能开始对话。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("说点什么", text: $store.input, axis: .vertical)
                    .accessibilityIdentifier("chat.input")
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .disabled(store.affinity.cooling || calling)
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
                            tracing: app.tracing,
                            replyStyle: app.replyStyle,
                            adultMode: app.adultMode(for: character)
                        ) }
                    }
                } label: {
                    Image(systemName: store.isStreaming ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .accessibilityIdentifier("chat.send")
                .disabled(
                    !store.isStreaming
                        && (store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || (!app.chatSettings.isConfigured && !app.isUsingFakeChat)
                            || store.affinity.cooling
                            || calling)
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
                startNewConversation()
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            .disabled(!newConversationIsEnabled)
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
                            tracing: app.tracing,
                            replyStyle: app.replyStyle,
                            adultMode: app.adultMode(for: character)
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
