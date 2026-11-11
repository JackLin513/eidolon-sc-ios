import EidolonCore
import SwiftUI

/// The app's four first-level pages (spec #64, #94). iPhone keeps the tab bar stack;
/// iPad uses S2.1's rail + breakpoint shell.
struct MainTabsView: View {
    @Bindable var app: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var measuredWidth: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let band = ResponsiveLayout.band(width: width, sizeClass: sizeClass)

            Group {
                if band == .compact {
                    tabShell
                } else {
                    PadShellView(app: app, band: band)
                        .environment(app)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { measuredWidth = $0 }
        }
        .overlay(alignment: .top) {
            if let toast = app.achievementToast {
                Text(toast)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 8, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityIdentifier("achievement.toast")
            }
        }
        .animation(.snappy, value: app.achievementToast)
        .alert(
            "成就补算",
            isPresented: Binding(
                get: { app.achievementLaunch != nil },
                set: { if !$0 { app.dismissAchievementLaunch() } }
            )
        ) {
            Button("知道了") {}
        } message: {
            if let summary = app.achievementLaunch {
                Text(
                    "解锁 \(summary.stages) 个阶段，到账 \(summary.draws) 次抽奖"
                        + (summary.resetCards > 0 ? "、\(summary.resetCards) 张重置卡" : "")
                        + "。通话时长从这次更新后开始计，抽过的奖从 0 起。"
                )
            }
        }
        .onChange(of: app.conversationPath.isEmpty) { _, isEmpty in
            // A compact back button returns to the list. Expanding afterwards must not
            // reopen the chat the producer just left.
            if isEmpty {
                app.padConversationID = nil
            }
        }
        .onChange(of: measuredWidth ?? 0) { oldWidth, newWidth in
            let oldBand = ResponsiveLayout.band(width: oldWidth, sizeClass: sizeClass)
            let newBand = ResponsiveLayout.band(width: newWidth, sizeClass: sizeClass)
            guard oldBand != .compact, newBand == .compact else { return }
            guard app.conversationPath.isEmpty,
                  let id = app.padConversationID,
                  let character = app.characters.first(where: { $0.id == id })
            else { return }
            app.conversationPath.append(character)
        }
    }

    /// The compact phone shell. Each tab keeps its own stack, and the conversation page
    /// is the existing single-column list; the chat is pushed.
    private var tabShell: some View {
        TabView(selection: selection) {
            Tab("对话", systemImage: "bubble.left.and.bubble.right", value: MainTab.conversation) {
                ConversationListView()
                    .environment(app)
            }
            Tab("朋友圈", systemImage: "person.2", value: MainTab.moments) {
                MomentsView()
                    .frame(maxWidth: ResponsiveLayout.wideMaxWidth)
                    .frame(maxWidth: .infinity)
                    .environment(app)
            }
            .badge(app.momentsBadge ? 1 : 0)
            Tab("玩法", systemImage: "sparkles", value: MainTab.play) {
                PlayHubView()
                    .frame(maxWidth: ResponsiveLayout.wideMaxWidth)
                    .frame(maxWidth: .infinity)
                    .environment(app)
            }
            .badge(app.achievementBadge ? 1 : 0)
            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
                    .environment(app)
            }
        }
    }

    /// A tap on 设置 is a manual visit. A debug launch selects the tab in `AppModel`
    /// directly, so this setter is not used and the destinations it opened stay pending
    /// (spec #64).
    private var selection: Binding<MainTab> {
        Binding(
            get: { app.selectedTab },
            set: { tab in
                if tab == .settings, app.selectedTab != .settings {
                    #if DEBUG
                    app.markSettingsOpenedManually()
                    #endif
                }
                app.selectedTab = tab
            }
        )
    }
}
