import SwiftUI

/// The app's three first-level pages (spec #64). Each tab keeps its own navigation stack,
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
            Tab("玩法", systemImage: "sparkles", value: MainTab.play) {
                PlayHubView()
            }
            Tab("设置", systemImage: "gearshape", value: MainTab.settings) {
                SettingsView()
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
