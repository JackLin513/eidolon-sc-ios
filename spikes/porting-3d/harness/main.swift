import Foundation
import simd

// Standalone replay of `MotionPlayback.apply` without RealityKit: it reads the
// simulator's `rest.json` (the joints RealityKit reported), the packed dance
// and the sway sidecar, then steps the dance at the playback rate and reports
// what the sway solver does to the panels. Used to pin the umbrella-skirt and
// floating bugs; not part of the app.

struct Probe {
    let joints: [String]
    let rest: [JointPose]
    let pose: [JointPose]
}

func loadRest(_ path: String) throws -> ([String], [JointPose]) {
    let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
    var names: [String] = []
    var poses: [JointPose] = []
    for row in rows {
        names.append(row["name"] as! String)
        let t = row["t"] as! [Double]
        let r = row["r"] as! [Double]
        let s = row["s"] as! [Double]
        poses.append(JointPose(
            translation: SIMD3(Float(t[0]), Float(t[1]), Float(t[2])),
            rotation: SIMD4(Float(r[0]), Float(r[1]), Float(r[2]), Float(r[3])),
            scale: SIMD3(Float(s[0]), Float(s[1]), Float(s[2]))))
    }
    return (names, poses)
}

func quatAngle(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
    let d = abs(simd_dot(simd_normalize(a), simd_normalize(b)))
    return 2 * acos(min(d, 1)) * 180 / .pi
}

// `GEOM=1`: how deep each skirt root's *rest* tip sits inside each collider,
// computed independently of MotionSway, so a space/offset mistake shows up as
// a number rather than a rendered umbrella.
func geometryProbe(names: [String], rest: [JointPose], poses: [JointPose],
                  config: MotionSway.Configuration) {
    var parents = [Int?](repeating: nil, count: names.count)
    var byPath: [String: Int] = [:]
    for (i, n) in names.enumerated() where byPath[n] == nil { byPath[n] = i }
    for (i, n) in names.enumerated() {
        if let cut = n.lastIndex(of: "/") { parents[i] = byPath[String(n[..<cut])] }
    }
    let world = JointWorld.transforms(poses, parents: parents)
    let colliders = config.colliders ?? []
    if ProcessInfo.processInfo.environment["LEGS"] != nil {
        for n in ["KOSHI", "KOSHI/MOMO_L", "KOSHI/MOMO_L/HIZA_L", "KOSHI/MOMO_R", "KOSHI/MOMO_R/HIZA_R"] {
            if let i = byPath[n] {
                let p = world[i].0
                let label = n.padding(toLength: max(n.count, 22), withPad: " ", startingAt: 0)
                print(String(format: "    leg @ (%6.3f, %6.3f, %6.3f) ", p.x, p.y, p.z) + label)
            }
        }
    }
    for bone in config.bones where bone.isSkirt == true && bone.name.hasSuffix("A0") {
        guard let j = byPath[bone.name], bone.tail.count == 3 else { continue }
        let tail = SIMD3(bone.tail[0], bone.tail[1], bone.tail[2])
        let parent = parents[j].map { world[$0] } ?? (.zero, SIMD4(0, 0, 0, 1))
        let base = parent.0 + QuaternionMath.rotate(parent.1, poses[j].translation)
        let rigid = QuaternionMath.multiply(parent.1, rest[j].rotation)
        let tip = base + QuaternionMath.rotate(rigid, tail)
        print("  \(bone.name)  tip=(\(fmt(tip.x)), \(fmt(tip.y)), \(fmt(tip.z)))  r=\(bone.radius ?? 0)")
        for ci in bone.colliders ?? [] {
            guard colliders.indices.contains(ci) else { continue }
            let c = colliders[ci]
            guard c.offset.count == 3, let cj = byPath[c.joint] else { continue }
            let centre = world[cj].0 + QuaternionMath.rotate(world[cj].1, SIMD3(c.offset[0], c.offset[1], c.offset[2]))
            var closest = centre
            var axisLabel = ""
            if c.type.lowercased() == "capsule" {
                let a: SIMD3<Float>
                switch (c.axis ?? "X").uppercased() {
                case "Y": a = SIMD3(0, 1, 0)
                case "Z": a = SIMD3(0, 0, 1)
                default: a = SIMD3(1, 0, 0)
                }
                let unit = simd_normalize(QuaternionMath.rotate(world[cj].1, a))
                let half = max(c.distance, 0) / 2
                closest = centre + unit * simd_clamp(simd_dot(tip - centre, unit), -half, half)
                axisLabel = " axis=(\(fmt(unit.x)),\(fmt(unit.y)),\(fmt(unit.z))) half=\(fmt(half))"
            }
            let dist = simd_length(tip - closest)
            let limit = c.radius + (bone.radius ?? 0)
            let depth = limit - dist
            print("    collider#\(ci) \(c.type)@\(c.joint) r=\(fmt(c.radius)) dist=\(fmt(dist)) limit=\(fmt(limit))"
                  + " depth=\(String(format: "%7.1f", depth * 1000))mm\(axisLabel)")
        }
    }
}

