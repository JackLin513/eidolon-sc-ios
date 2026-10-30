import Foundation

extension CharacterConfig {
    /// Her tastes at the bar (GLOSSARY.md「口味」「酒量」), from the bar columns of
    /// `characters.json` — upstream's `characters.toml`. Absent where the content does not
    /// configure her for the bar.
    public var bar: BarTastes? {
        let object = raw
        guard object["bar_tolerance"] != nil else { return nil }
        return BarTastes(
            flavors: (object["bar_flavors"]?.arrayValue ?? []).compactMap(\.stringValue)
                .compactMap(Flavor.init(rawValue:)),
            flavorNames: (object["bar_flavors"]?.arrayValue ?? []).compactMap(\.stringValue),
            kind: object["bar_kind"]?.stringValue,
            favorites: (object["bar_favorites"]?.arrayValue ?? []).compactMap(\.stringValue),
            dislikedFlavor: object["bar_disliked_flavor"]?.stringValue,
            tolerance: Tolerance(rawValue: object["bar_tolerance"]?.stringValue ?? "")
        )
    }
}

/// Her tastes at the bar: the flavors she likes, the kind, the drinks she loves, the flavor
/// she dislikes and how well she holds her drink.
public struct BarTastes: Sendable, Hashable {
    /// The flavors she likes, parsed; only those of `flavorNames` that are flavors.
    public var flavors: [Flavor]
    /// The same, as the configuration wrote them (for reporting what is wrong).
    public var flavorNames: [String]
    /// The kind she likes, as the configuration wrote it.
    public var kind: String?
    /// The drinks she loves, by identifier.
    public var favorites: [String]
    /// The flavor she dislikes, as the configuration wrote it.
    public var dislikedFlavor: String?
    /// How well she holds her drink; nil if it is not one of the three.
    public var tolerance: Tolerance?

    public init(
        flavors: [Flavor] = [],
        flavorNames: [String] = [],
        kind: String? = nil,
        favorites: [String] = [],
        dislikedFlavor: String? = nil,
        tolerance: Tolerance? = nil
    ) {
        self.flavors = flavors
        self.flavorNames = flavorNames
        self.kind = kind
        self.favorites = favorites
        self.dislikedFlavor = dislikedFlavor
        self.tolerance = tolerance
    }

    /// The kind she likes, as a kind.
    public var kindValue: DrinkKind? { kind.flatMap(DrinkKind.init(rawValue:)) }

    /// The flavor she dislikes, as a flavor.
    public var dislikedValue: Flavor? { dislikedFlavor.flatMap(Flavor.init(rawValue:)) }
}

/// Checks the bar columns of every character against the catalog (upstream
/// `check_bar_tastes`): one to two flavors she likes, a kind or none, one to three drinks she
/// loves in the catalog, a flavor she dislikes that is not one she likes and that none of
/// what she loves is of, and a way she holds her drink.
public enum BarTastesCheck {
    public static func check(_ characters: [CharacterConfig], catalog: DrinkCatalog) throws {
        for character in characters {
            let flavors = character.raw["bar_flavors"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let favorites = character.raw["bar_favorites"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let kind = character.raw["bar_kind"]?.stringValue
            let disliked = character.raw["bar_disliked_flavor"]?.stringValue
            let tolerance = character.raw["bar_tolerance"]?.stringValue
            let id = character.id

            try someOf(id, "bar_flavors", "喜欢的口味", flavors, DrinkCatalog.maxFlavors)
            for flavor in flavors {
                try named(flavor, Flavor.self, "角色 \(id) 的 bar_flavors")
            }
            if let kind { try named(kind, DrinkKind.self, "角色 \(id) 的 bar_kind") }
            try someOf(id, "bar_favorites", "爱喝的饮品", favorites, DrinkCatalog.maxFavorites)
            let unknown = favorites.filter { catalog.drink(id: $0) == nil }
            guard unknown.isEmpty else {
                throw EidolonError.invalidContent("角色 \(id) 的 bar_favorites 里的 \(unknown.joined(separator: "、")) 不在饮品目录里")
            }
            if let disliked {
                try named(disliked, Flavor.self, "角色 \(id) 的 bar_disliked_flavor")
                guard !flavors.contains(disliked) else {
                    throw EidolonError.invalidContent(
                        "角色 \(id) 的 bar_disliked_flavor \(disliked) 也在她喜欢的口味 bar_flavors 里"
                    )
                }
                let hated = favorites.filter { catalog.drink(id: $0)?.flavor.rawValue == disliked }
                guard hated.isEmpty else {
                    throw EidolonError.invalidContent(
                        "角色 \(id) 爱喝的 \(hated.joined(separator: "、")) 是她讨厌的口味 \(disliked)"
                    )
                }
            }
            guard let tolerance else {
                throw EidolonError.invalidContent("角色 \(id) 没有配 bar_tolerance（酒量）")
            }
            try named(tolerance, Tolerance.self, "角色 \(id) 的 bar_tolerance")
        }
    }

    private static func someOf(
        _ id: String, _ field: String, _ what: String, _ names: [String], _ most: Int
    ) throws {
        guard !names.isEmpty else {
            throw EidolonError.invalidContent("角色 \(id) 没有配 \(field)（\(what)，1–\(most) 个）")
        }
        guard names.count <= most else {
            throw EidolonError.invalidContent("角色 \(id) 的 \(field) 有 \(names.count) 个，最多 \(most) 个")
        }
        guard Set(names).count == names.count else {
            throw EidolonError.invalidContent("角色 \(id) 的 \(field) 里有重复的\(what)")
        }
    }

    private static func named<T: RawRepresentable & CaseIterable>(
        _ value: String, _ type: T.Type, _ label: String
    ) throws where T.RawValue == String {
        guard type.init(rawValue: value) != nil else {
            let all = T.allCases.map(\.rawValue).joined(separator: "、")
            throw EidolonError.invalidContent("\(label) 里的 \(value) 不在 \(all) 之中")
        }
    }
}
