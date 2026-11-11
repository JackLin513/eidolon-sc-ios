import EidolonCore
import OSLog
import SwiftUI
import UIKit

@MainActor
struct RootView: View {
    private let uiLog = Logger(subsystem: "com.jacklin.eidolon", category: "ui")
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var callPageFrame: CGRect?
    @State private var callChatFrame: CGRect?
    @State private var callRosterWidth: CGFloat?
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
                } else if app.phase == .ready {
                    // Read `phase` directly in the body. Keeping it only inside the
                    // nested content builder left the loading view on screen after the
                    // model became ready.
                    pages(app)
                } else {
                    content(for: app)
                }
            } else if let startupError {
                ContentUnavailableView(
                    "无法启动",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupError)
                )
            } else {
                ProgressView("正在打开…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .onChange(of: app?.phase) { _, phase in
            uiLog.notice("root phase=\(String(describing: phase), privacy: .public)")
        }
        .task {
            guard app == nil, startupError == nil else { return }
            do {
                let model = try AppModel()
                app = model
                // Bootstrap in an unstructured task: setting `app` re-renders this view,
                // and a view-owned `.task` can be cancelled mid-await. A cancelled
                // bootstrap used to leave the launch spinner suspended forever.
                Task { @MainActor in
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
                }
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
            let baseFrame = callFrame(presentation, in: geometry)
            #if DEBUG
            let _ = uiLog.notice(
                "frame page=\(String(describing: self.callPageFrame), privacy: .public) chat=\(String(describing: self.callChatFrame), privacy: .public) roster=\(String(describing: self.callRosterWidth), privacy: .public) base=\(String(describing: baseFrame), privacy: .public) band=\(String(describing: band), privacy: .public)"
            )
            #endif
            let resolvedPresentation = ResponsiveLayout.resolvePaneCallPresentation(
                presentation,
                paneSize: baseFrame.size
            )
            let rawFrame = callFrame(resolvedPresentation, in: geometry)
            let effectivePresentation = resolvedPresentation
            let safe = windowSafeInsets
            // RootView's GeometryReader is inset by the safe area; the call's background
            // has to paint into that inset (status bar and Home indicator) instead of
            // stopping at the safe rectangle. Only the content is inset again.
            let frame = CGRect(
                x: effectivePresentation.isPane ? rawFrame.minX : -safe.leading,
                y: -safe.top,
                width: effectivePresentation.isPane
                    ? rawFrame.width
                    : geometry.size.width + safe.leading + safe.trailing,
                height: geometry.size.height + safe.top + safe.bottom
            )
            let topInset = safe.top
            let bottomInset = safe.bottom
            // The ZStack centres a fixed-size child; offset from its centre to the pane's
            // actual centre instead of treating the pane origin as an offset.
            let callX = frame.midX - geometry.size.width / 2
            let callY = frame.midY - geometry.size.height / 2
            #if DEBUG
            let _ = uiLog.notice(
                "final pres=\(String(describing: effectivePresentation), privacy: .public) frame=\(String(describing: frame), privacy: .public) callX=\(callX, format: .fixed(precision: 1)) callY=\(callY, format: .fixed(precision: 1)) geometry=\(String(describing: geometry.size), privacy: .public)"
            )
            #endif
            ZStack {
                content(for: app)
                    .environment(app)
                    .onAppear { uiLog.notice("pages content appeared") }
                if app.call.isPresent, let character = app.call.character {
                    if effectivePresentation.isPane {
                        CallBackdropView(character: character)
                            .environment(app)
                            .frame(width: frame.width, height: frame.height)
                            .clipped()
                            .offset(x: callX, y: callY)
                            .opacity(app.call.isCollapsed ? 0 : 1)
                            .allowsHitTesting(false)
                            .zIndex(0.5)
                    }
                    CallView(
                        character: character,
                        presentation: effectivePresentation,
                        topInset: topInset,
                        bottomInset: bottomInset
                    )
                        .environment(app)
                        .ignoresSafeArea()
                        .frame(width: frame.width, height: frame.height)
                        .modifier(CallLayerClip(enabled: effectivePresentation.isPane))
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
                        .id("\(geometry.size.width)x\(geometry.size.height)")
                        .zIndex(2)
                }
            }
            .coordinateSpace(.named("callLayerRoot"))
            .onPreferenceChange(CallPageFramePreferenceKey.self) { callPageFrame = $0 }
            .onPreferenceChange(CallChatFramePreferenceKey.self) { callChatFrame = $0 }
            .onPreferenceChange(CallRosterWidthPreferenceKey.self) { callRosterWidth = $0 }            .animation(
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
        // A missing chat-frame preference must not demote the call to the whole page:
        // the page plus roster width still identifies the chat column. Demoting here
        // made the Air portrait call cover the roster.
        requested
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
        case .conversationPane, .phonePane:
            // Derive the chat column from the page and the roster width: an iPad
            // NavigationStack can report the whole page as its frame, which made the
            // call pane cover the roster on a tall portrait window.
            if let page = callPageFrame {
                let roster = callRosterWidth ?? ResponsiveLayout.rosterDefaultWidth
                return CGRect(
                    x: page.minX + roster,
                    y: page.minY,
                    width: max(1, page.width - roster),
                    height: page.height
                )
            }
            return callChatFrame ?? full
        }
    }

    /// 欢迎页看完（或跳过）：记下看过，回到下面的页面。没有内容包时下面就是导入入口。
    private func finishWelcome() {
        app?.markWelcomeSeen()
        showsWelcome = false
    }

    /// The opening spinner fills the screen, so it is centred rather than squeezed into
    /// the top-left corner by the group's intrinsic size.
    private func opening(_ app: AppModel) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            #if DEBUG
            Text("正在打开…")
            Text(app.startupStage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(String(format: "%.1fs", Date().timeIntervalSince(app.startupStartedAt)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            #else
            Text("正在打开…")
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }


    @ViewBuilder
    private func content(for app: AppModel) -> some View {
        switch app.phase {
        case .loading:
            opening(app)
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


    /// The key window's safe insets. RootView's GeometryReader works in the safe
    /// rectangle, while the call background must paint through it.
    private var windowSafeInsets: EdgeInsets {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return EdgeInsets() }
        let insets = window.safeAreaInsets
        return EdgeInsets(top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
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

struct CallRosterWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
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
