import Foundation

public enum AffinityTier: String, Codable, Sendable, CaseIterable, Hashable {
    case cold
    case distant
    case trust
    case close
    case intimate

    /// Where the tier begins, lowest first.
    public var start: Double {
        switch self {
        case .cold: 0
        case .distant: 20
        case .trust: 40
        case .close: 65
        case .intimate: 85
        }
    }

    /// The word the app shows; never a number (upstream `GLOSSARY.md「好感度」`).
    public var title: String {
        switch self {
        case .cold: "冷淡"
        case .distant: "疏远"
        case .trust: "信任"
        case .close: "亲近"
        case .intimate: "亲密"
        }
    }

    static func of(_ value: Double) -> AffinityTier {
        AffinityTier.allCases.last { value >= $0.start } ?? .cold
    }
}

/// Everything upstream's `affinity.py` goes by, in one place (ADR-0004).
public enum AffinityRules {
    public static let normal = 50.0
    public static let thaw = 10.0
    public static let recoveryPerDay = 10.0
    public static let lowest = 0.0
    public static let highest = 100.0
    /// How much a turn changes it, from hurting her (0) to making her very happy (4).
    public static let levelSteps: [Double] = [-5, -2, 0, 1, 2]
    public static let noEffect = 2
    public static let outOfLineStep = -10.0
    public static let gainsPerDay = 6.0
    public static let outOfLinePerConversation = 2
    public static let fedUpTurns = 8
    public static let fedUpAt = 12.0
    public static let warnsAt = 6.0
}

public struct Affinity: Sendable, Hashable {
    public var value: Double
    public var at: Date
    public var cooling: Bool

    public init(value: Double, at: Date, cooling: Bool = false) {
        self.value = value
        self.at = at
        self.cooling = cooling
    }

    public static func fresh(at: Date) -> Affinity {
        Affinity(value: AffinityRules.normal, at: at)
    }

    /// Recovered since `at`; a cooldown it has recovered out of is over.
    public func recovered(now: Date) -> Affinity {
        var value = self.value
        if value < AffinityRules.normal {
            let days = max(now.timeIntervalSince(at), 0) / 86_400
            value = min(AffinityRules.normal, value + AffinityRules.recoveryPerDay * days)
        }
        return Affinity(value: value, at: now, cooling: cooling && value < AffinityRules.thaw)
    }

    /// Changed by `step`, held between the lowest and the highest; falling to the lowest
    /// begins a cooldown.
    public func stepped(_ step: Double) -> Affinity {
        let value = min(max(self.value + step, AffinityRules.lowest), AffinityRules.highest)
        return Affinity(
            value: value,
            at: at,
            cooling: cooling || value <= AffinityRules.lowest
        )
    }

    public var tier: AffinityTier { AffinityTier.of(value) }

    public var cooldownUntil: Date? {
        guard cooling else { return nil }
        return at.addingTimeInterval(
            (AffinityRules.thaw - value) / AffinityRules.recoveryPerDay * 86_400
        )
    }
}

/// What the judge model made of a turn.
public struct Judged: Sendable, Hashable {
    public var level: Int
    public var outOfLine: Bool
    public var manipulation: Bool

    public init(level: Int, outOfLine: Bool = false, manipulation: Bool = false) {
        self.level = level
        self.outOfLine = outOfLine
        self.manipulation = manipulation
    }

    public static let noEffect = Judged(level: AffinityRules.noEffect)

    /// How much it changes affinity: out of line by its step; else by its level's step,
    /// never up when it tried to dictate it.
    public var step: Double {
        if outOfLine { return AffinityRules.outOfLineStep }
        guard (0..<AffinityRules.levelSteps.count).contains(level) else { return 0 }
        let step = AffinityRules.levelSteps[level]
        return manipulation && step > 0 ? 0 : step
    }

    /// How what was said makes her feel, as she is told it.
    public var feeling: String? {
        if outOfLine { return AffinityPrompt.outOfLineFeeling }
        if manipulation && level > AffinityRules.noEffect { return nil }
        guard (0..<AffinityPrompt.feelings.count).contains(level) else { return nil }
        return AffinityPrompt.feelings[level]
    }

    /// How much it took off her affinity, for `ends` and `warns`.
    public var hurt: Double { max(-step, 0) }
}

public enum Parting: Sendable, Hashable {
    case parts
    case hangsUp
}

public enum EndsReason: String, Sendable, Hashable {
    case outOfLine
    case fedUp
    case cooldown
}

