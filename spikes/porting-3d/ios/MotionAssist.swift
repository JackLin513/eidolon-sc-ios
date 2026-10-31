import Foundation
import simd

/// The game's `Imas.BoneLib.CalcBone` pass, replayed over a whole frame.
///
/// A dance only keys the bones the animator moved. The rig also carries assist
/// bones whose rule is encoded in the bone's name — `HIJI_L__rot_UDE_L__z50`
/// takes half of `UDE_L`'s turn — and the game recomputes them in `LateUpdate`
/// from the reference bone's current pose. Without that pass the elbow, wrist
/// and hip regions stay at their bind pose while the arm or leg swings, which
/// is what tears the mesh into long shards during a dance.
///
/// The rule grammar and the reference implementation's quirks are written up
/// in `research-mltd-calcbone.md` (not committed); the short version is that
/// names are `<mine>__<algorithm>_<reference>[__<parameters>]`, the algorithm
/// keywords are tested in a fixed order, and `gnull` names match none of them
/// so their bones stay untouched.
struct MotionAssist {
    /// Which of the game's four algorithms a helper runs.
    private enum Kind {
        case slerp
        case twist
        case rot
        /// `const`: turn so the helper's local −X axis points at a reference
        /// bone, in world space, because parent and reference sit under
        /// different parents.
        case constrain
    }

    private struct Helper {
        let joint: Int
        let kind: Kind
        let reference: Int
        /// The helper's own rest rotation, the game's `initMyRot`.
        let initMy: SIMD4<Float>
        /// The reference's rest rotation, `initRefRot`.
        let initRef: SIMD4<Float>
        /// `initRefRot * Vector3.right`.
        let initRefVector: SIMD3<Float>
        /// SLERP's blend amount; unused by the other kinds.
        let t: Float
        /// How much of the reference's turn to take: SLERP's second parameter,
        /// otherwise its first.
        let tx: Float
    }

    private let helpers: [Helper]
    private let parents: [Int?]

    var isEmpty: Bool { helpers.isEmpty }
    var count: Int { helpers.count }

    /// Parse the rules out of the joint names. `rest` is the loaded pose, the
    /// same one the game read when its own pass woke up.
    init(joints: [String], rest: [JointPose]) {
        guard joints.count == rest.count else {
            helpers = []
            parents = []
            return
        }
        var byPath: [String: Int] = [:]
        var byLeaf: [String: Int] = [:]
        for (index, name) in joints.enumerated() {
            if byPath[name] == nil { byPath[name] = index }
            let leaf = Self.leaf(of: name)
            if byLeaf[leaf] == nil { byLeaf[leaf] = index }
        }
        var parents = [Int?](repeating: nil, count: joints.count)
        for (index, name) in joints.enumerated() {
            if let path = Self.parentPath(of: name) { parents[index] = byPath[path] }
        }

        var helpers: [Helper] = []
        for (index, name) in joints.enumerated() {
            guard let rule = Self.rule(for: Self.leaf(of: name)) else { continue }
            let reference: Int?
            switch rule.kind {
            case .twist:
                // TWIST names carry no reference: the helper is a child of the
                // bone it twists, and `Awake` falls back to `transform.parent`.
                reference = parents[index]
            case .slerp, .rot, .constrain:
                reference = rule.target.flatMap { byLeaf[$0] }
            }
            guard let reference else { continue }
            let initRef = rest[reference].rotation
            helpers.append(Helper(
                joint: index,
                kind: rule.kind,
                reference: reference,
                initMy: rest[index].rotation,
                initRef: initRef,
                initRefVector: QuaternionMath.rotate(initRef, SIMD3(1, 0, 0)),
                t: rule.t,
                tx: rule.tx
            ))
        }
        self.helpers = helpers
        self.parents = parents
    }

    /// Run the pass on one frame's local poses. The three local algorithms only
    /// read their reference's local rotation, so they run first; constraints
    /// need world transforms and run after them.
    func apply(_ poses: inout [JointPose]) {
        var constraints: [Helper] = []
        for helper in helpers {
            let current = poses[helper.reference].rotation
            switch helper.kind {
            case .slerp:
                poses[helper.joint].rotation = Self.slerpEx(current, helper)
            case .twist:
                poses[helper.joint].rotation = Self.twist(current, helper)
            case .rot:
                poses[helper.joint].rotation = Self.rot(current, helper)
            case .constrain:
                constraints.append(helper)
            }
        }
        for helper in constraints {
            Self.constrain(&poses, helper: helper, parents: parents)
        }
    }

    // MARK: - The four algorithms

    /// `SlerpEx`: blend from the reference's rest rotation towards its current
    /// one, taking `tx` of the way first, then `t` of the way from rest to that.
    private static func slerpEx(_ current: SIMD4<Float>, _ helper: Helper) -> SIMD4<Float> {
        let aligned = QuaternionMath.fromToRotation(
            helper.initRefVector, QuaternionMath.rotate(current, SIMD3(1, 0, 0))
        )
        let goal = QuaternionMath.multiply(aligned, helper.initRef)
        let start = QuaternionMath.dot(current, goal) < 0 ? -current : current
        var middle = QuaternionMath.slerp(start, goal, helper.tx)
        if QuaternionMath.dot(helper.initRef, middle) < 0 { middle = -middle }
        return QuaternionMath.slerp(helper.initRef, middle, helper.t)
    }

