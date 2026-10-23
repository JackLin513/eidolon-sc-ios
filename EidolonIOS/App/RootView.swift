import SwiftUI

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var app: AppModel?
    @State private var startupError: String?

    var body: some View {
        Group {
            if let app {
                content(for: app)
                    .environment(app)
            } else if let startupError {
                ContentUnavailableView(
                    "无法启动",
                    systemImage: "exclamationmark.triangle",
                    description: Text(startupError)
                )
            } else {
                ProgressView("正在打开…")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, let app else { return }
            Task { await app.catchUpReachOuts() }
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

    @ViewBuilder
    private func content(for app: AppModel) -> some View {
        switch app.phase {
        case .loading:
            ProgressView("正在打开…")
        case .needsContentBundle:
            ImportGuideView()
        case .ready:
            ConversationListView()
        case .failed(let message):
            ContentUnavailableView(
                "存储不可用",
                systemImage: "externaldrive.badge.xmark",
                description: Text(message)
            )
        }
    }
}