func fmt(_ v: Float) -> String { String(format: "%.3f", v) }

let args = CommandLine.arguments
guard args.count >= 4 else {
    print("usage: sway_probe rest.json dance.motion.json sway.json [seconds]")
    exit(2)
}
let (names, rest) = try loadRest(args[1])
let dance = try JSONDecoder().decode(MotionDance.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
let config = try JSONDecoder().decode(MotionSway.Configuration.self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))
let seconds = args.count > 4 ? (Double(args[4]) ?? 5) : 5
let noColliders = ProcessInfo.processInfo.environment["NO_COLLIDERS"] != nil
let withoutSpring = ProcessInfo.processInfo.environment["NO_SPRING"] != nil

let map = MotionJointMap.resolve(paths: dance.bones.map(\.path), joints: names)
let sampler = MotionSampler(dance: dance, map: map, rest: rest, joints: names)
var effective = config
if noColliders {
    effective = MotionSway.Configuration(format: config.format, families: config.families, bones: config.bones, colliders: nil)
}
if withoutSpring {
    effective = MotionSway.Configuration(format: config.format, families: nil, bones: config.bones.map {
        MotionSway.Bone(name: $0.name, family: $0.family, tail: $0.tail, radius: $0.radius,
                        spring: MotionSway.Spring(stiffness: 0, drag: 1, gravity: 0),
                        follow: $0.follow, limit: $0.limit, colliders: $0.colliders,
                        sideLink: $0.sideLink, sideSpring: 0, antiFold: nil,
                        hitTwice: $0.hitTwice, useLinkHit: $0.useLinkHit, isSkirt: $0.isSkirt,
                        hitMute: $0.hitMute, hitMuteRate: $0.hitMuteRate)
    }, colliders: config.colliders)
}
guard var sway = MotionSway(configuration: effective, joints: names, rest: rest) else {
    print("sway init failed"); exit(1)
}

// The bones the report names: skirt roots, i.e. the panels hanging off KOSHI/skirt_GP.
let skirtBones = config.bones.filter { $0.isSkirt == true }
let roots = skirtBones.filter { $0.name.contains("skirt_") && $0.name.hasSuffix("A0") }
let allBones = config.bones
let reportNames: [String] = ProcessInfo.processInfo.environment["ALL"] != nil
    ? allBones.map(\.name)
    : (roots.isEmpty ? Array(skirtBones.prefix(8)).map(\.name) : roots.map(\.name))

var reports: [(Double, [String: Float], [String: Float])] = []
var lastPoses: [JointPose] = []
var thighBands: [String: (lo: Float, hi: Float)] = [:]
var footBands: (Float, Float) = (.greatestFiniteMagnitude, -.greatestFiniteMagnitude)
var time: Double = 0
let step = 1.0 / 60
let steps = Int(seconds / step)
for stepIndex in 0..<steps {
    var poses = sampler.pose(at: time)
    if ProcessInfo.processInfo.environment["GEOM"] != nil, stepIndex % 6 == 0 {
        print(String(format: "t=%.2f", time))
        geometryProbe(names: names, rest: rest, poses: poses, config: config)
    }
    sway.apply(&poses, dt: Float(step))
    lastPoses = poses
    time += step
    if dance.timeLength > 0 { time = time.truncatingRemainder(dividingBy: dance.timeLength) }
    var angles: [String: Float] = [:]
    for name in reportNames {
        guard let i = names.firstIndex(of: name) else { continue }
        angles[name] = quatAngle(poses[i].rotation, rest[i].rotation)
    }
    reports.append((time, angles, [:]))
    if ProcessInfo.processInfo.environment["FEET"] != nil {
        var parents = [Int?](repeating: nil, count: names.count)
        var byPath: [String: Int] = [:]
        for (i, n) in names.enumerated() where byPath[n] == nil { byPath[n] = i }
        for (i, n) in names.enumerated() {
            if let cut = n.lastIndex(of: "/") { parents[i] = byPath[String(n[..<cut])] }
        }
        let w = JointWorld.transforms(sampler.pose(at: time), parents: parents)
        let low = w.map { $0.0.z }.min() ?? 0
        footBands.0 = min(footBands.0, low)
        footBands.1 = max(footBands.1, low)
    }
    if ProcessInfo.processInfo.environment["THIGH"] != nil {
        var parents = [Int?](repeating: nil, count: names.count)
        var byPath: [String: Int] = [:]
        for (i, n) in names.enumerated() where byPath[n] == nil { byPath[n] = i }
        for (i, n) in names.enumerated() {
            if let cut = n.lastIndex(of: "/") { parents[i] = byPath[String(n[..<cut])] }
        }
        let pre = sampler.pose(at: time)
        let w = JointWorld.transforms(pre, parents: parents)
        for side in ["L", "R"] {
            guard let hip = byPath["KOSHI/MOMO_" + side], let knee = byPath["KOSHI/MOMO_" + side + "/HIZA_" + side] else { continue }
            let d = w[knee].0 - w[hip].0
            let len = simd_length(d)
            // Angle from straight down (−Z in the app's joint world).
            let down = SIMD3<Float>(0, 0, -1)
            let cos = simd_clamp(simd_dot(d / len, down), -1, 1)
            let angle = acos(cos) * 180 / .pi
            let previous = thighBands[side] ?? (lo: 180.0, hi: 0.0)
            thighBands[side] = (lo: min(previous.lo, angle), hi: max(previous.hi, angle))
        }
    }
}

