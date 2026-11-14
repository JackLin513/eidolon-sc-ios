import Foundation
import simd

/// One joint's local transform in the app's right-handed space, kept free of
/// RealityKit so the playback maths is a plain value type under test.
struct JointPose: Equatable {
    /// Local translation relative to the parent joint.
    var translation: SIMD3<Float>
    /// Rotation as `(x, y, z, w)`, the same layout `UnityEuler` returns.
    var rotation: SIMD4<Float>
    var scale: SIMD3<Float>

    static let identity = JointPose(
        translation: .zero, rotation: SIMD4(0, 0, 0, 1), scale: .one
    )
}

/// The exported model lives in glTF's right-handed frame; the game's curves are
/// authored in Unity's left-handed one. `gltf_export.flip_quaternion` maps
/// between them by conjugating with `diag(1, 1, -1)`, which for a quaternion
/// means negating x and y and keeping z, and for a point means negating z.
/// Playback has to apply the same mirror, or every joint bends the wrong way.
enum UnityHandedness {
    static func rotation(_ degrees: SIMD3<Float>) -> SIMD4<Float> {
        let q = UnityEuler.quaternion(degrees)
        return SIMD4(-q.x, -q.y, q.z, q.w)
    }

    static func translation(_ position: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(position.x, position.y, -position.z)
    }

    /// The extra turn between the game's frame and the one RealityKit uses as
    /// a skeleton root joint's parent.
    ///
    /// `rest.json` dumps RealityKit's own rest pose, and for the two root
    /// joints it disagrees with the game: `MUNE1` comes back at
    /// `(0, 0, 0.147)` where the dance's own chain has `(0, 0.147, 0)`, and its
    /// rest rotation is the game's `BASE` rotation turned a further +90° about
    /// X. That is the Y-up to Z-up turn the USDZ pipeline makes at the model
    /// root; child joints are unaffected because both they and their parents
    /// went through it. So a root joint's local rotation needs this left
    /// factor, and only a root joint's.
    static let rootFrame = SIMD4<Float>(0.70710678, 0, 0, 0.70710678)

    /// Rotation `a` followed by `b`, both `(x, y, z, w)`.
    static func multiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        QuaternionMath.multiply(a, b)
    }
}

/// Quaternion arithmetic in the app's right-handed frame, with Unity's operand
/// order: `multiply(a, b)` applies `b` first, then `a`.
enum QuaternionMath {
    static func multiply(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(
            a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
        )
    }

    static func inverse(_ q: SIMD4<Float>) -> SIMD4<Float> {
        SIMD4(-q.x, -q.y, -q.z, q.w)
    }

    /// Rotate `v` by the unit quaternion `q` (`q v q*`).
    static func rotate(_ q: SIMD4<Float>, _ v: SIMD3<Float>) -> SIMD3<Float> {
        let axis = SIMD3(q.x, q.y, q.z)
        let twice = 2 * simd_cross(axis, v)
        return v + q.w * twice + simd_cross(axis, twice)
    }

    static func dot(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
        simd_dot(a, b)
    }

    /// Shortest-path spherical interpolation, the same result as Unity's
    /// `Quaternion.Slerp` up to sign.
    static func slerp(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        var end = b
        var cosine = dot(a, end)
        if cosine < 0 {
            end = -end
            cosine = -cosine
        }
        if cosine > 0.9995 {
            return simd_normalize(a + (end - a) * t)
        }
        let angle = acos(min(cosine, 1))
        let sine = sin(angle)
        let start = sin((1 - t) * angle) / sine
        let finish = sin(t * angle) / sine
        return start * a + finish * end
    }

