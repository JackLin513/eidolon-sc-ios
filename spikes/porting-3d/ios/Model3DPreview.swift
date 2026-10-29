import EidolonCore
import RealityKit
import SwiftUI

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
    @State private var isLoading = false
    @State private var loadError: String?
    /// Kept across outfit swaps; actions arrive in the next ticket, but the
    /// selection seam must already be one value rather than an outfit-only flag.
    @State private var direction = StandDirection.calm

    init() {
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_OUTFIT"],
           let selected = Model3DOutfit(rawValue: raw) {
            _outfit = State(initialValue: selected)
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.26)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

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
                    .ignoresSafeArea()
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
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
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("还没有 USDZ", systemImage: "cube")
        } description: {
            Text("当前构建没有找到 mirai-pr001.usdz 或 mirai-ss003.usdz。")
        }
        .foregroundStyle(.white)
    }

    private func failureView(_ message: String) -> some View {
        ContentUnavailableView {
            Label("USDZ 载入失败", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .foregroundStyle(.white)
    }

    private func load(_ selected: Model3DOutfit) async {
        guard let url = Model3DResourceLocator.locate(
            environment: ProcessInfo.processInfo.environment,
            documents: URL.documentsDirectory,
            resourceRoot: Bundle.main.resourceURL,
            fileName: selected.fileName
        ) else {
            if entity == nil {
                phase = .failed("找不到 \(selected.fileName)")
            } else {
                loadError = "找不到 \(selected.fileName)"
            }
            return
        }

        isLoading = true
        if entity == nil { phase = .loading }
        defer { isLoading = false }

        do {
            let loaded = try await Entity.load(contentsOf: url)
            guard !Task.isCancelled else { return }
            guard normalize(loaded) else {
                if entity == nil {
                    phase = .failed("USDZ 里没有可见几何")
                } else {
                    loadError = "USDZ 里没有可见几何"
                }
                return
            }
            entity = loaded
            loadError = nil
            phase = .loaded
        } catch is CancellationError {
            return
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
    /// authored scale or origin. The fixed default camera is the preview framing;
    /// free orbit is intentionally not part of the parity surface.
    private func normalize(_ entity: Entity) -> Bool {
        let bounds = entity.visualBounds(relativeTo: nil)
        guard bounds.extents.x > 0.000_001,
              bounds.extents.y > 0.000_001,
              bounds.extents.z > 0.000_001
        else { return false }
        let scale = 1.6 / bounds.extents.y
        entity.scale = SIMD3<Float>(repeating: scale)
        let center = bounds.center * scale
        // Push the model away from the camera: the default RealityView camera
        // sits at the origin, so centring at zero crops her.
        entity.position = [-center.x, -center.y, -center.z - 1.35]

        // Key plus fill plus rim. A single directional light crushes every
        // surface facing away from it, which reads as damage on limbs; the game
        // never shows that because its toon ramp keeps a floor under the shadow.
        addLight(to: entity, pitch: .pi / 4, yaw: 0, intensity: 2_000)
        addLight(to: entity, pitch: 0, yaw: -.pi / 2, intensity: 1_100)
        addLight(to: entity, pitch: -.pi / 6, yaw: .pi, intensity: 700)
        return true
    }

    private func addLight(to entity: Entity, pitch: Float, yaw: Float, intensity: Float) {
        let light = DirectionalLight()
        light.light.intensity = intensity
        light.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
        entity.addChild(light)
    }
}
