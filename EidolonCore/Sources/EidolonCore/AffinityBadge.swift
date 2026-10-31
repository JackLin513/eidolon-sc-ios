import Foundation

/// The five hearts, as upstream draws them: crossed out, cracked, hollow, half filled,
/// filled (spec #38).
public enum AffinityHeart: Sendable, Hashable {
    case off
    case crack
    case outline
    case half
    case filled

}

/// What the badge under her name shows, and what its card explains (spec #38): the tier
/// with its heart and note, or the cooldown with when it ends. Copy is upstream's, less
/// the gift link (gifts are not in this version).
public struct AffinityBadge: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case tier(AffinityTier, AffinityHeart)
        case cooldown
    }

    public var kind: Kind
    /// What the badge itself writes: 「亲近」, or 「今天 21:40」.
    public var text: String
    /// What VoiceOver reads: 「你们的关系：亲近」 or 「X现在不想说话」.
    public var label: String
    /// The card's first line.
    public var title: String
    /// The card's explanation under its title.
    public var note: String

    public static func of(
        _ status: AffinityStatus,
        name: String,
        now: Date,
        timeZone: TimeZone = .current
    ) -> AffinityBadge {
        if let until = status.cooldownUntil {
            let untilText = AffinityCopy.untilText(until: until, now: now, timeZone: timeZone)
            let title = "\(name)现在不想说话"
            return AffinityBadge(
                kind: .cooldown,
                text: untilText,
                label: title,
                title: title,
                note: "\(untilText) 以后可以再找她。"
            )
        }
        let tier = status.tier
        return AffinityBadge(
            kind: .tier(tier, tier.heart),
            text: tier.title,
            label: "你们的关系：\(tier.title)",
            title: "你们现在的关系：\(tier.title)",
            note: AffinityCopy.notes[tier] ?? ""
        )
    }
}

/// The words the affinity UI uses, from upstream's `i18n/zh.ts` (spec #38).
public enum AffinityCopy {
    public static let tiersLabel = "五个档位"
    public static let rule = "她对你的态度会随你说的话变化。低于「信任」时，不联系也会慢慢回到「信任」。"

    public static let notes: [AffinityTier: String] = [
        .cold: "她对你明显冷淡，话很少。",
        .distant: "她有点生气或失望，比平时冷一些。",
        .trust: "你们一直以来的关系。",
        .close: "她比平时更放松，更愿意和你说心里话。",
        .intimate: "她非常信赖你，会说平时不轻易说的心事。",
    ]

    /// The cooldown's end as the producer's day writes it: 今天 or 明天, then `HH:mm`.
    /// A cooldown lasts at most a day, so those are the only two days there are.
    public static func untilText(until: Date, now: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: until)
        let end = calendar.startOfDay(for: until)
        let today = calendar.startOfDay(for: now)
        return (end == today ? "今天 " : "明天 ") + time
    }
}
