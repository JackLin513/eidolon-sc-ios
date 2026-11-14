import EidolonCore
import SwiftUI
import UIKit

/// The app's four first-level pages (spec #64, #94).
///
/// iPad keeps S2.1's custom `PadShellView` rail + breakpoint shell. iPhone uses the
/// system tab/sidebar component: on a Duo's regular-width inner display iOS places the
/// four menu items at the side, while the compact outer display stays a bottom tab bar.
struct MainTabsView: View {
    @Bindable var app: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var measuredWidth: CGFloat?
    /// A partially folded Duo uses the compact page layout even when the display is
    /// still regular-width; the shell stays system-owned and only the content adapts.
    @State private var isPartiallyOpen = false

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let band = ResponsiveLayout.band(width: width, sizeClass: sizeClass)

            Group {
                if ResponsiveLayout.usesPadShell(isPad: isPad, band: band) {
                    PadShellView(app: app, band: band)
                        .environment(app)
                } else {
                    phoneShell(forceCompactContent: isPartiallyOpen)
                        .modifier(HingeObserver(isPartiallyOpen: $isPartiallyOpen))
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

    /// The iPhone shell. iOS 27 places the compact floating tab bar at the side by
    /// default on the Duo's outer display; the same system placement must be left alone
    /// on the inner display instead of forcing the iPad-style labeled sidebar.
    private func phoneShell(forceCompactContent: Bool) -> some View {
        tabShell(forceCompactContent: forceCompactContent)
    }

    private func tabShell(forceCompactContent: Bool) -> some View {
        TabView(selection: selection) {
            Tab("对话", systemImage: "bubble.left.and.bubble.right", value: MainTab.conversation) {
                DuoConversationPage(forceCompactContent: forceCompactContent)
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
        .tabBarMinimizeBehavior(.never)
        .environment(\.isEidolonSystemSidebarShell, true)
        .environment(\.isEidolonForceCompactContent, forceCompactContent)
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

/// The conversation page inside the iPhone system sidebar shell. The page measures its
/// own content width: on a Duo's inner landscape the sidebar leaves about 630–650pt,
/// which is enough for the roster + chat columns once the chat's minimum is 340pt.
private struct DuoConversationPage: View {
    @Environment(AppModel.self) private var app
    let forceCompactContent: Bool

    var body: some View {
        GeometryReader { proxy in
            let band = forceCompactContent
                ? ResponsiveWidthBand.compact
                : ResponsiveLayout.duoPageBand(width: proxy.size.width, height: proxy.size.height)

            Group {
                if band == .wide {
                    PadConversationView(band: .wide)
                } else {
                    ConversationListView()
                }
            }
            .onChange(of: band) { oldBand, newBand in
                // Collapsing a two-column page must keep the open chat, not silently
                // drop the producer back to the roster.
                guard oldBand == .wide, newBand != .wide,
                      app.conversationPath.isEmpty,
                      let id = app.padConversationID,
                      let character = app.characters.first(where: { $0.id == id })
                else { return }
                app.conversationPath.append(character)
            }
        }
    }
}

/// Reads the Duo hinge without putting an iOS 27.1 type in the deployment target.
private struct HingeObserver: ViewModifier {
    @Binding var isPartiallyOpen: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, newContext in
                let partiallyOpen = newContext.hinge?.status == .partiallyOpen
                if isPartiallyOpen != partiallyOpen {
                    isPartiallyOpen = partiallyOpen
                }
            }
        } else {
            content
        }
    }
}

/// Tells settings that the system tab sidebar already owns first-level navigation, so
/// the page itself should use a single category list instead of nesting another split.
private struct EidolonSystemSidebarShellKey: EnvironmentKey {
    static let defaultValue = false
}

/// A partially folded Duo tells page content to use its compact form while the system
/// shell keeps the tab selection and navigation paths.
private struct EidolonForceCompactContentKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isEidolonSystemSidebarShell: Bool {
        get { self[EidolonSystemSidebarShellKey.self] }
        set { self[EidolonSystemSidebarShellKey.self] = newValue }
    }

    var isEidolonForceCompactContent: Bool {
        get { self[EidolonForceCompactContentKey.self] }
        set { self[EidolonForceCompactContentKey.self] = newValue }
    }
}
