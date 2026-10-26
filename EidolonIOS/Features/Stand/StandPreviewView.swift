import EidolonCore
import SwiftUI
import UIKit

/// The debug entry (ticket #30): see one of her outfits on screen, idling. When there is
/// no runtime, the page fails or her files are missing, it says 「没有立绘」; opening the
/// preview again retries.
struct StandPreviewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var characters: [CharacterConfig] = []
    @State private var selectedID: String?
    @State private var outfitID: String?
    @State private var renderer: (any StandRenderer)?
    @State private var phase = Phase.loading

    private enum Phase: Equatable {
        case loading
        case shown
        case missing(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            stage
            caption
        }
        .navigationTitle("立绘预览")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(characters, id: \.id) { character in
                        Button(character.name) { select(character.id) }
                    }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .disabled(characters.isEmpty)
            }
        }
        .task { await start() }
        .onChange(of: scenePhase) { _, value in
            renderer?.setPaused(value != .active)
        }
        .onDisappear { renderer?.setPaused(true) }
    }

    /// The stand over a dark backdrop so a transparent canvas is visible.
    private var stage: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.10), Color(white: 0.26)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                if let renderer, !hasFailed {
                    StandView(renderer: renderer)
                        .id(ObjectIdentifier(renderer as AnyObject))
                        .onAppear { renderer.setViewportSize(proxy.size) }
                        .onChange(of: proxy.size) { _, size in renderer.setViewportSize(size) }
                }
                switch phase {
                case .loading:
                    ProgressView("正在载入立绘…")
                        .tint(.white)
                        .foregroundStyle(.white)
                case .shown:
                    EmptyView()
                case .missing(let reason):
                    ContentUnavailableView {
                        Label("没有立绘", systemImage: "person.crop.rectangle")
                    } description: {
                        Text(reason)
                    }
                    .foregroundStyle(.white)
                }
            }
        }
    }

    private var hasFailed: Bool {
        if case .missing = phase { true } else { false }
    }

    private var caption: some View {        VStack(spacing: 2) {
            if let character = characters.first(where: { $0.id == selectedID }) {
                Text(character.name)
                    .font(.headline)
            }
            if let outfitID {
                Text("默认衣装 \(outfitID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func start() async {
        characters = app.characters.filter { $0.stand != nil }
        guard let first = characters.first else {
            phase = .missing("这份内容包里没有带立绘的角色")
            return
        }
        await show(first.id)
    }

    private func select(_ id: String) {
        Task { await show(id) }
    }

    /// Load her default outfit into a fresh renderer; a new renderer is also the retry
    /// after a failure.
    private func show(_ id: String) async {
        selectedID = id
        outfitID = nil
        phase = .loading
        renderer?.setPaused(true)
        renderer = nil

        guard let stand = await app.core.stand(for: id) else {
            phase = .missing("内容包里没有她的立绘")
            return
        }
        outfitID = stand.defaultOutfit.id

        let renderer = StandWebRenderer(
            contentRoot: app.core.location.contentDirectory,
            framing: StandFraming(compactWidth: sizeClass != .regular)
        )
        renderer.onLoaded = { _ in
            phase = .shown
        }
        renderer.onFailure = { failure in
            phase = .missing(Self.reason(failure))
        }
        renderer.setPaused(scenePhase != .active)
        // Idling: the calm body and face, mouth shut. The call's directives (#31) will
        // build poses like this from the call's events.
        renderer.direct(.calm)
        renderer.load(stand.defaultOutfit)
        self.renderer = renderer
    }

    private static func reason(_ failure: StandRenderFailure) -> String {
        switch failure {
        case .page(let message): "立绘页面打不开：\(message)"
        case .runtime(let message): "没有 Spine 运行时：\(message)"
        case .outfit(let message): "立绘素材读不出：\(message)"
        }
    }
}

/// Hosts whichever stand renderer the interface was given; it never sees WebKit.
private struct StandView: UIViewRepresentable {
    let renderer: any StandRenderer

    func makeUIView(context: Context) -> UIView {
        renderer.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
