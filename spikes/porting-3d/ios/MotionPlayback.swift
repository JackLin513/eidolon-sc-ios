import Foundation
import Observation
import QuartzCore
import RealityKit

/// Plays a decoded dance on a loaded model by writing joint transforms every
/// frame (issue #28).
///
/// `HasModel.jointTransforms` is the relative (parent-space) pose of each joint,
/// which is exactly what the game's curves hold once the handedness mirror is
/// applied, so no animation graph is involved: the sampler is evaluated at the
/// current time and the whole array is assigned.
@MainActor
@Observable
final class MotionPlayback {
    /// Whether the clock is running. Setting it through `play`/`pause`.
    private(set) var isPlaying = false
    /// Diagnostic line for `motion.log`, also the reason playback refused to
    /// start when the model had no skeleton.
    private(set) var status = ""
    var duration: Double = 0

    @ObservationIgnored private var sampler: MotionSampler?
    /// The spring for the bones the dance does not key; nil when the model has
    /// no sidecar, which leaves the skirt, ribbons and hair rigid.
    @ObservationIgnored private var sway: MotionSway?
    @ObservationIgnored private var restPose: [JointPose] = []
    @ObservationIgnored private var entities: [ModelEntity] = []
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var ticker: TickTarget?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var time: Double = 0

    /// Debug switch for the joint-space question: `rest` writes the skeleton's
    /// own pose back and holds it, so a screenshot says whether assigning
    /// `jointTransforms` alone disturbs the mesh.
    private static let mode = ProcessInfo.processInfo.environment["EIDOLON_3D_MOTION_MODE"]

    /// Probe inputs: in `probe` mode the skeleton stays at rest and only the
    /// named joint turns, so a screenshot says whether a joint's children
    /// follow it or the mesh tears off towards where they used to be.
    private static let probeJoint = ProcessInfo.processInfo.environment["EIDOLON_3D_PROBE_JOINT"]
    private static let probeDegrees = Float(
        ProcessInfo.processInfo.environment["EIDOLON_3D_PROBE_DEG"] ?? "60"
    ) ?? 60

    /// Write the pose actually applied to `Documents/pose.json` so the values
    /// the renderer sees can be compared with the offline model of the dance.
    private static let dumps = ProcessInfo.processInfo.environment["EIDOLON_3D_DUMP_POSE"] != nil

    // MARK: - Attaching

    /// Bind a dance to the skinned entities under `root`. Returns false when
    /// the model has no skeleton or no curve matched a joint.
    ///
    /// `configuration` is the model's sway sidecar. The dance never keys the
    /// skirt, ribbons or hair — the game moves those with runtime physics — so
    /// without it those bones keep their rest rotation.
    @discardableResult
    func attach(
        dance: MotionDance, to root: Entity, sway configuration: MotionSway.Configuration? = nil
    ) -> Bool {
        detach()
        let skinned = Self.skinnedEntities(in: root)
        guard let first = skinned.first, !first.jointNames.isEmpty else {
            status = "没有找到带骨骼的实体"
            return false
        }
        let names = first.jointNames
        let rest = first.jointTransforms.map(Self.pose(of:))
        restPose = rest
        let map = MotionJointMap.resolve(paths: dance.bones.map(\.path), joints: names)
        guard !map.bindings.isEmpty else {
            status = "曲线一条也没绑上（\(names.count) 根骨骼）"
            return false
        }
        sampler = MotionSampler(dance: dance, map: map, rest: rest, joints: names)
        sway = configuration.flatMap {
            MotionSway(configuration: $0, joints: names, rest: rest)
        }
        entities = skinned.filter { $0.jointNames == names }
        duration = dance.timeLength
        time = 0
        status = "骨骼 \(names.count)、绑定 \(map.bindings.count) 条、辅助骨 \(sampler?.assistCount ?? 0) 根、未绑 \(map.unmapped)"
        if configuration != nil {
            status += "、摆动 \(sway?.count ?? 0) 根"
        }
        apply()
        if ProcessInfo.processInfo.environment["EIDOLON_3D_LOG_MOTION"] != nil {
            Self.log(names: names, map: map, status: status, dance: dance, rest: rest)
        }
        return true
    }

    /// Drop the skeleton and stop the clock; the next `attach` owns it.
    func detach() {
        pause()
        sampler = nil
        sway = nil
        entities = []
        time = 0
        duration = 0
    }

    // MARK: - Transport

    func play() {
        guard sampler != nil, Self.mode == nil else { return }
        isPlaying = true
        startClock()
    }

