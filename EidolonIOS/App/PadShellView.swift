import EidolonCore
import SwiftUI

/// S2.1's medium/wide shell: a fixed 165pt navigation rail beside the current page.
/// The rail is ours, not a system sidebar, so there is no top-left collapse control and
/// the rail background reaches the status bar.
struct PadShellView: View {
    @Bindable var app: AppModel
    let band: ResponsiveWidthBand

    var body: some View {
        HStack(spacing: 0) {
            PadRail(app: app)
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemBackground))
        .environment(\.isEidolonPadShell, true)
    }

    @ViewBuilder
    private var page: some View {
        switch app.selectedTab {
        case .conversation:
            PadConversationView(band: band)
        case .moments:
            MomentsView()
                .frame(maxWidth: ResponsiveLayout.wideMaxWidth)
                .frame(maxWidth: .infinity)
        case .play:
            PlayHubView()
                .frame(maxWidth: ResponsiveLayout.wideMaxWidth)
                .frame(maxWidth: .infinity)
        case .settings:
            SettingsView()
        }
    }
}

private struct PadRail: View {
    @Bindable var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Eidolon")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 18)

            VStack(spacing: 3) {
                railRow(.conversation, "对话", "bubble.left.and.bubble.right")
                railRow(.moments, "朋友圈", "person.2", badge: app.momentsBadge)
                railRow(.play, "玩法", "sparkles", badge: app.achievementBadge)
                railRow(.settings, "设置", "gearshape")
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 2) {
                Text("内容包")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("\(app.characters.count) 位角色")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(width: ResponsiveLayout.railWidth)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
    }

    private func railRow(
        _ tab: MainTab,
        _ title: String,
        _ symbol: String,
        badge: Bool = false
    ) -> some View {
        Button {
            if tab == .settings {
                app.openSettings()
            } else {
                app.selectedTab = tab
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(app.selectedTab == tab ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    app.selectedTab == tab ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 9)
                )
                .overlay(alignment: .trailing) {
                    if badge {
                        Circle()
                            .fill(.tint)
                            .frame(width: 7, height: 7)
                            .padding(.trailing, 10)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("pad.tab.\(tab.railID)")
    }
}

/// The conversation column pair. Medium shows one full-width page at a time; wide shows
/// the roster beside the chat with a draggable gray handle between them.
struct PadConversationView: View {
    @Environment(AppModel.self) private var app
    let band: ResponsiveWidthBand

    @State private var listWidth: CGFloat = ResponsiveLayout.rosterStandardWidth
    @State private var dragStart: CGFloat?

    private var selected: CharacterConfig? {
        guard let id = app.padConversationID else { return nil }
        return app.characters.first { $0.id == id }
    }

    var body: some View {
        Group {
            if band == .wide {
                wide
            } else {
                medium
            }
        }
        .onAppear {
            adoptOpeningCharacter()
            adoptQARosterWidth()
        }
        .onChange(of: app.conversationTargetID) { adoptOpeningCharacter() }
        .onChange(of: app.characters.count) { _, _ in
            if selected == nil { app.padConversationID = nil }
        }
    }

    private var medium: some View {
        GeometryReader { proxy in
            ConversationListView(padChromeWidth: proxy.size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { syncMediumPath() }
        }
    }

    /// Wide selections are not pushes; when entering medium after a rotation, restore the
    /// same character as a real NavigationStack push.
    private func syncMediumPath() {
        guard app.conversationPath.isEmpty,
              let id = app.padConversationID,
              let character = app.characters.first(where: { $0.id == id })
        else { return }
        app.conversationPath.append(character)
    }

    private var wide: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                if listWidth > 0 {
                    let contentWidth = ResponsiveLayout.rosterContentWidth(visibleWidth: listWidth)
                    roster(width: contentWidth)
                        .frame(width: contentWidth, alignment: .leading)
                        .frame(width: listWidth, alignment: .leading)
                        .clipped()
                }

                if let selected {
                    chat(selected)
                } else {
                    PadEmptyConversationView { character in
                        app.openPadConversation(characterID: character.id)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .leading) {
                splitHandle()
                    .offset(x: max(listWidth - 22, 0))
            }
        }
    }

    private func roster(width: CGFloat) -> some View {
        ConversationListView(
            embedded: true,
            onSelect: { character in
                app.openPadConversation(characterID: character.id)
            },
            padChromeWidth: ResponsiveLayout.rosterContentWidth(visibleWidth: width)
        )
    }

    private func chat(_ character: CharacterConfig) -> some View {
        NavigationStack {
            ChatView(
                character: character,
                hidesTabBar: false,
                onPadBack: { app.closePadConversation() }
            )
        }
    }

    private func splitHandle() -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.55))
            .frame(width: 44, height: 4)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = listWidth
                        }
                        listWidth = ResponsiveLayout.draggingRosterWidth(
                            start: dragStart ?? listWidth,
                            translation: value.translation.width
                        )
                    }
                    .onEnded { value in
                        let start = dragStart ?? listWidth
                        let projected = ResponsiveLayout.draggingRosterWidth(
                            start: start,
                            translation: value.predictedEndTranslation.width
                        )
                        let snapped = ResponsiveLayout.snapRosterWidth(projectedWidth: projected)
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                            listWidth = snapped
                        }
                        dragStart = nil
                    }
            )
            .simultaneousGesture(
                TapGesture().onEnded {
                    guard listWidth == 0 else { return }
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        listWidth = ResponsiveLayout.rosterStandardWidth
                    }
                }
            )
            .accessibilityElement()
            .accessibilityLabel(listWidth == 0 ? "显示角色列表" : "调整角色列表宽度")
            .accessibilityIdentifier("conversation.splitHandle")
            .accessibilityAddTraits(.isButton)
    }

    /// DEBUG-only seed for the screenshot harness: the visual states must be repeatable
    /// without depending on a fling gesture that can be swallowed by the simulator.
    private func adoptQARosterWidth() {
        #if DEBUG
        if band == .wide,
           let raw = ProcessInfo.processInfo.environment["EIDOLON_PAD_ROSTER_WIDTH"],
           let value = Double(raw) {
            listWidth = ResponsiveLayout.snapRosterWidth(projectedWidth: CGFloat(value))
        }
        #endif
    }

    private func adoptOpeningCharacter() {
        guard let id = app.takeConversationTargetID() else { return }
        app.padConversationID = id
    }
}

