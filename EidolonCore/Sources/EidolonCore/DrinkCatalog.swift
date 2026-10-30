import Foundation

/// The drink catalog (GLOSSARY.md「饮品」「材料」), read from `characters/drinks.json` in the
/// content bundle — upstream's `drinks.toml`, configuration the maintainer keeps rather than
/// data. It has the original's 28 drinks: 24 mixed from five ingredients, 4 bottled.
///
/// What the bar counter holds is matched against the recipes exactly
/// (`DrinkCatalog.match`): the parts, the ice, the ageing and the method all as a recipe has
/// them, but for Karmotrine where a recipe leaves it optional, is that drink; all of them
/// doubled is its big glass, unless it is big already. Anything else is broken, and cannot be
/// served (ADR-0021).
public struct DrinkCatalog: Sendable {
    /// What the mixer holds, of the five ingredients together.
    public static let maxParts = 20
    /// The most flavors a character likes at the bar.
    public static let maxFlavors = 2
    /// The most drinks a character loves.
    public static let maxFavorites = 3

    /// The drinks, in file order.
    public let drinks: [Drink]
    private let byID: [String: Int]
    private let glasses: [Glass]

    /// - Parameter drinks: in file order. Throws if a mixture could be either of two.
    public init(drinks: [Drink]) throws {
        self.drinks = drinks
        self.byID = Dictionary(
            drinks.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        self.glasses = drinks.enumerated().flatMap { index, drink in
            Glass.glasses(of: drink, at: index)
        }
        for (i, one) in glasses.enumerated() {
            for other in glasses[(i + 1)...] where one.drinkID != other.drinkID {
                if Self.overlap(one, other) {
                    throw EidolonError.invalidContent(
                        "饮品 \(one.named)和 \(other.named)的配方重合，调出来认不出是哪一款"
                    )
                }
            }
        }
    }

    /// The drink of `id`, if the catalog has one.
    public func drink(id: String) -> Drink? {
        byID[id].map { drinks[$0] }
    }

    /// The mixed drinks, in file order.
    public var mixed: [Drink] {
        drinks.filter { $0.recipe != nil }
    }

    /// The drink a mixture is, or the bottled drink of an identifier; nil if the mixture is
    /// broken (over what the mixer holds, or parts that are not whole numbers from 0), or
    /// there is no such bottled drink.
    public func match(_ served: Mixture) -> Served? {
        let put = [served.adelhyde, served.bronsonExtract, served.powderedDelta,
                   served.flanergide, served.karmotrine]
        guard put.allSatisfy({ $0 >= 0 }), put.reduce(0, +) <= Self.maxParts else { return nil }
        guard let glass = glasses.first(where: { $0.madeOf(served) }) else { return nil }
        return Served(drink: drinks[glass.drinkIndex], big: glass.big, karmotrine: served.karmotrine)
    }

    /// The bottled drink of `id`, served as it is; nil if there is no such bottled drink.
    public func match(bottle id: String) -> Served? {
        guard let index = byID[id], drinks[index].recipe == nil else { return nil }
        return Served(drink: drinks[index], big: false, karmotrine: drinks[index].bottledKarmotrine)
    }

    /// Whether some mixture is made as both glasses.
    private static func overlap(_ one: Glass, _ other: Glass) -> Bool {
        one.parts == other.parts
            && one.ice == other.ice && one.aged == other.aged && one.method == other.method
            && (one.karmotrine == nil || other.karmotrine == nil || one.karmotrine == other.karmotrine)
    }
}

/// Flavor (口味) as the recipe book names it.
public enum Flavor: String, Sendable, CaseIterable, Hashable {
    case sweet, bitter, sour, spicy, bubbly

    /// In Chinese, as the prompt says it.
    public var zh: String {
        switch self {
        case .sweet: "甜"
        case .bitter: "苦"
        case .sour: "酸"
        case .spicy: "辣"
        case .bubbly: "发泡"
        }
    }

    /// In Japanese, as she says it.
    public var ja: String {
        switch self {
        case .sweet: "甘いの"
        case .bitter: "苦いの"
        case .sour: "酸っぱいの"
        case .spicy: "辛いの"
        case .bubbly: "シュワシュワの"
        }
    }
}

/// Kind (种类) as the recipe book's menu names it.
public enum DrinkKind: String, Sendable, CaseIterable, Hashable {
    case girly, manly, classic, classy, promo

    /// In Chinese, as the prompt says it.
    public var zh: String {
        switch self {
        case .girly: "女性化"
        case .manly: "男性化"
        case .classic: "经典"
        case .classy: "时尚"
        case .promo: "宣传"
        }
    }

    /// In Japanese, as she says it.
    public var ja: String {
        switch self {
        case .girly: "かわいい系の"
        case .manly: "男らしいの"
        case .classic: "定番の"
        case .classy: "おしゃれなの"
        case .promo: "キャンペーンの"
        }
    }
}

/// How well a character holds her drink (酒量).
public enum Tolerance: String, Sendable, CaseIterable, Hashable {
    case weak, medium, strong

    /// In Chinese, as the prompt says it.
    public var zh: String {
        switch self {
        case .weak: "不太能喝"
        case .medium: "一般"
        case .strong: "很能喝"
        }
    }
}

/// Shaken under 5 seconds, or 5 seconds and on.
public enum Method: String, Sendable, Hashable {
    case mix, blend
}

/// How a mixed drink is made, as its recipe card has it.
public struct Recipe: Sendable, Hashable {
    public var adelhyde: Int
    public var bronsonExtract: Int
    public var powderedDelta: Int
    public var flanergide: Int
    /// nil where it is optional: none makes the drink without alcohol.
    public var karmotrine: Int?
    public var ice: Bool
    public var aged: Bool
    public var method: Method
    /// A big glass already, with no doubled one.
    public var big: Bool

