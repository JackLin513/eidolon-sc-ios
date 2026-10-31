import Foundation

/// How one turn changed her affinity (spec #38, upstream `AffinityChange`): up or down,
/// whether that crossed a tier, which tier it left her in, and whether she went into a
/// cooldown. Kept with her reply so the transcript can say it after the fact.
public struct AffinityChange: Sendable, Hashable {
    public var up: Bool
    public var tierChanged: Bool
    public var tier: AffinityTier
    public var cooldown: Bool

    public init(up: Bool, tierChanged: Bool, tier: AffinityTier, cooldown: Bool) {
        self.up = up
        self.tierChanged = tierChanged
        self.tier = tier
        self.cooldown = cooldown
    }

    /// The one sentence the transcript, the badge and the call's status line show: what
    /// came first wins — a cooldown, then a new tier, then the same tier's feeling.
    public func text(name: String) -> String {
        if cooldown {
            return "\(name)现在不想说话了"
        }
        if tierChanged {
            return up
                ? "和\(name)更近了一步：\(tier.title)"
                : "\(name)和你疏远了一些：\(tier.title)"
        }
        return up ? "\(name)有点开心" : "\(name)有点不高兴"
    }
}
