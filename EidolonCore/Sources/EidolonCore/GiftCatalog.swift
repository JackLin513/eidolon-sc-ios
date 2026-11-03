import Foundation

/// What a gift is (GLOSSARY.md「礼物」): food, drink, flowers or a small thing.
public enum GiftCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case food
    case drink
    case flower
    case trinket

    public var title: String {
        switch self {
        case .food: "吃的"
        case .drink: "饮品"
        case .flower: "花草"
        case .trinket: "小物件"
        }
    }
}

/// How rare a gift is; a draw's odds and the affinity it raises follow this.
public enum GiftRarity: String, Codable, Sendable, CaseIterable, Hashable {
    case common
    case uncommon
    case rare

    public var title: String {
        switch self {
        case .common: "普通"
        case .uncommon: "少见"
        case .rare: "稀有"
        }
    }
}

/// One gift in the catalog. Its identifier is also its illustration's file name in the
/// content bundle (`gifts/<id>.webp`).
public struct Gift: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var category: GiftCategory
    public var rarity: GiftRarity
    /// No draw gives it any more; whoever has one still sees it and can give it.
    public var retired: Bool
    /// More welcome during her period and the days before it. Never shown as a reason.
    public var warm: Bool

    public init(
        id: String,
        name: String,
        category: GiftCategory,
        rarity: GiftRarity,
        retired: Bool = false,
        warm: Bool = false
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.rarity = rarity
        self.retired = retired
        self.warm = warm
    }

    public init(json: JSONValue) throws {
        guard let object = json.objectValue else {
            throw EidolonError.invalidBundle("礼物目录里的条目应当是对象")
        }
        let label = object["id"]?.stringValue ?? "（没有标识）"
        for field in ["id", "name", "category", "rarity"] where object[field] == nil {
            throw EidolonError.invalidBundle("礼物 \(label) 缺少 \(field)")
        }
        guard let id = object["id"]?.stringValue, isShortIdentifier(id) else {
            throw EidolonError.invalidBundle(
                "礼物标识 \(label) 只能用小写字母、数字、- 和 _"
            )
        }
        guard let name = object["name"]?.stringValue,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw EidolonError.invalidBundle("礼物 \(id) 的 name 应当是一段文字")
        }
        guard let categoryText = object["category"]?.stringValue,
              let category = GiftCategory(rawValue: categoryText)
        else {
            throw EidolonError.invalidBundle(
                "礼物 \(id) 的类别 \(object["category"]?.stringValue ?? "（缺）") 不在 "
                    + GiftCategory.allCases.map(\.rawValue).joined(separator: "、") + " 之中"
            )
        }
        guard let rarityText = object["rarity"]?.stringValue,
              let rarity = GiftRarity(rawValue: rarityText)
        else {
            throw EidolonError.invalidBundle(
                "礼物 \(id) 的稀有度 \(object["rarity"]?.stringValue ?? "（缺）") 不在 "
                    + GiftRarity.allCases.map(\.rawValue).joined(separator: "、") + " 之中"
            )
        }
        self.init(
            id: id,
            name: name,
            category: category,
            rarity: rarity,
            retired: try Self.flag(object, "retired", gift: id),
            warm: try Self.flag(object, "warm", gift: id)
        )
    }

    private static func flag(
        _ object: [String: JSONValue],
        _ field: String,
        gift id: String
    ) throws -> Bool {
        switch object[field] {
        case nil, .null: return false
        case .bool(let value): return value
        default:
            throw EidolonError.invalidBundle("礼物 \(id) 的 \(field) 应当是 true 或 false")
        }
    }
}

/// The gift catalog exported from upstream's `characters/gifts.toml` as
/// `characters/gifts.json`. It is configuration, not user data: every install replaces it.
/// A bundle without one is an older bundle; the gift page then says so and nothing else
/// breaks.
public struct GiftCatalog: Sendable, Hashable {
    /// In file order, which is the order a backpack and the page show.
    public let gifts: [Gift]
    private let byID: [String: Gift]

    /// The most gifts one character may like (upstream `MAX_LIKED`).
    public static let maxLiked = 3

    public init(gifts: [Gift]) throws {
        guard !gifts.isEmpty else {
            throw EidolonError.invalidBundle("礼物目录是空的")
        }
        var byID: [String: Gift] = [:]
        for gift in gifts {
            guard byID[gift.id] == nil else {
                throw EidolonError.invalidBundle("礼物标识 \(gift.id) 重复")
            }
            byID[gift.id] = gift
        }
        for rarity in GiftRarity.allCases
        where !gifts.contains(where: { $0.rarity == rarity && !$0.retired }) {
            throw EidolonError.invalidBundle(
                "礼物目录里稀有度 \(rarity.rawValue) 没有一件没下架的礼物，这一档抽不出东西"
            )
        }
        self.gifts = gifts
        self.byID = byID
    }

    /// The catalog as the exporter writes it: `{"gifts": [...]}`.
    public init(data: Data) throws {
        let root: JSONValue
        do {
            root = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw EidolonError.invalidBundle(
                "礼物目录 characters/gifts.json 无法解析：\(error.localizedDescription)"
            )
        }
        guard let entries = root.objectValue?["gifts"]?.arrayValue else {
            throw EidolonError.invalidBundle(
                "礼物目录 characters/gifts.json 里的 gifts 应当是 [[gifts]] 段"
            )
        }
        try self.init(gifts: entries.map(Gift.init(json:)))
    }

    /// The catalog in the installed content directory, or nil when the bundle is older
    /// than gifts.
    public static func load(in directory: URL) throws -> GiftCatalog? {
        let url = directory.appendingPathComponent("characters/gifts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EidolonError.invalidBundle(
                "读不到 characters/gifts.json：\(error.localizedDescription)"
            )
        }
        return try GiftCatalog(data: data)
    }

    public func gift(id: String) -> Gift? { byID[id] }

    /// The gifts a draw of `rarity` may give: that rarity's, not retired, in catalog order.
    public func drawable(_ rarity: GiftRarity) -> [Gift] {
        gifts.filter { $0.rarity == rarity && !$0.retired }
    }

    /// Checks every character's `liked_gifts` against the catalog (upstream
    /// `check_liked_gifts`): one to three, no repeats, all present, not all rare.
    public func validateLikedGifts(_ characters: [CharacterConfig]) throws {
        for character in characters {
            let liked = character.likedGifts
            guard !liked.isEmpty else {
                throw EidolonError.invalidBundle(
                    "角色 \(character.id) 没有配 liked_gifts（喜欢的礼物，1–\(Self.maxLiked) 件）"
                )
            }
            guard liked.count <= Self.maxLiked else {
                throw EidolonError.invalidBundle(
                    "角色 \(character.id) 的 liked_gifts 有 \(liked.count) 件，最多 \(Self.maxLiked) 件"
                )
            }
            guard Set(liked).count == liked.count else {
                throw EidolonError.invalidBundle(
                    "角色 \(character.id) 的 liked_gifts 里有重复的礼物"
                )
            }
            let unknown = liked.filter { byID[$0] == nil }
            guard unknown.isEmpty else {
                throw EidolonError.invalidBundle(
                    "角色 \(character.id) 的 liked_gifts 里的 \(unknown.joined(separator: "、")) 不在礼物目录里"
                )
            }
            if liked.allSatisfy({ byID[$0]?.rarity == .rare }) {
                throw EidolonError.invalidBundle(
                    "角色 \(character.id) 的 liked_gifts 全是稀有礼物，至少要有一件普通或少见的"
                )
            }
        }
    }
}
