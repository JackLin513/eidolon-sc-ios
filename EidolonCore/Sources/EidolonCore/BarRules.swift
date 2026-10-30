import Foundation

/// A number below the one given, from 0, each as likely as another (upstream `Random`).
public typealias BarRandom = @Sendable (Int) -> Int

/// Where her order is drawn from (GLOSSARY.md「点单」).
public enum Bucket: String, Sendable, CaseIterable, Hashable {
    /// 爱喝的
    case favorite
    /// 合口味的
    case liking
    /// 心血来潮
    case whim
}

/// What she orders: the drink she means, how she says it and what of it.
public struct BarOrder: Sendable, Hashable {
    public var target: Drink
    public var phrasing: Phrasing
    /// What she says of it, all of which a drink must be to be right: as the target is.
    public var said: [Condition]
    /// For the usual, what she wanted the last time.
    public var usual: Set<String>

    public init(
        target: Drink, phrasing: Phrasing = .name, said: [Condition] = [], usual: Set<String> = []
    ) {
        self.target = target
        self.phrasing = phrasing
        self.said = said
        self.usual = usual
    }

    /// What she is to say of it: `said`, after a big glass where she asks for it by name.
    public var mentioned: [Condition] {
        phrasing == .nameBig ? [.big] + said : said
    }

    /// What she is to say of it, each as she says it, in Chinese or in Japanese.
    public func words(ja: Bool = false) -> [String] {
        mentioned.map { BarRules.word($0, target, ja: ja) }
    }

    /// The order memo, the producer's note to self of what she wants (the text box shows it
    /// while the drink is mixed); for an analogy, her order's `subtitle`, as she said it.
    public func memo(subtitle: String) -> String {
        if phrasing == .analogy { return "她说：「\(subtitle)」" }
        if [.flavor, .kind, .conditions].contains(phrasing) {
            return "她要\(words().joined(separator: "，"))。"
        }
        let head = BarRules.memos[phrasing] ?? "她要 \(target.name)"
        return ([head] + words()).joined(separator: "，") + "。"
    }
}

/// A drink served for an order, and how well.
public struct Serving: Sendable, Hashable {
    public var order: BarOrder
    public var served: Served
    public var tier: Tier
    /// How it is wrong, if it is.
    public var wrong: Wrong?

    public init(order: BarOrder, served: Served, tier: Tier, wrong: Wrong? = nil) {
        self.order = order
        self.served = served
        self.tier = tier
        self.wrong = wrong
    }
}

/// How a drink served wrong is.
public enum Wrong: String, Sendable, CaseIterable, Hashable {
    /// Of the flavor she dislikes.
    case disliked
    /// With alcohol, wanted without.
    case alcohol
    /// Not the usual.
    case notUsual = "not_usual"
    /// Of the flavor she meant but not its kind.
    case flavorOnly = "flavor_only"
    /// Of the kind she meant but not its flavor.
    case kindOnly = "kind_only"
    /// Quite off.
    case off
}

/// One of her orders in a visit done, as it is remembered.
public struct Had: Sendable, Hashable {
    /// The drink's identifier.
    public var target: String
    public var phrasing: Phrasing
    public var served: String
    public var big: Bool
    public var tier: Tier

    public init(target: String, phrasing: Phrasing, served: String, big: Bool, tier: Tier) {
        self.target = target
        self.phrasing = phrasing
        self.served = served
        self.big = big
        self.tier = tier
    }

    /// The drink she wanted, as the producer would know it: the one served, served right or
    /// best; else the one she ordered.
    public var wanted: String { tier == .wrong ? target : served }
}

/// What her orders are drawn knowing of the user and her.
public struct Known: Sendable, Hashable {
    /// Whether the user has fewer than `NOVICE_VISITS` visits done, with anyone.
    public var novice: Bool
    /// What she wanted on her last visit with the user; none before one.
    public var usual: Set<String>