    public init(
        adelhyde: Int,
        bronsonExtract: Int,
        powderedDelta: Int,
        flanergide: Int,
        karmotrine: Int?,
        ice: Bool,
        aged: Bool,
        method: Method,
        big: Bool = false
    ) {
        self.adelhyde = adelhyde
        self.bronsonExtract = bronsonExtract
        self.powderedDelta = powderedDelta
        self.flanergide = flanergide
        self.karmotrine = karmotrine
        self.ice = ice
        self.aged = aged
        self.method = method
        self.big = big
    }

    /// The four ingredients but Karmotrine, in the recipe card's order.
    public var parts: [Int] {
        [adelhyde, bronsonExtract, powderedDelta, flanergide]
    }
}

/// One drink of the catalog.
public struct Drink: Sendable, Hashable, Identifiable {
    /// What is easy to read, from its English name (`sugar-rush`).
    public var id: String
    /// Its English name, as the recipe book, the order memo and her subtitles have it.
    public var name: String
    /// Its name in the Japanese release, as she says it.
    public var nameJa: String
    /// As the mixer shows it once made.
    public var shortName: String
    public var flavor: Flavor
    public var kind: DrinkKind
    /// The official Chinese description: on its recipe card, or, bottled, the line under it.
    public var description: String
    /// nil for a bottled drink.
    public var recipe: Recipe?
    /// Its recipe card's number; nil for a bottled drink.
    public var page: Int?
    /// How many parts of Karmotrine a bottled drink has in it.
    public var bottledKarmotrine: Int

    public init(
        id: String,
        name: String,
        nameJa: String,
        shortName: String,
        flavor: Flavor,
        kind: DrinkKind,
        description: String,
        recipe: Recipe? = nil,
        page: Int? = nil,
        bottledKarmotrine: Int = 0
    ) {
        self.id = id
        self.name = name
        self.nameJa = nameJa
        self.shortName = shortName
        self.flavor = flavor
        self.kind = kind
        self.description = description
        self.recipe = recipe
        self.page = page
        self.bottledKarmotrine = bottledKarmotrine
    }

    /// Bottled, served as it is.
    public var isBottled: Bool { recipe == nil }

    /// Whether it has a doubled glass: mixed, and not big already.
    public var doubles: Bool {
        guard let recipe else { return false }
        return !recipe.big
    }
}

/// What the bar counter holds as a drink is served: how many parts of each ingredient,
/// whether on ice and aged, and how it was shaken.
public struct Mixture: Sendable, Hashable {
    public var adelhyde: Int
    public var bronsonExtract: Int
    public var powderedDelta: Int
    public var flanergide: Int
    public var karmotrine: Int
    public var ice: Bool
    public var aged: Bool
    public var method: Method

    public init(
        adelhyde: Int = 0,
        bronsonExtract: Int = 0,
        powderedDelta: Int = 0,
        flanergide: Int = 0,
        karmotrine: Int = 0,
        ice: Bool = false,
        aged: Bool = false,
        method: Method = .mix
    ) {
        self.adelhyde = adelhyde
        self.bronsonExtract = bronsonExtract
        self.powderedDelta = powderedDelta
        self.flanergide = flanergide
        self.karmotrine = karmotrine
        self.ice = ice
        self.aged = aged
        self.method = method
    }

    /// The four ingredients but Karmotrine, in the recipe card's order.
    public var parts: [Int] {
        [adelhyde, bronsonExtract, powderedDelta, flanergide]
    }
}

/// A drink as it would be served.
public struct Served: Sendable, Hashable {
    public var drink: Drink
    /// Its doubled glass; never for a drink big already, or bottled.
    public var big: Bool
    /// How many parts of Karmotrine are in this glass: as many as were put in, the doubled
    /// glass's doubled; or as many as are in the bottle.
    public var karmotrine: Int

    public init(drink: Drink, big: Bool, karmotrine: Int) {
        self.drink = drink
        self.big = big
        self.karmotrine = karmotrine
    }

    public var alcoholic: Bool { karmotrine > 0 }
}

/// One glass a mixed drink is made as, its own or its doubled one.
private struct Glass {
    var drinkIndex: Int
    var drinkID: String
    var big: Bool
    /// Of the four ingredients but Karmotrine, in the recipe card's order.
    var parts: [Int]
    /// nil where it is optional.
    var karmotrine: Int?
    var ice: Bool
    var aged: Bool
    var method: Method

    /// The glasses `drink` is made as: its own, and doubled unless it is big already.
    static func glasses(of drink: Drink, at index: Int) -> [Glass] {
        guard let recipe = drink.recipe else { return [] }
        let own = Glass(
            drinkIndex: index, drinkID: drink.id, big: false, parts: recipe.parts,
            karmotrine: recipe.karmotrine, ice: recipe.ice, aged: recipe.aged,
            method: recipe.method
        )
        guard !recipe.big else { return [own] }
        let doubled = Glass(
            drinkIndex: index, drinkID: drink.id, big: true, parts: recipe.parts.map { $0 * 2 },
            karmotrine: recipe.karmotrine.map { $0 * 2 }, ice: recipe.ice, aged: recipe.aged,
            method: recipe.method
        )
        return [own, doubled]
    }

    func madeOf(_ mixture: Mixture) -> Bool {
        ice == mixture.ice && aged == mixture.aged && method == mixture.method
            && parts == mixture.parts
            && (karmotrine == nil || karmotrine == mixture.karmotrine)
    }

    var named: String { big ? "\(drinkID)（大杯）" : "\(drinkID) " }
}
