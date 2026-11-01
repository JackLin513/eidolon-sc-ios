import EidolonCore
import RealityKit
import SwiftUI
import UIKit

/// A standalone 3D preview. This is deliberately not connected to `StandRenderer`:
/// the game's current stand is Spine 2D, while this spike loads USDZ 3D models.
@MainActor
struct Model3DPreview: View {
    private enum DragMode {
        case rotate
        case move
    }

    private enum Phase: Equatable {
        case empty
        case loading
        case loaded
        case failed(String)
    }

    @State private var outfit = Model3DOutfit.starting
    @State private var character = Model3DOutfit.starting.character
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
    /// Drives the decoded dance curves; attached only when a motion file sits
    /// beside the model (or `EIDOLON_3D_MOTION` names one).
    @State private var playback = MotionPlayback()
    /// Every action found in `Documents/poses`, grouped for the picker.
    @State private var poseClips: [PoseClip] = []
    @State private var showingPosePicker = false
    /// Name of the action currently attached, for the button's label.
    @State private var currentPose: String?
    /// URL of the model on screen; the sway sidecar and replay paths hang off it.
    @State private var loadedModelURL: URL?

    /// `EIDOLON_3D_POSE`: name (or prefix) of the action to attach on launch.
    private static var startingPose: String? {
        ProcessInfo.processInfo.environment["EIDOLON_3D_POSE"]
    }

    /// Framing the loader chose, before any inspection gesture moves it.
    @State private var baseScale: Float = 1
    @State private var basePosition = SIMD3<Float>.zero
    /// Scale and position the last fit settled on; double-tap restores them.
    @State private var appliedScale: Float = 0
    @State private var fittedPosition = SIMD3<Float>.zero

    /// Inspection gestures. Orbit is a debug affordance, not the parity framing:
    /// the preview opens on the fixed front composition.
    /// `EIDOLON_3D_YAW` (degrees): a starting pose for screenshot runs.
    private static var startingYaw: Float {
        (Float(ProcessInfo.processInfo.environment["EIDOLON_3D_YAW"] ?? "0") ?? 0) * .pi / 180
    }

    @State private var yaw: Float = Model3DPreview.startingYaw
    @State private var pitch: Float = 0
    @State private var zoom: Float = Float(ProcessInfo.processInfo.environment["EIDOLON_3D_ZOOM"] ?? "1") ?? 1
    @State private var dragStart: SIMD2<Float>?
    /// What a drag does. Rotation is the default; panning exists so the model can
    /// be moved out from behind the buttons.
    @State private var dragMode = DragMode.rotate
    @State private var panStart: SIMD3<Float>?
    @State private var zoomStart: Float?

