import Foundation

/// Which of an outfit's animations show a direction, on each of the player's five tracks
/// (the upstream `standAnimations.pickAnimations`). Every fallback lives here, in one pure
/// function; the player only plays what it is given (ADR-0017).
public enum StandAnimator {
    /// Body animations for each emotion, the first the outfit has being played.
    private static let body: [StandEmotion: [String]] = [
        .calm: ["wait"],
        .happy: ["smile1", "smile2"],
        .shy: ["shy1", "shy2", "smile2"],
        .surprised: ["surp1", "surp2"],
        .sad: ["sad1", "sad2"],
        .angry: ["anger1", "anger2"],
        .thinking: ["think", "think1", "think2", "wait4", "wait"],
    ]

    /// Faces for each emotion; `blank` when the outfit has none.
    private static let face: [StandEmotion: [String]] = [
        .calm: ["face_wait"],
        .happy: ["face_smile", "face_smile1", "face_smile2"],
        .shy: ["face_shy", "face_shy2"],
        .surprised: ["face_surp"],
        .sad: ["face_sad"],
        .angry: ["face_anger", "face_anger1", "face_anger2"],
        .thinking: ["face_serious"],
    ]

    /// The `<k>` of each emotion's talking mouth, `lip_<k>`.
    private static let lip: [StandEmotion: String] = [
        .calm: "wait",
        .happy: "smile",
        .shy: "shy",
        .surprised: "surp",
        .sad: "sad",
        .angry: "anger",
        .thinking: "serious",
    ]

    /// What to play from now on, given what an outfit can play (`animation` name → duration
    /// in seconds, as the player reports it). With reduced motion the body stays `wait`;
    /// faces, mouth, nods and gaze go on.
    public static func pose(
        for direction: StandDirection,
        reducedMotion: Bool,
        animations: [String: Double]
    ) -> StandPose {
        let mood = direction.mood
        let k = lip[mood] ?? "wait"
        let mouth = first(["lip_\(k)", "lip_\(k)1", "lip_\(k)2", "lip_smile", "lip_wait"], in: animations)
            ?? anyMouth(in: animations)
        let nod = direction.nod.flatMap { nod -> StandPose.Nod? in
            let names = [nod.kind.rawValue, nod.kind.rawValue + "2"]
            return first(names, in: animations).map { StandPose.Nod(name: $0, id: nod.id) }
        }
        return StandPose(
            body: reducedMotion ? "wait" : first(body[mood] ?? [], in: animations) ?? "wait",
            face: first(face[mood] ?? [], in: animations) ?? "blank",
            mouth: mouth.map { StandPose.Mouth(name: $0, open: direction.speaking) },
            eye: direction.looking && animations["eye_front"] != nil ? "eye_front" : nil,
            nod: nod
        )
    }

    /// The first of `names` the outfit has.
    private static func first(_ names: [String], in animations: [String: Double]) -> String? {
        names.first { animations[$0] != nil }
    }

    /// Any talking mouth that moves: not a still `lip_*_s`, nor `lip_a`. Sorted, so an
    /// outfit with several gives the same one every time.
    private static func anyMouth(in animations: [String: Double]) -> String? {
        animations.keys.sorted().first { name in
            name.hasPrefix("lip_")
                && name != "lip_a"
                && (animations[name] ?? 0) > 0
                && name.range(of: #"_s\d*$"#, options: .regularExpression) == nil
        }
    }
}