// `TIPS=1`: where each panel's tip ended up, in the joint world.
if ProcessInfo.processInfo.environment["TIPS"] != nil {
    var parents = [Int?](repeating: nil, count: names.count)
    var byPath: [String: Int] = [:]
    for (i, n) in names.enumerated() where byPath[n] == nil { byPath[n] = i }
    for (i, n) in names.enumerated() {
        if let cut = n.lastIndex(of: "/") { parents[i] = byPath[String(n[..<cut])] }
    }
    let poses = lastPoses
    let world = JointWorld.transforms(poses, parents: parents)
    for bone in config.bones where bone.isSkirt == true && bone.name.hasSuffix("0") {
        guard let i = byPath[bone.name], bone.tail.count == 3 else { continue }
        let M = world[i]
        let tail = SIMD3(bone.tail[0], bone.tail[1], bone.tail[2])
        let tip = M.position + QuaternionMath.rotate(M.rotation, tail)
        // Rest direction of the same panel, from the rest skeleton.
        let parent = parents[i].map { world[$0] } ?? (.zero, SIMD4(0, 0, 0, 1))
        let restDir = QuaternionMath.rotate(
            QuaternionMath.multiply(parent.1, rest[i].rotation), tail)
        let up = SIMD3<Float>(0, 0, 1)
        let radialRaw = restDir - up * simd_dot(restDir, up)
        var line = String(format: "  tip (%6.3f,%6.3f,%6.3f) ", tip.x, tip.y, tip.z)
            + bone.name.padding(toLength: max(bone.name.count, 32), withPad: " ", startingAt: 0)
        if simd_length(radialRaw) > 1e-4 {
            let outward = simd_normalize(radialRaw)
            let tangent = simd_cross(up, outward)
            func angles(_ v: SIMD3<Float>) -> (Float, Float) {
                let h = SIMD2(simd_dot(v, outward), simd_dot(v, tangent))
                return (atan2(h.y, h.x) * 180 / .pi, -atan2(simd_dot(v, up), simd_length(h)) * 180 / .pi)
            }
            let r = angles(QuaternionMath.rotate(QuaternionMath.multiply(parent.1, rest[i].rotation), tail))
            let c = angles(tip - M.position)
            line += String(format: " yaw %+6.1f° pitch %+6.1f°",
                           c.0 - r.0, c.1 - r.1)
        }
        print(line)
    }
}

// Print the max over the run and where it happened, then the last frame.
var peak: [String: Float] = [:]
for (_, angles, _) in reports {
    for (name, value) in angles { peak[name] = max(peak[name] ?? 0, value) }
}
print("clip=\(args[2].split(separator: "/").last ?? "") seconds=\(seconds) steps=\(steps) swayBones=\(sway.count)")
if footBands.0 < .greatestFiniteMagnitude {
    print(String(format: "  lowest joint z over run: %.3f … %.3f", footBands.0, footBands.1))
}
for (side, band) in thighBands.sorted(by: { $0.key < $1.key }) {
    print("  thigh " + side + " from vertical: "
          + String(format: "%.1f", band.lo) + "° … " + String(format: "%.1f", band.hi) + "°")
}
for name in reportNames.sorted() {
    let padded = name.padding(toLength: max(name.count, 36), withPad: " ", startingAt: 0)
    print("  \(padded) peak \(String(format: "%6.1f", peak[name] ?? 0))°  last \(String(format: "%6.1f", reports.last!.1[name] ?? 0))°")
}
