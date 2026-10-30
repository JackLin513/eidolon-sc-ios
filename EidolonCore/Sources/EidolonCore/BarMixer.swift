import Foundation

/// The five ingredients, in the bar counter's order (its bottles).
public enum Ingredient: String, Sendable, Hashable, CaseIterable {
    case adelhyde
    case bronsonExtract = "bronson_extract"
    case powderedDelta = "powdered_delta"
    case flanergide
    case karmotrine

    /// The bottle's English name, as the original has it.
    public var name: String {
        switch self {
        case .adelhyde: "Adelhyde"
        case .bronsonExtract: "Bronson Extract"
        case .powderedDelta: "Powdered Delta"
        case .flanergide: "Flanergide"
        case .karmotrine: "Karmotrine"
        }
    }
}

/// The bar counter (`.scratch/bar-room` spec「调酒台」; upstream `lib/barMixer.ts`): what the
/// shaker holds as the producer mixes her drink, reduced from what they do with it. Pure: the
/// screen draws it and keeps the time (`now`, in seconds).
///
/// - Parts of the five ingredients go in one at a time, up to `capacity` in all, and come out one
///   at a time; ice and ageing are switched on and off. All of that before shaking.
/// - Shaken, it shakes slowly, and fast once `fastAfter` has gone by; stopped while slow it is
///   mixed, while fast blended. Stopped, it is made into a drink, or broken.
/// - A bottled drink goes into the shaker only while it is empty, and nothing else after it.
/// - What is made is matched to the catalog as the server matches it (ADR-0021): the parts but
///   optional Karmotrine, the ice, the ageing and the method all as a recipe has them; all of
///   them doubled is its big glass, unless it is big already; anything else is broken.
public enum BarMixer {
    /// The most parts the shaker holds.
    public static let capacity = 20
    /// Shaken this long, it shakes fast: stopped then, it is blended.
    public static let fastAfter: TimeInterval = 5

    /// What the shaker holds, before shaking and once stopped.
    public struct State: Sendable, Hashable {
        /// `parts` or the state itself; the screen keeps it, so an action that cannot be done
        /// leaves it as it was.
        public var parts: [Ingredient: Int]
        public var ice: Bool
        public var aged: Bool
        /// Not shaken yet, shaking since `shakenAt`, or stopped.
        public var shake: Shake
        public var shakenAt: TimeInterval?
        /// How it was shaken, once stopped.
        public var method: Method?
        /// What it was made into, once stopped (a bottle put in, that bottle).
        public var made: Served?
        /// The bottled drink put in the shaker.
        public var bottle: Drink?
        /// The slot's garble, once broken.
        public var garble: String?

        public init(
            parts: [Ingredient: Int] = [:],
            ice: Bool = false,
            aged: Bool = false,
            shake: Shake = .still,
            shakenAt: TimeInterval? = nil,
            method: Method? = nil,
            made: Served? = nil,
            bottle: Drink? = nil,
            garble: String? = nil
        ) {
            self.parts = parts
            self.ice = ice
            self.aged = aged
            self.shake = shake
            self.shakenAt = shakenAt
            self.method = method
            self.made = made
            self.bottle = bottle
            self.garble = garble
        }

        public enum Shake: String, Sendable, Hashable {
            case still, shaking, stopped
        }

        public func parts(_ ingredient: Ingredient) -> Int {
            parts[ingredient] ?? 0
        }
    }

    /// Something done at the counter. One that cannot be done leaves the state as it was, so
    /// the screen can tell and play `buttonnoclick`.
    public enum Action: Sendable, Hashable {
        case add(Ingredient)
        case remove(Ingredient)
        case ice
        case aged
        case shake(now: TimeInterval)
        /// Stopped at `now`, matched against `drinks`; `garble` is what the slot says if broken.
        case stop(now: TimeInterval, drinks: [Drink], garble: String)
        /// A bottled drink dragged into the shaker.
        case bottle(Drink)
        /// Poured away.
        case reset
        /// The drink served was found broken: it is, whatever the screen made of it.
        case broken(garble: String)
    }

    public static var empty: State { State() }

    /// How many parts are in it.
    public static func totalParts(_ state: State) -> Int {
        Ingredient.allCases.reduce(0) { $0 + state.parts($1) }
    }

    /// Ingredients may go in and come out, ice and ageing be switched: not shaken, no bottle in.
    public static func isTakingIngredients(_ state: State) -> Bool {
        state.shake == .still && state.bottle == nil
    }

    /// Nothing in it: no parts, no ice, not aged, not shaken, no bottle.
    public static func isEmpty(_ state: State) -> Bool {
        isTakingIngredients(state) && totalParts(state) == 0 && !state.ice && !state.aged
    }

    /// Done with: stopped (made or broken), or a bottle put in.
    public static func isFinished(_ state: State) -> Bool {
        state.bottle != nil || state.shake == .stopped
    }

