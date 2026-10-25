import Foundation

/// What she is told of the day it is in Tokyo, where she lives (upstream `today.py`): whether
/// it is her birthday, whose of the others' it is, which of Japan's holidays it is, and which
/// of the live days she stood on fell on it in years before, told as past. Each line is told
/// only on its day, after what she is told of now, in the same section, in a typed turn, a
/// call or a reach-out alike; nothing on a day that is none of them. The producer's own
/// birthday goes by their day, and is told by `NowPrompt`.
public enum TodayPrompt {
    /// The day she lives by: Tokyo's, whichever zone the producer is in.
    public static let tokyo = TimeZone(identifier: "Asia/Tokyo") ?? .current

    /// Her birthday as she always knows it, the same for every producer.
    public static func herBirthday(_ birthday: Birthday) -> String {
        "你的生日是\(birthday.month)月\(birthday.day)日。"
    }

    /// What `character` is told of the day it is in Tokyo at `now`: her birthday, the
    /// birthdays of the others among `characters` in idol order, the holiday, each if it is
    /// the day; then each of the days of `herLives` (`WorldSetting.livesOf`) on this day in
    /// a year before, earliest first.
    public static func lines(
        now: Date,
        character: CharacterConfig,
        characters: [CharacterConfig],
        herLives: [(WorldSetting.Live, [WorldSetting.LiveDay])],
        holidays: HolidayTable? = nil
    ) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tokyo
        let parts = calendar.dateComponents([.year, .month, .day], from: now)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0

        var lines: [String] = []
        if let birthday = character.birthday, isBirthday(birthday, now: now) {
            lines.append(
                "今天是你的生日。可以自然地提起一两次，不要每句都提；不向制作人要礼物；制作人祝福你就接受。"
            )
        }
        let others = idolOrder(characters)
            .filter { other in
                other.id != character.id
                    && other.birthday.map { isBirthday($0, now: now) } == true
            }
            .map(\.name)
        if !others.isEmpty {
            lines.append(
                "今天是\(others.joined(separator: "、"))的生日。可以顺口提一句，"
                    + "不要替她们向制作人要祝福，也不要催制作人做什么。"
            )
        }
        if let holiday = holidays?.name(year: year, month: month, day: day) {
            lines.append("今天是日本的节假日：\(holiday)。可以自然地提到，不必每句都说。")
        }
        lines += livesOnThisDay(year: year, month: month, day: day, herLives: herLives)
        return lines
    }

    // MARK: - Parts

    static func isBirthday(_ birthday: Birthday, now: Date) -> Bool {
        NowPrompt.isBirthday((birthday.month, birthday.day), now: now, timeZone: tokyo)
    }

    /// The characters in the order of their idol numbers in the original, those without one
    /// after them as given (upstream `characters.in_idol_order`). The sort falls back to the
    /// original position where numbers tie, as Python's stable sort does.
    static func idolOrder(_ characters: [CharacterConfig]) -> [CharacterConfig] {
        characters.enumerated()
            .sorted { left, right in
                let (a, b) = (left.element.idolID, right.element.idolID)
                if (a == nil) != (b == nil) { return a == nil }
                if a != b { return (a ?? 0) < (b ?? 0) }
                return left.offset < right.offset
            }
            .map(\.element)
    }

    /// A line for each of the days she stood on that fell on this month and day in a year
    /// before: told as past, with its year, so that she is not to take it for today.
    static func livesOnThisDay(
        year: Int,
        month: Int,
        day: Int,
        herLives: [(WorldSetting.Live, [WorldSetting.LiveDay])]
    ) -> [String] {
        struct Found {
            var when: Day
            var live: WorldSetting.Live
            var day: WorldSetting.LiveDay
            /// Where it came in `herLives`, to keep the original order on a tie.
            var order: Int
        }
        var found: [Found] = []
        for (live, days) in herLives {
            for when in days {
                guard let date = parseDay(when.date),
                      date.year < year,
                      date.month == month,
                      date.day == day
                else { continue }
                found.append(Found(when: date, live: live, day: when, order: found.count))
            }
        }
        found.sort { left, right in
            left.when == right.when ? left.order < right.order : left.when < right.when
        }
        return found.map { item in
            // Only a live with more than one day has a day number.
            let which: String
            if item.live.days.count > 1,
               let index = item.live.days.firstIndex(of: item.day) {
                which = "第\(index + 1)天"
            } else {
                which = ""
            }
            return "今天是\(year - item.when.year)年前你站上「\(item.live.name)」\(which)的日子"
                + "（\(item.when.year)年\(item.when.month)月\(item.when.day)日，\(item.day.venue)）。"
                + "那是过去的事，今天没有这场演出；可以当回忆顺口提一句，不要说成今天的事。"
        }
    }

    /// An ISO `YYYY-MM-DD` day, as the world setting writes dates.
    struct Day: Comparable {
        var year: Int
        var month: Int
        var day: Int

        static func < (left: Day, right: Day) -> Bool {
            (left.year, left.month, left.day) < (right.year, right.month, right.day)
        }
    }

    static func parseDay(_ iso: String) -> Day? {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        return Day(year: year, month: month, day: day)
    }
}
