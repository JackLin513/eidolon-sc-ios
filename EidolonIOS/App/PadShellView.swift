import EidolonCore
import SwiftUI

/// S2.2's medium/wide shell. The 165pt rail is now a resizable column (88–240pt): a
/// narrow icon rail up to the label threshold, a labelled rail above it. The page stays
/// crisp while the rail is dragged; the active boundary paints the blue line and blurs
/// the page behind it.
struct PadShellView: View {
    @Bindable var app: AppModel
    let band: ResponsiveWidthBand

    @State private var railWidth = ResponsiveLayout.railDefaultWidth
    @State private var railDragStart: CGFloat?
    @State private var railDragging = false

    var body: some View {
        HStack(spacing: 0) {
            PadRail(app: app, width: railWidth)
                .frame(width: railWidth)

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .blur(radius: railDragging ? ResponsiveLayout.dragBlurRadius : 0)
                .animation(.easeInOut(duration: ResponsiveLayout.dragFeedbackDuration), value: railDragging)
        }
        .background(Color(.systemBackground))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.tint)
                .frame(width: ResponsiveLayout.activeLineWidth)
                .frame(maxHeight: .infinity)
                .offset(x: railWidth - ResponsiveLayout.activeLineWidth / 2)
                .opacity(railDragging ? 1 : 0)
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: ResponsiveLayout.dragFeedbackDuration), value: railDragging)
        }
        .overlay(alignment: .leading) {
            // No idle handle for the rail: only a 12pt invisible hit strip on the seam.
            Color.clear
                .frame(width: ResponsiveLayout.railHitWidth)
                .contentShape(Rectangle())
                .offset(x: railWidth - ResponsiveLayout.railHitWidth / 2)
                .gesture(railResizeGesture)
                .accessibilityElement()
                .accessibilityLabel("调整导航栏宽度")
                .accessibilityValue("\(Int(railWidth))")
                .accessibilityAdjustableAction { direction in
                    let step: CGFloat = 16
                    switch direction {
                    case .increment: railWidth = ResponsiveLayout.clampedRailWidth(railWidth + step)
                    case .decrement: railWidth = ResponsiveLayout.clampedRailWidth(railWidth - step)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("pad.rail.handle")
        }
        .environment(\.isEidolonPadShell, true)
        .onAppear {
            adoptQARailWidth()
            #if DEBUG
            if ProcessInfo.processInfo.environment["EIDOLON_PAD_DRAG_FEEDBACK"] == "rail" {
                railDragging = true
            }
            #endif
        }
    }

    private var railResizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if railDragStart == nil {
                    railDragStart = railWidth
                    railDragging = true
                }
                railWidth = ResponsiveLayout.clampedRailWidth(
                    (railDragStart ?? railWidth) + value.translation.width
                )
            }
            .onEnded { _ in
                railDragStart = nil
                railDragging = false
            }
    }

    private func adoptQARailWidth() {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_PAD_RAIL_WIDTH"],
           let value = Double(raw) {
            railWidth = ResponsiveLayout.clampedRailWidth(CGFloat(value))
        }
        #endif
    }

    @ViewBuilder
    private var page: some View {
        switch app.selectedTab {
        case .conversation:
            PadConversationView(band: band)
        case .moments:
            MomentsView()
        case .play:
            PlayHubView()
        case .settings:
            SettingsView()
        }
    }
}

private struct PadRail: View {
    @Bindable var app: AppModel
    let width: CGFloat

    private var showsLabels: Bool {
        ResponsiveLayout.railShowsLabels(width: width)
    }

