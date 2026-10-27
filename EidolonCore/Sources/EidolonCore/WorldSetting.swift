import Foundation

/// The world setting shipped in the bundle (`characters/world.json`), rendered as the
/// prompt section upstream's `world.py` renders. The port is deliberate and literal:
/// the text is part of the persona's behaviour, so it has to match upstream word for
/// word (ADR-0004).
public struct WorldSetting: Codable, Sendable {
    public struct Staff: Codable, Sendable, Hashable {
        public var name: String
        public var reading: String
        public var position: String
    }

    public struct Unit: Codable, Sendable, Hashable {
        public var name: String
        public var reading: String?
        public var members: [String]
    }

    public struct Idol: Codable, Sendable, Hashable {
        public var name: String
        public var reading: String
        public var unit: String?
        public var cv: String?

        enum CodingKeys: String, CodingKey {
            case name, reading, unit, cv
        }
    }

    public struct Track: Codable, Sendable, Hashable {
        public var title: String
        public var song: String?
    }

    public struct Release: Codable, Sendable, Hashable {
        public var catalog: String
        public var title: String
        public var date: String
        public var tracks: [Track]
    }

    public struct Song: Codable, Sendable, Hashable {
        public var id: String
        public var title: String
        public var singers: [String]
        public var specialUnit: String?
        public var releases: [String]

        enum CodingKeys: String, CodingKey {
            case id, title, singers
            case specialUnit = "special_unit"
            case releases
        }
    }

    public struct SetlistItem: Codable, Sendable, Hashable {
        public var title: String
        public var singers: [String]
        public var dancers: [String]
        public var brand: String?

        enum CodingKeys: String, CodingKey {
            case title, singers, dancers, brand
        }

        public init(title: String, singers: [String] = [], dancers: [String] = [], brand: String? = nil) {
            self.title = title
            self.singers = singers
            self.dancers = dancers
            self.brand = brand
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            title = try container.decode(String.self, forKey: .title)
            singers = try container.decodeIfPresent([String].self, forKey: .singers) ?? []
            dancers = try container.decodeIfPresent([String].self, forKey: .dancers) ?? []
            brand = try container.decodeIfPresent(String.self, forKey: .brand)
        }
    }

    public struct LiveDay: Codable, Sendable, Hashable {
        public var date: String
        public var venue: String
        public var performers: [String]
        public var absent: [String]?
        /// What was performed that day, in order; empty if it is not known (a day still
        /// to come, or one of two shows). Upstream `LiveDay.setlist`.
        public var setlist: [SetlistItem]?

        public init(
            date: String,
            venue: String,
            performers: [String],
            absent: [String]? = nil,
            setlist: [SetlistItem]? = nil
        ) {
            self.date = date
            self.venue = venue
            self.performers = performers
            self.absent = absent
            self.setlist = setlist
        }
    }

    public struct Live: Codable, Sendable, Hashable {
        public var name: String
        public var days: [LiveDay]
    }

    struct Office: Codable, Sendable, Hashable {
        public var name: String
        public var staff: [Staff]
    }

    public var asOf: String
    var office: Office
    public var units: [Unit]
    public var idols: [Idol]
    public var releases: [Release]
    public var songs: [Song]
    public var lives: [Live]

    enum CodingKeys: String, CodingKey {
        case asOf = "as_of"
        case office, units, idols, releases, songs, lives
    }

    public init(json data: Data) throws {
        do {
            self = try JSONDecoder().decode(WorldSetting.self, from: data)
        } catch {
            throw EidolonError.invalidContent("world.json 无法解析：\(error.localizedDescription)")
        }
    }

    // MARK: - What a character is

    public func idol(_ name: String) -> Idol? {
        idols.first { $0.name == name }
    }

    public func isStaff(_ name: String) -> Bool {
        idol(name) == nil && office.staff.contains { $0.name == name }
    }

    /// The others in her unit, by name; none if she is in none (upstream `unit_mates`).
    public func unitMates(of name: String) -> [String] {
        guard let idol = idol(name),
              let unit = units.first(where: { $0.name == idol.unit })
        else { return [] }
        return unit.members.filter { $0 != name }
    }

    // MARK: - Prompt

    /// The world setting as a turn on `today` (an ISO `YYYY-MM-DD` day) with the
    /// character called `name` carries it.
    public func prompt(name: String, today: String) -> String {
        if isStaff(name) {
            return settingPrompt(staff: true)
        }
        return [settingPrompt(staff: false), songsPrompt(name, today), livesPrompt(name, today)]
            .joined(separator: "\n\n")
    }

