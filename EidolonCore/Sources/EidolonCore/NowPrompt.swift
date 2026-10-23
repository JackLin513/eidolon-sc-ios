import Foundation

/// The prompt section about now, ported from upstream `producer.now_prompt`: the time where
/// the producer is, how they are talking, when they last were in touch, their birthday, and
/// how she feels toward them (`AffinityPrompt.lines`).
public enum NowPrompt {
    public enum Talking: Sendable {
        case typing
        case inCall
        case apart

        var text: String {
            switch self {
            case .typing:
                "制作人正在用文字和你聊天，你们没有在打电话；不想聊的时候就说不想聊，不要说挂电话或挂断。"
            case .inCall:
                "制作人正在和你打电话。"
            case .apart:
                "你们这会儿没在说话。"
            }
        }
    }

    private static let weekdays = "一二三四五六日"

    public static func text(
        now: Date,
        timeZone: TimeZone,
        talking: Talking,
        affinityLines: [String],
        lastContact: Date?,
        birthday: (month: Int, day: Int)?
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let weekdayIndex = ((parts.weekday ?? 1) + 5) % 7 // 1=Sunday -> 日, 2 -> 一, …
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)

        var lines = [
            "# 此刻",
            "现在是 \(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
                + "（星期\(String(weekdays[weekdays.index(weekdays.startIndex, offsetBy: weekdayIndex)]))）"
                + "\(clock)（制作人所在时区 \(timeZone.identifier)）。",
            talking.text,
        ]
        if let lastContact {
            let then = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: lastContact)
            let year = (then.year ?? 0) != (parts.year ?? 0) ? "\(then.year ?? 0)年" : ""
            let stamp = String(format: "%02d:%02d", then.hour ?? 0, then.minute ?? 0)
            lines.append(
                "上次和制作人说话是 \(year)\(then.month ?? 0)月\(then.day ?? 0)日 \(stamp)，"
                    + "隔了 \(howLong(now.timeIntervalSince(lastContact)))。"
            )
        }
        if let birthday, isBirthday(birthday, now: now, timeZone: timeZone) {
            lines.append(
                talking == .apart
                    ? "今天是制作人的生日。今天还没祝福过的话，用你自己的方式祝福一次。"
                    : "今天是制作人的生日。请在合适的时候用你自己的方式祝福一次：先回应制作人说的话，不要每句都提。"
            )
        }
        lines += affinityLines
        return lines.joined(separator: "\n")
    }

    /// In minutes under an hour, in hours under two days, else days.
    static func howLong(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "不到 1 分钟" }
        if minutes < 60 { return "\(minutes) 分钟" }
        if minutes < 48 * 60 { return "\(minutes / 60) 小时" }
        return "\(Int(seconds / 86_400)) 天"
    }

    /// February 29 falls on February 28 in a year that has no February 29.
    static func isBirthday(_ birthday: (month: Int, day: Int), now: Date, timeZone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.dateComponents([.month, .day, .year], from: now)
        if birthday.month == today.month && birthday.day == today.day { return true }
        let isLeap = calendar.range(of: .day, in: .year, for: now).map { $0.count > 365 } ?? false
        return birthday.month == 2 && birthday.day == 29
            && today.month == 2 && today.day == 28 && !isLeap
    }
}
