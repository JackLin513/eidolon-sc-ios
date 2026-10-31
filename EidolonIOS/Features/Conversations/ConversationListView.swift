import EidolonCore
import SwiftUI

/// The roster: who she is, the latest thing she said, and whether she reached
/// out while you were away, and the bar at its top (ADR-0021).

/// What the bar's row says under its name.
enum BarEntry {
    /// Before its package is in: the bar cannot be drawn without it.
    static let importHint = "还没有导入酒吧素材包，进设置导入"
    static let rewardToday = "今天第一次光顾有奖励"
    static let rewardTaken = "今天的奖励领过了"
}
struct ConversationListView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var showSettings = false
    @State private var isBarShown = false
    @State private var path = NavigationPath()
    /// The moment the list writes its times against; refreshed every minute while it is
    /// open, so an old 昨天 turns into a date and today's times keep up (spec #35).
    @State private var now = Date()
    /// The character a tap asked to enter while another call is under way (spec #46).
    @State private var pendingCharacter: CharacterConfig?

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    barEntry
                }
                Section {
                    ForEach(filtered, id: \.id) { character in
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
                }
            }
            .listStyle(.plain)
            // The folded call's bar sits at the top of every page (spec #46).
            .safeAreaInset(edge: .top, spacing: 0) {
                CallBar()
            }
            .searchable(text: $query, prompt: "搜中文名、假名、罗马字或组合")
            .navigationTitle("对话")
            .refreshable { await app.refresh() }
            .navigationDestination(for: CharacterConfig.self) { character in
                ChatView(character: character)
            }
            // 酒吧整屏呈现，而不是推进 NavigationStack：栈里的 destination 会把安全区的大小
            // 当成布局的槽，画面再 `.ignoresSafeArea()` 也只扩到绘制的边（实测仍量到 776×400），
            // 上下就贴不满。整屏呈现时它自己就是窗口，画框能真正铺到屏幕边上。
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
                    path.append(character)
                }
                Button("取消", role: .cancel) {
                    pendingCharacter = nil
                }
            } message: { _ in
                Text("进入别的角色的对话会挂断这通电话。")
            }
            .fullScreenCover(isPresented: $isBarShown) {
                BarRoomView(
                    settings: BarSettings.stored(app.barSettingsValue),
                    jukebox: app.barJukeboxState,
                    tutorialWalked: app.barTutorialDone
                )
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
                if app.openDebugSettingsIfRequested() {
                    showSettings = true
                }
                if path.isEmpty,
                   let id = app.debugCharacterID,
                   let character = app.characters.first(where: { $0.id == id }) {
                    path.append(character)
                }
                if path.isEmpty, app.debugBarRequested {
                    isBarShown = true
                }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        #if DEBUG
                        app.markSettingsOpenedManually()
                        #endif
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
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
    }

    /// 酒吧 at the top of the roster: the door in, or the way to bring its package in first.
    /// Without its package the screen cannot be drawn, so the row leads to settings rather
    /// than into an empty room (ADR-0021).
    @ViewBuilder
    private var barEntry: some View {
        if app.barInfo == nil {
            Button { showSettings = true } label: { barRow }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
        } else {
            Button { isBarShown = true } label: { barRow }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
        }
    }

    private var barRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "wineglass")
                .font(.title3)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: "#3c2a4d"))
                )
                .foregroundStyle(Color(hex: "#ffb8d8"))
            VStack(alignment: .leading, spacing: 3) {
                Text("酒吧")
                    .font(.headline)
                Text(barSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// The bar's line under its name: the way to bring its package in, today's reward, or
    /// that today's has been taken.
    private var barSubtitle: String {
        guard app.barInfo != nil else { return BarEntry.importHint }
        return app.barRewardToday ? BarEntry.rewardToday : BarEntry.rewardTaken
    }

    private var filtered: [CharacterConfig] {
        // Most recent activity first; ties keep the content's own order (upstream `arrange`).
        let ordered = ConversationOrder.byRecency(app.characters, latest: app.latest)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return ordered }
        return ordered.filter { $0.matches(needle) }
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
                }
                if !character.subtitle.isEmpty {
                    Text(character.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(preview(character))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
