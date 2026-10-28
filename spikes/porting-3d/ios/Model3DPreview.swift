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
            importPickedFile(url)
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
        placeholder(
            title: "还没有 USDZ",
            systemImage: "cube",
            message: "把 mirai.usdz 放进 Documents，或选择一个 USDZ 文件。",
            button: "选择 USDZ"
        )
    }

    private func failureView(_ message: String) -> some View {
        placeholder(
            title: "USDZ 载入失败",
            systemImage: "exclamationmark.triangle",
            message: message,
            button: "换一个 USDZ"
        )
    }

    private func placeholder(
        title: String,
        systemImage: String,
        message: String,
        button: String
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(button) { isPicking = true }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
    }

    private func importPickedFile(_ url: URL) {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = URL.documentsDirectory.appending(path: url.lastPathComponent)
            if destination.standardizedFileURL != url.standardizedFileURL {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.copyItem(at: url, to: destination)
            }
            modelURL = destination
        } catch {
            phase = .failed("无法复制所选 USDZ：\(error.localizedDescription)")
        }
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
            guard normalize(loaded) else {
                entity = nil
                phase = .failed("USDZ 里没有可见几何")
                return
            }
            entity = loaded
            phase = .loaded
        } catch {
            entity = nil
            phase = .failed(error.localizedDescription)
        }
    }

    /// The USDZ may come from any source; keep the camera useful regardless of its
    /// authored scale or origin.
    private func normalize(_ entity: Entity) -> Bool {
        let bounds = entity.visualBounds(relativeTo: nil)
        guard bounds.extents.x > 0.000_001,
              bounds.extents.y > 0.000_001,
              bounds.extents.z > 0.000_001
        else { return false }
        let scale = 1.6 / bounds.extents.y
        entity.scale = SIMD3<Float>(repeating: scale)
        let center = bounds.center * scale
        entity.position = [-center.x, -center.y, -center.z]

        // One light belongs to the loaded model; adding it to the entity keeps
        // RealityView content rebuilds from accumulating duplicate lights.
        let light = DirectionalLight()
        light.light.intensity = 2_000
        light.orientation = simd_quatf(angle: .pi / 4, axis: [1, 0, 0])
        entity.addChild(light)
        return true
    }
}
