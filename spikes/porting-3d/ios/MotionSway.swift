import Foundation
import simd

/// The game's runtime sway for the bones its dances never key (issue #28).
///
/// The dance curves cover 57 bones and none of the skirt panels, ribbons or
/// hair chains; the game moves those with `Imas.BoneLib.SwayBone` in a
/// `SwayManager.ExecuteUpdate` pass. Without it the skirt hangs rigid while the
/// hips swing.
///
/// This mirrors the game's V01 solver, decompiled from the shipped build:
///
/// * The state is the **tip position**, not a direction. `SwayMove` (RVA
///   0x1C6867C) seeds it from the rigid rest direction, carries it along with
///   the base (`MoveTipPos`, scaled by `follow`), then integrates a spring
///   towards the rest tip at `stiffnessForce`, `(tip − previousTip)` damped by
///   `(1 − dragForce)`, and gravity — all normalised to the game's 1/60 s step
///   (`ratio = dt · 60`: forces divided by `ratio²` and the step multiplied
///   back, so damping is frame-rate independent).
/// * `SwayHit` (0x1C68C3C) pushes the tip out of every collider the bone
///   lists — the thigh capsules and the hip sphere in `_sway.txt` — and keeps
///   the deepest push. A frame that was hit skips gravity the next frame, so a
///   leg does not press the panel straight back in.
/// * `CalcRotate` (0x1C69F04) clamps the tip's yaw/pitch to
///   `minYAngle…maxYAngle` / `minZAngle…maxZAngle` and, when it clamps,
///   recomputes the tip from the clamped angles instead of dropping the
///   rotation. That "penetrative" correction is why the game's panels never
///   rotate into the legs.
/// * `CalcSideLineDistance` / `CalcAntiFoldForce` keep neighbouring panels of
///   the same ring from folding through each other.
///
/// Units are the game's, taken straight from `<model>_sway.txt`: `stiffness`
/// 0.02, `drag` 0.6, `gravity` 0.0001 are per-60-Hz-frame quantities, not SI.
struct MotionSway {
    /// The sidecar `sway.py` writes beside a model.
    ///
    /// Version 2 carries what the game's own `_sway.txt` carries: a spring per
    /// bone in the game's numbers, the angle window the game clamps each panel
    /// to, and the colliders (thigh capsules, hip sphere) a panel is tested
    /// against. Version 1 is the hand-tuned form and is still accepted so an
    /// older export keeps working, it just has no limits and no collisions.
    struct Configuration: Decodable {
        let format: String
        let families: [String: Spring]?
        let bones: [Bone]
        let colliders: [Collider]?
    }

    struct Spring: Decodable {
        let stiffness: Float
        let drag: Float
        /// Downward pull along the solver's up axis, in the game's per-frame
        /// units. Version 1 carried a hand-tuned magnitude from a different
        /// scale; version 2 carries the game's own `gravity.y` magnitude.
        let gravity: Float
    }

    struct Bone: Decodable {
        let name: String
        let family: String
        let tail: [Float]
        /// Tip sphere radius the game collides with (`SwayBone.radius`).
        let radius: Float?
        /// Per-bone spring; falls back to the family's.
        let spring: Spring?
        /// How much of the base's movement the tip follows (0–1).
        let follow: Float?
        /// The game's `minYAngle`/`maxYAngle`/`minZAngle`/`maxZAngle`, degrees
        /// in the parent's frame. `nil` leaves the bone unclamped.
        let limit: Limit?
        /// Indices into `Configuration.colliders`.
        let colliders: [Int]?
        /// Another sway bone this one stays side-by-side with (`sideLink`).
        let sideLink: String?
        /// The game's `sideSpringForce`; 0 or absent turns the link off.
        let sideSpring: Float?
        let antiFold: AntiFold?
        /// `SwayBone.hitTwice`: a second `SwayHit` pass on the pushed tip.
        let hitTwice: Bool?
        /// `SwayBone.useLinkHit`: also collide with the side-linked bone's set.
        let useLinkHit: Bool?