    init() {
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_OUTFIT"],
           let selected = Model3DOutfit.all.first(where: {
               $0.id == raw || $0.title == raw
           }) {
            _outfit = State(initialValue: selected)
            _character = State(initialValue: selected.character)
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
                        // RealityKit applies a scene-level tone map after the
                        // surface shader and before sRGB encoding, which pulled
                        // every colour down (0.5 came out at 110/255 instead of
                        // 128/255 and the whole character read dark). Toe and
                        // shoulder weights of zero make that curve the identity
                        // (measured within 1.25/255 across 0...1), so the shader's
                        // output reaches the screen as the game's numbers.
                        // iOS 27 and undocumented; the fallback keeps older
                        // systems on the tone-mapped look rather than crashing.
                        if #available(iOS 27.0, *) {
                            let tone = Entity()
                            tone.components.set(
                                ToneMappingComponent(toeStrength: 0, shoulderStrength: 0)
                            )
                            content.add(tone)
                        }
                        content.add(container)
                    }
                    .ignoresSafeArea()
                    .gesture(SimultaneousGesture(orbitGesture, zoomGesture))
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
        .task {
            // Screenshot runs cannot tap, so let the environment open the
            // picker: `EIDOLON_3D_SHOW_POSES=1`.
            guard ProcessInfo.processInfo.environment["EIDOLON_3D_SHOW_POSES"] != nil
            else { return }
            poseClips = PoseCatalog.load(documents: URL.documentsDirectory)
            showingPosePicker = true
        }
        .sheet(isPresented: $showingPosePicker) {
            PosePickerView(clips: poseClips) { clip in
                playPose(clip)
            }
        }
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
        guard let current = Model3DOutfit.all.firstIndex(of: outfit),
              Model3DOutfit.all.count > 1
        else { return }
        outfit = Model3DOutfit.all[(current + 1) % Model3DOutfit.all.count]
    }

    private var controls: some View {
        VStack(spacing: 8) {
        HStack(spacing: 10) {
            Button {
                zoom = min(zoom * 1.25, 3)
                applyInspection()
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                zoom = max(zoom / 1.25, 0.4)
                applyInspection()
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                dragMode = dragMode == .rotate ? .move : .rotate
            } label: {
                Image(systemName: dragMode == .rotate
                      ? "rotate.3d"
                      : "arrow.up.left.and.arrow.down.right")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                if poseClips.isEmpty {
                    poseClips = PoseCatalog.load(documents: URL.documentsDirectory)
                }
                showingPosePicker = true
            } label: {
                Image(systemName: "figure.walk")
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            if playback.duration > 0 {
                Button {
                    playback.toggle()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .tint(playback.isPlaying ? .pink : .white)

                Button {
                    playback.seek(to: 0)
                } label: {
                    Image(systemName: "backward.end.fill")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }

        }
        characterRow
        outfitRow
        }
        .padding()
    }

    /// One button per idol found on disk. Each character's outfits sit in the
    /// row below, so a corpus of a dozen characters stays readable.
    private var characterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Model3DOutfit.characters(Model3DOutfit.all), id: \.self) { name in
                    Button {
                        character = name
                        if let first = Model3DOutfit.outfits(
                            of: name, in: Model3DOutfit.all
                        ).first {
                            outfit = first
                        }
                    } label: {
                        Text(name).padding(.horizontal, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(character == name ? .pink : .white)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private var outfitRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Model3DOutfit.outfits(of: character, in: Model3DOutfit.all)) { candidate in
                    Button {
                        outfit = candidate
                    } label: {
                        Text(candidate.title).padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(candidate == outfit ? .pink : .gray)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private var orbitGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                switch dragMode {
                case .rotate:
                    if dragStart == nil { dragStart = SIMD2(yaw, pitch) }
                    guard let start = dragStart else { return }
                    yaw = start.x + Float(value.translation.width) * 0.012
                    pitch = start.y + Float(value.translation.height) * 0.012
                case .move:
                    if panStart == nil { panStart = basePosition }
                    guard let start = panStart else { return }
                    // Screen points to world units: the model is a couple of
                    // units tall in a viewport a few units wide.
                    basePosition = SIMD3(
                        start.x + Float(value.translation.width) * 0.004,
                        start.y - Float(value.translation.height) * 0.004,
                        start.z
                    )
                }
                applyInspection()
            }
            .onEnded { _ in
                dragStart = nil
                panStart = nil
            }
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

    /// Double-tap: undo rotation, zoom and panning.
    private func resetInspection() {
        yaw = Self.startingYaw
        pitch = 0
        zoom = Float(ProcessInfo.processInfo.environment["EIDOLON_3D_ZOOM"] ?? "1") ?? 1
        basePosition = fittedPosition
        applyInspection()
    }

    private func applyInspection() {
        guard entity != nil else { return }
        // The outline pass is a sibling of the model, so the transform lives on
        // the container and both passes move together.
        container.scale = SIMD3<Float>(repeating: baseScale * zoom)
        container.position = basePosition
        container.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
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
        // Discovery already found the USDZ beside its sidecars; only fall back
        // to the shared locator for the bundled models, which have no folder.
        let besideModel = selected.directory.appending(path: selected.fileName)
        guard let url = FileManager.default.fileExists(atPath: besideModel.path)
            ? besideModel
            : Model3DResourceLocator.locate(
                environment: ProcessInfo.processInfo.environment,
                documents: URL.documentsDirectory,
                resourceRoot: Bundle.main.resourceURL,
                fileName: selected.fileName
            )
        else {
            if entity == nil {
                phase = .failed("找不到 \(selected.fileName)")
            } else {
                loadError = "找不到 \(selected.fileName)"
            }
            return
        }

        loadedModelURL = url
        isLoading = true
        if entity == nil { phase = .loading }
        defer { isLoading = false }

        do {
            let loaded = try await Self.decode(url)
            guard !Task.isCancelled else { return }
            let environment = ProcessInfo.processInfo.environment
            let locate: (String) -> URL? = { name in
                // The batch corpus keeps each outfit in its own folder, so the
                // sidecars sit next to the USDZ rather than at Documents' root.
                // Look there first; the shared locator only knows flat names.
                let besideModel = url.deletingLastPathComponent().appending(path: name)
                if FileManager.default.fileExists(atPath: besideModel.path) {
                    return besideModel
                }
                return Model3DResourceLocator.locate(
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
            // Where the skeleton actually puts the figure, in model units.
            // `visualBounds` reports the bind box, and for a model whose root
            // joint carries a translation that box is a body height away from
            // what gets drawn, so the camera would aim at empty air.
            let drawnCentreY: Float? = locate("\(selected.id)-bounds.json")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(BoundsSidecar.self, from: $0) }
                .flatMap { box in
                    guard box.min.count > 1, box.max.count > 1 else { return nil }
                    return (box.min[1] + box.max[1]) / 2
                }
            // The same sidecar's floor, so a ground grid can sit at her feet
            // instead of wherever the exported origin happens to be.
            let drawnFloorY: Float? = locate("\(selected.id)-bounds.json")
                .flatMap { try? Data(contentsOf: $0) }
                .flatMap { try? JSONDecoder().decode(BoundsSidecar.self, from: $0) }
                .flatMap { box in box.min.count > 1 ? box.min[1] : nil }
            // The container carries the last outfit's transform, and the bounds
            // sampled below are world-space, so the fit would compound the
            // previous scale and offset. Start from identity every load.
            container.scale = .one
            container.position = .zero
            ToonShading.apply(to: loaded, parameters: materials)
            // The game's outline is a second draw of the same mesh with front
            // faces culled and vertices pushed out along the normal. RealityKit
            // has no per-model second pass, so it is a cloned sibling.
            let outline = loaded.clone(recursive: true)
            ToonShading.applyOutline(to: outline, parameters: materials)
            outline.name = loaded.name + "-outline"
            // Snapshot the old children before touching them: a load that was
            // cancelled after it had already installed its model leaves a body
            // and its outline behind, and the outline (a clone of the previous
            // mesh) is what shows up drawn over the new outfit.
            let stale = container.children
            for child in stale {
                child.removeFromParent()
            }
            container.addChild(loaded)
            if environment["EIDOLON_3D_NO_OUTLINE"] == nil {
                container.addChild(outline)
            }
            // Bounds of a skinned model are only meaningful once the skeleton is
            // mounted and resolved, and they keep growing for a few frames after
            // that — a single early read sized the model anywhere from a quarter
            // to twice the intended height. Fit repeatedly and keep the largest
            // box seen.
            guard await fitAfterSettle(loaded, drawnCentreY: drawnCentreY) else {
                // A cancelled load fails the fit by construction; that is not an
                // error to report, the newer load owns the view now.
                if Task.isCancelled { return }
                if entity == nil {
                    phase = .failed("USDZ 里没有可见几何")
                } else {
                    loadError = "USDZ 里没有可见几何"
                }
                return
            }
            // A cancelled load must not touch the container: the next outfit's
            // load may already own it.
            guard !Task.isCancelled else { return }
            // Belt and braces: whatever else is parented to the container is a
            // leftover from an earlier outfit and would render on top of this one.
            for child in container.children
            where child !== loaded && child !== outline {
                child.removeFromParent()
            }
            resetInspection()
            entity = loaded
            applyInspection()
            addGround(to: container, floorY: drawnFloorY ?? 0)
            if let wanted = Self.startingPose {
                // `EIDOLON_3D_POSE=<name prefix>`: pick an action without a tap.
                let clips = PoseCatalog.load(documents: URL.documentsDirectory)
                if let clip = clips.first(where: { $0.name == wanted })
                    ?? clips.first(where: { $0.name.hasPrefix(wanted) }) {
                    playPose(clip)
                }
            } else {
                startMotion(for: selected, beside: url)
            }

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

    /// Attach a dance when one was exported beside the model. The file is named
    /// after the outfit (`014mir-ss002.motion.json`) because the curves belong
    /// to the body skeleton rather than the costume; `EIDOLON_3D_MOTION` names a
    /// file directly, or one to look up beside the USDZ, for a one-off run.
    private func startMotion(for selected: Model3DOutfit, beside url: URL) {
        guard let motionURL = motionURL(for: selected, beside: url) else { return }
        do {
            let dance = try JSONDecoder().decode(
                MotionDance.self, from: Data(contentsOf: motionURL)
            )
            guard playback.attach(
                dance: dance, to: container,
                sway: swayConfiguration(for: selected, beside: url)
            ) else {
                loadError = playback.status
                return
            }
            // A screenshot takes most of a second, so a diagnostic run that
            // wants "the pose at t" holds that frame instead of racing the
            // clock.
            if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_PAUSE_AT"],
               let seconds = Double(raw) {
                playback.seek(to: seconds)
            } else {
                playback.play()
            }
        } catch {
            loadError = "动作读不了：\(error.localizedDescription)"
        }
    }

    /// Play one action from the picker on the model that is already loaded.
    /// Attaching replaces whatever was running; the sway setup is re-read for
    /// the current outfit so the skirt keeps moving.
    private func playPose(_ clip: PoseClip) {
        guard let modelURL = loadedModelURL else { return }
        do {
            let dance = try JSONDecoder().decode(
                MotionDance.self, from: Data(contentsOf: clip.url)
            )
            guard playback.attach(
                dance: dance, to: container,
                sway: swayConfiguration(for: outfit, beside: modelURL)
            ) else {
                loadError = playback.status
                return
            }
            currentPose = clip.name
            playback.play()
        } catch {
            loadError = "动作读不了：\(error.localizedDescription)"
        }
    }

    private func motionURL(for selected: Model3DOutfit, beside url: URL) -> URL? {
        let exists = FileManager.default.fileExists(atPath:)
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_MOTION"] {
            let direct = URL(filePath: raw)
            if exists(direct.path) { return direct }
            let besideModel = url.deletingLastPathComponent().appending(path: raw)
            return exists(besideModel.path) ? besideModel : nil
        }
        let besideModel = url.deletingLastPathComponent()
            .appending(path: "\(selected.id).motion.json")
        return exists(besideModel.path) ? besideModel : nil
    }

    /// The spring sidecar `sway.py` generates for this model, if it was copied
    /// beside the USDZ. A missing or unreadable one is not fatal: the dance
    /// still plays, just with the skirt, ribbons and hair left rigid.
    private func swayConfiguration(
        for selected: Model3DOutfit, beside url: URL
    ) -> MotionSway.Configuration? {
        let exists = FileManager.default.fileExists(atPath:)
        let directory = url.deletingLastPathComponent()
        let candidates: [URL]
        if let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_SWAY"] {
            candidates = [URL(filePath: raw), directory.appending(path: raw)]
        } else {
            candidates = [directory.appending(path: "\(selected.id).sway.json")]
        }
        guard let path = candidates.first(where: { exists($0.path) }),
              let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(MotionSway.Configuration.self, from: data)
    }

    /// Parsing a multi-megabyte USDZ on the main actor froze the app when the
    /// user swapped outfits, so the decode runs off it.
    private nonisolated static func decode(_ url: URL) async throws -> Entity {
        try await Entity.load(contentsOf: url)
    }

    /// Fit once `visualBounds` has **converged**, not on a fixed timer.
    ///
    /// Two things did not work. A fixed 2-second median was still unstable: the
    /// same build opened with her head behind the Dynamic Island on one launch
    /// and clear of it on the next. Reading the meshes instead is exact for
    /// static geometry but wrong here — a skinned mesh reports its *bind* box,
    /// and stage costumes are authored with joint scales that leave the drawn
    /// figure anywhere from 1x to 2x that. The measurement that matters is the
    /// one RealityKit actually draws with.
    ///
    /// So sample `visualBounds` until the height stops moving: the settle is a
    /// decaying sequence, and six consecutive readings inside 2% is the point
    /// where it has stopped. Capped at ~4 seconds for a model that never
    /// settles at all, in which case the last reading is used.
    private func fitAfterSettle(_ entity: Entity, drawnCentreY: Float? = nil) async -> Bool {
        addLights(to: entity)
        var history: [SIMD3<Float>] = []
        for _ in 0..<50 {
            guard !Task.isCancelled else { return false }
            let extents = entity.visualBounds(relativeTo: nil).extents
            if extents.y > 0.000_001 {
                history.append(extents)
                let recent = history.suffix(6).map(\.y)
                if recent.count == 6,
                   let low = recent.min(), let high = recent.max(),
                   high - low < high * 0.02 {
                    break
                }
            }
            do { try await Task.sleep(for: .milliseconds(80)) } catch { return false }
        }
        guard let extents = history.last else { return false }
        return fit(entity, height: extents.y,
                   centre: entity.visualBounds(relativeTo: nil).center, extents: extents,
                   drawnCentreY: drawnCentreY)
    }

    /// The USDZ may come from any source; keep the camera useful regardless of its
    /// authored scale or origin. The fixed default camera is the preview framing;
    /// free orbit is intentionally not part of the parity surface.
    private func fit(
        _ entity: Entity, height: Float? = nil, centre sampled: SIMD3<Float>? = nil,
        extents known: SIMD3<Float>? = nil, drawnCentreY: Float? = nil
    ) -> Bool {
        let bounds = entity.visualBounds(relativeTo: nil)
        let extents = known ?? bounds.extents
        guard extents.x > 0.000_001,
              extents.z > 0.000_001
        else { return false }
        let extent = height ?? bounds.extents.y
        guard extent > 0.000_001 else { return false }
        if ProcessInfo.processInfo.environment["EIDOLON_3D_LOG_MATERIALS"] != nil {
            // `print` does not reach the simulator log, so the numbers a
            // framing problem needs go to a file next to the models instead.
            let line = "[frame] extents=\(extents) centre=\(sampled ?? bounds.center) "
                + "drawn=\(String(describing: drawnCentreY)) known=\(known != nil)\n"
            let url = URL.documentsDirectory.appending(path: "frame.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
        // World units of height the model should occupy. Calibrated against the
        // settled bounds: 2.3 rendered her at 38% of the viewport height, so 4.2
        // lands near 70% with the head clear of the status bar.
        // `EIDOLON_3D_FIT_ZOOM` pulls the camera back while inspecting: a pose
        // that throws a limb out of frame can only be judged when the whole
        // swept volume is visible.
        let zoom = Float(ProcessInfo.processInfo.environment["EIDOLON_3D_FIT_ZOOM"] ?? "") ?? 1
        let targetHeight: Float = 2.1 * zoom
        let scale = targetHeight / extent
        let centre = sampled ?? bounds.center
        let center = centre * scale
        // The skinned box is where the figure actually stands; `visualBounds`
        // can report the bind box instead, and that one can sit a whole body
        // height away when the root joint carries a translation.
        let centerY = (drawnCentreY ?? centre.y) * scale
        // Push the model away from the camera: the default RealityView camera
        // sits at the origin, so the content has to move into view. Putting the
        // drawn box's centre on that camera's look-at is the whole of the
        // framing: this used to add `extent * 0.62` as well, but `extent` is
        // measured *before* the fit scale is applied, so that "half a model
        // height" was nearly a whole body height in world units and parked her
        // against the top edge. Drag in move mode to shift her.
        //
        // The control bar covers the bottom ~18% of the view, so the stage she
        // is framed in is the area above it, whose centre sits 0.29 units above
        // the view's centre. The camera's look-at is also ~0.15 units above the
        // content origin, so the box has to rise by their sum to land there.
        // Both numbers come from a screenshot at this captured distance.
        basePosition = [-center.x, -centerY + 0.44, -center.z - 1.0]
        fittedPosition = basePosition
        appliedScale = scale
        baseScale = scale
        // The transform lives on the container (applyInspection) so the outline
        // pass, a sibling of the model, follows it. Setting it here as well would
        // apply the scale twice.
        return true
    }


    /// A ground reference drawn in the model's own space: a 10 cm grid plus the
    /// three axes, so a pose can be read against real coordinates.
    ///
    /// It is parented to the container, so fitting, panning and yaw all carry it
    /// along, and it is rebuilt per outfit from that outfit's own floor height —
    /// the exported origin is not always under the feet. Unlit materials keep it
    /// out of the toon lighting, and the grid is geometry rather than a texture
    /// so it needs no asset and stays crisp at any zoom.
    private func addGround(to container: Entity, floorY: Float) {
        if ProcessInfo.processInfo.environment["EIDOLON_3D_NO_GROUND"] != nil { return }
        let ground = Entity()
        ground.name = "ground"
        let extent: Float = 0.8
        let step: Float = 0.1
        let minor = UIColor(white: 1, alpha: 0.08)
        let major = UIColor(white: 1, alpha: 0.20)

        func line(_ from: SIMD3<Float>, _ to: SIMD3<Float>, _ color: UIColor, _ width: Float) {
            let delta = to - from
            let length = simd_length(delta)
            guard length > 0.0001 else { return }
            let box = MeshResource.generateBox(width: width, height: width, depth: length)
            let entity = ModelEntity(mesh: box, materials: [UnlitMaterial(color: color)])
            entity.position = (from + to) / 2
            entity.orientation = simd_quatf(from: SIMD3(0, 0, 1), to: simd_normalize(delta))
            ground.addChild(entity)
        }

        // The grid lies in the model's XZ plane; the exported rig is Y-up and
        // `floorY` is where the bounds sidecar says the figure actually stands.
        let y = floorY
        var offset = -extent
        while offset <= extent + 0.0001 {
            let isMajor = abs(offset.rounded() - offset) < 0.0001
            let color = isMajor ? major : minor
            line(SIMD3(-extent, y, offset), SIMD3(extent, y, offset), color, 0.0025)
            line(SIMD3(offset, y, -extent), SIMD3(offset, y, extent), color, 0.0025)
            offset += step
        }

        // Axes: +X red, +Y green, +Z blue, half a body long.
        let origin = SIMD3<Float>(0, y, 0)
        let arm: Float = 0.4
        line(origin, origin + SIMD3(arm, 0, 0), UIColor(red: 0.95, green: 0.25, blue: 0.25, alpha: 0.95), 0.006)
        line(origin, origin + SIMD3(0, arm, 0), UIColor(red: 0.3, green: 0.9, blue: 0.35, alpha: 0.95), 0.006)
        line(origin, origin + SIMD3(0, 0, arm), UIColor(red: 0.3, green: 0.5, blue: 0.95, alpha: 0.95), 0.006)

        container.addChild(ground)
    }

    /// Key plus fill plus rim. RealityKit's lit model runs on top of the surface
    /// shader's output, so these are what set the preview's overall exposure;
    /// the game's own ramp supplies the two tones.
    private func addLights(to entity: Entity) {
        if ProcessInfo.processInfo.environment["EIDOLON_3D_NO_LIGHTS"] != nil { return }
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

/// `<stem>-bounds.json`: the box the skeleton draws, written by
/// `spikes/porting-3d/skinned_bounds.py`. Only the Y centre is used — that is
/// the axis RealityKit's bind box gets wrong — but the file carries all three
/// so a future framing change does not need a re-export.
private struct BoundsSidecar: Decodable {
    let min: [Float]
    let max: [Float]
}


// MARK: - Action catalogue

/// One action file on disk, as the picker lists it.
struct PoseClip: Identifiable, Hashable {
    enum Category: String, CaseIterable, Identifiable {
        case standby = "待机"
        case theatre = "剧场"
        case commu = "剧情"
        case photo = "照相"
        case login = "登录"
        case other = "其他"

        var id: String { rawValue }
    }

    /// Clip name, e.g. `the_stdcac_coach_lop_102mis`.
    let name: String
    let url: URL
    let seconds: Double
    let bones: Int

    var id: String { name }

    /// Which shelf the clip belongs on. The prefixes are the game's own:
    /// `the_` theatre (the standby loops carry `standd`/`stdcac`), `com_` commu,
    /// `pho_` photo studio, `lgn_` login.
    static func category(of name: String) -> Category {
        if name.hasPrefix("pho_") { return .photo }
        if name.hasPrefix("lgn_") { return .login }
        if name.hasPrefix("com_") { return .commu }
        if name.hasPrefix("the_") {
            return name.contains("standd") || name.contains("stdcac") ? .standby : .theatre
        }
        return .other
    }

    var category: Category { Self.category(of: name) }
}

/// Reads what is on disk: the exported `library.json` when present, otherwise
/// the pose folder itself. Everything is name-sorted so the list is stable.
enum PoseCatalog {
    private struct Library: Decodable {
        struct Entry: Decodable {
            let clip: String
            let file: String
            let seconds: Double?
            let bones: Int?
        }
        let poses: [Entry]
    }

    static func load(documents: URL) -> [PoseClip] {
        let poses = documents.appending(path: "poses")
        let library = documents.appending(path: "library.json")
        if let data = try? Data(contentsOf: library),
           let decoded = try? JSONDecoder().decode(Library.self, from: data) {
            let clips = decoded.poses.map { entry in
                PoseClip(
                    name: entry.clip,
                    url: poses.appending(path: entry.file),
                    seconds: entry.seconds ?? 0,
                    bones: entry.bones ?? 0
                )
            }
            if !clips.isEmpty { return clips.sorted { $0.name < $1.name } }
        }
        return scan(poses)
    }

    static func scan(_ directory: URL) -> [PoseClip] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".motion.json") }
            .map { name in
                PoseClip(
                    name: String(name.dropLast(".motion.json".count)),
                    url: directory.appending(path: name),
                    seconds: 0,
                    bones: 0
                )
            }
            .sorted { $0.name < $1.name }
    }
}

/// The action picker: sections per shelf, searchable by name.
struct PosePickerView: View {
    let clips: [PoseClip]
    let choose: (PoseClip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [PoseClip] {
        guard !query.isEmpty else { return clips }
        return clips.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(PoseClip.Category.allCases) { category in
                    let items = filtered.filter { $0.category == category }
                    if !items.isEmpty {
                        Section("\(category.rawValue)（\(items.count)）") {
                            ForEach(items) { clip in
                                Button {
                                    choose(clip)
                                    dismiss()
                                } label: {
                                    HStack {
                                        Text(clip.name)
                                            .lineLimit(1)
                                        Spacer()
                                        if clip.seconds > 0 {
                                            Text(String(format: "%.1fs", clip.seconds))
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "按名字过滤")
            .navigationTitle("动作（\(clips.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