/// Whether she ends the conversation after this turn, and why.
public func ends(
    judged: Judged?,
    cools: Bool,
    outOfLineBefore: Int,
    hurtBefore: [Double]
) -> EndsReason? {
    guard let judged else { return nil }
    if cools { return .cooldown }
    if judged.outOfLine && outOfLineBefore + 1 >= AffinityRules.outOfLinePerConversation {
        return .outOfLine
    }
    if lately(hurtBefore + [judged.hurt]) >= AffinityRules.fedUpAt { return .fedUp }
    return nil
}

/// Whether she warns that she will not want to talk any more should it go on.
public func warns(
    judged: Judged?,
    cools: Bool,
    outOfLineBefore: Int,
    hurtBefore: [Double]
) -> Bool {
    guard judged != nil, !cools else { return false }
    if ends(judged: judged, cools: cools, outOfLineBefore: outOfLineBefore, hurtBefore: hurtBefore) != nil {
        return false
    }
    return lately(hurtBefore) < AffinityRules.warnsAt
        && lately(hurtBefore + [judged!.hurt]) >= AffinityRules.warnsAt
}

private func lately(_ hurts: [Double]) -> Double {
    hurts.suffix(AffinityRules.fedUpTurns).reduce(0, +)
}

/// The prompt lines about how she feels toward the producer, ported from upstream
/// `affinity.affinity_prompt`.
public enum AffinityPrompt {
    static let inHerOwnWay = "请按你自己的性格和口吻表现出来。"

    static let tierPrompts: [AffinityTier: String] = [
        .cold: "你现在对制作人态度很冷：话很少，客气而有距离；不主动找话题，不开玩笑也不撒娇；"
            + "对方关心你，你也只是淡淡地回应。但你仍然有礼貌，不说伤人的话。",
        .distant: "你现在对制作人有点生气或失望，比平时冷一些：回应偏短，不太主动关心对方；"
            + "不过对方好好说话时，你还是会接话。",
        .close: "你现在和制作人比平时更近：更放松，更愿意说心里话，更主动关心对方，玩笑也多一些。",
        .intimate: "你现在非常信赖制作人：会说出平时不轻易说的心事，流露出对对方的依赖，"
            + "对制作人的事格外上心。",
    ]

    static let fondness: [AffinityTier: String] = [
        .close: "偶尔可以轻轻带一句想念，隔得久了也可以嗔怪制作人好久没来找你。",
        .intimate: "可以明着撒娇：说想制作人、一直在等，隔得久了也可以嗔怪对方好久没来。",
    ]

    static let sweetWithinBounds = "撒娇也要照你的人设，不要变得不像你；上一次主动找制作人或回复时已经抱怨过，这次就别再抱怨。"
        + "不要说难过得哭了，不要让制作人保证常来，也不要拿什么要挟。"

    static let whateverTheTier = "无论现在关系怎样，人设里的硬性规则照旧；一起经历过的事和你们在事务所里的关系都不会改变。"
        + "如果想不起具体是因为什么，就不要编造原因。"

    static let feelings: [String?] = [
        "制作人刚才说的话伤到了你。",
        "制作人刚才说的话让你有点不舒服。",
        nil,
        "制作人刚才说的话让你有点开心。",
        "制作人刚才说的话让你很开心，觉得被在意。",
    ]

    static let outOfLineFeeling = "制作人刚才说的话让你很受伤、很生气；你可以明确表示不能接受。"

    static let warnings: [Parting: String] = [
        .parts: "你快受不了了。先回应，再用你自己的方式表明：制作人再这样下去你就不想聊了。",
        .hangsUp: "你快受不了了。先回应，再用你自己的方式表明：制作人再这样下去你就要挂电话了。",
    ]

    static let partings: [Parting: String] = [
        .parts: "这句话之后你暂时不想再和制作人说话了。先回应，再用你自己的方式表明你现在不想聊下去。",
        .hangsUp: "说完这句你就挂断电话。先回应，再用你自己的方式表明你要挂电话了。",
    ]

    public static func lines(
        tier: AffinityTier,
        judged: Judged?,
        parting: Parting? = nil,
        warning: Parting? = nil
    ) -> [String] {
        var lines: [String] = []
        if tier != .trust {
            lines.append(tierPrompts[tier]! + inHerOwnWay)
            if let fondness = fondness[tier] {
                lines.append(fondness + sweetWithinBounds)
            }
            lines.append(whateverTheTier)
        }
        if let feeling = judged?.feeling {
            lines.append(feeling)
        }
        if let parting {
            lines.append(partings[parting]!)
        } else if let warning {
            lines.append(warnings[warning]!)
        }
        return lines
    }
}
