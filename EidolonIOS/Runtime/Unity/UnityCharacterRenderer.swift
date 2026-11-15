#if canImport(UnityFramework)
import EidolonCore
import Foundation
import os
import UIKit

/// The 3D adapter (ADR-0034/0035): one surface's `CharacterRenderer` backed by the single
/// embedded Unity player. It never invents Spine animation names; it maps the semantic
/// frame to the Unity scene's own messages and reports the measured capabilities.
@MainActor
final class UnityCharacterRenderer: CharacterRenderer {
    private static let log = Logger(subsystem: "com.jacklin.eidolon", category: "stand3d")

    let runtimeID = RuntimeID.unityUaaL
    let view = UIView()

    var onReady: ((RuntimeReport) -> Void)?
    var onFailure: ((RuntimeFailure) -> Void)?

    /// The prototype scene's framing until a package declares its own bounds.
    private static let defaultBounds = StandBounds(
        x: -0.35, y: 0, width: 0.7, height: 1.62
    )

    private var assets: RuntimeAssets
    private let container = UIView()
    private var unityView: UIView?
    private var frame: PresentationFrame?
    private var loaded = false
    private var failed: RuntimeFailure?
    private var retry: Timer?
    private var retries = 0
    private var paused = false
    private var catalog: MotionCatalog?
    private var lastEmotion: StandEmotion?
    private var lastFraming: StandFraming?
    private var actionCycle: Timer?

    /// The story theatre drives the body pose from the scene script and must not have
    /// an emotion change also fire a daily action on top of it.
    var performsEmotionActions = true

    init(assets: RuntimeAssets) {
        self.assets = assets
        container.backgroundColor = .clear
        container.isUserInteractionEnabled = false
        view.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        UnityRuntime.shared.onEvent = { [weak self] json in
            self?.handle(event: json)
        }
    }

    deinit {
        retry?.invalidate()
        actionCycle?.invalidate()
    }

    func prepare(_ assets: RuntimeAssets) {
        self.assets = assets
        guard assets.model3D != nil else {
            fail(.contentMissing("没有 model3d 角色映射"))
            return
        }
        guard let unityView = UnityRuntime.shared.start() else {
            fail(.unavailable("Unity 运行时没有加载"))
            return
        }
        embed(unityView)
        loadMotionCatalog()
        sendLoad()
        scheduleRetry()
    }

    func load(_ outfit: StandOutfit) {
        // The model package already declares its outfits; the page's StandOutfit id is
        // used only when the 3D renderer is asked to switch.
        if loaded { sendLoad(outfitID: outfit.id) }
    }

    func present(_ frame: PresentationFrame) {
        self.frame = frame
        guard loaded else { return }
        apply(frame)
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        UnityRuntime.shared.setPaused(paused)
        container.isHidden = paused
    }

    /// Play one daily action from the package's catalog (`act/swt/yes/noo/str/lop/end`).
    /// The Unity host cross-fades one-shot clips over the idle loop; unknown names are
    /// dropped there, so a catalog entry the bundle does not carry degrades to idle.
    func playAction(_ action: String) {
        guard loaded else { return }
        Self.log.info("3D action: \(action, privacy: .public)")
        UnityRuntime.shared.send("PlayAction", action)
    }

