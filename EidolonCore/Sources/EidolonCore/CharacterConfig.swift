import Foundation

/// One entry of `characters/characters.json`. The exporter normalises the
/// upstream TOML and rewrites file paths to be relative to the bundle root
/// (for example `characters/sheets/mano.md`).
public struct CharacterConfig: Sendable, Hashable {
    public var id: String
    public var name: String
    public var intro: String?
    public var nameZh: String?
    public var nameKana: String?
    public var nameRomaji: String?
    public var unit: String?
    public var color: String?
    public var voiceID: String?
    public var sheet: String?
    public var facts: String?
    public var avatar: String?
    public var background: String?
    public var speakers: [String]
    public var idolID: Int?
    /// Her default outfit and outfit list, when the bundle carries her stand.
    public var stand: StandConfig?
    public var birthday: Birthday?
    public var raw: [String: JSONValue]

    public init(
        id: String,
        name: String,
        intro: String? = nil,
        nameZh: String? = nil,
        nameKana: String? = nil,
        nameRomaji: String? = nil,
        unit: String? = nil,
        color: String? = nil,
        voiceID: String? = nil,
        sheet: String? = nil,
        facts: String? = nil,
        avatar: String? = nil,
        background: String? = nil,
        speakers: [String] = [],
        idolID: Int? = nil,
        stand: StandConfig? = nil,
        birthday: Birthday? = nil,
        raw: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.intro = intro
        self.nameZh = nameZh
        self.nameKana = nameKana
        self.nameRomaji = nameRomaji
        self.unit = unit
        self.color = color
        self.voiceID = voiceID
        self.sheet = sheet
        self.facts = facts
        self.avatar = avatar
        self.background = background
        self.speakers = speakers
        self.idolID = idolID
        self.stand = stand
        self.birthday = birthday
        self.raw = raw
    }

    public init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw EidolonError.invalidContent("角色条目不是 JSON 对象")
        }
        guard let id = object["id"]?.stringValue, !id.isEmpty else {
            throw EidolonError.invalidContent("角色条目缺少 id")
        }
        guard let name = object["name"]?.stringValue, !name.isEmpty else {
            throw EidolonError.invalidContent("角色 \(id) 缺少 name")
        }
        let birthdayText = object["birthday"]?.stringValue
        guard let birthdayText, let birthday = Birthday(birthdayText) else {
            throw EidolonError.invalidContent(
                "角色 \(id) 的生日应为 MM-DD 格式、一年中有的一天（例如 \"04-25\"），现在是 "
                    + (birthdayText.map { "\"\($0)\"" } ?? "（缺）")
            )
        }
        let idolID = object["idol_id"]?.intValue
        if let idolID, idolID <= 0 {
            throw EidolonError.invalidContent(
                "角色 \(id) 的偶像编号应为正整数，现在是 \(idolID)"
            )
        }
        let stand: StandConfig?
        if let value = object["stand"], value != .null {
            stand = try StandConfig(json: value, characterID: id)
        } else {
            stand = nil
        }
        self.init(
            id: id,
            name: name,
            intro: object["intro"]?.stringValue,
            nameZh: object["name_zh"]?.stringValue,
            nameKana: object["name_kana"]?.stringValue,
            nameRomaji: object["name_romaji"]?.stringValue,
            unit: object["unit"]?.stringValue,
            color: object["color"]?.stringValue,
            voiceID: object["voice_id"]?.stringValue,
            sheet: object["sheet"]?.stringValue,
            facts: object["facts"]?.stringValue,
            avatar: object["avatar"]?.stringValue,
            background: object["background"]?.stringValue,
            speakers: object["speakers"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            idolID: idolID,
            stand: stand,
            birthday: birthday,
            raw: object
        )
    }
}

extension CharacterConfig {
    /// The line under her name in the list: the first alias there is, else her unit.
    public var subtitle: String {
        [nameZh, nameKana, nameRomaji].compactMap { $0 }.first ?? unit ?? ""
    }

    /// Search across every name she can be found by, her unit and her intro.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return true }
        return [name, nameZh ?? "", nameKana ?? "", nameRomaji ?? "", unit ?? "", intro ?? ""]
            .joined(separator: " ")
            .lowercased()
            .contains(needle)
    }
}

/// What the character list shows under her name: the latest message and whether
/// she has an unseen reach-out.
public struct LatestActivity: Sendable, Hashable {
    public var lastMessagePreview: String?
    public var lastMessageRole: String?
    public var lastMessageAt: String?
    public var unseenReachOut: Bool

    public init(
        lastMessagePreview: String? = nil,
        lastMessageRole: String? = nil,
        lastMessageAt: String? = nil,
        unseenReachOut: Bool = false
    ) {
        self.lastMessagePreview = lastMessagePreview
        self.lastMessageRole = lastMessageRole
        self.lastMessageAt = lastMessageAt
        self.unseenReachOut = unseenReachOut
    }
}
