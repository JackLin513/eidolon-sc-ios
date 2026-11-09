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

    private let assets: RuntimeAssets
    private let container = UIView()
    private var unityView: UIView?
    private var frame: PresentationFrame?
    private var loaded = false
    private var failed: RuntimeFailure?
    private var retry: Timer?
    private var retries = 0
    private var paused = false

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
    }

    func prepare(_ assets: RuntimeAssets) {
        guard assets.model3D != nil else {
            fail(.contentMissing("没有 model3d 角色映射"))
            return
        }
        guard let unityView = UnityRuntime.shared.start() else {
            fail(.unavailable("Unity 运行时没有加载"))
            return
        }
        embed(unityView)
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

    func setViewport(_ size: CGSize) {
        container.frame = CGRect(origin: .zero, size: size)
        unityView?.frame = container.bounds
    }

    // MARK: - Messages

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
            retry?.invalidate()
            Self.log.info("3D stand loaded: \(json, privacy: .public)")
            let bounds = assets.model3D?.bounds
                ?? StandBounds(x: -0.35, y: 0, width: 0.7, height: 1.62)
            onReady?(RuntimeReport(resolved: .unity3D, bounds: bounds))
            if let frame { apply(frame) }
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
        UnityRuntime.shared.send("SetEmotion", "\(index),0")
        UnityRuntime.shared.send("SetSpeaking", frame.speaking ? "1" : "0")
        if let nod = frame.nod {
            UnityRuntime.shared.send("SetNod", nod.kind == .no ? "no" : "yes")
        }
        UnityRuntime.shared.send("SetFraming", frame.framing.rawValue)
    }

    private func fail(_ failure: RuntimeFailure) {
        guard failed == nil else { return }
        failed = failure
        retry?.invalidate()
        onFailure?(failure)
    }
}
#endif
