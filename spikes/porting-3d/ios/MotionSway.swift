import Foundation
import simd

/// The game's runtime spring for the bones its dances never key (issue #28).
///
/// The dance curves cover 57 bones and none of the skirt panels, ribbons or
/// hair chains; the game moves those with `Imas.BoneLib.SwayBone` in
/// `LateUpdate`. Without that pass the skirt hangs rigid while the hips swing,
/// which is exactly what the phone showed before this existed.
///
/// Each bone is a pendulum. Its rest direction comes from the parent's current
/// world rotation and a tail measured from the skin weights; a spring pulls the
/// simulated direction back towards that one, gravity pulls it down and drag
/// bleeds off the velocity. The bone is then turned so its rigid direction
/// points at the simulated one.
///
/// The simulation integrates a **unit direction in the parent's frame**, not a
/// world-space position. Skirt tails are 14–28 cm, while gravity's equilibrium
/// offset in a positional spring is `g/k = 0.375` world units — larger than the
/// whole tail. Integrating positions therefore made gravity win outright: every
/// panel snapped to world down within a frame and ignored the hips for the rest
/// of the dance. On the unit sphere the same constants make gravity an angular
/// pull of `atan(g/k)` (≈21° for the skirt), so panels keep the parent's
/// direction and swing against it.
///
/// State must stay in that frame. Carrying the tip as a world position and
/// rebuilding the direction from it against the *current* parent each frame
/// turns every root translation into an angular kick: the dance's bob and
/// weight shifts move the pelvis several centimetres per frame, and dividing
/// that by a 14 cm tail flings the panels tens of degrees off target. The
/// direction is therefore the state, seeded from the rest direction and never
/// re-derived from world position.
///
/// The spring constants are not the game's — its `SwayBone` values are not in
/// the shipped bundles — so they were tuned against offline renders of this
/// same dance rather than derived.
struct MotionSway {
    /// The sidecar `sway.py` writes beside a model.
    struct Configuration: Decodable {
        let format: String
        let families: [String: Spring]
        let bones: [Bone]
    }

    struct Spring: Decodable {
        let stiffness: Float
        let drag: Float
        let gravity: Float
    }

    struct Bone: Decodable {
        let name: String
        let family: String
        let tail: [Float]
    }

    static let format = "eidolon.sway/1"

    private struct Pendulum {
        let joint: Int
        let parent: Int?
        /// The mass point in the bone's own local axes, as exported.
        let tail: SIMD3<Float>
        let length: Float
        /// The bone's rest rotation. The dance never keys a sway bone, so this
        /// is the local rotation the rigid pose holds.
        let restRotation: SIMD4<Float>
        let spring: Spring
    }

    private static let substeps = 4

    private let pendulums: [Pendulum]
    private let parents: [Int?]
    /// The solver works in world space, where the rest skeleton's up is +Z —
    /// the root-frame turn the USDZ pipeline makes lands there — not the +Y
    /// the model's own bounds use. Derive it instead of hard-coding it.
    private let up: SIMD3<Float>

    private var directions: [SIMD3<Float>]
    private var velocities: [SIMD3<Float>]
    private var seeded: [Bool]

    var count: Int { pendulums.count }