    public init(novice: Bool = true, usual: Set<String> = []) {
        self.novice = novice
        self.usual = usual
    }
}

/// The bar's rules (GLOSSARY.md「光顾」「点单」): every number a visit is drawn and judged by,
/// and how her orders are drawn, said and the drinks served her judged (upstream
/// `bar_rules.py`).
public enum BarRules {
    /// Each bucket her order is drawn from, in the order an empty one falls to the next, and
    /// how likely, in percent.
    public static let buckets: [(Bucket, Int)] = [(.favorite, 45), (.liking, 35), (.whim, 20)]

    /// Each way she says her order, and how likely, in percent of all.
    public static let phrasings: [(Phrasing, Int)] = [
        (.name, 40), (.nameBig, 7), (.flavor, 12), (.kind, 12), (.conditions, 8),
        (.analogy, 8), (.myFavorite, 4), (.yourCall, 4), (.usual, 5),
    ]

    /// How many visits done, with anyone, a user has before the hardest ways of ordering.
    public static let noviceVisits = 3

    /// How likely she wants a drink that may be made without alcohol so, in percent, by how
    /// well she holds her drink.
    public static let noAlcohol: [Tolerance: Int] = [.weak: 40, .medium: 10, .strong: 0]

    /// How many parts of Karmotrine she has in a visit to be drunk, by how well she holds her
    /// drink.
    public static let drunkAt: [Tolerance: Int] = [.weak: 8, .medium: 14, .strong: 20]

    /// How many drinks she has in a visit, and how likely each, in percent.
    public static let cups: [(Int, Int)] = [(1, 20), (2, 60), (3, 20)]

    /// How many visits with the user she has had, done, to be a regular at the bar.
    public static let regularVisits = 5

    /// Longer than this since her last visit, she has not been in for a long time.
    public static let longAgo: TimeInterval = 14 * 24 * 60 * 60

    /// What she may say of a drink beside its flavor or kind, in the order she says them.
    public static let extras: [Condition] = [.ice, .big, .noAlcohol]

    /// Each condition but the flavor and kind as she says it, in Chinese and in Japanese.
    static let extrasSaid: [Condition: (zh: String, ja: String)] = [
        .ice: ("加冰", "氷入り"), .big: ("大杯", "大きいサイズ"), .noAlcohol: ("不要酒精", "アルコール抜き"),
    ]

    /// The memo's opening for the ways of ordering it has one of its own.
    static let memos: [Phrasing: String] = [
        .myFavorite: "她要她喜欢的", .yourCall: "她让我拿主意", .usual: "她要上次那款",
    ]

    // MARK: - Drawing

    /// Which row of `table`, each as likely as its share of the percents, by `random`.
    public static func drawn<T>(_ table: [(T, Int)], _ random: BarRandom) -> Int {
        let number = random(table.reduce(0) { $0 + $1.1 })
        var upto = 0
        for (i, row) in table.enumerated() {
            upto += row.1
            if number < upto { return i }
        }
        // The number is below the percents' sum, as upstream asserts.
        return table.count - 1
    }

    /// How many drinks she has in a visit.
    public static func cups(_ random: BarRandom) -> Int {
        cups[drawn(cups, random)].0
    }