    /// The shortest turn that takes unit vector `from` onto `to`.
    static func fromToRotation(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> SIMD4<Float> {
        let a = simd_normalize(from)
        let b = simd_normalize(to)
        let cosine = simd_dot(a, b)
        if cosine < -0.999999 {
            // Antiparallel: any perpendicular axis gives a half turn.
            let fallback: SIMD3<Float> = abs(a.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            let axis = simd_normalize(simd_cross(a, fallback))
            return SIMD4(axis.x, axis.y, axis.z, 0)
        }
        let axis = simd_cross(a, b)
        return simd_normalize(SIMD4(axis.x, axis.y, axis.z, 1 + cosine))
    }
}


/// Parent-space poses to world, walking the parent links derived from the joint
/// names. Joint scales are 1 on this rig, so only rotation and translation
/// compose.
enum JointWorld {
    static func transforms(
        _ poses: [JointPose], parents: [Int?]
    ) -> [(position: SIMD3<Float>, rotation: SIMD4<Float>)] {
        var world = [(position: SIMD3<Float>, rotation: SIMD4<Float>)](
            repeating: (.zero, SIMD4(0, 0, 0, 1)), count: poses.count
        )
        var built = [Bool](repeating: false, count: poses.count)
        func build(_ joint: Int) {
            guard !built[joint] else { return }
            let local = poses[joint]
            if let parent = parents[joint] {
                build(parent)
                world[joint].rotation = QuaternionMath.multiply(
                    world[parent].rotation, local.rotation
                )
                world[joint].position = world[parent].position
                    + QuaternionMath.rotate(world[parent].rotation, local.translation)
            } else {
                world[joint] = (local.translation, local.rotation)
            }
            built[joint] = true
        }
        for joint in poses.indices { build(joint) }
        return world
    }
}


/// Turns a decoded dance into a full joint pose for any frame.
///
/// Channels are expanded once up front: a running sum per lookup would cost
/// a few hundred thousand additions per rendered frame, and the expanded form
/// of a whole dance is only a few megabytes.
struct MotionSampler {
    /// One bone's animation after resolution and unit conversion.
    private struct Track {
        let joint: Int
        /// Whether this joint hangs off the model space instead of a parent
        /// joint, and so needs the frame change in `pose(atFrame:)`.
        let isRoot: Bool
        /// Euler degrees per frame, still in Unity space.
        let rotation: [SIMD3<Float>]?
        /// Unity units per frame, still in Unity space.
        let translation: [SIMD3<Float>]?
    }

    /// The model-space `BASE` node, which sits above the whole skeleton and is
    /// not a joint, so it never binds. Its curves are nevertheless most of a
    /// dance's whole-body motion: in `014mir-ss002` the hip yaw and lean all
    /// live here, while the pelvis `KOSHI` is a skeleton root whose own curve is
    /// a constant. The skirt therefore cannot swing until the roots move.
    ///
    /// The exported rest pose already has `BASE` folded in at frame 0. Measured
    /// on that dance: rest is 0.0° from `rootFrame · mirror(KOSHI at frame 0)`
    /// and 87° from `rootFrame · mirror(BASE · KOSHI at frame 0)`. So the dance
    /// has to reach the roots as a delta from frame 0, not as an absolute turn,
    /// or the body would face 87° the wrong way on the first frame.
    /// How far `BASE`'s translation may lift the figure before it is treated
    /// as stage placement and clipped. Dance bobs sit well under this (the
    /// corpus median is 9 mm, the 90th percentile 150 mm).
    static let maxRootLift: Float = 0.5

    private struct BaseMotion {
        /// `BASE`'s rotation per frame, mirrored into app space.
        let rotations: [SIMD4<Float>]
        /// `BASE`'s translation per frame, mirrored into app space.
        let translations: [SIMD3<Float>]?
    }

    let dance: MotionDance
    let map: MotionJointMap
    /// The pose a joint keeps when the dance says nothing about it.
    private let rest: [JointPose]
    private let tracks: [Track]
    private let base: BaseMotion?
    /// The game's calc-bone pass over the rig's assist bones, empty when the
    /// caller did not pass the joint names.
    private let assist: MotionAssist

    init(dance: MotionDance, map: MotionJointMap, rest: [JointPose], joints: [String] = []) {
        self.dance = dance
        self.map = map
        self.rest = rest
        self.assist = MotionAssist(joints: joints, rest: rest)
        self.tracks = map.bindings.map { binding in
            let bone = dance.bones[binding.bone]
            return Track(
                joint: binding.joint,
                isRoot: map.roots.contains(binding.joint),
                rotation: Self.euler(bone, dance: dance),
                translation: Self.position(bone, dance: dance)
            )
        }
        let baseBone = dance.bones.first { $0.path.split(separator: "/").last == "BASE" }
        if let baseBone, let rotations = Self.euler(baseBone, dance: dance) {
            self.base = BaseMotion(
                rotations: rotations.map(UnityHandedness.rotation),
                translations: Self.position(baseBone, dance: dance)?
                    .map(UnityHandedness.translation)
            )
        } else {
            self.base = nil
        }
    }

    var jointCount: Int { rest.count }

    /// How many assist bones the calc-bone pass drives, for the status line.
    var assistCount: Int { assist.count }

    /// Whether the dance's model-space `BASE` track reaches the skeleton roots.
    var hasRootMotion: Bool { base != nil }

    /// Every joint's local transform at `frame`, in `rest` order.
    func pose(atFrame frame: Int) -> [JointPose] {
        var poses = rest
        for track in tracks {
            let index = min(max(frame, 0), dance.frames - 1)
            var pose = poses[track.joint]
            if let rotation = track.rotation {
                let mirrored = UnityHandedness.rotation(rotation[index])
                pose.rotation = track.isRoot
                    ? UnityHandedness.multiply(UnityHandedness.rootFrame, mirrored)
                    : mirrored
            }
            if let translation = track.translation {
                pose.translation = UnityHandedness.translation(translation[index])
            }
            poses[track.joint] = pose
        }
        assist.apply(&poses)
        if let base {
            // After the tracks and the calc-bone pass: `BASE` sits above the
            // whole skeleton, so its turn has to land on top of everything the
            // joints decided for themselves.
            apply(base, frame: min(max(frame, 0), dance.frames - 1), to: &poses)
        }
        return poses
    }

    /// Turn and lift every skeleton root by what `BASE` has done since frame 0.
    ///
    /// `BASE`'s curves are expressed in its own parent's space, which for the
    /// model root is Unity's world. The roots live in the model space the USDZ
    /// was exported in, so the delta has to cross the same frame a root's own
    /// rotation does: `RF · mirror(Δ) · RF⁻¹`. Translating the roots likewise
    /// uses the point form of that frame, which turns a Unity Y bob into +Z.
    ///
    /// The rest translation of a root is its offset from `BASE`'s origin, so
    /// strictly the delta should also rotate that offset; at 0.147 units it
    /// moves the figure by at most a hand's width and is left out, which keeps
    /// her dancing in place instead of orbiting the model root.
    private func apply(_ base: BaseMotion, frame: Int, to poses: inout [JointPose]) {
        let delta = QuaternionMath.multiply(
            base.rotations[frame], QuaternionMath.inverse(base.rotations[0])
        )
        let world = QuaternionMath.multiply(
            QuaternionMath.multiply(UnityHandedness.rootFrame, delta),
            QuaternionMath.inverse(UnityHandedness.rootFrame)
        )
        // `BASE`'s translation is stage placement, not body motion: the `com_*`
        // story clips move it by up to 4.7 units so the character stands where
        // the cut needs her. Nothing else is staged — across the 2,919 clips in
        // the corpus the horizontal channels never move at all — so a lift past
        // a hand's width is scenery, and letting it through floated the model
        // metres above the preview floor.
        let translation = base.translations.map { value -> SIMD3<Float> in
            var delta = QuaternionMath.rotate(
                UnityHandedness.rootFrame, UnityHandedness.translation(value[frame] - value[0])
            )
            delta.z = min(max(delta.z, -Self.maxRootLift), Self.maxRootLift)
            return delta
        }
        for root in map.roots {
            // The BASE delta is a rigid turn of the whole model about its
            // origin. Rotating the root's orientation alone leaves each root
            // chain pivoting in place — the skeleton has several independently
            // rooted chains (KOSHI, MUNE1, …), so the body tore apart at the
            // seams instead of turning.
            poses[root].translation = QuaternionMath.rotate(world, poses[root].translation)
            poses[root].rotation = QuaternionMath.multiply(world, poses[root].rotation)
            if let translation {
                poses[root].translation += translation
            }
        }
    }

    func pose(at time: Double) -> [JointPose] {
        pose(atFrame: dance.frame(at: time))
    }

    private static func euler(_ bone: MotionDance.Bone, dance: MotionDance) -> [SIMD3<Float>]? {
        guard bone.rot.count == 3 else { return nil }
        let channels = bone.rot.map { $0.expanded(frames: dance.frames) }
        let scale = dance.angleScale
        return (0..<dance.frames).map { frame in
            SIMD3(
                Float(channels[0][frame]) / scale,
                Float(channels[1][frame]) / scale,
                Float(channels[2][frame]) / scale
            )
        }
    }

    private static func position(_ bone: MotionDance.Bone, dance: MotionDance) -> [SIMD3<Float>]? {
        guard let pos = bone.pos, pos.count == 3 else { return nil }
        let channels = pos.map { $0.expanded(frames: dance.frames) }
        let scale = dance.positionScale
        return (0..<dance.frames).map { frame in
            SIMD3(
                Float(channels[0][frame]) / scale,
                Float(channels[1][frame]) / scale,
                Float(channels[2][frame]) / scale
            )
        }
    }
}