        init(name: String, family: String, tail: [Float], radius: Float? = nil,
             spring: Spring? = nil, follow: Float? = nil, limit: Limit? = nil,
             colliders: [Int]? = nil, sideLink: String? = nil,
             sideSpring: Float? = nil, antiFold: AntiFold? = nil,
             hitTwice: Bool? = nil, useLinkHit: Bool? = nil) {
            self.name = name
            self.family = family
            self.tail = tail
            self.radius = radius
            self.spring = spring
            self.follow = follow
            self.limit = limit
            self.colliders = colliders
            self.sideLink = sideLink
            self.sideSpring = sideSpring
            self.antiFold = antiFold
            self.hitTwice = hitTwice
            self.useLinkHit = useLinkHit
        }
    }

    struct Limit: Decodable {
        let minY: Float
        let maxY: Float
        let minZ: Float
        let maxZ: Float
    }

    /// The game's `antiFoldForceK` / `antiFoldAngle`: once two neighbours fold
    /// closer than `angle` degrees, the pair is pushed apart with `force`.
    struct AntiFold: Decodable {
        let force: Float
        let angle: Float
    }

    /// A `SwayCollider` from the game's data: a sphere or capsule hung on a
    /// joint, in that joint's local space. `distance` is the capsule's full
    /// length along `axis`; `offset` moves its centre off the joint.
    struct Collider: Decodable {
        let joint: String
        let type: String
        let radius: Float
        let distance: Float
        let offset: [Float]
        let axis: String?
        /// Plane only: the plane's normal in the joint's local frame.
        let normal: [Float]?
        /// Bridge only: the joint at the far end of the capsule.
        let target: String?

        init(joint: String, type: String, radius: Float, distance: Float,
             offset: [Float], axis: String?,
             normal: [Float]? = nil, target: String? = nil) {
            self.joint = joint
            self.type = type
            self.radius = radius
            self.distance = distance
            self.offset = offset
            self.axis = axis
            self.normal = normal
            self.target = target
        }
    }