    private func settingPrompt(staff: Bool) -> String {
        var lines = [
            "# 世界设定",
            "以下是你所在的\(office.name)的基本情况，资料截止到 \(WorldSetting.formatDay(asOf))。",
            "",
        ]
        for person in office.staff {
            let reading = person.reading.isEmpty ? "" : "（\(person.reading)）"
            lines.append("\(person.position)：\(person.name)\(reading)")
        }
        lines += ["", "事务所的组合和成员（每位偶像只属于一个组合）："]
        for unit in units {
            let reading = unit.reading.map { "（\($0)）" } ?? ""
            lines.append("- \(unit.name)\(reading)：\(unit.members.joined(separator: "、"))")
        }
        lines += [
            "",
            "关于作品里的事实：",
            "- 歌曲、唱片、演出，上面的资料里查不到的，就老实说一时想不起来；"
                + "既不说「没有这回事」，也不顺着对方的说法附和、编下去。",
            "- 不引用歌词，也不编造歌词。被要求唱或念歌词时，用你自己的方式岔开，"
                + (staff ? "比如说那是偶像们的歌，想听就去听她们唱。" : "比如说想在舞台上唱给他听。"),
            "- 关于演出，你只知道名称、日期、会场、出演者和曲目这类事实，不编造台上发生了什么（MC、现场的情节等）。",
            "- 不谈论声优，也不知道「中の人」这回事；被问到时按你自己的性格应对，不说出任何人的名字。",
            "- 不谈论具体的周边商品（立牌、徽章之类），被问到时按你自己的性格应对，不编造商品。",
            "- \(WorldSetting.formatDay(asOf))以后的事（新的歌曲、唱片、演出、新来的偶像等）你一概不知道，被问到就说还没听说。",
        ]
        return lines.joined(separator: "\n")
    }

