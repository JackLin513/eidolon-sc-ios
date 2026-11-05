import SwiftUI

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var app: AppModel?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let app {
                GeometryReader { geometry in
                    ZStack {
                        content(for: app)
                            .environment(app)
                        // The call layer lives over the pages for as long as the call does:
                        // folded off the bottom while the producer is elsewhere, slid back
                        // up when they return to it (spec #46).
                        if app.call.isPresent, let character = app.call.character {
                            CallView(character: character)
                                .environment(app)
                                .offset(y: app.call.isCollapsed ? screenHeight(geometry) : 0)
                                .allowsHitTesting(!app.call.isCollapsed)
                                .transition(.move(edge: .bottom))
                        }
                    }
                    .animation(
                        reduceMotion
                            ? nil
                            : .timingCurve(0.24, 1, 0.4, 1, duration: 0.41),
                        value: app.call.layer
                    )
                }
            } else if let startupError {
                ContentUnavailableView(
                    "无法启动",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupError)
                )
            } else {
                opening
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let app else { return }
            Task {
                await app.catchUpReachOuts()
                await app.runMoments()
                await app.refreshMomentsBadge()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: MomentsNotifications.openMoments)) { _ in
            app?.selectedTab = .moments
            MomentsNotifications.pendingOpen = false
        }
        .onChange(of: app == nil) { _, loading in
            guard !loading, MomentsNotifications.pendingOpen else { return }
            app?.selectedTab = .moments
            MomentsNotifications.pendingOpen = false
        }
        .task {
            guard app == nil, startupError == nil else { return }
            do {
                let model = try AppModel()
                app = model
                await model.bootstrap()
            } catch {
                startupError = error.localizedDescription
            }
        }
    }

    /// The opening spinner fills the screen, so it is centred rather than squeezed into
    /// the top-left corner by the group's intrinsic size.
    private var opening: some View {
        ProgressView("正在打开…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The layer paints past the safe area, so it has to clear the whole screen, not just
    /// the part the pages are laid out in.
    private func screenHeight(_ geometry: GeometryProxy) -> CGFloat {
        geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom
    }

    @ViewBuilder
    private func content(for app: AppModel) -> some View {
        switch app.phase {
        case .loading:
            opening
        case .needsContentBundle:
            ImportGuideView()
        case .ready:
            MainTabsView(app: app)
        case .failed(let message):
            ContentUnavailableView(
                "存储不可用",
                systemImage: "externaldrive.badge.xmark",
                description: Text(message)
            )
        }
    }
}