    static let format = "eidolon.sway/2"
    static let legacyFormat = "eidolon.sway/1"
    /// The game solves at a fixed 1/60 s (`SwayManager.FIXED_DELTA`).
    static let framesPerSecond: Float = 60
    /// How far outside a collider a panel is settled (metres).
    private static let surfaceMargin: Float = 0.001

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
        let radius: Float
        let follow: Float
        let limit: Limit?
        let colliders: [Int]
        let sideLinkPath: String?
        let sideSpring: Float
        let antiFold: AntiFold?
        /// The game's `hitTwice`: run `SwayHit` a second time on the pushed tip.
        let hitTwice: Bool
        /// The game's `useLinkHit`: also test the side-linked bone's colliders.
        let useLinkHit: Bool
    }

    private enum BoundKind { case sphere, capsule, plane, bridge }

    private struct Bounds {
        let kind: BoundKind
        let joint: Int
        let radius: Float
        let halfLength: Float
        let offset: SIMD3<Float>
        /// Local axis the capsule runs along; unused for spheres.
        let axis: SIMD3<Float>
        /// Plane only: the normal in the joint's local frame.
        let normal: SIMD3<Float>
        /// Bridge only: the joint at the far end of the capsule.
        let target: Int?
    }

    private let pendulums: [Pendulum]
    /// `sideLink` resolved to an index after the parent-before-child sort.
    private let sideLinks: [Int?]
    private let bounds: [Bounds]
    private let parents: [Int?]
    /// The solver works in world space, where the rest skeleton's up is +Z —
    /// the root-frame turn the USDZ pipeline makes lands there — not the +Y
    /// the model's own bounds use. Derive it instead of hard-coding it.
    private let up: SIMD3<Float>

    private var tips: [SIMD3<Float>]
    private var previousTips: [SIMD3<Float>]
    private var bases: [SIMD3<Float>]
    private var lastBases: [SIMD3<Float>]
    private var seeded: [Bool]
    /// Distance between a panel and its `sideLink`, remembered from the rest
    /// pose so the pair keeps its shape.
    private var sideLineRest: [Float]
    /// The `SwayHit` half of the game: a hit frame suppresses gravity next.
    private var hitLastFrame: [Bool]

    var count: Int { pendulums.count }

    /// Bind the sidecar to a skeleton. Returns nil when the format is not ours
    /// or none of its bones exist in `joints`, so a sidecar from another model
    /// leaves the pose rigid instead of half-swaying it.
    init?(configuration: Configuration, joints: [String], rest: [JointPose]) {
        guard configuration.format == Self.format
            || configuration.format == Self.legacyFormat,
            joints.count == rest.count
        else {
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

        var bounds: [Bounds] = []
        for entry in configuration.colliders ?? [] {
            guard entry.offset.count == 3,
                  let joint = byPath[entry.joint],
                  entry.radius > 0
            else { continue }
            var axis = SIMD3<Float>(1, 0, 0)
            switch entry.axis?.uppercased() {
            case "Y": axis = SIMD3(0, 1, 0)
            case "Z": axis = SIMD3(0, 0, 1)
            default: break
            }
            var normal = SIMD3<Float>(0, 0, 1)
            if let raw = entry.normal, raw.count == 3 {
                normal = SIMD3(raw[0], raw[1], raw[2])
                if simd_length(normal) > 1e-6 { normal = simd_normalize(normal) }
            }
            var target: Int?
            let kind: BoundKind
            switch entry.type.lowercased() {
            case "capsule": kind = .capsule
            case "plane":
                guard entry.normal?.count == 3 else { continue }
                kind = .plane
            case "bridge":
                guard let name = entry.target, let far = byPath[name] else { continue }
                target = far
                kind = .bridge
            default: kind = .sphere
            }
            bounds.append(Bounds(
                kind: kind, joint: joint, radius: entry.radius,
                halfLength: max(entry.distance, 0) / 2,
                offset: SIMD3(entry.offset[0], entry.offset[1], entry.offset[2]),
                axis: axis, normal: normal, target: target
            ))
        }

        var pendulums: [Pendulum] = []
        for bone in configuration.bones {
            guard bone.tail.count == 3,
                  let joint = byPath[bone.name],
                  let spring = bone.spring ?? configuration.families?[bone.family]
            else { continue }
            let tail = SIMD3(bone.tail[0], bone.tail[1], bone.tail[2])
            let length = simd_length(tail)
            guard length > 1e-5 else { continue }
            let colliders = (bone.colliders ?? []).filter { bounds.indices.contains($0) }
            pendulums.append(Pendulum(
                joint: joint, parent: parents[joint], tail: tail, length: length,
                restRotation: rest[joint].rotation, spring: spring,
                radius: max(bone.radius ?? 0, 0),
                follow: min(max(bone.follow ?? 1, 0), 1),
                limit: bone.limit, colliders: colliders,
                sideLinkPath: bone.sideLink, sideSpring: bone.sideSpring ?? 0,
                antiFold: bone.antiFold,
                hitTwice: bone.hitTwice ?? false,
                useLinkHit: bone.useLinkHit ?? false
            ))
        }
        guard !pendulums.isEmpty else { return nil }
        // Parent before child: a chain bone has to turn its child's world frame
        // before the child reads it.
        pendulums.sort { depth[$0.joint] < depth[$1.joint] }

        var indexByPath: [String: Int] = [:]
        for (index, pendulum) in pendulums.enumerated() {
            indexByPath[joints[pendulum.joint]] = index
        }
        let sideLinks = pendulums.map { pendulum in
            pendulum.sideLinkPath.flatMap { indexByPath[$0] }
        }

        self.pendulums = pendulums
        self.sideLinks = sideLinks
        self.bounds = bounds
        self.parents = parents
        self.up = Self.upAxis(joints: joints, rest: rest, parents: parents)
        self.tips = Array(repeating: .zero, count: pendulums.count)
        self.previousTips = Array(repeating: .zero, count: pendulums.count)
        self.bases = Array(repeating: .zero, count: pendulums.count)
        self.lastBases = Array(repeating: .zero, count: pendulums.count)
        self.seeded = Array(repeating: false, count: pendulums.count)
        self.sideLineRest = Array(repeating: 0, count: pendulums.count)
        self.hitLastFrame = Array(repeating: false, count: pendulums.count)
    }

    /// Advance the solver by `dt` and fold the result into `poses`. A zero `dt`
    /// only re-clamps and re-collides the bones, which is what a held frame
    /// needs.
    mutating func apply(_ poses: inout [JointPose], dt: Float) {
        var world = JointWorld.transforms(poses, parents: parents)
        let frames = max(dt, 0) * Self.framesPerSecond
        let square = max(frames * frames, 1e-6)

        for (index, pendulum) in pendulums.enumerated() {
            let parent = pendulum.parent
            let parentPosition = parent.map { world[$0].position } ?? .zero
            let parentRotation = parent.map { world[$0].rotation }
                ?? SIMD4<Float>(0, 0, 0, 1)
            // The bone turns about its own origin, which is not the parent's:
            // group nodes (`skirt_GP`, `ribbon_GP`, …) carry metre-sized
            // compensation offsets, so using the parent's position as the base
            // put the tip a whole unit away from the bone and turned the panel
            // into spaghetti.
            let base = parentPosition
                + QuaternionMath.rotate(parentRotation, poses[pendulum.joint].translation)
            let rigid = QuaternionMath.multiply(parentRotation, pendulum.restRotation)
            let restDirection = QuaternionMath.rotate(rigid, pendulum.tail)
            let aim = base + restDirection
            bases[index] = base

            if !seeded[index] {
                tips[index] = aim
                previousTips[index] = aim
                lastBases[index] = base
                seeded[index] = true
                if let link = sideLinks[index], seeded[link] {
                    sideLineRest[index] = simd_length(tips[link] - tips[index])
                }
            }

            if dt > 0 {
                // `MoveTipPos`: the tip rides along with the base.
                let travel = (base - lastBases[index]) * pendulum.follow
                tips[index] += travel
                previousTips[index] += travel

                // `SwayMove`'s force: spring towards the rest tip, damped
                // velocity, gravity, then the neighbour springs.
                let velocity = tips[index] - previousTips[index]
                var force = (aim - tips[index]) * pendulum.spring.stiffness
                    + velocity * (1 - pendulum.spring.drag) / square
                if !hitLastFrame[index] {
                    force -= up * pendulum.spring.gravity
                }
                if sideLineRest[index] == 0, let link = sideLinks[index],
                   seeded[link] {
                    sideLineRest[index] = simd_length(tips[link] - tips[index])
                }
                force += sideLineForce(for: index)
                force += antiFoldForce(for: index)

                let oldTip = tips[index]
                tips[index] += force * square
                previousTips[index] = oldTip
                lastBases[index] = base
            }

            hitLastFrame[index] = false
            // `SwayHit` then `CalcRotate`: a panel is only ever drawn at
            // `length` from its base, so a push out of a collider has to be
            // applied to the direction and re-normalised — pushing the free
            // tip and then rescaling it back to `length` would pull the panel
            // straight back into the thigh.
            // The game's order is `SwayMove` (spring) → `SwayHit` (collision
            // on the free tip) → `CalcRotate` (angle window). The window has to
            // come last: a collider push can leave the window, and clamping
            // before the push let hair strands be shoved 90 degrees out of a
            // ±20 degree window — the "hair floating" on the dance.
            var springDirection = tips[index] - base
            if simd_length(springDirection) < 1e-5 {
                springDirection = restDirection
            }
            springDirection = simd_normalize(springDirection)
            // Two thigh capsules can push against each other: a panel
            // between them gets opposite normals that cancel, so a plain
            // push does nothing (measured on the real dance: still 17 mm
            // inside). Relax the summed violation first, then, if the panel is
            // wedged, search the tangent circle around the current direction —
            // the escape there is a few degrees sideways (4° on this dance).
            // `CheckSideLine`: with `useLinkHit` on, the game tests the
            // segment between this tip and its `sideLink` neighbour as well —
            // a pair can straddle a leg with both tips still clear of it.
            var sideTip: SIMD3<Float>?
            var sideRadius: Float = 0
            if pendulum.useLinkHit, let link = sideLinks[index], seeded[link] {
                sideTip = tips[link]
                sideRadius = pendulums[link].radius
            }
            var resolved = resolvingCollisions(
                direction: springDirection, base: base, pendulum: pendulum,
                colliders: pendulum.colliders, sideTip: sideTip,
                sideRadius: sideRadius, world: world
            )
            // `SwayBoneMT`'s job calls `SwayHit` a second time when `hitTwice`
            // is set; the second pass starts from the tip the first one pushed
            // out and catches whatever lies behind it.
            if pendulum.hitTwice {
                let second = resolvingCollisions(
                    direction: resolved.direction, base: base, pendulum: pendulum,
                    colliders: pendulum.colliders, sideTip: sideTip,
                    sideRadius: sideRadius, world: world
                )
                resolved = (second.direction, resolved.hit || second.hit)
            }
            hitLastFrame[index] = resolved.hit
            tips[index] = base + resolved.direction * pendulum.length
            let direction = clampedDirection(
                of: tips[index], from: base, parentRotation: parentRotation,
                restDirection: restDirection, limit: pendulum.limit
            )

            let turned = QuaternionMath.multiply(
                QuaternionMath.fromToRotation(restDirection, direction),
                rigid
            )
            poses[pendulum.joint].rotation = parent.map {
                QuaternionMath.multiply(QuaternionMath.inverse(world[$0].rotation), turned)
            } ?? turned
            world[pendulum.joint] = (base, turned)
        }
    }

    /// Forget the simulated tips. Playback replays the dance from the top
    /// before showing a seek, so a held frame carries the sway playback would
    /// reach.
    mutating func reset() {
        seeded = Array(repeating: false, count: pendulums.count)
        hitLastFrame = Array(repeating: false, count: pendulums.count)
        sideLineRest = Array(repeating: 0, count: pendulums.count)
    }

    // MARK: - The game's judgements


    /// Push the bone's direction out of every collider it lists. Returns the
    /// resolved direction, which is `direction` itself when nothing was hit.
    private func resolvingCollisions(
        direction: SIMD3<Float>, base: SIMD3<Float>, pendulum: Pendulum,
        colliders: [Int], sideTip: SIMD3<Float>? = nil, sideRadius: Float = 0,
        world: [(position: SIMD3<Float>, rotation: SIMD4<Float>)]
    ) -> (direction: SIMD3<Float>, hit: Bool) {
        guard !colliders.isEmpty else { return (direction, false) }
        var resolved = direction

        func correction(at candidate: SIMD3<Float>) -> SIMD3<Float> {
            let point = base + candidate * pendulum.length
            var correction = SIMD3<Float>.zero
            for collider in colliders {
                if let (normal, depth) = violation(
                    of: point, with: bounds[collider], world: world,
                    radius: pendulum.radius
                ) {
                    correction += normal * depth
                }
                if let sideTip, let (normal, depth) = sideViolation(
                    of: point, link: sideTip, radius: pendulum.radius,
                    linkRadius: sideRadius, with: bounds[collider], world: world
                ) {
                    correction += normal * depth
                }
            }
            return correction
        }

        // Small tangential steps, not one normalised jump towards the summed
        // correction: when two capsules push from opposite sides the big step
        // overshoots into the other one and bounces between them forever. At
        // rest the skirt panels start ~4 cm inside the thigh capsules (the bind
        // pose is authored that way), so this loop runs on every frame and any
        // instability shows up as the skirt flapping in a wind.
        let stepAngle: Float = 0.5 * .pi / 180
        for _ in 0..<180 {
            let sum = correction(at: resolved)
            guard simd_length(sum) > 1e-6 else {
                return (resolved, resolved != direction)
            }
            var tangential = sum - resolved * simd_dot(sum, resolved)
            if simd_length(tangential) < 1e-7 { tangential = sum }
            let way = simd_normalize(tangential)
            resolved = simd_normalize(resolved + way * sin(stepAngle))
        }

        // Wedged between two capsules: walk out around the tangent circle.
        let sum = correction(at: resolved)
        guard simd_length(sum) > 1e-6 else { return (resolved, true) }
        var tangent = simd_cross(resolved, sum)
        if simd_length(tangent) < 1e-5 {
            tangent = simd_cross(resolved, SIMD3(0, 0, 1))
        }
        if simd_length(tangent) < 1e-5 { return (resolved, true) }
        tangent = simd_normalize(tangent)
        let bitangent = simd_cross(resolved, tangent)
        var found: SIMD3<Float>?
        for step in 1...12 {
            let angle = Float(step) * 6 * .pi / 180
            for index in 0..<12 {
                let around = Float(index) * .pi / 6
                let offset = tangent * cos(around) + bitangent * sin(around)
                let candidate = simd_normalize(resolved + offset * sin(angle))
                if simd_length(correction(at: candidate)) <= 1e-6 {
                    found = candidate
                    break
                }
            }
            if found != nil { break }
        }
        // The grid is coarse on purpose — it only has to find *a* way out. Bisect
        // back to the boundary before returning it, so a panel that lands here
        // does not snap by a whole 6 degree cell between frames.
        if var best = found {
            var low: Float = 0
            var high: Float = 1
            for _ in 0..<12 {
                let mid = (low + high) / 2
                let probe = simd_normalize(resolved + (best - resolved) * mid)
                if simd_length(correction(at: probe)) <= 1e-6 {
                    high = mid
                    best = probe
                } else {
                    low = mid
                }
            }
            return (best, true)
        }
        return (resolved, true)
    }

    /// How far a tip is inside a sphere or capsule, with the normal that
    /// pushes it out. `nil` when it is outside.
    private func violation(
        of tip: SIMD3<Float>, with bound: Bounds,
        world: [(position: SIMD3<Float>, rotation: SIMD4<Float>)], radius: Float
    ) -> (SIMD3<Float>, Float)? {
        let joint = world[bound.joint]
        let centre = joint.position + QuaternionMath.rotate(joint.rotation, bound.offset)
        // Aim a hair outside the surface: the relaxation approaches the
        // boundary asymptotically, and landing exactly on it leaves the panel
        // half a millimetre in.
        let limit = bound.radius + radius + Self.surfaceMargin

        switch bound.kind {
        case .plane:
            // `SwayColliderMT.CheckPlane`: a half-space through the collider's
            // offset point. The bone's own radius is the margin the game
            // takes from that plane (FixedParams.n_radius).
            let normal = simd_normalize(QuaternionMath.rotate(joint.rotation, bound.normal))
            let signed = simd_dot(tip - centre, normal)
            let margin = radius + Self.surfaceMargin
            guard signed < margin else { return nil }
            return (normal, margin - signed)

        case .bridge:
            // `CapsuleBridgeHit`: a capsule spanning this joint and the
            // `bridgetgt` joint, exactly like a normal capsule otherwise.
            guard let far = bound.target else { return nil }
            let other = world[far].position
            let span = other - joint.position
            let spanLength = simd_length(span)
            guard spanLength > 1e-5 else { return nil }
            let axis = span / spanLength
            let midpoint = joint.position + span * 0.5
            let half = min(bound.halfLength > 0 ? bound.halfLength : spanLength / 2,
                           spanLength / 2)
            let along = simd_clamp(simd_dot(tip - midpoint, axis), -half, half)
            let closest = midpoint + axis * along
            let delta = tip - closest
            let distance = simd_length(delta)
            guard distance < limit else { return nil }
            let normal = distance > 1e-5 ? delta / distance : axis
            return (normal, limit - distance)

        case .sphere, .capsule:
            var closest = centre
            if bound.kind == .capsule {
                let axis = simd_normalize(QuaternionMath.rotate(joint.rotation, bound.axis))
                let along = simd_clamp(
                    simd_dot(tip - centre, axis), -bound.halfLength, bound.halfLength
                )
                closest = centre + axis * along
            }
            let delta = tip - closest
            let distance = simd_length(delta)
            guard distance < limit else { return nil }
            let normal = distance > 1e-5
                ? delta / distance
                : simd_normalize(QuaternionMath.rotate(joint.rotation, SIMD3(1, 0, 0)))
            return (normal, limit - distance)
        }
    }

    /// `CheckSideLine`: the segment between this tip and its `sideLink`
    /// neighbour — `SwayBoneMT` works from the tips' midpoint, half their
    /// separation long each way — is tested against the same colliders as a
    /// capsule `0.9 x` the smaller bone radius thick. Two panels either side
    /// of a thigh can straddle it with both tips already outside, which is the
    /// gap a wide skirt opens when the dance swings it between the legs.
    ///
    /// The game also branches this check per collider type; no shipped costume
    /// links a plane or bridge (`useLinkHit` in the corpus only ever names the
    /// thigh capsules), so those two keep the point hit only.
    private func sideViolation(
        of tip: SIMD3<Float>, link: SIMD3<Float>,
        radius: Float, linkRadius: Float, with bound: Bounds,
        world: [(position: SIMD3<Float>, rotation: SIMD4<Float>)]
    ) -> (SIMD3<Float>, Float)? {
        guard bound.kind == .sphere || bound.kind == .capsule else { return nil }
        let joint = world[bound.joint]
        let centre = joint.position + QuaternionMath.rotate(joint.rotation, bound.offset)
        // `SwayCollider.SideLineHitRadius`: 0.9 x the smaller of the two bone
        // radii on top of the collider's own surface.
        let limit = bound.radius + 0.9 * min(radius, linkRadius)

        let delta = tip - link
        let span = simd_length(delta)
        guard span > 1e-5 else { return nil }
        let midpoint = (tip + link) * 0.5
        let axis = delta / span
        let half = span * 0.5

        var capsuleAxis = SIMD3<Float>.zero
        var capsuleHalf: Float = 0
        if bound.kind == .capsule {
            capsuleAxis = simd_normalize(QuaternionMath.rotate(joint.rotation, bound.axis))
            capsuleHalf = bound.halfLength
        }
        let (onSide, onCollider) = Self.closestPoints(
            midpoint - axis * half, midpoint + axis * half,
            centre - capsuleAxis * capsuleHalf, centre + capsuleAxis * capsuleHalf
        )
        let push = onSide - onCollider
        let distance = simd_length(push)
        guard distance < limit else { return nil }
        let fallback = abs(axis.z) < 0.9 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(1, 0, 0)
        let normal = distance > 1e-5
            ? push / distance
            : simd_normalize(simd_cross(axis, fallback))
        return (normal, limit - distance)
    }

    /// Closest points on two segments (Ericson, *Real-Time Collision
    /// Detection*, 5.1.9), returned as one point on each.
    private static func closestPoints(
        _ p1: SIMD3<Float>, _ q1: SIMD3<Float>,
        _ p2: SIMD3<Float>, _ q2: SIMD3<Float>
    ) -> (SIMD3<Float>, SIMD3<Float>) {
        let d1 = q1 - p1
        let d2 = q2 - p2
        let r = p1 - p2
        let a = simd_dot(d1, d1)
        let e = simd_dot(d2, d2)
        let f = simd_dot(d2, r)
        let epsilon: Float = 1e-7
        if a <= epsilon && e <= epsilon { return (p1, p2) }
        var s: Float
        var t: Float
        if a <= epsilon {
            s = 0
            t = simd_clamp(f / e, 0, 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= epsilon {
                t = 0
                s = simd_clamp(-c / a, 0, 1)
            } else {
                let b = simd_dot(d1, d2)
                let denominator = a * e - b * b
                s = denominator > epsilon
                    ? simd_clamp((b * f - c * e) / denominator, 0, 1)
                    : 0
                t = (b * s + f) / e
                if t < 0 {
                    t = 0
                    s = simd_clamp(-c / a, 0, 1)
                } else if t > 1 {
                    t = 1
                    s = simd_clamp((b - c) / a, 0, 1)
                }
            }
        }
        return (p1 + d1 * s, p2 + d2 * t)
    }

    /// The game's angle window. `CalcRotate` measures the tip in the bone's
    /// bind frame (`m_offset_rot`, the `useBindDir` direction), so the limits
    /// are **deviations from the rest direction**, not absolute world angles:
    /// `minZAngle … maxZAngle` is how far the panel may swing down from where
    /// the costume was modelled, `minYAngle … maxYAngle` how far sideways.
    private func clampedDirection(
        of tip: SIMD3<Float>, from base: SIMD3<Float>,
        parentRotation: SIMD4<Float>, restDirection: SIMD3<Float>,
        limit: Limit?
    ) -> SIMD3<Float> {
        let offset = tip - base
        let length = simd_length(offset)
        guard length > 1e-6 else { return simd_normalize(restDirection) }
        let local = QuaternionMath.rotate(
            QuaternionMath.inverse(parentRotation), offset
        ) / length

        guard let limit else {
            return simd_normalize(QuaternionMath.rotate(parentRotation, local))
        }
        let rest = QuaternionMath.rotate(
            QuaternionMath.inverse(parentRotation), restDirection
        )
        let (restYaw, restPitch) = Self.angles(of: rest)
        var (yaw, pitch) = Self.angles(of: local)
        yaw = Self.wrap(yaw - restYaw) + restYaw
        pitch -= restPitch
        yaw = restYaw + min(max(yaw - restYaw, limit.minY), limit.maxY)
        pitch = restPitch + min(max(pitch, limit.minZ), limit.maxZ)
        let yawRadians = yaw * .pi / 180
        let pitchRadians = pitch * .pi / 180
        let clamped = SIMD3(
            cos(pitchRadians) * sin(yawRadians),
            -sin(pitchRadians),
            -cos(pitchRadians) * cos(yawRadians)
        )
        return simd_normalize(QuaternionMath.rotate(parentRotation, clamped))
    }

    /// The game's two angles: yaw about the up axis, pitch towards −up.
    private static func angles(of direction: SIMD3<Float>) -> (Float, Float) {
        let yaw = atan2(direction.x, -direction.z) * 180 / .pi
        let pitch = -atan2(direction.y, simd_length(SIMD2(direction.x, direction.z)))
            * 180 / .pi
        return (yaw, pitch)
    }

    /// Keep a yaw difference on the same turn of the circle so a panel near
    /// ±180° does not read as a full revolution.
    private static func wrap(_ degrees: Float) -> Float {
        var value = degrees
        while value > 180 { value -= 360 }
        while value < -180 { value += 360 }
        return value
    }

    /// The game's `CalcSideLineDistance`: a panel and its neighbour keep the
    /// distance they had at rest.
    private func sideLineForce(for index: Int) -> SIMD3<Float> {
        guard let link = sideLinks[index], seeded[link], seeded[index],
              sideLineRest[index] > 0
        else { return .zero }
        let delta = tips[link] - tips[index]
        let distance = simd_length(delta)
        guard distance > 1e-5 else { return .zero }
        let stretch = distance - sideLineRest[index]
        return delta / distance * (stretch * pendulums[index].sideSpring)
    }

    /// The game's `CalcAntiFoldForce`: once two neighbours fold tighter than
    /// `antiFoldAngle`, push them apart along the bisector of their tips.
    private func antiFoldForce(for index: Int) -> SIMD3<Float> {
        guard let fold = pendulums[index].antiFold,
              let link = sideLinks[index], seeded[link], seeded[index]
        else { return .zero }
        let mine = tips[index] - bases[index]
        let theirs = tips[link] - bases[link]
        guard simd_length(mine) > 1e-5, simd_length(theirs) > 1e-5 else {
            return .zero
        }
        let cosine = simd_dot(simd_normalize(mine), simd_normalize(theirs))
        let angle = acos(simd_clamp(cosine, -1, 1))
        guard angle < fold.angle * .pi / 180 else { return .zero }
        let apart = simd_normalize(mine) - simd_normalize(theirs)
        return simd_length(apart) > 1e-5
            ? simd_normalize(apart) * fold.force
            : .zero
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
