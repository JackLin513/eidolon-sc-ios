import Foundation
import GRDB

/// Which page a card of the play page opens (spec #94).
public enum PlayCardKind: String, Sendable, Hashable {
    case gifts
    case achievements
    case calendar
    case cycles
    case bar
}

/// One card of the play page: its name and the line under it, read before the page opens.
public struct PlayCardStatus: Sendable, Hashable, Identifiable {
    public let kind: PlayCardKind
    public let title: String
    public let status: String
    /// Whether the card has something the producer has not looked at.
    public let isNew: Bool

    public var id: String { kind.rawValue }

    public init(kind: PlayCardKind, title: String, status: String, isNew: Bool) {
        self.kind = kind
        self.title = title
        self.status = status
        self.isNew = isNew
    }
}

/// The play page's cards in the order it shows them.
public struct PlaySummary: Sendable, Hashable {
    public let cards: [PlayCardStatus]

    public init(cards: [PlayCardStatus]) {
        self.cards = cards
    }
}

extension Eidolon {
    /// The five cards' status, read once when the play page opens (spec #94).
    public func playSummary(now: Date = Date(), timeZone: TimeZone = .current) throws -> PlaySummary {
        let badges = try playBadges()
        let gifts = try giftState(at: now)
        let characters = try characters()

        var cards: [PlayCardStatus] = [
            PlayCardStatus(
                kind: .gifts,
                title: "礼物",
                status: Self.giftStatus(gifts),
                isNew: badges.gifts
            ),
            PlayCardStatus(
                kind: .achievements,
                title: "成就",
                status: badges.unseenStages > 0
                    ? "\(badges.unseenStages) 个新解锁"
                    : "已解锁 \(badges.unlockedStages) 个阶段",
                isNew: badges.achievements
            ),
            PlayCardStatus(
                kind: .calendar,
                title: "日历",
                status: try calendarStatus(
                    now: now, timeZone: timeZone, characters: characters
                ),
                isNew: false
            ),
        ]

        if try cycleEnabled() {
            cards.append(
                PlayCardStatus(
                    kind: .cycles,
                    title: "她的周期",
                    status: try cycleStatus(characters: characters),
                    isNew: false
                )
            )
        }

        let bar: String
        if try installedBarInfo() == nil {
            bar = "还没有导入酒吧素材包，进设置导入"
        } else if try barRewardToday(now: now) {
            bar = "今天第一次光顾有奖励"
        } else {
            bar = "今天的奖励领过了"
        }
        cards.append(PlayCardStatus(kind: .bar, title: "酒吧", status: bar, isNew: false))

        return PlaySummary(cards: cards)
    }

    private static func giftStatus(_ state: GiftState) -> String {
        if state.catalogMissing { return "内容包没有礼物目录" }
        var parts = ["还有 \(state.draws) 次抽奖"]
        let items = state.backpack.reduce(0) { $0 + $1.count }
        if items > 0 { parts.append("背包 \(items) 件") }
        if state.resetCards > 0 { parts.append("重置卡 \(state.resetCards) 张") }
        return parts.joined(separator: " · ")
    }

    /// The calendar card: this week's unscheduled work, then the next event from today
    /// (upstream `playCards`'s calendar status).
    private func calendarStatus(
        now: Date, timeZone: TimeZone, characters: [CharacterConfig]
    ) throws -> String {
        let overview = try scheduleOverview(now: now, timeZone: timeZone)
        var parts: [String] = []
        if overview.pendingThisWeek > 0 {
            parts.append("本周还有 \(overview.pendingThisWeek) 项工作待排")
        }

        let today = CalendarPage.today(now: now, timeZone: timeZone)
        let producer = try producerProfile()
        let holidays = try? holidayTable()
        let birthday = producer.birthday
        var month = CalendarPage.Month(
            year: today.year, month: today.month, timeZone: timeZone
        )
        // A birthday, holiday or job is at most a year away; one extra month covers a
        // February 29 that falls on the 28th.
        for _ in 0..<13 {
            let events = CalendarPage.events(
                in: month,
                characters: characters,
                producerBirthday: birthday,
                holidays: holidays,
                schedule: overview.entries
            )
            if let event = events.first(where: { $0.day >= today }) {
                let what = Self.eventText(event)
                if event.day == today {
                    parts.append("今天：\(what)")
                } else {
                    parts.append("下一个：\(event.day.month)月\(event.day.day)日 \(what)")
                }
                break
            }
            month = month.next()
        }
        return parts.joined(separator: " · ")
    }

    private static func eventText(_ event: CalendarEvent) -> String {
        switch event.kind {
        case .character: "\(event.title)的生日"
        default: event.title
        }
    }

    /// The cycle card: how many were written down and whose latest record is newest. One
    /// read for every character, rather than a query per character.
    private func cycleStatus(characters: [CharacterConfig]) throws -> String {
        let rows = try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT character_id, MAX(first_day) AS latest
                    FROM cycle_records GROUP BY character_id
                    """
            )
        }
        guard !rows.isEmpty else {
            return "还没有记录。只记最近一次经期的第一天和天数，就会开始推算。"
        }
        let names = Dictionary(uniqueKeysWithValues: characters.map { ($0.id, $0.name) })
        var latest: (name: String, day: CalendarDay)?
        for row in rows {
            let characterID: String = row["character_id"]
            let day = CalendarDay.parse(row["latest"])
            if let current = latest, day <= current.day { continue }
            latest = (names[characterID] ?? characterID, day)
        }
        guard let latest else {
            return "还没有记录。只记最近一次经期的第一天和天数，就会开始推算。"
        }
        return "记过 \(rows.count) 位 · 最近 \(latest.name) \(latest.day.month)月\(latest.day.day)日"
    }
}

private extension CalendarDay {
    /// A `yyyy-MM-dd` stamp as the cycle records write it.
    static func parse(_ stamp: String) -> CalendarDay {
        let parts = stamp.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return CalendarDay(year: 0, month: 1, day: 1) }
        return CalendarDay(year: parts[0], month: parts[1], day: parts[2])
    }
}