    var body: some View {
        VStack(alignment: showsLabels ? .leading : .center, spacing: 0) {
            ZStack(alignment: showsLabels ? .leading : .center) {
                Text("Eidolon")
                    .font(.title3.weight(.semibold))
                    .opacity(showsLabels ? 1 : 0)
                Text("E")
                    .font(.title3.weight(.semibold))
                    .opacity(showsLabels ? 0 : 1)
            }
            .frame(maxWidth: .infinity, alignment: showsLabels ? .leading : .center)
            .clipped()
            .padding(.horizontal, showsLabels ? 16 : 8)
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

            if showsLabels {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
        .animation(.easeInOut(duration: ResponsiveLayout.dragFeedbackDuration), value: showsLabels)
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
            HStack(spacing: showsLabels ? 10 : 0) {
                Image(systemName: symbol)
                    .font(.body)
                    .frame(width: 22)
                if showsLabels {
                    Text(title)
                        .font(.subheadline.weight(app.selectedTab == tab ? .semibold : .regular))
                }
            }
            .frame(maxWidth: .infinity, alignment: showsLabels ? .leading : .center)
            .padding(.horizontal, showsLabels ? 12 : 8)
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
                        .padding(.trailing, showsLabels ? 10 : 3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("pad.tab.\(tab.railID)")
    }
}

/// The conversation column pair. Medium shows one full-width page at a time; wide shows
/// the roster beside the chat with a continuous, safe-zone bounded splitter.
struct PadConversationView: View {
    @Environment(AppModel.self) private var app
    let band: ResponsiveWidthBand

    @State private var listWidth = ResponsiveLayout.rosterDefaultWidth
    @State private var splitDragStart: CGFloat?
    @State private var splitDragging = false
    @State private var wideAvailableWidth: CGFloat = 0

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
            #if DEBUG
            if ProcessInfo.processInfo.environment["EIDOLON_PAD_DRAG_FEEDBACK"] == "split",
               band == .wide {
                splitDragging = true
            }
            #endif
        }
        .onChange(of: app.conversationTargetID) { adoptOpeningCharacter() }
        .onChange(of: app.characters.count) { _, _ in
            if selected == nil { app.padConversationID = nil }
        }
        .onChange(of: app.padConversationID) { _, newValue in
            if selected == nil, listWidth == 0 {
                listWidth = ResponsiveLayout.rosterDefaultWidth
            }
            #if DEBUG
            if newValue != nil,
               wideAvailableWidth > 0,
               let raw = ProcessInfo.processInfo.environment["EIDOLON_PAD_ROSTER_WIDTH"],
               let value = Double(raw) {
                listWidth = ResponsiveLayout.clampedRosterWidth(
                    CGFloat(value),
                    availableWidth: wideAvailableWidth,
                    hasSelection: true
                )
            }
            #endif
        }
    }

    private var medium: some View {
        GeometryReader { proxy in
            ConversationListView(padChromeWidth: proxy.size.width)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { syncMediumPath() }
        }
    }

    private func syncMediumPath() {
        guard app.conversationPath.isEmpty,
              let id = app.padConversationID,
              let character = app.characters.first(where: { $0.id == id })
        else { return }
        app.conversationPath.append(character)
    }

    private var wide: some View {
        GeometryReader { proxy in
            let available = max(proxy.size.width, ResponsiveLayout.rosterMinWidth)
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if listWidth > 0 {
                        let contentWidth = max(listWidth, ResponsiveLayout.rosterMinWidth)
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
                .blur(radius: splitDragging ? ResponsiveLayout.dragBlurRadius : 0)
                .animation(.easeInOut(duration: ResponsiveLayout.dragFeedbackDuration), value: splitDragging)

                Rectangle()
                    .fill(.tint)
                    .frame(width: ResponsiveLayout.activeLineWidth)
                    .frame(maxHeight: .infinity)
                    .offset(x: max(listWidth - ResponsiveLayout.activeLineWidth / 2, 0))
                    .opacity(splitDragging ? 1 : 0)
                    .allowsHitTesting(false)
                    .animation(.easeInOut(duration: ResponsiveLayout.dragFeedbackDuration), value: splitDragging)

                splitHandle(availableWidth: available)
                    .offset(x: max(listWidth - ResponsiveLayout.handleHitSize / 2, 0))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                wideAvailableWidth = available
                adoptQARosterWidth(availableWidth: available)
                listWidth = ResponsiveLayout.clampedRosterWidth(
                    listWidth,
                    availableWidth: available,
                    hasSelection: selected != nil
                )
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                let newAvailable = max(newWidth, ResponsiveLayout.rosterMinWidth)
                wideAvailableWidth = newAvailable
                listWidth = ResponsiveLayout.clampedRosterWidth(
                    listWidth,
                    availableWidth: newAvailable,
                    hasSelection: selected != nil
                )
            }
        }
    }

    private func roster(width: CGFloat) -> some View {
        ConversationListView(
            embedded: true,
            onSelect: { character in
                app.openPadConversation(characterID: character.id)
            },
            padChromeWidth: max(width, ResponsiveLayout.rosterMinWidth)
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

    private func splitHandle(availableWidth: CGFloat) -> some View {
        ZStack {
            Capsule()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: ResponsiveLayout.handlePillWidth, height: ResponsiveLayout.handlePillHeight)
                .opacity(splitDragging ? 0 : 1)
        }
        .frame(width: ResponsiveLayout.handleHitSize, height: ResponsiveLayout.handleHitSize)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if splitDragStart == nil {
                        splitDragStart = listWidth
                        splitDragging = true
                    }
                    let start = splitDragStart ?? listWidth
                    if start <= 0 {
                        // From a collapsed roster a rightward drag previews a restore.
                        if value.translation.width > 0 {
                            listWidth = min(
                                ResponsiveLayout.rosterDefaultWidth,
                                max(value.translation.width, ResponsiveLayout.rosterMinWidth)
                            )
                        }
                        return
                    }
                    let result = ResponsiveLayout.resolveRosterDrag(
                        rawWidth: start + value.translation.width,
                        availableWidth: availableWidth,
                        hasSelection: selected != nil
                    )
                    listWidth = result.visibleWidth
                }
                .onEnded { value in
                    let start = splitDragStart ?? listWidth
                    defer {
                        splitDragStart = nil
                        splitDragging = false
                    }
                    if start <= 0 {
                        if value.translation.width > 20 {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                                listWidth = ResponsiveLayout.rosterDefaultWidth
                            }
                        }
                        return
                    }
                    let result = ResponsiveLayout.resolveRosterDrag(
                        rawWidth: start + value.translation.width,
                        availableWidth: availableWidth,
                        hasSelection: selected != nil
                    )
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        listWidth = result.settledWidth
                    }
                }
        )
        .simultaneousGesture(
            TapGesture().onEnded {
                guard listWidth == 0 else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                    listWidth = ResponsiveLayout.rosterDefaultWidth
                }
            }
        )
        .accessibilityElement()
        .accessibilityLabel(listWidth == 0 ? "显示角色列表" : "调整角色列表宽度")
        .accessibilityValue("\(Int(listWidth))")
        .accessibilityIdentifier("conversation.splitHandle")
        .accessibilityAddTraits(.isButton)
    }

    /// DEBUG-only state seed for deterministic screenshot QA.
    private func adoptQARosterWidth(availableWidth: CGFloat) {
        #if DEBUG
        if band == .wide,
           let raw = ProcessInfo.processInfo.environment["EIDOLON_PAD_ROSTER_WIDTH"],
           let value = Double(raw) {
            listWidth = ResponsiveLayout.clampedRosterWidth(
                CGFloat(value),
                availableWidth: availableWidth,
                hasSelection: selected != nil
            )
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
