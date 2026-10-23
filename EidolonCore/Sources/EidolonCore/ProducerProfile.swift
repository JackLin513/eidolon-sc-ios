import Foundation

/// The producer profile and the prompt section about them, ported from upstream
/// `producer.py`. Only the parts v1 uses: form of address, gender, time zone and
/// birthday; a field left unset keeps upstream's default.
public struct ProducerProfile: Sendable, Hashable {
    public enum Gender: String, Sendable, Hashable {
        case male
        case female
    }

    public var formOfAddress: String?
    public var gender: Gender?
    public var timezone: String?
    public var birthdayMonth: Int?
    public var birthdayDay: Int?

    public init(
        formOfAddress: String? = nil,
        gender: Gender? = nil,
        timezone: String? = nil,
        birthdayMonth: Int? = nil,
        birthdayDay: Int? = nil
    ) {
        self.formOfAddress = formOfAddress
        self.gender = gender
        self.timezone = timezone
        self.birthdayMonth = birthdayMonth
        self.birthdayDay = birthdayDay
    }

    public static let `default` = ProducerProfile()

    /// Her birthday when the profile has one.
    public var birthday: (month: Int, day: Int)? {
        guard let month = birthdayMonth, let day = birthdayDay else { return nil }
        return (month, day)
    }

    /// The prompt section about the user: who they are, the same from turn to turn.
    public var prompt: String {
        var lines = ["# 制作人", "和你对话的是你的制作人，也就是 283 事务所的制作人。"]
        if let formOfAddress, !formOfAddress.isEmpty {
            lines.append(
                "制作人希望你称呼对方为「\(formOfAddress)」。这只是叫法，"
                    + "对方仍然是你的制作人；请按你自己的性格和习惯，在合适的时候这样称呼。"
            )
        }
        switch gender {
        case .male?:
            lines.append(
                "制作人是男性。这只影响你现在怎么对待对方；"
                    + "回忆原作剧情时，剧情中发生过的事保持原样，不要改写。"
            )
        case .female?:
            lines.append(
                "制作人是女性。这只影响你现在怎么对待对方；"
                    + "回忆原作剧情时，剧情中发生过的事保持原样，不要改写。"
            )
        case nil:
            lines.append("制作人是男性，和原作一致。")
        }
        if let month = birthdayMonth, let day = birthdayDay {
            lines.append(
                "制作人的生日是\(month)月\(day)日，"
                    + "这是制作人自己在档案里填的；记忆里如果有不一样的说法，以这里为准。"
                    + "被问起时可以回答，平时不要主动提起。"
            )
        }
        return lines.joined(separator: "\n")
    }
}