    func pause() {
        isPlaying = false
        link?.invalidate()
        link = nil
        ticker = nil
        lastTimestamp = 0
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    /// Move the playhead, clamped into the dance, and show that frame.
    func seek(to seconds: Double) {
        guard let sampler else { return }
        time = min(max(seconds, 0), sampler.dance.timeLength)
        warmUpSway()
        apply()
    }

    // MARK: - Clock

    /// The spring is stateful, so a seeked frame would otherwise show the skirt
    /// wherever the last run left it. Replay the dance's own frames up to the
    /// new playhead at the dance's rate. Capped so a far seek stays instant;
    /// beyond the cap only the transient differs, not the hanging pose.
    private func warmUpSway() {
        guard var sway, let sampler else { return }
        sway.reset()
        let fps = sampler.dance.fps
        let last = min(sampler.dance.frame(at: time), 30 * fps)
        let step = 1 / Float(fps)
        for frame in 0...last {
            var poses = sampler.pose(atFrame: frame)
            sway.apply(&poses, dt: step)
        }
        self.sway = sway
    }

    private func startClock() {
        guard link == nil else { return }
        let ticker = TickTarget()
        ticker.playback = self
        let link = CADisplayLink(target: ticker, selector: #selector(TickTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.ticker = ticker
        self.link = link
        lastTimestamp = 0
    }

    fileprivate func advance(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard isPlaying, lastTimestamp > 0 else { return }
        let elapsed = link.timestamp - lastTimestamp
        time += elapsed
        if duration > 0 {
            time = time.truncatingRemainder(dividingBy: duration)
        }
        // A backgrounded app can report a whole second in one tick; handing
        // that to a stiff spring in a single step only makes it jump.
        apply(dt: Float(min(max(elapsed, 0), 1.0 / 15)))
    }

    /// Write the current frame onto every skinned entity. The outline pass is a
    /// clone of the model with its own copy of the skeleton, so it needs the
    /// same pose or it draws the old outfit on top of the new.
    ///
    /// `dt` advances the sway spring; the diagnostic modes stay rigid so their
    /// screenshots keep showing only what they probe.
    private func apply(dt: Float = 0) {
        guard let sampler else { return }
        var poses: [JointPose]
        switch Self.mode {
        case "rest":
            poses = restPose
        case "probe":
            poses = Self.probed(restPose, names: entities.first?.jointNames ?? [])
        case "zero":
            poses = restPose.map { JointPose(translation: $0.translation, rotation: .init(0, 0, 0, 1), scale: .one) }
        default:
            poses = sampler.pose(at: time)
            sway?.apply(&poses, dt: dt)
        }
        let transforms = poses.map(Self.transform(of:))
        for entity in entities {
            entity.jointTransforms = transforms
        }
        if Self.dumps {
            Self.dump(
                time: time, names: entities.first?.jointNames ?? [],
                transforms: transforms, readback: entities.first?.jointTransforms
            )
        }
    }

    /// The rest pose with one joint turned about its own Z, to see which parts
    /// of the mesh that joint owns.
    private static func probed(_ rest: [JointPose], names: [String]) -> [JointPose] {
        guard let name = probeJoint, let index = names.firstIndex(of: name) else { return rest }
        var poses = rest
        let half = probeDegrees * .pi / 180 / 2
        poses[index].rotation = SIMD4(0, 0, sin(half), cos(half))
        return poses
    }

    /// The applied pose beside what the entity reports back, so a mismatch
    /// between "what we wrote" and "where the joints ended up" is visible.
    private static func dump(
        time: Double, names: [String] = [], transforms: [Transform], readback: [Transform]?
    ) {
        func row(_ t: Transform) -> [String: Any] {
            [
                "t": [t.translation.x, t.translation.y, t.translation.z] as [Float],
                "r": [t.rotation.imag.x, t.rotation.imag.y, t.rotation.imag.z, t.rotation.real],
                "s": [t.scale.x, t.scale.y, t.scale.z] as [Float],
            ]
        }
        let payload: [String: Any] = [
            "time": time,
            "names": names,
            "written": transforms.map(row),
            "readback": (readback ?? []).map(row),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL.documentsDirectory.appending(path: "pose.json"))
    }

    // MARK: - Conversions

    private static func skinnedEntities(in root: Entity) -> [ModelEntity] {
        var found: [ModelEntity] = []
        func walk(_ entity: Entity) {
            if let model = entity as? ModelEntity, !model.jointNames.isEmpty {
                found.append(model)
            }
            for child in entity.children { walk(child) }
        }
        walk(root)
        return found
    }

    private static func pose(of transform: Transform) -> JointPose {
        let q = transform.rotation
        return JointPose(
            translation: transform.translation,
            rotation: SIMD4(q.imag.x, q.imag.y, q.imag.z, q.real),
            scale: transform.scale
        )
    }

    private static func transform(of pose: JointPose) -> Transform {
        Transform(
            scale: pose.scale,
            rotation: simd_quatf(
                ix: pose.rotation.x, iy: pose.rotation.y,
                iz: pose.rotation.z, r: pose.rotation.w
            ),
            translation: pose.translation
        )
    }

    // MARK: - Diagnostics

    /// `print` does not reach the simulator log, and the joint names RealityKit
    /// reports are what the mapping has to match, so they go to a file beside
    /// the models.
    private static func log(
        names: [String], map: MotionJointMap, status: String, dance: MotionDance,
        rest: [JointPose]
    ) {
        let lines = [
            status,
            "dance bones \(dance.bones.count), frames \(dance.frames) @ \(dance.fps) fps",
            "joints: \(names.joined(separator: " "))",
            "unmapped: \(map.unmapped.joined(separator: " "))",
        ].joined(separator: "\n") + "\n"
        let url = URL.documentsDirectory.appending(path: "motion.log")
        try? Data(lines.utf8).write(to: url)
        Self.logRest(names: names, transforms: rest.map(transform(of:)))
    }

    /// Whether `jointTransforms` is parent-relative or model-relative decides
    /// how a dance has to be written, and the only ground truth is what
    /// RealityKit reports for a known skeleton, so a debug run dumps it.
    private static func logRest(names: [String], transforms: [Transform]) {
        let rows = zip(names, transforms).map { name, t in
            [
                "name": name,
                "t": [t.translation.x, t.translation.y, t.translation.z] as [Float],
                "r": [t.rotation.imag.x, t.rotation.imag.y, t.rotation.imag.z, t.rotation.real],
                "s": [t.scale.x, t.scale.y, t.scale.z] as [Float],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        try? data.write(to: URL.documentsDirectory.appending(path: "rest.json"))
    }
}

/// `CADisplayLink` retains its target, and the playback owns the link, so the
/// target is a separate object holding the playback weakly.
private final class TickTarget: NSObject {
    weak var playback: MotionPlayback?

    @objc func step(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            playback?.advance(link)
        }
    }
}
