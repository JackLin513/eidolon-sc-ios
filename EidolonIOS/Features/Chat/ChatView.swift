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
    @State private var showsAchievements = false
    @State private var showsDebug = false
    /// The call's live turn while the call is folded over this page: what the producer
    /// just said or typed, and her segments as they arrive. The record replaces them when
    /// the turn is written (spec #46).
    @State private var liveHeard: String?
    @State private var liveReply: Int?
    @State private var liveLines: [Int: HerLine] = [:]

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
        // A conversation is a page of its own: the first-level tabs stay behind it, even
        // when a call is folded away over it (spec #64). Letting a live call bring them
        // back made the tab bar fight the input bar for the bottom edge and bounce during
        // push/pop (bug 2026-11-04); the folded call's own bar is the way back to it.
        // The id makes a new controller when the tab comes back into view: switching to
        // the gift page and back does not send this page an appearance callback, and the
        // bar would stay up (spec bug, 2026-11-04).
        .background {
            TabBarHides()
                .id(app.selectedTab)
        }
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
                        app.openHerSchedule(characterID: character.id)
                    }
                    .disabled(!app.hasJobList)
                    Button("成就") {
                        showsAchievements = true
                    }
                    .accessibilityIdentifier("chat.achievements")
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
        // any cooldown (spec「返回刷新」, spec #46). A fold only changes what covers the
        // chat, so each finished call turn (the state going back to listening) and each
        // collapse re-read the record; without that the page kept the turns it loaded
        // before the call (bug 2026-11-04).
        .modifier(CallTurnObserver(
            characterID: character.id,
            store: store,
            liveHeard: $liveHeard,
            liveReply: $liveReply,
            liveLines: $liveLines
        ))
        .onChange(of: app.conversationRevision) {
            Task { await store?.load() }
        }
        .onDisappear {
            app.readAloud.stop()
        }
        .sheet(isPresented: $showsAchievements) {
            NavigationStack {
                HerAchievementsView(characterID: character.id, characterName: character.name)
            }
            .environment(app)
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
            created.onRewards = { rewards in app.showAchievementRewards(rewards) }
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
                            background: app.backgroundProvider,
                            judge: app.judgeProvider,
                            embedder: app.embeddingProvider,
                            reranker: app.rerankProvider,
                            historyTurns: app.chatSettings.historyTurns,
                            tracing: app.tracing,
                            replyStyle: app.replyStyle,
                            adultMode: app.adultMode(for: character),
                            photo: app.photoContext
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
        return ScrollView {
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
                if let retryAt = photoRetryAt {
                    photoUsedUpCapsule(retryAt)
                        .id("photoUsedUp")
                        .padding(.top, 8)
                }
                if showsLiveCall {
                    liveCallRows
                        .id("liveCall")
                        .accessibilityIdentifier("chat.liveCall")
                        .padding(.top, 8)
                }
            }
            // The producer can keep a line: long press selects her Japanese, its
            // subtitle, the producer's own words, scenes, names and times, with the
            // system copy menu (spec #75, #76).
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        // The page follows its bottom through every size change — the keyboard coming and
        // going, a line sent, her reply growing — so a new line rises from behind the input
        // bar instead of leaving a gap. An explicit scroll (spec #42's send scroll) took
        // that anchor away once the keyboard left, so there is none (bug 2026-11-04).
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollDismissesKeyboard(.interactively)
    }

    /// The hour's pictures are gone: said once, where the turn would have been, with the
    /// time she can be asked again (ticket #102).
    private func photoUsedUpCapsule(_ retryAt: Date) -> some View {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return Label(
            "这一小时的照片用完了，\(formatter.string(from: retryAt)) 以后可以再要",
            systemImage: "camera.badge.ellipsis"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("chat.photoUsedUp")
    }

    /// The turn's own notice first; while a call with her is folded here, what the call
    /// was told (spec #98: the notice reaches the conversation from a call too).
    private var photoRetryAt: Date? {
        if let own = store?.photoRetryAt { return own }
        return app.call.isCalling(character.id) ? app.call.photoRetryAt : nil
    }

    /// The call's picture until it is recorded: once the reply is in the conversation,
    /// the recorded row is the one shown (spec #98).
    private var liveCallPhoto: CallPhoto? {
        guard let photo = app.call.photo else { return nil }
        if let store, store.messages.contains(where: { $0.photo?.id == photo.id }) {
            return nil
        }
        return photo
    }

    private var liveBlocks: [ReplyBlock] {
        liveLines.values
            .sorted { $0.segment < $1.segment }
            .filter { !$0.ja.isEmpty || !$0.zh.isEmpty }
            .map { .line(ReplySegment(ja: $0.ja, zh: $0.zh)) }
    }

    private var showsLiveCall: Bool {
        app.call.isCalling(character.id)
            && store?.isPast != true
            && store?.ended != true
            && (liveHeard != nil || !liveBlocks.isEmpty || liveCallPhoto != nil)
    }

    @ViewBuilder
    private var liveCallRows: some View {
        // Her picture is the first thing of the live turn, as it will be once recorded
        // (ticket #103).
        if let photo = liveCallPhoto {
            HerMessageRow(character: character) {
                PhotoBubble(photo: PhotoReference(
                    id: photo.id,
                    status: photo.status,
                    reason: photo.reason
                ))
            }
            .id("livePhoto-\(photo.id)")
        }
        if let heard = liveHeard, !heard.isEmpty {
            HStack {
                Spacer(minLength: 40)
                producerBubble(heard)
            }
        }
        if !liveBlocks.isEmpty {
            HerMessageRow(character: character) {
                ReplyBubble(blocks: liveBlocks, character: character)
            }
            .accessibilityIdentifier("chat.liveHer")
        }
    }

    private func clearLiveCall() {
        liveHeard = nil
        liveReply = nil
        liveLines = [:]
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
                Text(eventText(event))
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

    private func eventText(_ event: ConversationEventRecord) -> String {
        if ConversationEventKind(stored: event.kind) == .gift {
            let name = event.giftID.flatMap { app.giftCatalog?.gift(id: $0)?.name } ?? "礼物"
            return GiftText.given(characterName: character.name, giftName: name)
        }
        return ConversationEventKind(stored: event.kind).displayText
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
                        joinsNext: !row.last,
                        photo: message.photo
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
    /// Watches the one call for this page: reloads the recorded turn when it finishes,
    /// and shapes the live rows the folded chat shows while it is still going (spec #46).
    private struct CallTurnObserver: ViewModifier {
        @Environment(AppModel.self) private var app
        let characterID: String
        let store: ChatStore?
        @Binding var liveHeard: String?
        @Binding var liveReply: Int?
        @Binding var liveLines: [Int: HerLine]

        func body(content: Content) -> some View {
            content
                .onChange(of: app.call.state) { _, next in
                    switch next {
                    case .ended:
                        Task {
                            await store?.load()
                            clearLiveCall()
                        }
                    case .thinking:
                        liveReply = nil
                        liveLines = [:]
                    case .listening:
                        if app.call.isCollapsed {
                            Task {
                                await store?.load()
                                clearLiveCall()
                            }
                        } else {
                            clearLiveCall()
                        }
                    default:
                        break
                    }
                }
                .onChange(of: app.call.layer) { _, layer in
                    guard layer == .collapsed else { return }
                    Task { await store?.load() }
                }
                .onChange(of: app.call.hearing) { _, text in
                    guard callBelongsToThisPage, let text, !text.isEmpty else { return }
                    liveHeard = text
                }
                .onChange(of: app.call.recognized) { _, text in
                    guard callBelongsToThisPage, let text, !text.isEmpty else { return }
                    liveHeard = text
                }
                .onChange(of: app.call.typed) { _, text in
                    guard callBelongsToThisPage, let text, !text.isEmpty else { return }
                    liveHeard = text
                }
                .onChange(of: app.call.line) { _, line in
                    guard callBelongsToThisPage else { return }
                    guard let line else {
                        liveReply = nil
                        liveLines = [:]
                        return
                    }
                    if liveReply != line.reply {
                        liveReply = line.reply
                        liveLines = [:]
                    }
                    liveLines[line.segment] = line
                    if let previous = app.call.previousLine, previous.reply == line.reply {
                        liveLines[previous.segment] = previous
                    }
                }
                // This page is her conversation: a new picture is already on screen as
                // the live row, so the bar need not say it too (ticket #103).
                .onChange(of: app.call.photo) { _, _ in
                    if callBelongsToThisPage { app.call.markPhotoSeen() }
                }
                .onAppear {
                    seedLiveCall()
                    if callBelongsToThisPage { app.call.markPhotoSeen() }
                }
        }

        /// A chat opened while she is already answering catches up with the call's current
        /// line instead of waiting for the next segment.
        private func seedLiveCall() {
            guard callBelongsToThisPage else { return }
            switch app.call.state {
            case .thinking, .speaking:
                break
            default:
                return
            }
            liveHeard = app.call.recognized ?? app.call.typed ?? app.call.hearing
            guard let line = app.call.line else { return }
            liveReply = line.reply
            liveLines = [line.segment: line]
            if let previous = app.call.previousLine, previous.reply == line.reply {
                liveLines[previous.segment] = previous
            }
        }

        private var callBelongsToThisPage: Bool {
            app.call.isCalling(characterID) && store?.isPast != true && store?.ended != true
        }

        private func clearLiveCall() {
            liveHeard = nil
            liveReply = nil
            liveLines = [:]
        }
    }

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

    /// The picture that came with a reply. It is made after the reply is written, so it
    /// shows a developing frame until the file is there (spec #98).
    private struct PhotoBubble: View {
        let photo: PhotoReference

        @Environment(AppModel.self) private var app
        @State private var image: UIImage?
        @State private var viewing = false
        @State private var blinking = false

        private var width: CGFloat { PhotoGeometry.bubbleWidth }

        var body: some View {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: width)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .onTapGesture { viewing = true }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("照片")
                        .accessibilityIdentifier("chat.photo")
                } else if photo.status == .failed {
                    // What went wrong, in one short line; asking again is a new turn, not
                    // a retry here (ticket #102).
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("照片没发出来")
                            if let reason = photo.reason {
                                Text(reason.shortText)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .frame(width: width, alignment: .leading)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("chat.photo.failed")
                } else {
                    // The same box the finished picture takes, so nothing moves when it
                    // lands; faint, a blinking camera and a spinner, no words (spec #98).
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.tertiarySystemBackground))
                        .frame(width: width, height: width / PhotoGeometry.aspectRatio)
                        .overlay {
                            VStack(spacing: 10) {
                                Image(systemName: "camera")
                                    .font(.title2)
                                    .opacity(blinking ? 0.35 : 1)
                                ProgressView()
                            }
                            .foregroundStyle(.secondary)
                        }
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                blinking = true
                            }
                        }
                        .accessibilityLabel("照片正在生成")
                        .accessibilityIdentifier("chat.photo.pending")
                }
            }
            .task(id: photo.status) {
                guard photo.status == .ready else { return }
                image = await app.photoImage(photo.id)
            }
            .fullScreenCover(isPresented: $viewing) {
                PhotoViewer(id: photo.id)
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
        /// The picture she sent with this reply, if the turn made one (spec #98).
        var photo: PhotoReference? = nil

        @Environment(AppModel.self) private var app

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                // The picture is the first block of her reply (spec #98).
                if let photo {
                    PhotoBubble(photo: photo)
                }
                // One text view for the whole bubble: with several Text views only the last
                // one gets a selection container, so her Japanese and the scene would not be
                // selectable (spec #76).
                Text(bubbleText)
                    .font(.body)
                    .textSelection(.enabled)
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

        /// The bubble's scene, Japanese and subtitle as one attributed run, so the whole
        /// bubble can be selected and copied (spec #76).
        private var bubbleText: AttributedString {
            var result = AttributedString()
            for (index, block) in blocks.enumerated() {
                if index > 0 { result += AttributedString("\n") }
                switch block {
                case let .line(segment):
                    var japanese = AttributedString(shown(segment.ja))
                    japanese.font = .body
                    result += japanese
                    if !segment.zh.isEmpty {
                        var subtitle = AttributedString("\n" + shown(segment.zh))
                        subtitle.font = .callout
                        subtitle.foregroundColor = .secondary
                        result += subtitle
                    }
                case let .scene(scene):
                    var narration = AttributedString(scene)
                    narration.font = .callout.italic()
                    narration.foregroundColor = .secondary
                    result += narration
                }
            }
            return result
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
            if let warning = app.contentBundleRetrievalWarning {
                Text(warning)
                    .font(.footnote)
                    .foregroundStyle(.orange)
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
                            background: app.backgroundProvider,
                            judge: app.judgeProvider,
                            embedder: app.embeddingProvider,
                            reranker: app.rerankProvider,
                            historyTurns: app.chatSettings.historyTurns,
                            tracing: app.tracing,
                            replyStyle: app.replyStyle,
                            adultMode: app.adultMode(for: character),
                            photo: app.photoContext
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
                            background: app.backgroundProvider,
                            judge: app.judgeProvider,
                            embedder: app.embeddingProvider,
                            reranker: app.rerankProvider,
                            historyTurns: app.chatSettings.historyTurns,
                            tracing: app.tracing,
                            replyStyle: app.replyStyle,
                            adultMode: app.adultMode(for: character),
                            photo: app.photoContext
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