    /// `state` after `action`; the state itself when nothing can be done.
    public static func apply(_ state: State, _ action: Action) -> State {
        switch action {
        case .add(let ingredient):
            guard isTakingIngredients(state), totalParts(state) < capacity else { return unchanged(state, action) }
            var next = state
            next.parts[ingredient] = state.parts(ingredient) + 1
            return next
        case .remove(let ingredient):
            guard isTakingIngredients(state), state.parts(ingredient) > 0 else { return unchanged(state, action) }
            var next = state
            next.parts[ingredient] = state.parts(ingredient) - 1
            return next
        case .ice:
            guard isTakingIngredients(state) else { return unchanged(state, action) }
            var next = state
            next.ice.toggle()
            return next
        case .aged:
            guard isTakingIngredients(state) else { return unchanged(state, action) }
            var next = state
            next.aged.toggle()
            return next
        case .shake(let now):
            guard isTakingIngredients(state), totalParts(state) > 0 else { return unchanged(state, action) }
            var next = state
            next.shake = .shaking
            next.shakenAt = now
            return next
        case let .stop(now, drinks, garble):
            guard state.shake == .shaking, let shakenAt = state.shakenAt else { return unchanged(state, action) }
            let method: Method = (now - shakenAt >= fastAfter) ? Method.blend : Method.mix
            let made = matchDrink(drinks, mixture(state, method))
            var next = state
            next.shake = .stopped
            next.method = method
            next.made = made
            next.garble = made == nil ? garble : nil
            return next
        case .bottle(let drink):
            guard drink.recipe == nil, isEmpty(state) else { return unchanged(state, action) }
            var next = state
            next.bottle = drink
            next.made = Served(drink: drink, big: false, karmotrine: drink.bottledKarmotrine)
            return next
        case .reset:
            return isEmpty(state) ? unchanged(state, action) : empty
        case let .broken(garble):
            var next = state
            next.shake = .stopped
            next.made = nil
            next.bottle = nil
            next.garble = garble
            return next
        }
    }

    /// `state` as it was, for a next state to be told apart from it (`unchanged`).
    private static func unchanged(_ state: State, _ action: Action) -> State { state }

    /// Shaking slowly or fast at `now`, or still, or stopped.
    public enum Stage: String, Sendable, Hashable {
        case still, slow, fast, stopped
    }

    public static func shakeStage(_ state: State, now: TimeInterval) -> Stage {
        guard state.shake == .shaking else {
            switch state.shake {
            case .still: return .still
            case .shaking: return .slow
            case .stopped: return .stopped
            }
        }
        return (state.shakenAt.map { now - $0 >= fastAfter } ?? false) ? Stage.fast : Stage.slow
    }

    /// It may be served: stopped and not broken, or a bottle put in.
    public static func canServe(_ state: State) -> Bool {
        state.made != nil && (state.bottle != nil || state.shake == .stopped)
    }

    /// What the shaker holds as the bar takes it; nil if it cannot be served.
    public static func served(_ state: State) -> (mixture: Mixture?, bottle: String?) {
        guard canServe(state), let made = state.made else { return (nil, nil) }
        if state.bottle != nil { return (nil, made.drink.id) }
        guard let method = state.method else { return (nil, nil) }
        return (mixture(state, method), nil)
    }

    /// What the slot under the shaker says: the short name of what is made, the garble if it
    /// broke; nothing before it is stopped.
    public static func slotText(_ state: State) -> String? {
        guard isFinished(state) else { return nil }
        if let made = state.made { return made.drink.shortName }
        return state.garble
    }

    /// The slot's garble when it breaks (the original's random `##20%!!` and the like).
    public static func garble(random: () -> Double = { .random(in: 0..<1) }) -> String {
        let characters = Array("#%!?@&*0123456789")
        return String((0..<7).map { _ in
            characters[min(characters.count - 1, max(0, Int((random() * Double(characters.count)).rounded(.down))))]
        })
    }

    /// The drink a mixture is in `drinks` (the content bundle's catalog), its big glass with it;
    /// nil if broken: over what the shaker holds, or none of the recipes.
    public static func matchDrink(_ drinks: [Drink], _ mixture: Mixture) -> Served? {
        guard mixture.parts.reduce(0, +) + mixture.karmotrine <= capacity,
              let catalog = try? DrinkCatalog(drinks: drinks)
        else { return nil }
        return catalog.match(mixture)
    }

    /// What the shaker holds, as a mixture shaken `method`.
    static func mixture(_ state: State, _ method: Method) -> Mixture {
        Mixture(
            adelhyde: state.parts(.adelhyde),
            bronsonExtract: state.parts(.bronsonExtract),
            powderedDelta: state.parts(.powderedDelta),
            flanergide: state.parts(.flanergide),
            karmotrine: state.parts(.karmotrine),
            ice: state.ice,
            aged: state.aged,
            method: method
        )
    }
}
