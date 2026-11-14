#if DEBUG
import EidolonCore
import SwiftUI
import UIKit

/// Development-only 3D smoke test: no call, no microphone, just the packaged
/// `Unity3DContent` and an MLTD content character.
struct Model3DPreviewView: View {
    @Environment(AppModel.self) private var app
    @State private var renderer: (any CharacterRenderer)?
    @State private var loaded = false
    @State private var status = "正在启动 3D…"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let renderer {
                StandHostView(renderer: renderer)
                    .ignoresSafeArea()
                    .opacity(loaded ? 1 : 0)
                    .allowsHitTesting(false)
            }
            VStack {
                Spacer()
                Text(status)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(10)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding()
            }
        }
        .task { start() }
    }

    @MainActor
    private func start() {
        let count = app.model3DManifest?.characters.count ?? -1
        let root = app.model3DRoot?.lastPathComponent ?? "nil"
        let available = app.is3DAvailable
        let bundleRoot = Bundle.main.bundleURL.appendingPathComponent("Unity3DContent", isDirectory: true)
        let manifestURL = bundleRoot.appendingPathComponent("manifest.json")
        let exists = FileManager.default.fileExists(atPath: manifestURL.path)
        let bytes = (try? Data(contentsOf: manifestURL))?.count ?? -1
        guard let outfit = app.first3DOutfit(for: "001har") else {
            status = "没有 001har 映射  characters=\(count) root=\(root) available=\(available) exists=\(exists) bytes=\(bytes)"
            return
        }
        let assets = app.preparedAssets(RuntimeAssets(
            contentRoot: app.core.location.contentDirectory,
            characterID: "001har",
            outfit: outfit,
            framing: .full
        ))
        guard let made = app.makeRenderer(assets, allow3D: true) else {
            status = "没有可用的 3D 渲染器"
            return
        }
        status = "runtime=\(made.runtimeID)"
        made.onReady = { report in
            loaded = true
            status = "已载入 \(report.resolved.fullBleed ? "fullBleed" : "normal")"
        }
        made.onFailure = { failure in
            loaded = false
            status = "失败：\(failure)"
        }
        made.setViewport(UIScreen.main.bounds.size)
        renderer = made
        made.prepare(assets)
    }
}
#endif
