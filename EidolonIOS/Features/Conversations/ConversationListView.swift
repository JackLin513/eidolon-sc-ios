import EidolonCore
import SwiftUI

/// The roster: who she is and the latest thing she said (spec #64: the bar moved to the
/// play tab).
struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    /// 有没看过的新公告时，铃铛右上角一个小圆点。
    private var bell: some View {
        Button {
            showingAnnouncements = true
        } label: {
            Image(systemName: "bell")
                .overlay(alignment: .topTrailing) {
                    if app.server.hasUnreadAnnouncements {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                    }
                }
        }
        .accessibilityLabel("公告")
        .accessibilityIdentifier("conversations.announcements")
    }

    /// The conversation tab's stack lives in `AppModel` so another tab can open her chat
    /// (spec #64).
    private var conversationPath: Binding<NavigationPath> {
        Binding(get: { app.conversationPath }, set: { app.conversationPath = $0 })
    }
    /// The moment the list writes its times against; refreshed every minute while it is
    /// open, so an old 昨天 turns into a date and today's times keep up (spec #35).
    @State private var now = Date()
    /// The character a tap asked to enter while another call is under way (spec #46).
    @State private var pendingCharacter: CharacterConfig?
    /// Whether the roles hidden from the list are being shown (spec #48).
    @State private var showingHidden = false
    /// 公告的弹窗（#122 把公告从设置搬到了这一页的页首，照上游的铃铛）。
    @State private var showingAnnouncements = false

    var body: some View {
        // The folded call's bar floats over the empty part of the large-title header, so
        // showing or hiding it does not move the title or the list (bug 2026-11-04). Her
        // chat keeps its own bar under the inline navigation bar, so the floating one is
        // only drawn while the roster is the page on top.
        NavigationStack(path: conversationPath) {
                List {
                    Section {
                        ForEach(filtered, id: \.id) { character in
                            Group {
                                if app.call.isLive, !app.call.isCalling(character.id) {
                                    // Entering another character hangs the call up: ask first
                                    // (spec #46).
                                    Button {
                                        pendingCharacter = character
                                    } label: {
                                        HStack(spacing: 8) {
                                            row(character)
                                            Image(systemName: "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.primary)
                                } else {
                                    NavigationLink(value: character) {
                                        row(character)
                                    }
                                }
                            }
                            .swipeActions(edge: .leading) {
                                let pinned = app.roster.isPinned(character.id)
                                Button {
                                    app.togglePinned(character.id)
                                } label: {
                                    Label(pinned ? "取消置顶" : "置顶",
                                          systemImage: pinned ? "pin.slash" : "pin")
                                }
                                .tint(.accentColor)
                            }
                            .swipeActions(edge: .trailing) {
                                let hidden = app.roster.isHidden(character.id)
                                Button {
                                    app.toggleHidden(character.id)
                                } label: {
                                    Label(hidden ? "显示" : "隐藏",
                                          systemImage: hidden ? "eye" : "eye.slash")
                                }
                                .tint(.gray)
                            }
                        }
                    }
                    if !searching, hiddenCount > 0 {
                        Section {
                            Button {
                                showingHidden.toggle()
                            } label: {
                                Label(
                                    showingHidden
                                        ? "收起隐藏的角色"
                                        : "已隐藏 \(hiddenCount) 位",
                                    systemImage: showingHidden ? "eye.slash" : "eye"
                                )
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "搜中文名、假名、罗马字或组合")
                .navigationTitle("对话")
                .refreshable { await app.refresh() }
                .toolbar {
                    if app.server.isSignedIn {
                        ToolbarItem(placement: .topBarTrailing) { bell }
                    }
                }
                .sheet(isPresented: $showingAnnouncements) {
                    AnnouncementsView()
                        .environment(app)
                }
                .onChange(of: app.selectedTab) { _, tab in
                    // 切回这一页再拉一次；拉不到就保持上一次的。
                    guard tab == .conversation else { return }
                    Task { await app.server.refreshAnnouncements() }
                }
                .task { await app.server.refreshAnnouncements() }
                .navigationDestination(for: CharacterConfig.self) { character in
                    ChatView(character: character)
                }
                .confirmationDialog(
                    "结束通话并进入？",
                    isPresented: Binding(
                        get: { pendingCharacter != nil },
                        set: { if !$0 { pendingCharacter = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingCharacter
                ) { character in
                    Button("结束通话并进入", role: .destructive) {
                        pendingCharacter = nil
                        app.call.hangUpAndLeave()
                        app.conversationPath.append(character)
                    }
                    Button("取消", role: .cancel) {
                        pendingCharacter = nil
                    }
                } message: { _ in
                    Text("进入别的角色的对话会挂断这通电话。")
                }
                .task { await app.refresh() }
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        now = Date()
                    }
                }
                .task {
                    #if DEBUG
                    let wantsSettings = app.openDebugSettingsIfRequested()
                    if wantsSettings, app.debugCharacterID == nil {
                        app.selectedTab = .settings
                    }
                    if let id = app.consumeDebugCharacterRequest() {
                        // The launch flag may run before the bundle's characters are
                        // published; wait briefly instead of dropping the request.
                        for _ in 0..<50 {
                            if let character = app.characters.first(where: { $0.id == id }) {
                                if app.conversationPath.isEmpty {
                                    app.conversationPath.append(character)
                                }
                                break
                            }
                            try? await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    if app.debugBarRequested {
                        app.selectedTab = .play
                    }
                    #endif
                }
                .overlay {
                    if app.characters.isEmpty {
                        ContentUnavailableView(
                            "没有角色",
                            systemImage: "person.2",
                            description: Text("这份内容包里没有角色")
                        )
                    }
                }
                .alert("出错了", isPresented: errorBinding) {
                    Button("好") { app.errorMessage = nil }
                } message: {
                    Text(app.errorMessage ?? "")
                }
            }
            .overlay(alignment: .top) {
                if app.conversationPath.isEmpty {
                    CallBar()
                }
            }
    }

    private var filtered: [CharacterConfig] {
        // Most recent activity first; ties keep the content's own order (upstream `arrange`).
        let ordered = ConversationOrder.byRecency(app.characters, latest: app.latest)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Searching always looks through the hidden ones too, as upstream's list does.
        let arranged = app.roster.arrange(ordered, showingHidden: showingHidden || !needle.isEmpty)
        guard !needle.isEmpty else { return arranged }
        return arranged.filter { $0.matches(needle) }
    }

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hiddenCount: Int {
        app.roster.hiddenCount(of: app.characters)
    }

    private func row(_ character: CharacterConfig) -> some View {
        HStack(spacing: 12) {
            avatar(character)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(character.name)
                        .font(.headline)
                    if app.latest[character.id]?.unseenReachOut == true {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                    if app.roster.isPinned(character.id) {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("置顶")
                    }
                    if app.roster.isHidden(character.id) {
                        Text("已隐藏")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !character.subtitle.isEmpty {
                    Text(character.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if app.latest[character.id]?.hasPhoto == true {
                        Image(systemName: "camera")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("照片")
                    }
                    Text(preview(character))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if let time = lastTime(character) {
                Text(time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func avatar(_ character: CharacterConfig) -> some View {
        if let image = app.avatar(for: character.id) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 46, height: 46)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Color(hex: character.color ?? "#888888").opacity(0.35))
                .frame(width: 46, height: 46)
                .overlay {
                    Text(String(character.name.prefix(1)))
                        .font(.headline)
                }
        }
    }

    private func preview(_ character: CharacterConfig) -> String {
        guard let activity = app.latest[character.id] else { return character.intro ?? "" }
        // The last thing in the conversation may be something that happened, not said.
        if let giftID = activity.lastGiftID {
            let name = app.giftCatalog?.gift(id: giftID)?.name ?? "礼物"
            return GiftText.given(characterName: character.name, giftName: name)
        }
        if let kind = activity.lastEventKind { return Self.eventPreview(kind) }
        return activity.lastMessagePreview ?? "还没聊过"
    }

    /// When this conversation last heard from her or the producer, as the list writes it;
    /// nothing at all until there has been something (spec #35).
    private func lastTime(_ character: CharacterConfig) -> String? {
        guard let stamp = app.latest[character.id]?.lastMessageAt,
              let at = Eidolon.parseTimestamp(stamp)
        else { return nil }
        return ConversationTime.listTime(of: at, now: now)
    }

    private static func eventPreview(_ kind: String) -> String {
        ConversationEventKind(stored: kind).displayText
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { app.errorMessage != nil && !app.characters.isEmpty },
            set: { shown in
                if !shown { app.errorMessage = nil }
            }
        )
    }
}
