import RealityKit
import SwiftUI
import UniformTypeIdentifiers

/// A standalone 3D preview. This is deliberately not connected to `StandRenderer`:
/// the game's current stand is Spine 2D, while this spike loads USDZ 3D models.
@MainActor
struct Model3DPreview: View {
    private enum Phase: Equatable {
        case empty
        case loading
        case loaded
        case failed(String)
    }

    @State private var outfit = Model3DOutfit.privateClothes
    @State private var entity: Entity?
    @State private var phase = Phase.empty
    @State private var isPicking = false
    @State private var loadError: String?

    init() {
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_OUTFIT"],
           let selected = Model3DOutfit(rawValue: raw) {
            _outfit = State(initialValue: selected)
        }
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
                    if let loadError {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.red.opacity(0.8), in: Capsule())
                            .padding(.top, 8)
                    }
                }
            case .failed(let message):
                failureView(message)
            }
        }
        .task(id: outfit) { await load(outfit) }
        .fileImporter(
            isPresented: $isPicking,
            allowedContentTypes: [UTType(filenameExtension: "usdz") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            importPickedFile(url)
        }
        .overlay(alignment: .bottom) {
            if phase == .loaded {
                HStack(spacing: 10) {
                    ForEach(Model3DOutfit.allCases) { candidate in
                        Button(candidate.title) {
                            outfit = candidate
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(candidate == outfit ? .pink : .gray)
                    }
                }
                .padding()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if phase != .empty {
                Button("选择 USDZ") { isPicking = true }
                    .buttonStyle(.bordered)
                    .padding()
            }
        }
    }

    private var emptyView: some View {
        placeholder(
            title: "还没有 USDZ",
            systemImage: "cube",
            message: "把 mirai-pr001.usdz 或 mirai-ss003.usdz 放进 bundle/Documents，或选择一个 USDZ 文件。",
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
            phase = .loading
            Task {
                do {
                    let loaded = try await Entity.load(contentsOf: destination)
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
        } catch {
            phase = .failed("无法载入所选 USDZ：\(error.localizedDescription)")
        }
    }

    private func load(_ selected: Model3DOutfit) async {
        guard let url = Model3DResourceLocator.locate(
            environment: ProcessInfo.processInfo.environment,
            documents: URL.documentsDirectory,
            resourceRoot: Bundle.main.resourceURL,
            fileName: selected.fileName
        ) else {
            entity = nil
            phase = .failed("找不到 \(selected.fileName)")
            return
        }
        phase = .loading
        do {
            let loaded = try await Entity.load(contentsOf: url)
            guard normalize(loaded) else {
                if entity != nil {
                    loadError = "USDZ 里没有可见几何"
                    phase = .loaded
                } else {
                    phase = .failed("USDZ 里没有可见几何")
                }
                return
            }
            entity = loaded
            loadError = nil
            phase = .loaded
        } catch {
            if entity != nil {
                loadError = error.localizedDescription
                phase = .loaded
            } else {
                phase = .failed(error.localizedDescription)
            }
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
