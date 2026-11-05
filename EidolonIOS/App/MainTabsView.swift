import SwiftUI

/// The app's four first-level pages (spec #64, #94). Each tab keeps its own navigation stack,
/// so switching away and back returns to the page the producer left. The call layer stays
/// above all of them in the root view; the folded bar is drawn by each page.
struct MainTabsView: View {
    @Bindable var app: AppModel

    var body: some View {
        // The `Tab` form lets the same tab set become a sidebar on iPad and the new
        // floating tab bar on iPhone (spec #64, page design direction: latest system).
        TabView(selection: selection) {
            Tab("对话", systemImage: "bubble.left.and.bubble.right", value: MainTab.conversation) {
                ConversationListView()
            }
            Tab("朋友圈", systemImage: "person.2", value: MainTab.moments) {
                MomentsView()
            }
            .badge(app.momentsBadge ? 1 : 0)
            Tab("玩法", systemImage: "sparkles", value: MainTab.play) {
                PlayHubView()
            }
            .badge(app.achievementBadge ? 1 : 0)
            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
            }
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
        // A conversation is a page of its own: the four first-level tabs stay behind it
        // (spec #64). A live call is the exception, so the play tab stays within reach.
        // (The chat page hides the bar itself; see ChatView.)
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
