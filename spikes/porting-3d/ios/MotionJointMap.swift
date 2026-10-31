import Foundation

/// Which dance curve drives which joint of a loaded model (issue #28).
///
/// The game addresses bones by their full Transform path
/// (`MODEL_00/BODY_SCALE/BASE/MUNE1`); RealityKit names a skeleton's joints by
/// their node name, so the mapping is by name, resolved once at load time.
///
/// Two of the 57 paths in `dan_loveig_01` never resolve: `POSITION` and
/// `POSITION/SCALE_POINT` sit on root Transforms the glTF export folded away
/// (#27). They are reported instead of silently dropped so the caller can put
/// their translation on the model root.
struct MotionJointMap: Equatable {
    struct Binding: Equatable {
        /// Index into `MotionDance.bones`.
        let bone: Int
        /// Index into the model's `jointNames`.
        let joint: Int
    }

    let bindings: [Binding]
    /// Bone paths with no matching joint, in dance order.
    let unmapped: [String]
    /// Joints that are roots of the skeleton, i.e. whose name is a bare leaf.
    /// RealityKit reports a root joint's transform relative to the model
    /// space, while every other joint is relative to its parent, so roots need
    /// one extra frame change at playback (`UnityHandedness.rootFrame`).
    let roots: Set<Int>

    /// Resolve paths against joint names by suffix, longest first.
    ///
    /// The two sides name the same chain but start at different places. The
    /// game addresses a Transform from above the character
    /// (`MODEL_00/BODY_SCALE/BASE/MUNE1/MUNE2/SAKOTSU_L`); RealityKit names a
    /// joint by its path from the skeleton's root joint
    /// (`MUNE1/MUNE2/SAKOTSU_L`), which is what `motion.log` from a device
    /// shows. So every suffix of the dance's path is tried in turn — the full
    /// path, then with one leading component dropped, and so on down to the
    /// leaf, which is the handle for a joint that is itself a root. A joint is
    /// claimed by the first path that names it.
    static func resolve(paths: [String], joints: [String]) -> MotionJointMap {
        var byName: [String: Int] = [:]
        for (index, name) in joints.enumerated() where byName[name] == nil {
            byName[name] = index
        }

        var bindings: [Binding] = []
        var unmapped: [String] = []
        var claimed: Set<Int> = []

        for (bone, path) in paths.enumerated() {
            let components = path.split(separator: "/")
            var joint: Int?
            for start in 0..<components.count {
                let candidate = components[start...].joined(separator: "/")
                if let found = byName[candidate], !claimed.contains(found) {
                    joint = found
                    break
                }
            }
            if let joint {
                claimed.insert(joint)
                bindings.append(Binding(bone: bone, joint: joint))
            } else {
                unmapped.append(path)
            }
        }
        return MotionJointMap(
            bindings: bindings,
            unmapped: unmapped,
            roots: Set(joints.indices.filter { !joints[$0].contains("/") })
        )
    }
}
