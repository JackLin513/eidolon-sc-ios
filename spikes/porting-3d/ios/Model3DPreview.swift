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
    /// Added to the scene once. Models are swapped inside it, because
    /// `RealityView`'s make closure does not run again when state changes.
    @State private var container = Entity()
    @State private var entity: Entity?
    @State private var phase = Phase.empty
    @State private var isLoading = false
    @State private var loadError: String?
    /// Kept across outfit swaps; actions arrive in the next ticket, but the
    /// selection seam must already be one value rather than an outfit-only flag.
    @State private var direction = StandDirection.calm

    /// Framing the loader chose, before any inspection gesture moves it.
    @State private var baseScale: Float = 1
    @State private var basePosition = SIMD3<Float>.zero
    /// Scale the last fit settled on.
    @State private var appliedScale: Float = 0

    /// Inspection gestures. Orbit is a debug affordance, not the parity framing:
    /// the preview opens on the fixed front composition.
    @State private var yaw: Float = 0
    @State private var pitch: Float = 0
    @State private var zoom: Float = 1
    @State private var dragStart: SIMD2<Float>?
    @State private var zoomStart: Float?

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
                        content.add(container)
                    }
                    .ignoresSafeArea()
                    .gesture(orbitGesture)
                    .simultaneousGesture(zoomGesture)
                    .onTapGesture(count: 2) { resetInspection() }
                }
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
            case .failed(let message):
                failureView(message)
            }
        }
        .task(id: outfit) { await load(outfit) }
        .task { await scheduleDebugSwap() }
        .safeAreaInset(edge: .bottom) {
            if phase == .loaded {
                controls
            }
        }
    }

    /// Debug hook: `EIDOLON_3D_SWAP_SECONDS=4` switches outfits once after launch,
    /// which exercises the same path as the buttons without a tap.
    private func scheduleDebugSwap() async {
        guard let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_SWAP_SECONDS"],
              let seconds = Double(raw)
        else { return }
        try? await Task.sleep(for: .seconds(seconds))
        outfit = outfit == .privateClothes ? .stageCostume : .privateClothes
    }

    private var controls: some View {
        HStack(spacing: 10) {
            ForEach(Model3DOutfit.allCases) { candidate in
                Button {
                    outfit = candidate
                } label: {
                    Text(candidate.title)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(candidate == outfit ? .pink : .gray)
                .contentShape(Rectangle())
            }
        }
        .padding()
    }

    private var orbitGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = SIMD2(yaw, pitch) }
                guard let start = dragStart else { return }
                yaw = start.x + Float(value.translation.width) * 0.012
                pitch = start.y + Float(value.translation.height) * 0.012
                applyInspection()
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil { zoomStart = zoom }
                guard let start = zoomStart else { return }
                zoom = min(max(start * Float(value.magnification), 0.4), 3)
                applyInspection()
            }
            .onEnded { _ in zoomStart = nil }
    }

    private func resetInspection() {
        yaw = 0
        pitch = 0
        zoom = 1
        applyInspection()
    }

    private func applyInspection() {
        guard let entity else { return }
        entity.scale = SIMD3<Float>(repeating: baseScale * zoom)
        entity.position = basePosition
        entity.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
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
            let loaded = try await Self.decode(url)
            guard !Task.isCancelled else { return }
            let environment = ProcessInfo.processInfo.environment
            let locate: (String) -> URL? = { name in
                Model3DResourceLocator.locate(
                    environment: environment,
                    documents: URL.documentsDirectory,
                    resourceRoot: Bundle.main.resourceURL,
                    fileName: name
                )
            }
            var materials: MaterialParameters?
            if let atlas = locate(selected.parametersFileName),
               let table = locate(selected.materialsFileName) {
                materials = await MaterialParameters.load(atlas: atlas, table: table)
            }
            ToonShading.apply(to: loaded, parameters: materials)
            for child in container.children {
                child.removeFromParent()
            }
            container.addChild(loaded)
            // Bounds of a skinned model are only meaningful once the skeleton is
            // mounted and resolved, and they keep growing for a few frames after
            // that — a single early read sized the model anywhere from a quarter
            // to twice the intended height. Fit repeatedly and keep the largest
            // box seen.
            guard await fitAfterSettle(loaded) else {
                if entity == nil {
                    phase = .failed("USDZ 里没有可见几何")
                } else {
                    loadError = "USDZ 里没有可见几何"
                }
                return
            }
            resetInspection()
            entity = loaded
            applyInspection()
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

    /// Parsing a multi-megabyte USDZ on the main actor froze the app when the
    /// user swapped outfits, so the decode runs off it.
    private nonisolated static func decode(_ url: URL) async throws -> Entity {
        try await Entity.load(contentsOf: url)
    }

    /// Sample the bounds for a couple of seconds and fit to the **median**.
    ///
    /// `visualBounds` of a skinned model is not merely late to settle, it is
    /// noisy: the same build framed her anywhere from 2% to 80% of the viewport
    /// depending on which frame got read, and neither "first", "last" nor
    /// "largest" was stable. A median over two dozen samples ignores both the
    /// runaway small boxes and the transient huge ones.
    private func fitAfterSettle(_ entity: Entity) async -> Bool {
        addLights(to: entity)
        var heights: [Float] = []
        var centres: [SIMD3<Float>] = []
        for _ in 0..<24 {
            let bounds = entity.visualBounds(relativeTo: nil)
            if bounds.extents.y > 0.000_001 {
                heights.append(bounds.extents.y)
                centres.append(bounds.center)
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !heights.isEmpty else { return false }

        let height = heights.sorted()[heights.count / 2]
        let centre = SIMD3<Float>(
            centres.map(\.x).sorted()[centres.count / 2],
            centres.map(\.y).sorted()[centres.count / 2],
            centres.map(\.z).sorted()[centres.count / 2]
        )
        return fit(entity, height: height, centre: centre)
    }

    /// The USDZ may come from any source; keep the camera useful regardless of its
    /// authored scale or origin. The fixed default camera is the preview framing;
    /// free orbit is intentionally not part of the parity surface.
    private func fit(
        _ entity: Entity, height: Float? = nil, centre sampled: SIMD3<Float>? = nil
    ) -> Bool {
        let bounds = entity.visualBounds(relativeTo: nil)
        guard bounds.extents.x > 0.000_001,
              bounds.extents.z > 0.000_001
        else { return false }
        let extent = height ?? bounds.extents.y
        guard extent > 0.000_001 else { return false }
        if ProcessInfo.processInfo.environment["EIDOLON_3D_LOG_MATERIALS"] != nil {
            print("[frame] extents=\(bounds.extents) centre=\(sampled ?? bounds.center)")
        }
        // World units of height the model should occupy. Calibrated against the
        // settled bounds: 2.3 rendered her at 38% of the viewport height, so 4.2
        // lands near 70% with the head clear of the status bar.
        let targetHeight: Float = 4.2
        let scale = targetHeight / extent
        let center = (sampled ?? bounds.center) * scale
        // Push the model away from the camera: the default RealityView camera
        // sits at the origin, so centring at zero crops her. The upward nudge is
        // a fraction of her height so the framing holds at any scale.
        basePosition = [-center.x, -center.y + targetHeight * 0.11, -center.z - 1.0]
        appliedScale = scale
        baseScale = scale
        entity.scale = SIMD3<Float>(repeating: scale)
        entity.position = basePosition
        return true
    }

    /// Key plus fill plus rim. RealityKit's lit model runs on top of the surface
    /// shader's output, so these are what set the preview's overall exposure;
    /// the game's own ramp supplies the two tones.
    private func addLights(to entity: Entity) {
        guard entity.children.allSatisfy({ $0.components[DirectionalLightComponent.self] == nil }) else {
            return
        }
        addLight(to: entity, pitch: .pi / 4, yaw: 0, intensity: 2_000)
        addLight(to: entity, pitch: 0, yaw: -.pi / 2, intensity: 1_100)
        addLight(to: entity, pitch: -.pi / 6, yaw: .pi, intensity: 700)
    }

    private func addLight(to entity: Entity, pitch: Float, yaw: Float, intensity: Float) {
        let light = DirectionalLight()
        light.light.intensity = intensity
        light.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
        entity.addChild(light)
    }
}
