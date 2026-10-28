import RealityKit
import SwiftUI
import UniformTypeIdentifiers

/// A standalone 3D preview. This is deliberately not connected to `StandRenderer`:
/// the game's current stand is Spine 2D, while this spike loads a USDZ 3D model.
@MainActor
struct Model3DPreview: View {
    private enum Phase: Equatable {
        case empty
        case loading
        case loaded
        case failed(String)
    }

    @State private var modelURL: URL?
    @State private var entity: Entity?
    @State private var phase = Phase.empty
    @State private var isPicking = false

    init(modelURL: URL?) {
        _modelURL = State(initialValue: modelURL)
    }

    var body: some View {
        ZStack {
            Color(white: 0.08).ignoresSafeArea()
            switch phase {
            case .empty:
                emptyView
            case .loading:
                ProgressView("正在载入 USDZ…")
                    .tint(.white)
                    .foregroundStyle(.white)
            case .loaded:
                if let entity {
                    RealityView { content in
                        if entity.parent == nil {
                            content.add(entity)
                        }
                        let light = DirectionalLight()
                        light.light.intensity = 2_000
                        light.orientation = simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
                        content.add(light)
                    }
                    .realityViewCameraControls(.orbit)
                    .ignoresSafeArea()
                }
            case .failed(let message):
                failureView(message)
            }
        }
        .task(id: modelURL) { await load() }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [UTType(filenameExtension: "usdz") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            modelURL = url
        }
        .overlay(alignment: .bottomTrailing) {
            if phase != .empty {
                Button("选择 USDZ") { isPicking = true }
                    .buttonStyle(.borderedProminent)
                    .padding()
            }
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("还没有 USDZ", systemImage: "cube")
        } description: {
            Text("把 mirai.usdz 放进 Documents，或选择一个 USDZ 文件。")
        } actions: {
            Button("选择 USDZ") { isPicking = true }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("USDZ 载入失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("换一个 USDZ") { isPicking = true }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private func load() async {
        guard let modelURL else {
            phase = .empty
            entity = nil
            return
        }
        phase = .loading
        do {
            let loaded = try await Entity.load(contentsOf: modelURL)
            normalize(loaded)
            entity = loaded
            phase = .loaded
        } catch {
            entity = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// The USDZ may come from any source; keep the camera useful regardless of its
    /// authored scale or origin.
    private func normalize(_ entity: Entity) {
        let bounds = entity.visualBounds(relativeTo: nil)
        let height = max(bounds.extents.y, 0.001)
        let scale = 1.6 / height
        entity.scale = SIMD3<Float>(repeating: scale)
        let center = bounds.center * scale
        entity.position = [-center.x, -center.y, -center.z]
    }
}
