import SwiftUI

@MainActor
struct RootView: View {
    @State private var app = AppModel()

    var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ProgressView("正在连接…")
            case .signedOut:
                LoginView()
            case .needsConsent:
                ConsentView()
            case .ready:
                ConversationListView()
            }
        }
        .environment(app)
        .task {
            await app.bootstrap()
        }
    }
}