    /// `Twist`: the reference's twist about its own X axis, scaled by `tx` and
    /// expressed in the reference's frame because the helper is its child.
    private static func twist(_ current: SIMD4<Float>, _ helper: Helper) -> SIMD4<Float> {
        let aligned = QuaternionMath.fromToRotation(
            helper.initRefVector, QuaternionMath.rotate(current, SIMD3(1, 0, 0))
        )
        let goal = QuaternionMath.multiply(aligned, helper.initRef)
        let start = QuaternionMath.dot(current, goal) < 0 ? -current : current
        let turn = QuaternionMath.slerp(goal, start, helper.tx)
        return QuaternionMath.multiply(QuaternionMath.inverse(start), turn)
    }

    /// `ROT`: the part of the reference's turn that the helper has not already
    /// taken by sharing the reference's parent, scaled by `tx`, on top of the
    /// helper's own rest rotation.
    private static func rot(_ current: SIMD4<Float>, _ helper: Helper) -> SIMD4<Float> {
        let aligned = QuaternionMath.fromToRotation(
            helper.initRefVector, QuaternionMath.rotate(current, SIMD3(1, 0, 0))
        )
        let goal = QuaternionMath.multiply(aligned, helper.initRef)
        var remainder = QuaternionMath.multiply(QuaternionMath.inverse(goal), current)
        if remainder.w < 0 { remainder = -remainder }
        let turn = QuaternionMath.slerp(SIMD4(0, 0, 0, 1), remainder, helper.tx)
        return QuaternionMath.multiply(helper.initMy, turn)
    }

    /// `Constrain`: point the helper's local X back at the reference. The
    /// helper is a chest bone under `MUNE2` whose reference sits under
    /// `SAKOTSU_*`, so the alignment has to happen in world space and be
    /// converted back through the helper's own parent.
    private static func constrain(
        _ poses: inout [JointPose], helper: Helper, parents: [Int?]
    ) {
        poses[helper.joint].rotation = helper.initMy
        let world = worldTransforms(poses, parents: parents)
        let mine = world[helper.joint]
        let direction = world[helper.reference].position - mine.position
        let distance = simd_length(direction)

        let worldRotation: SIMD4<Float>
        if distance > 1e-5 {
            let forward = QuaternionMath.rotate(mine.rotation, SIMD3(-1, 0, 0))
            let turn = QuaternionMath.fromToRotation(forward, direction / distance)
            worldRotation = QuaternionMath.multiply(turn, mine.rotation)
        } else {
            worldRotation = mine.rotation
        }

        if let parent = parents[helper.joint] {
            poses[helper.joint].rotation = QuaternionMath.multiply(
                QuaternionMath.inverse(world[parent].rotation), worldRotation
            )
        } else {
            poses[helper.joint].rotation = worldRotation
        }
    }

    /// Parent-space poses to world, walking the parent links derived from the
    /// joint names. Joint scales are 1 on this rig, so only rotation and
    /// translation compose.
    private static func worldTransforms(
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

    // MARK: - Name grammar

    /// What a helper's name asks for.
    private static func rule(for name: String) -> (kind: Kind, target: String?, t: Float, tx: Float)? {
        // `Awake` tests `name.Contains` in exactly this order, so a CONST bone
        // whose name also contains "rot" is still a constraint.
        if name.contains("slerp") {
            guard let target = targetName(name) else { return nil }
            let values = parameters(name)
            guard let t = values.first else { return nil }
            return (.slerp, target, t, values.count > 1 ? values[1] : 0)
        }
        if name.contains("twist") {
            guard let tx = twistParameter(name) else { return nil }
            return (.twist, nil, 0, tx)
        }
        if name.contains("const") {
            guard let target = targetName(name) else { return nil }
            return (.constrain, target, 0, 0)
        }
        if name.contains("rot") {
            guard let target = targetName(name) else { return nil }
            guard let tx = parameters(name).first else { return nil }
            return (.rot, target, 0, tx)
        }
        // `transform26__gnull` and anything unrecognised were never registered
        // by the game either, so their bones keep the rest pose.
        return nil
    }

    private static func leaf(of name: String) -> String {
        name.split(separator: "/").last.map(String.init) ?? name
    }

    private static func parentPath(of name: String) -> String? {
        guard let cut = name.lastIndex(of: "/") else { return nil }
        return String(name[..<cut])
    }

    /// The reference bone's name: between the `_` after the algorithm and the
    /// next `__`. TWIST's one-separator names have no such span.
    private static func targetName(_ name: String) -> String? {
        guard
            let head = name.range(of: "__"),
            let start = name.range(of: "_", range: head.upperBound..<name.endIndex),
            let end = name.range(of: "__", range: start.upperBound..<name.endIndex)
        else { return nil }
        return String(name[start.upperBound..<end.lowerBound])
    }

    /// `getParams`: the groups after the reference, e.g. `i30_x0` gives
    /// t = 0.30 then tx = 0.00, and `x100` gives tx = 1.00. Each group is an
    /// axis letter and an integer in hundredths.
    private static func parameters(_ name: String) -> [Float] {
        guard
            let head = name.range(of: "__"),
            let separator = name.range(of: "__", range: head.upperBound..<name.endIndex)
        else { return [] }
        return name[separator.upperBound...].split(separator: "_").compactMap(hundredths)
    }

    /// TWIST puts its one parameter right after the algorithm name instead of
    /// after a second `__`: `KATA_MD_R__twist_x50`.
    private static func twistParameter(_ name: String) -> Float? {
        guard let head = name.range(of: "__") else { return nil }
        let tail = name[head.upperBound...]
        guard let cut = tail.firstIndex(of: "_") else { return nil }
        return hundredths(tail[tail.index(after: cut)...])
    }

    private static func hundredths(_ group: Substring) -> Float? {
        guard
            let letter = group.first,
            "ixyz".contains(letter),
            let value = Int(group.dropFirst())
        else { return nil }
        return Float(value) / 100
    }
}