    /// Development aid: `EIDOLON_3D_ACTIONS=act,yes,lop` plays the listed actions in a
    /// loop once the character has loaded, so a screenshot run can prove the clips
    /// actually differ without driving a conversation.
    private func startActionCycleForDebuggingIfRequested() {
        guard actionCycle == nil,
              let raw = ProcessInfo.processInfo.environment["EIDOLON_3D_ACTIONS"],
              !raw.isEmpty
        else { return }
        let actions = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !actions.isEmpty else { return }
        var index = 0
        actionCycle = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.loaded else {
                    timer.invalidate()
                    return
                }
                self.playAction(actions[index % actions.count])
                index += 1
            }
        }
    }

    /// Switch the body to a story pose clip. The path is absolute (story package and
    /// character bundle can live in different roots).
    ///
    /// The host mirrors the game's own pose state machine (`AnimCtrl_Commu`): the
    /// previous pose plays its `_end` clip, the new pose plays `_start` then settles
    /// into `_loop`. `loopDirect` (the ADV pose type flag) skips `_start`.
    /// <param name="enter">Authored walk-in clip: `str` (normal `_start`), `swt`
    /// (switch poses such as `a16_p17`) or `act` (private one-shot actions).</param>
    func playPose(atPath path: String, loopDirect: Bool = false, enter: String? = nil) {
        guard loaded else { return }
        let kind = enter ?? "str"
        Self.log.info("3D pose: \(path, privacy: .public) loopDirect=\(loopDirect, privacy: .public) enter=\(kind, privacy: .public)")
        UnityRuntime.shared.send("PlayPose", "\(path)|\(loopDirect ? 1 : 0)|\(kind)")
    }

    /// Stand in the game's own neutral `p01` idle clip (`com_cut_01z_lop`) instead of
    /// the character's daily action loop. Passed in by the story theatre once the
    /// character is loaded.
    func setIdleClip(atPath path: String) {
        guard loaded else { return }
        Self.log.info("3D idle clip: \(path, privacy: .public)")
        UnityRuntime.shared.send("SetIdleClip", path)
    }

    /// Leave the current story pose (plays its `_end` clip) and return to the idle.
    func resetPose() {
        guard loaded else { return }
        UnityRuntime.shared.send("ResetPose", "")
    }

    /// Story `actor_facial`: the script names the native facialMenu row (0..27), so the
    /// authored expression goes straight to Unity instead of the seven-mood table.
    func setFacialMenu(_ index: Int) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetFacialMenu", String(max(0, min(27, index))))
    }

    /// Story theatre speaks without touching the authored facial row, so the
    /// `actor_facial` expression set for this line is not reset at the line start.
    func setSpeaking(_ speaking: Bool) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetSpeaking", speaking ? "1" : "0")
    }

    /// Story `actor_yes_no`: the current pose's own nod/shake clip when it ships one.
    func setNod(yes: Bool) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetNod", yes ? "yes" : "noo")
    }

    /// Back to the neutral facial row (native row 0) after the story ends.
    func resetExpression() {
        guard loaded else { return }
        UnityRuntime.shared.send("SetEmotion", "0,0")
    }

    /// Story `actor_cheek` overlay: 0 off, 1 light, 2 strong.
    func setCheek(_ level: Int) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetCheek", String(max(0, min(2, level))))
    }

    /// Story `actor_eye_direction`: the script's gaze rate (-100…100 on each axis).
    func setGaze(h: Int, v: Int) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetGaze", "\(max(-100, min(100, h))),\(max(-100, min(100, v)))")
    }

    /// Story `actor_eye_blink`: the script's own eye mode — `close`, `open` or
    /// `blink`. Mirrors CharacterActorBase.SetEyeMode(CharacterEyeMode).
    func setEyeMode(_ mode: String) {
        guard loaded else { return }
        guard mode == "close" || mode == "open" || mode == "blink" else { return }
        UnityRuntime.shared.send("SetEyeMode", mode)
    }

    /// Story line mouth envelope: the game's authored `fhout` samples (0..1 mouth
    /// opening) resampled to 30 fps. An empty list stops envelope playback.
    func setLipEnvelope(fps: Int, values: [Double]) {
        guard loaded else { return }
        guard !values.isEmpty else {
            UnityRuntime.shared.send("SetLipEnvelope", "")
            return
        }
        var message = "\(fps):"
        message.reserveCapacity(values.count * 5 + 4)
        for (index, value) in values.enumerated() {
            if index > 0 { message.append(",") }
            message.append(String(format: "%.2f", max(0, min(1, value))))
        }
        UnityRuntime.shared.send("SetLipEnvelope", message)
    }

    // MARK: - Scene staging (ADV actor commands)

    /// `actor_visible_character`: hide or show the loaded character.
    func setVisible(_ visible: Bool) {
        guard loaded else { return }
        Self.log.debug("3D visible: \(visible, privacy: .public)")
        UnityRuntime.shared.send("SetVisible", visible ? "1" : "0")
    }

    /// `actor_2d_bg`: the scene's ADV background image (nil hides it).
    func setBackground(fileURL: URL?) {
        guard loaded else { return }
        Self.log.debug("3D background: \(fileURL?.lastPathComponent ?? "-", privacy: .public)")
        UnityRuntime.shared.send("SetBackground", fileURL?.path ?? "")
    }

    /// `actor_set_rotation` / `actor_chara_dorotate` without animation.
    func setCharacterRotation(x: Double, y: Double, z: Double) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetCharacterRotation", String(format: "%.3f,%.3f,%.3f", x, y, z))
    }

    /// `actor_chara_dorotate`: animate the character rotation over the cut frames.
    func rotateCharacter(x: Double, y: Double, z: Double, durationMs: Int, ease: String) {
        guard loaded else { return }
        Self.log.debug("3D rotate: \(y, privacy: .public)deg over \(durationMs, privacy: .public)ms")
        UnityRuntime.shared.send(
            "RotateCharacter",
            String(format: "%.3f,%.3f,%.3f,%.3f,%@", x, y, z, Double(durationMs) / 1000, ease)
        )
    }

    /// `actor_set_position`: explicit stage offset in metres.
    func setCharacterOffset(x: Double, y: Double, z: Double) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetCharacterOffset", String(format: "%.3f,%.3f,%.3f", x, y, z))
    }

    /// `actor_reset_sway`: drop the accumulated sway state.
    func resetSway() {
        guard loaded else { return }
        UnityRuntime.shared.send("ResetSway", "1")
    }

    /// `actor_lip`: `Close` (mute) or `Fomalhout` (formal mouth).
    func setLipMode(_ mode: String) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetLipMode", mode)
    }

    /// `actor_camera_set_position_preset`: shot distance per ADV camera setup.
    func setCameraPreset(_ preset: String) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetCameraPreset", preset)
    }

    /// `actor_character_set_position_preset`: one stand means the character stays put.
    func setPlacePreset(_ preset: String) {
        guard loaded else { return }
        UnityRuntime.shared.send("SetPlacePreset", preset)
    }

    /// `actor_in_out`: walk in or out of the stage.
    func playInOut(name: String, speed: Double, durationMs: Int) {
        guard loaded else { return }
        UnityRuntime.shared.send("PlayInOut", String(format: "%@,%.3f,%d", name, speed, durationMs))
    }

    func setViewport(_ size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        unityView?.frame = container.bounds
    }

    // MARK: - Messages

    /// The package's `motions/catalog.json`: which daily actions each character ships,
    /// with the tag the action was authored for. Read once per loaded content root.
    private struct MotionCatalog: Decodable {
        struct Entry: Decodable {
            let id: String
            let tags: [String]?
        }
        struct Character: Decodable {
            let actions: [Entry]
        }
        let characters: [String: Character]

        func action(tagged tag: String, for character: String) -> String? {
            guard let actions = characters[character]?.actions else { return nil }
            return actions.first { $0.tags?.contains(tag) == true }?.id
        }
    }

    private func loadMotionCatalog() {
        guard catalog == nil, let root = assets.model3DRoot else { return }
        let url = root.appendingPathComponent("motions/catalog.json")
        guard let data = try? Data(contentsOf: url) else { return }
        catalog = try? JSONDecoder().decode(MotionCatalog.self, from: data)
    }

    /// The action a changed emotion should show, using the tags the catalog was built
    /// with (see `tools/fetch_unity3d_content.py`: idle/agree/disagree/surprise/relax/leave).
    /// Calm falls back to the idle loop, so a neutral turn never interrupts it.
    private func action(for emotion: StandEmotion) -> String? {
        let tag: String
        switch emotion {
        case .calm: return nil
        case .happy: tag = "agree"
        case .shy: tag = "relax"
        case .surprised, .thinking: tag = "surprise"
        case .sad, .angry: tag = "disagree"
        }
        guard let model = assets.model3D?.model,
              let action = catalog?.action(tagged: tag, for: model)
        else { return nil }
        return action
    }

    private func sendLoad(outfitID: String? = nil) {
        guard let character = assets.model3D else { return }
        let outfit = outfitID ?? character.outfits.first ?? ""
        guard let root = assets.model3DRoot else {
            fail(.contentMissing("没有 model3d 内容目录"))
            return
        }
        let object: [String: Any] = [
            "contentRoot": root.path,
            "character": character.model,
            "outfit": outfit,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8)
        else {
            fail(.loadFailed("3D 加载请求拼不出来"))
            return
        }
        UnityRuntime.shared.send("LoadCharacter", json)
    }

    private func scheduleRetry() {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                guard !self.loaded, self.failed == nil else {
                    timer.invalidate()
                    return
                }
                self.retries += 1
                // S1: one retry, then give up and let the page fall back.
                if self.retries > 1 {
                    timer.invalidate()
                    self.fail(.loadFailed("Unity 场景没有回应"))
                    return
                }
                self.sendLoad()
            }
        }
    }

    private func embed(_ unityView: UIView) {
        unityView.translatesAutoresizingMaskIntoConstraints = true
        unityView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        unityView.frame = container.bounds
        unityView.isUserInteractionEnabled = false
        unityView.isOpaque = false
        unityView.layer.isOpaque = false
        unityView.backgroundColor = .clear
        container.addSubview(unityView)
        self.unityView = unityView
    }

    private func handle(event json: String) {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        switch type {
        case "loaded":
            loaded = true
            // A new character reloads the scene camera to its own default framing.
            lastFraming = nil
            retry?.invalidate()
            Self.log.info("3D stand loaded: \(json, privacy: .public)")
            let bounds = assets.model3D?.bounds ?? Self.defaultBounds
            var resolved = RuntimeCapabilities.unity3D
            if let character = assets.model3D {
                let emotions = character.emotionMap.keys.compactMap(StandEmotion.init)
                if !emotions.isEmpty { resolved.expressions = Set(emotions) }
                resolved.outfitSwitch = !character.outfits.isEmpty
            }
            onReady?(RuntimeReport(resolved: resolved, bounds: bounds))
            if let frame { apply(frame) }
            startActionCycleForDebuggingIfRequested()
        case "failure":
            let reason = object["reason"] as? String ?? "unknown"
            Self.log.error("3D stand load failure: \(reason, privacy: .public)")
            if retries > 1 { fail(.loadFailed(reason)) }
        default:
            break
        }
    }

    private func apply(_ frame: PresentationFrame) {
        let emotions = StandEmotion.allCases
        let index = emotions.firstIndex(of: frame.emotion) ?? 0
        // The package owns the emotion → native face map. The fallback index keeps the
        // adapter usable with the prototype scene until its host accepts names.
        let nativeFace = assets.model3D?.nativeFace(for: frame.emotion)
        UnityRuntime.shared.send("SetEmotion", nativeFace ?? "\(index),0")
        UnityRuntime.shared.send("SetSpeaking", frame.speaking ? "1" : "0")
        if let nod = frame.nod {
            UnityRuntime.shared.send("SetNod", nod.kind == .no ? "no" : "yes")
        } else if performsEmotionActions, frame.emotion != lastEmotion, let action = action(for: frame.emotion) {
            // The judge changes her mood once per reply segment; only the change plays
            // an action, so a held emotion does not loop the clip.
            UnityRuntime.shared.send("PlayAction", action)
        }
        lastEmotion = frame.emotion
        // Re-framing recomputes the camera from the *current* animated bounds, so
        // sending it on every presentation pulses the camera whenever the pose changes
        // (the story theatre presents once per script event). The host keeps its
        // framing until told otherwise, so one message per actual change is enough.
        if lastFraming != frame.framing {
            lastFraming = frame.framing
            UnityRuntime.shared.send("SetFraming", frame.framing.rawValue)
        }
    }

    private func fail(_ failure: RuntimeFailure) {
        guard failed == nil else { return }
        failed = failure
        retry?.invalidate()
        onFailure?(failure)
    }
}
#endif
