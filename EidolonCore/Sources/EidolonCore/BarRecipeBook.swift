import Foundation

/// The recipe book (`.scratch/bar-room` spec「配方书」; upstream `lib/barRecipeBook.ts`): what it
/// shows as the producer looks a drink up while mixing, reduced from where they click.
///
/// - Four tabs, by name, by flavor, by kind and the bottled; before any is picked, its cover.
/// - By name, by flavor and by kind list their categories (the drinks' initials; the menu's five
///   flavors and five kinds); a category lists its drinks, six at most; a drink opens its recipe
///   card.
/// - The cards turn one by one in their pages' order, not round: past either end nothing happens.
/// - The bottled tab lists the four bottled drinks; one opens to its picture and its line.
/// - Only drinks with a card are looked up by name, flavor or kind. No filters together.
public enum BarRecipeBook {
    public enum Tab: String, Sendable, Hashable, CaseIterable {
        case name, flavor, kind, bottle
    }

    /// The most drinks a category lists.
    static let perCategory = 6

    /// The menu's flavors and kinds, in its order.
    static let flavors: [Flavor] = Flavor.allCases
    static let kinds: [DrinkKind] = DrinkKind.allCases

    public struct State: Sendable, Hashable {
        /// The tab picked; nil on the cover.
        public var tab: Tab?
        /// The category open in it (an initial, a flavor, a kind).
        public var category: String?
        /// The drink open: its card, or the bottled one's picture.
        public var drink: String?

        public init(tab: Tab? = nil, category: String? = nil, drink: String? = nil) {
            self.tab = tab
            self.category = category
            self.drink = drink
        }

        /// Its cover: no tab picked.
        public static let cover = State()
    }

    public enum Action: Sendable, Hashable {
        case tab(Tab)
        case category(String)
        case drink(String)
        /// The card before (-1) or after (1).
        case page(Int)
    }

    /// The drinks with a recipe card, in their pages' order.
    static func cards(_ drinks: [Drink]) -> [Drink] {
        drinks
            .filter { $0.recipe != nil && $0.page != nil }
            .sorted { ($0.page ?? 0) < ($1.page ?? 0) }
    }

    /// What a tab lists first: the initials of the drinks with a card (by name), the five flavors
    /// or kinds.
    public static func categories(_ tab: Tab, _ drinks: [Drink]) -> [String] {
        switch tab {
        case .flavor: return flavors.map(\.rawValue)
        case .kind: return kinds.map(\.rawValue)
        case .bottle: return []
        case .name:
            return Set(cards(drinks).map { initial(of: $0) }).sorted()
        }
    }

    /// What a category lists, by name, six at most; the bottled tab lists the bottled drinks.
    public static func drinksIn(_ tab: Tab, _ category: String?, _ drinks: [Drink]) -> [Drink] {
        if tab == .bottle { return drinks.filter(\.isBottled) }
        guard let category else { return [] }
        let isIn: (Drink) -> Bool
        switch tab {
        case .name: isIn = { initial(of: $0) == category }
        case .flavor: isIn = { $0.flavor.rawValue == category }
        case .kind: isIn = { $0.kind.rawValue == category }
        case .bottle: isIn = { _ in false }
        }
        return Array(cards(drinks).filter(isIn).sorted { $0.name < $1.name }.prefix(perCategory))
    }

    /// Where the open card is among them: the n of 「n/24」, from 1; nil when no card is open.
    public static func pageOf(_ state: State, _ drinks: [Drink]) -> (n: Int, of: Int)? {
        let all = cards(drinks)
        guard let index = all.firstIndex(where: { $0.id == state.drink }) else { return nil }
        return (n: index + 1, of: all.count)
    }

    /// The book after a click. One that changes nothing (the tab already open with nothing under
    /// it, a page past either end, a category or drink not there) is the state it was given.
    public static func apply(_ state: State, _ action: Action, _ drinks: [Drink]) -> State {
        switch action {
        case let .tab(tab):
            // 点当前的标签：从下面一层回到这一栏的第一层。
            if state.tab == tab, state.category == nil, state.drink == nil { return state }
            return State(tab: tab)
        case let .category(category):
            guard let tab = state.tab, categories(tab, drinks).contains(category) else { return state }
            var next = state
            next.category = category
            next.drink = nil
            return next
        case let .drink(id):
            guard let tab = state.tab,
                  drinksIn(tab, state.category, drinks).contains(where: { $0.id == id })
            else { return state }
            var next = state
            next.drink = id
            return next
        case let .page(step):
            guard let page = pageOf(state, drinks) else { return state }
            let all = cards(drinks)
            let to = page.n - 1 + step
            guard all.indices.contains(to) else { return state }
            var next = state
            next.drink = all[to].id
            return next
        }
    }

    private static func initial(of drink: Drink) -> String {
        String(drink.name.prefix(1)).uppercased()
    }
}
