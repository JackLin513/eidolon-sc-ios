import EidolonCore
import SwiftUI

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var callPageFrame: CGRect?
    @State private var callChatFrame: CGRect?
    @State private var capsuleCorner: CallCapsuleCorner = .bottomTrailing
    @State private var app: AppModel?
    @State private var startupError: String?
    /// 欢迎页（spec #118）：放着的时候整屏都是它，原生只剩右上角的跳过。
    @State private var showsWelcome = false

    var body: some View {
        Group {
            if let app {
                if showsWelcome {
                    WelcomeView { finishWelcome() }
                        .environment(app)
                } else {
                    pages(app)
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
        .onReceive(NotificationCenter.default.publisher(for: WelcomeNotifications.replay)) { _ in
            showsWelcome = true
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
                // 别的调试注入开着时不放这一页，免得它盖住界面把 UI 用例挡住；
                // 欢迎页自己的开关（`EIDOLON_WELCOME`）例外。
                let environment = ProcessInfo.processInfo.environment
                let ordered = environment["EIDOLON_WELCOME"] == "1"
                let suppressed = environment.keys.contains {
                    $0.hasPrefix("EIDOLON_") && $0 != "EIDOLON_WELCOME"
                }
                showsWelcome = ordered || (!suppressed && WelcomeLaunch.shouldPresent(
                    seen: model.welcomeSeen,
                    hasContentBundle: model.phase == .ready
                ))
            } catch {
                startupError = error.localizedDescription
            }
        }
    }

    /// 四个页签和压在上面的通话层（spec #46、#64）。S2.3 gives the call a pane over
    /// the content the S2.2 shell measures; the same single CallView keeps its renderer
    /// while it is folded, so folding does not reload her stand.
    private func pages(_ app: AppModel) -> some View {
        GeometryReader { geometry in
            let band = ResponsiveLayout.band(width: geometry.size.width, sizeClass: sizeClass)
            let presentation = effectiveCallPresentation(
                requested: ResponsiveLayout.callPresentation(
                    band: band,
                    onConversation: app.selectedTab == .conversation
                )
            )
            let frame = callFrame(presentation, in: geometry)
            // The ZStack centres a fixed-size child; offset from its centre to the pane's
            // actual centre instead of treating the pane origin as an offset.
            let callX = frame.midX - geometry.size.width / 2
            let callY = frame.midY - geometry.size.height / 2
            ZStack {
                content(for: app)
                    .environment(app)
                if app.call.isPresent, let character = app.call.character {
                    CallView(character: character, presentation: presentation)
                        .environment(app)
                        .frame(width: frame.width, height: frame.height)
                        .modifier(CallLayerClip(enabled: presentation.isPane))
                        .offset(
                            x: callX,
                            y: callY + (app.call.isCollapsed ? frame.height : 0)
                        )
                        .opacity(app.call.isCollapsed ? 0 : 1)
                        .allowsHitTesting(!app.call.isCollapsed)
                        .transition(.move(edge: .bottom))
                        .zIndex(1)
                    if !app.call.isCollapsed {
                        Color.clear
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: callX, y: callY)
                            .accessibilityElement()
                            .accessibilityLabel("通话层")
                            .accessibilityIdentifier("call.layer")
                            .allowsHitTesting(false)
                            .zIndex(1.5)
                    }
                }
                if app.call.isPresent {
                    CallCapsule(corner: $capsuleCorner)
                        .environment(app)
                        .zIndex(2)
                }
            }
            .coordinateSpace(.named("callLayerRoot"))
            .onPreferenceChange(CallPageFramePreferenceKey.self) { callPageFrame = $0 }
            .onPreferenceChange(CallChatFramePreferenceKey.self) { callChatFrame = $0 }
            .animation(
                reduceMotion
                    ? nil
                    : .timingCurve(0.24, 1, 0.4, 1, duration: 0.41),
                value: app.call.layer
            )
            // The chat preference is only consulted for `.conversationPane`; other
            // presentations use the page frame, so no stale-frame reset is needed.
        }
    }

    /// A wide conversation keeps the roster, but its chat frame arrives on the next
    /// preference pass. Until then the page pane keeps the call inside the shell instead
    /// of flashing it over the rail.
    private func effectiveCallPresentation(requested: CallPresentation) -> CallPresentation {
        if requested == .conversationPane, callChatFrame == nil {
            return .page
        }
        return requested
    }

    private func callFrame(
        _ presentation: CallPresentation,
        in geometry: GeometryProxy
    ) -> CGRect {
        let full = CGRect(origin: .zero, size: geometry.size)
        switch presentation {
        case .fullScreen:
            return full
        case .page:
            return callPageFrame ?? full
        case .conversationPane:
            return callChatFrame ?? callPageFrame ?? full
        }
    }

    /// 欢迎页看完（或跳过）：记下看过，回到下面的页面。没有内容包时下面就是导入入口。
    private func finishWelcome() {
        app?.markWelcomeSeen()
        showsWelcome = false
    }

    /// The opening spinner fills the screen, so it is centred rather than squeezed into
    /// the top-left corner by the group's intrinsic size.
    private var opening: some View {
        ProgressView("正在打开…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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


/// S2.2 shell reports the page area to the right of the rail and, on a wide conversation
/// page, the chat column itself. Frames are in RootView's named coordinate space.
struct CallPageFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

struct CallChatFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect?
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() { value = next }
    }
}

/// A pane owns a clip rectangle; a full-screen call lets its `ignoresSafeArea`
/// background reach the status/home areas instead of leaving black strips.
private struct CallLayerClip: ViewModifier {
    let enabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.clipShape(Rectangle())
        } else {
            content
        }
    }
}