/// The wide screen's right pane before a character is chosen. It continues the most
/// recent conversation rather than leaving the third column as generic white space.
private struct PadEmptyConversationView: View {
    @Environment(AppModel.self) private var app
    let open: (CharacterConfig) -> Void

    private var recent: CharacterConfig? {
        let ordered = ConversationOrder.byRecency(app.characters, latest: app.latest)
        return ordered.first { app.latest[$0.id] != nil }
    }

    var body: some View {
        Group {
            if let recent {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    VStack(spacing: 14) {
                        avatar(recent)
                        VStack(spacing: 4) {
                            Text(recent.name)
                                .font(.title2.weight(.semibold))
                            if let unit = recent.unit {
                                Text(unit)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let line = preview(recent) {
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .frame(maxWidth: 380)
                        }
                        HStack(spacing: 10) {
                            Button {
                                open(recent)
                            } label: {
                                Label("继续对话", systemImage: "bubble.left")
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("pad.empty.open")

                            Button {
                                Task { await app.call.start(recent) }
                            } label: {
                                Label("打电话", systemImage: "phone")
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("pad.empty.call")
                        }
                    }
                    .padding(28)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            } else {
                ContentUnavailableView(
                    "选一个角色",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("从左边选一位开始聊天")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func avatar(_ character: CharacterConfig) -> some View {
        Group {
            if let image = app.avatar(for: character.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(Color(hex: character.color ?? "#888888").opacity(0.32))
                    .overlay {
                        Text(String(character.name.prefix(1)))
                            .font(.system(size: 34, weight: .semibold))
                    }
            }
        }
        .frame(width: 96, height: 96)
        .clipShape(Circle())
    }

    private func preview(_ character: CharacterConfig) -> String? {
        guard let activity = app.latest[character.id] else { return nil }
        if let giftID = activity.lastGiftID {
            let name = app.giftCatalog?.gift(id: giftID)?.name ?? "礼物"
            return GiftText.given(characterName: character.name, giftName: name)
        }
        if let kind = activity.lastEventKind {
            return ConversationEventKind(stored: kind).displayText
        }
        return activity.lastMessagePreview
    }
}

private extension MainTab {
    var railID: String {
        switch self {
        case .conversation: "conversation"
        case .moments: "moments"
        case .play: "play"
        case .settings: "settings"
        }
    }
}

/// Tells settings that the S2.1 shell already owns the navigation rail, so it can use a
/// plain two-column layout instead of a second system `NavigationSplitView` with a
/// duplicate sidebar toggle.
private struct EidolonPadShellKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isEidolonPadShell: Bool {
        get { self[EidolonPadShellKey.self] }
        set { self[EidolonPadShellKey.self] = newValue }
    }
}
