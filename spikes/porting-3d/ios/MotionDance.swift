import Foundation

/// Packed dance curves for on-device playback (issue #27).
///
/// The file is produced by `spikes/porting-3d/compress_motion.py`. Every
/// channel is sampled on a uniform `fps` grid, quantised (1/100 degree for
/// rotations, 1/4000 Unity unit for positions), then delta-coded:
///
/// - a channel that never changes is a bare integer;
/// - an animated channel is `[first, delta, delta, ...]`, one delta per frame.
///
/// The format mirrors the shipped `CharacterImasMotionPlayer`: rotations are
/// `Quaternion.Euler(AngleX, AngleY, AngleZ)` in Unity's Z-then-X-then-Y order,
/// and a bone's `pos` is present only when the dance had at least one Position
/// curve for it. A bone without `pos` keeps whatever local position its rest
/// pose has.
struct MotionDance: Decodable, Equatable {
    struct Bone: Decodable, Equatable {
        let path: String
        let rot: [MotionChannel]
        let pos: [MotionChannel]?
    }

    static let format = "eidolon.motion/1"

    let formatName: String
    let fps: Int
    let frames: Int
    let timeLength: Double
    let angleScale: Float
    let positionScale: Float
    let bones: [Bone]

    enum CodingKeys: String, CodingKey {
        case fps, frames, bones
        case formatName = "format"
        case timeLength = "time_length"
        case angleScale = "angle_scale"
        case positionScale = "position_scale"
    }

    /// Frame index for a playback time, clamped to the dance.
    func frame(at time: Double) -> Int {
        let scaled = (time * Double(fps)).rounded(.down)
        return min(max(Int(scaled), 0), frames - 1)
    }

    /// Euler degrees for a bone, exactly what the game passes to
    /// `Quaternion.Euler` after dequantising.
    func rotationDegrees(of bone: Bone, at frame: Int) -> SIMD3<Float>? {
        guard bone.rot.count == 3 else { return nil }
        return SIMD3(
            Float(bone.rot[0].value(at: frame)) / angleScale,
            Float(bone.rot[1].value(at: frame)) / angleScale,
            Float(bone.rot[2].value(at: frame)) / angleScale
        )
    }

    /// Local position in Unity units, or nil when the dance never sets one.
    func position(of bone: Bone, at frame: Int) -> SIMD3<Float>? {
        guard let pos = bone.pos, pos.count == 3 else { return nil }
        return SIMD3(
            Float(pos[0].value(at: frame)) / positionScale,
            Float(pos[1].value(at: frame)) / positionScale,
            Float(pos[2].value(at: frame)) / positionScale
        )
    }
}

/// One packed channel. `Int` on the wire means constant, an array means
/// `[first, delta, ...]`.
enum MotionChannel: Decodable, Equatable {
    case constant(Int)
    case deltas([Int])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let constant = try? container.decode(Int.self) {
            self = .constant(constant)
        } else {
            self = .deltas(try container.decode([Int].self))
        }
    }

    /// Quantised value at `frame`, clamped to the encoded range.
    func value(at frame: Int) -> Int {
        switch self {
        case .constant(let value):
            return value
        case .deltas(let deltas):
            guard let first = deltas.first else { return 0 }
            let end = min(max(frame, 0), deltas.count - 1)
            guard end >= 1 else { return first }
            var total = first
            for index in 1...end {
                total += deltas[index]
            }
            return total
        }
    }

    /// Every frame expanded once, for callers that play the dance and would
    /// otherwise pay the running sum per lookup.
    func expanded(frames: Int) -> [Int] {
        switch self {
        case .constant(let value):
            return [Int](repeating: value, count: max(frames, 0))
        case .deltas(let deltas):
            guard let first = deltas.first else {
                return [Int](repeating: 0, count: max(frames, 0))
            }
            var values = [Int]()
            values.reserveCapacity(max(frames, 0))
            var total = first
            for index in 0..<max(frames, 0) {
                if index > 0, index < deltas.count {
                    total += deltas[index]
                }
                values.append(total)
            }
            return values
        }
    }
}

/// Euler-to-quaternion conversion matching `UnityEngine.Quaternion.Euler`.
enum UnityEuler {
    /// Degrees to a quaternion, ordered `(x, y, z, w)`, applied z, then x,
    /// then y — the order inside Unity's `Internal_FromEulerRad`.
    static func quaternion(_ degrees: SIMD3<Float>) -> SIMD4<Float> {
        let half = degrees * 0.5 * (Float.pi / 180)
        let (sx, cx) = (sin(half.x), cos(half.x))
        let (sy, cy) = (sin(half.y), cos(half.y))
        let (sz, cz) = (sin(half.z), cos(half.z))
        return SIMD4(
            cy * sx * cz + sy * cx * sz,
            sy * cx * cz - cy * sx * sz,
            cy * cx * sz - sy * sx * cz,
            cy * cx * cz + sy * sx * sz
        )
    }
}