    /// Her next order, having ordered `ordered` these drinks in the visit so far.
    public static func drawOrder(
        _ character: CharacterConfig,
        _ catalog: DrinkCatalog,
        _ random: BarRandom,
        ordered: [String],
        known: Known
    ) throws -> BarOrder {
        let tastes = try tastes(of: character)
        let (target, bucket) = target(
            buckets(of: character, catalog: catalog), random, ordered,
            avoiding: ordered.isEmpty ? known.usual : []
        )
        let usuals = catalog.drinks.filter { drink in
            known.usual.contains(drink.id) && !ordered.contains(drink.id)
                && drink.flavor != tastes.dislikedValue
        }
        let can: [Phrasing: Bool] = [
            .name: true,
            .nameBig: target.doubles,
            .flavor: true,
            .kind: true,
            .conditions: !known.novice && !extras(target).isEmpty,
            .analogy: !known.novice && !target.description.isEmpty,
            .myFavorite: bucket == .favorite && !known.usual.isEmpty,
            .yourCall: true,
            .usual: !usuals.isEmpty,
        ]
        let possible = phrasings.filter { can[$0.0] == true }
        let phrasing = possible[drawn(possible, random)].0
        if phrasing == .usual {
            let usual = usuals[random(usuals.count)]
            return BarOrder(target: usual, phrasing: .usual, usual: known.usual)
        }
        var said: [Condition] = []
        switch phrasing {
        case .flavor: said = [.flavor]
        case .kind: said = [.kind]
        case .conditions: said = conditions(target, random)
        default: break
        }
        if !said.contains(.noAlcohol), wantsItWithoutAlcohol(character, target, random) {
            said.append(.noAlcohol)
        }
        return BarOrder(target: target, phrasing: phrasing, said: said)
    }

    /// How well `served` answers `order` for her.
    public static func judged(
        _ order: BarOrder, _ served: Served, _ character: CharacterConfig
    ) throws -> Serving {
        let tastes = try tastes(of: character)
        let drink = served.drink
        let right = drink.flavor != tastes.dislikedValue
            && order.said.allSatisfy { meets($0, order.target, served) }
            && among(order, drink, tastes)
        guard right else {
            return Serving(order: order, served: served, tier: .wrong, wrong: wrong(order, served, tastes))
        }
        return Serving(order: order, served: served, tier: best(order, served, tastes) ? .best : .right)
    }

    /// Whether any of the drinks, served in any glass, would be best for `order`.
    public static func hasBest(
        _ order: BarOrder, _ character: CharacterConfig, _ catalog: DrinkCatalog
    ) throws -> Bool {
        try servable(catalog).contains { try judged(order, $0, character).tier == .best }
    }

    /// Whether she is drunk, having been served `servings` in a visit: as many parts of
    /// Karmotrine in them as she holds, or more.
    public static func drunk(_ character: CharacterConfig, servings: [Serving]) throws -> Bool {
        guard let tolerance = try tastes(of: character).tolerance,
              let at = drunkAt[tolerance] else { return false }
        return servings.reduce(0) { $0 + $1.served.karmotrine } >= at
    }

    // MARK: - Fixed lines

    /// Whether `lines`, her order, name drinks as they should: the drink she means, in
    /// Chinese by its English name or in Japanese by its Japanese one, where she orders by
    /// name; else none of the catalog's in either.
    public static func namesRightly(
        _ order: BarOrder, _ lines: [BarLine], _ catalog: DrinkCatalog
    ) -> Bool {
        BarNames.rightly(order, lines, catalog: catalog)
    }

    /// Her order said in one of the fixed lines for how she says it, and the line she adds
    /// for it without alcohol where she wants it so but cannot say it in that line; with the
    /// order as it is now: an analogy, which a fixed line cannot make, said and judged as
    /// conditions, the drink's flavor and kind.
    public static func fixedOrder(
        _ order: BarOrder, _ lines: BarLines, _ random: BarRandom
    ) -> (order: BarOrder, lines: [BarLine]) {
        var order = order
        if order.phrasing == .analogy {
            order = BarOrder(
                target: order.target, phrasing: .conditions,
                said: [.flavor, .kind] + order.said.filter { $0 == .noAlcohol },
                usual: order.usual
            )
        }
        let group = lines.orders[order.phrasing] ?? []
        var said = [filled(group.isEmpty ? BarLineText(ja: "", zh: "") : group[random(group.count)],
                          order, order: true)]
        if order.said.contains(.noAlcohol) && order.phrasing != .conditions {
            let added = lines.noAlcohol[random(lines.noAlcohol.count)]
            said.append(BarLine(speaker: .her, zh: added.zh, ja: added.ja, emotion: added.emotion, order: true))
        }
        return (order, said)
    }