    /// Bind the sidecar to a skeleton. Returns nil when the format is not ours
    /// or none of its bones exist in `joints`, so a sidecar from another model
    /// leaves the pose rigid instead of half-swaying it.
    init?(configuration: Configuration, joints: [String], rest: [JointPose]) {
        guard configuration.format == Self.format, joints.count == rest.count else {
            return nil
        }
        var byPath: [String: Int] = [:]
        for (index, name) in joints.enumerated() where byPath[name] == nil {
            byPath[name] = index
        }
        var parents = [Int?](repeating: nil, count: joints.count)
        for (index, name) in joints.enumerated() {
            if let cut = name.lastIndex(of: "/") {
                parents[index] = byPath[String(name[..<cut])]
            }
        }
        var depth = [Int](repeating: 0, count: joints.count)
        for index in joints.indices {
            var cursor = parents[index]
            while let parent = cursor {
                depth[index] += 1
                cursor = parents[parent]
            }
        }

        var pendulums: [Pendulum] = []
        for bone in configuration.bones {
            guard bone.tail.count == 3,
                  let joint = byPath[bone.name],
                  let spring = configuration.families[bone.family]
            else { continue }
            let tail = SIMD3(bone.tail[0], bone.tail[1], bone.tail[2])
            let length = simd_length(tail)
            guard length > 1e-5 else { continue }
            pendulums.append(Pendulum(
                joint: joint, parent: parents[joint], tail: tail, length: length,
                restRotation: rest[joint].rotation, spring: spring
            ))
        }
        guard !pendulums.isEmpty else { return nil }
        // Parent before child: a chain bone has to turn its child's world frame
        // before the child reads it.
        pendulums.sort { depth[$0.joint] < depth[$1.joint] }

        self.pendulums = pendulums
        self.parents = parents
        self.up = Self.upAxis(joints: joints, rest: rest, parents: parents)
        self.directions = Array(repeating: .zero, count: pendulums.count)
        self.velocities = Array(repeating: .zero, count: pendulums.count)
        self.seeded = Array(repeating: false, count: pendulums.count)
    }

    /// Advance the spring by `dt` and fold the result into `poses`. A zero `dt`
    /// only re-clamps the bones, which is what a held frame needs.
    mutating func apply(_ poses: inout [JointPose], dt: Float) {
        var world = JointWorld.transforms(poses, parents: parents)
        let step = max(dt, 0) / Float(Self.substeps)
        for (index, pendulum) in pendulums.enumerated() {
            let parent = pendulum.parent
            let base = parent.map { world[$0].position } ?? .zero
            let parentRotation = parent.map { world[$0].rotation }
                ?? SIMD4<Float>(0, 0, 0, 1)
            let rigid = QuaternionMath.multiply(parentRotation, pendulum.restRotation)
            let restDirection = QuaternionMath.rotate(rigid, pendulum.tail)
            let target = restDirection / pendulum.length
            if !seeded[index] {
                directions[index] = target
                velocities[index] = .zero
                seeded[index] = true
            }

            let spring = pendulum.spring
            var direction = directions[index]
            var velocity = velocities[index]
            for _ in 0..<Self.substeps {
                let acceleration = spring.stiffness * (target - direction)
                    - spring.drag * velocity
                    - spring.gravity * up
                velocity += acceleration * step
                direction = simd_normalize(direction + velocity * step)
                // Normalising moves the point back onto the sphere; project
                // the radial speed out too, or that correction becomes energy.
                velocity -= direction * simd_dot(velocity, direction)
            }
            directions[index] = direction
            velocities[index] = velocity

            let turned = QuaternionMath.multiply(
                QuaternionMath.fromToRotation(restDirection, direction), rigid
            )
            poses[pendulum.joint].rotation = parent.map {
                QuaternionMath.multiply(QuaternionMath.inverse(world[$0].rotation), turned)
            } ?? turned
            world[pendulum.joint] = (base, turned)
        }
    }

    /// Forget the simulated directions. Playback replays the dance from the top
    /// before showing a seek, so a held frame carries the sway playback would
    /// reach.
    mutating func reset() {
        seeded = Array(repeating: false, count: pendulums.count)
    }

    private static func upAxis(
        joints: [String], rest: [JointPose], parents: [Int?]
    ) -> SIMD3<Float> {
        let world = JointWorld.transforms(rest, parents: parents)
        var top: SIMD3<Float>?
        var bottom: SIMD3<Float>?
        for (index, name) in joints.enumerated() {
            let leaf = name.split(separator: "/").last.map(String.init) ?? name
            if leaf == "HAIR" { top = world[index].position }
            if leaf == "KOSHI" { bottom = world[index].position }
        }
        guard let top, let bottom else { return SIMD3(0, 0, 1) }
        let direction = top - bottom
        return simd_length(direction) > 1e-5
            ? simd_normalize(direction)
            : SIMD3(0, 0, 1)
    }
}