    private func songsPrompt(_ name: String, _ today: String) -> String {
        let songs = songsOf(name)
        var lines = ["# 你的歌"]
        guard !songs.isEmpty else {
            lines.append("资料里还没有你唱的歌。")
            return lines.joined(separator: "\n")
        }
        lines.append(
            "下面是你一个人唱的歌，和你所在的组合全员一起唱的歌，以及收录它们的唱片。"
                + "别的偶像的歌、特别组合或者全体一起唱的歌不在这里。"
        )
        let releasesByCatalog = Dictionary(uniqueKeysWithValues: releases.map { ($0.catalog, $0) })
        for song in songs {
            let on = song.releases.compactMap { catalog -> String? in
                guard let release = releasesByCatalog[catalog] else { return nil }
                let coming = release.date > today ? "将于" : ""
                return "《\(release.title)》（\(coming)\(WorldSetting.formatDay(release.date))发售）"
            }
            lines.append(on.isEmpty ? "- \(song.title)" : "- \(song.title)：\(on.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    private func songsOf(_ name: String) -> [Song] {
        let unit = officeUnit(of: name).flatMap { name in units.first { $0.name == name } }
        var wanted: [Set<String>] = [Set([name])]
        if let unit { wanted.append(Set(unit.members)) }
        return songs.filter { song in
            song.specialUnit == nil && wanted.contains(Set(song.singers))
        }
    }

    private func officeUnit(of name: String) -> String? {
        idol(name)?.unit
    }

    private func livesPrompt(_ name: String, _ today: String) -> String {
        let lives = livesOf(name)
        var lines = ["# 你上过的演出"]
        guard !lives.isEmpty else {
            lines.append("资料里还没有你站上过的舞台。")
            return lines.joined(separator: "\n")
        }
        lines.append(
            "下面是你站上过的舞台，和已经定下、你将要站上的舞台，按演出日列出日期和会场。"
                + "你没有上台的演出和日子不在这里：那些演出你可能知道，但你没有站上去。"
        )
        for (live, days) in lives {
            var runs: [(venue: String, whens: [String])] = []
            for day in days {
                let when = (day.date > today ? "将于" : "") + WorldSetting.formatDay(day.date)
                if !runs.isEmpty, runs[runs.count - 1].venue == day.venue {
                    runs[runs.count - 1].whens.append(when)
                } else {
                    runs.append((day.venue, [when]))
                }
            }
            let on = runs.map { "\($0.whens.joined(separator: "、"))（\($0.venue)）" }
            lines.append("- \(live.name)：\(on.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    /// The lives `name` stood on, each with the days of it she performed (upstream
    /// `World.lives_of`).
    func livesOf(_ name: String) -> [(Live, [LiveDay])] {
        lives.compactMap { live in
            let days = live.days.filter { $0.performers.contains(name) }
            return days.isEmpty ? nil : (live, days)
        }
    }

    /// `2026-10-21` as upstream's `_day` writes it: `2026年10月21日`.
    static func formatDay(_ iso: String) -> String {
        let parts = iso.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return iso }
        return "\(year)年\(month)月\(day)日"
    }
}

extension WorldSetting {
    /// One of the work facts: a song, a release or a live day (upstream `World.entries`).
    public struct Entry: Sendable, Hashable {
        public var kind: String
        public var title: String
        public var text: String
    }

    /// What retrieval searches in the world setting. Setlists are left out.
    public func entries() -> [Entry] {
        var found: [Entry] = []
        let releasesByCatalog = Dictionary(uniqueKeysWithValues: releases.map { ($0.catalog, $0) })
        for song in songs {
            var lines = ["歌曲「\(song.title)」", "演唱：\(singers(song))"]
            let on = song.releases.compactMap { catalog -> String? in
                guard let release = releasesByCatalog[catalog] else { return nil }
                return "《\(release.title)》（\(WorldSetting.formatDay(release.date))发售）"
            }
            if !on.isEmpty { lines.append("收录于：\(on.joined(separator: "、"))") }
            found.append(Entry(kind: "song", title: lines[0], text: lines.joined(separator: "\n")))
        }
        for release in releases {
            var lines = ["唱片《\(release.title)》（\(release.catalog)）",
                         "发售日：\(WorldSetting.formatDay(release.date))"]
            if !release.tracks.isEmpty {
                lines.append("曲目：")
                lines += release.tracks.enumerated().map { "\($0.offset + 1). \($0.element.title)" }
            }
            found.append(Entry(kind: "release", title: lines[0], text: lines.joined(separator: "\n")))
        }
        for live in lives {
            for day in live.days {
                let performers = day.performers.isEmpty
                    ? "（资料里没有记录）"
                    : day.performers.joined(separator: "、")
                var lines = [
                    "演出「\(live.name)」",
                    "日期：\(WorldSetting.formatDay(day.date))",
                    "会场：\(day.venue)",
                    "出演偶像：\(performers)",
                ]
                if let setlist = day.setlist, !setlist.isEmpty {
                    lines.append("曲目单（标着别的品牌的是翻唱，不是闪耀色彩的歌）：")
                    lines += setlist.enumerated().map { index, item in
                        "\(index + 1). \(setlistLine(item, day: day))"
                    }
                }
                found.append(Entry(
                    kind: "live",
                    title: lines[0] + WorldSetting.formatDay(day.date),
                    text: lines.joined(separator: "\n")
                ))
            }
        }
        return found
    }

    /// One setlist item as upstream `_setlist_line` writes it: its title, the brand it
    /// covers if it is one, and who sang or danced to it.
    private func setlistLine(_ item: SetlistItem, day: LiveDay) -> String {
        let line = item.title + (item.brand.map { "（\($0)的歌）" } ?? "")
        var who: [String] = []
        if !item.singers.isEmpty {
            who.append("\(saidWho(item.singers, day: day))演唱")
        }
        if !item.dancers.isEmpty {
            who.append("\(saidWho(item.dancers, day: day))伴舞，没有演唱")
        }
        return who.isEmpty
            ? "\(line)：资料里没能确定是谁演唱"
            : "\(line)：\(who.joined(separator: "；"))"
    }

    /// `idols` as briefly as they can be named (upstream `_who`): everyone on the day, one
    /// or two whole units, everyone but one or two, or the whole units among them and then
    /// the rest.
    private func saidWho(_ idols: [String], day: LiveDay) -> String {
        var rest = idols
        var names: [String] = []
        for unit in units where unit.members.count > 1 && Set(unit.members).isSubset(of: Set(rest)) {
            names.append(unit.name)
            rest.removeAll { unit.members.contains($0) }
        }
        let leftOut = day.performers.filter { !idols.contains($0) }
        let severalOnStage = idols.count > 1 && Set(idols).isSubset(of: Set(day.performers))
        if severalOnStage && leftOut.isEmpty { return "全体出演偶像" }
        if rest.isEmpty && names.count <= 2 { return names.joined(separator: "、") }
        if severalOnStage && leftOut.count < min(3, idols.count) {
            return "除\(leftOut.joined(separator: "、"))以外的全体出演偶像"
        }
        return (names + rest).joined(separator: "、")
    }

    private func singers(_ song: Song) -> String {
        let idols = song.singers.joined(separator: "、")
        if let special = song.specialUnit { return "\(special)（\(idols)）" }
        let unit = units.first { Set($0.members) == Set(song.singers) }
        return unit.map { "\($0.name)（\(idols)）" } ?? idols
    }
}