    /// Her reaction to `serving`, her last drink, and her farewell, drunk or not, said in one
    /// of the fixed lines each, where the call to write them cannot be.
    public static func fixedFarewell(
        _ serving: Serving, _ drunk: Bool, _ lines: BarLines, _ random: BarRandom
    ) -> [BarLine] {
        let reactions = lines.reactions[serving.tier] ?? []
        let farewells = lines.farewells[drunk ? .drunk : .sober] ?? []
        return [reactions[random(reactions.count)], farewells[random(farewells.count)]].map {
            BarLine(speaker: .her, zh: $0.zh, ja: $0.ja, emotion: $0.emotion)
        }
    }

    /// `line` with what `order` names filled in, marked as her order.
    private static func filled(_ line: BarLineText, _ order: BarOrder, order marking: Bool) -> BarLine {
        let target = order.target
        let ja = line.ja.filled([
            "name_ja": target.nameJa,
            "flavor": word(.flavor, target, ja: true),
            "kind": word(.kind, target, ja: true),
            "conditions": order.words(ja: true).joined(separator: "、"),
        ])
        let zh = line.zh.filled([
            "name": target.name,
            "flavor": word(.flavor, target, ja: false),
            "kind": word(.kind, target, ja: false),
            "conditions": order.words().joined(separator: "、"),
        ])
        return BarLine(speaker: .her, zh: zh, ja: ja, emotion: line.emotion, order: marking)
    }

    // MARK: - Words

    static func word(_ condition: Condition, _ drink: Drink, ja: Bool) -> String {
        switch condition {
        case .flavor: return ja ? drink.flavor.ja : "\(drink.flavor.zh)的"
        case .kind: return ja ? drink.kind.ja : "\(drink.kind.zh)的"
        case .ice, .big, .noAlcohol:
            let said = extrasSaid[condition]!
            return ja ? said.ja : said.zh
        }
    }

    // MARK: - Private

    static func tastes(of character: CharacterConfig) throws -> BarTastes {
        guard let tastes = character.bar else {
            throw EidolonError.invalidContent("角色 \(character.id) 没有配酒吧的口味")
        }
        return tastes
    }

    /// The drink she means, and the bucket it is of.
    private static func target(
        _ buckets: [Bucket: [Drink]], _ random: BarRandom, _ ordered: [String], avoiding: Set<String>
    ) -> (Drink, Bucket) {
        let start = drawn(Self.buckets, random)
        for avoided in [avoiding, []] {
            for bucket in Self.buckets[start...].map(\.0) {
                let left = (buckets[bucket] ?? []).filter {
                    !ordered.contains($0.id) && !avoided.contains($0.id)
                }
                if !left.isEmpty { return (left[random(left.count)], bucket) }
            }
        }
        // Every drink but those of the flavor she dislikes has been ordered.
        let every = Self.buckets.map(\.0).flatMap { buckets[$0] ?? [] }
        return (every[0], .whim)
    }

    private static func servable(_ catalog: DrinkCatalog) -> [Served] {
        catalog.drinks.flatMap { drink -> [Served] in
            guard let recipe = drink.recipe else {
                return [Served(drink: drink, big: false, karmotrine: drink.bottledKarmotrine)]
            }
            return (drink.doubles ? [false, true] : [false]).flatMap { big in
                (recipe.karmotrine == nil ? [0, 1] : [recipe.karmotrine!]).map { karmotrine in
                    Served(drink: drink, big: big, karmotrine: karmotrine * (big ? 2 : 1))
                }
            }
        }
    }

    /// What she may say of `drink` beside its flavor and kind.
    static func extras(_ drink: Drink) -> [Condition] {
        let recipe = drink.recipe
        let can: [Condition: Bool] = [
            .ice: recipe?.ice == true,
            .big: drink.doubles,
            .noAlcohol: recipe.map { $0.karmotrine == nil || $0.karmotrine == 0 }
                ?? (drink.bottledKarmotrine == 0),
        ]
        return extras.filter { can[$0] == true }
    }

    /// Its flavor or its kind, and one or two of what else she may say of it.
    private static func conditions(_ target: Drink, _ random: BarRandom) -> [Condition] {
        let flavorOrKind: Condition = random(2) == 0 ? .flavor : .kind
        var left = extras(target)
        let count = left.count > 1 ? 1 + random(2) : 1
        var picked: [Condition] = []
        for _ in 0..<count {
            picked.append(left.remove(at: random(left.count)))
        }
        return [flavorOrKind] + extras.filter { picked.contains($0) }
    }

    /// Whether she wants `target` without alcohol, which it may be made with or without.
    private static func wantsItWithoutAlcohol(
        _ character: CharacterConfig, _ target: Drink, _ random: BarRandom
    ) -> Bool {
        guard let tolerance = try? tastes(of: character).tolerance,
              let percent = noAlcohol[tolerance], percent > 0 else { return false }
        guard let recipe = target.recipe, recipe.karmotrine == nil else { return false }
        return random(100) < percent
    }

    /// Whether `served` is as `target` is in `condition`.
    private static func meets(_ condition: Condition, _ target: Drink, _ served: Served) -> Bool {
        let drink = served.drink
        switch condition {
        case .flavor: return drink.flavor == target.flavor
        case .kind: return drink.kind == target.kind
        case .ice: return drink.recipe?.ice == true
        // A drink big already is served in a big glass.
        case .big: return served.big || (drink.recipe?.big == true)
        case .noAlcohol: return !served.alcoholic
        }
    }

    /// Whether `drink` is one of those `order` may be answered with, by how she says it.
    private static func among(_ order: BarOrder, _ drink: Drink, _ tastes: BarTastes) -> Bool {
        switch order.phrasing {
        case .name, .nameBig, .analogy:
            return drink.id == order.target.id
        case .usual:
            return order.usual.contains(drink.id)
        case .myFavorite:
            return tastes.favorites.contains(drink.id) || tastes.flavors.contains(drink.flavor)
                || (tastes.kindValue != nil && drink.kind == tastes.kindValue)
        default:
            return true
        }
    }

    /// Whether `served`, right for `order`, is best for it.
    private static func best(_ order: BarOrder, _ served: Served, _ tastes: BarTastes) -> Bool {
        switch order.phrasing {
        case .name, .analogy, .usual:
            return false
        case .nameBig:
            return served.big
        default:
            return tastes.favorites.contains(served.drink.id)
        }
    }

    /// How `served`, wrong for `order`, is wrong: the first of these ways that is so.
    private static func wrong(_ order: BarOrder, _ served: Served, _ tastes: BarTastes) -> Wrong {
        let target = order.target
        let drink = served.drink
        if drink.flavor == tastes.dislikedValue { return .disliked }
        if order.said.contains(.noAlcohol) && served.alcoholic { return .alcohol }
        if order.phrasing == .usual { return .notUsual }
        if drink.flavor == target.flavor && drink.kind != target.kind { return .flavorOnly }
        if drink.kind == target.kind && drink.flavor != target.flavor { return .kindOnly }
        return .off
    }

    /// The drinks of each bucket, in catalog order, none of the flavor she dislikes.
    private static func buckets(of character: CharacterConfig, catalog: DrinkCatalog) -> [Bucket: [Drink]] {
        let tastes = character.bar ?? BarTastes()
        let drinks = catalog.drinks.filter { $0.flavor != tastes.dislikedValue }
        let favorites = Set(tastes.favorites)
        return [
            .favorite: drinks.filter { favorites.contains($0.id) },
            .liking: drinks.filter {
                !favorites.contains($0.id)
                    && (tastes.flavors.contains($0.flavor)
                        || (tastes.kindValue != nil && $0.kind == tastes.kindValue))
            },
            .whim: drinks,
        ]
    }
}
