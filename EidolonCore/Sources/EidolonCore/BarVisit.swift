import Foundation

/// What a visit to the bar comes to, as the page reads it (upstream `BarEvent`, ADR-0021):
/// she comes in, each line as it closes, the order memo once her order is written, that she
/// waits for her drink, that a call is made again, and how the visit went.
public enum BarEvent: Sendable, Hashable {
    /// She came in: the visit's identifier, which every later step names, and who she is.
    case visit(visitID: String, characterID: String)
    /// A line of hers or the producer's, as it closes.
    case line(BarLine)
    /// The order memo, after the line she ordered in.
    case memo(String)
    /// The call is written: she waits for her drink.
    case waiting
    /// The call failed and is made again: what it sent is to be cleared.
    case retrying
    /// Her farewell is written: the visit is done, rewarded or not (nil).
    case done(Reward?)
    /// The call could not be written, tried again or not: the visit stops before it, till it
    /// is tried again or left.
    case failed(String)
}

/// What a visit done was rewarded with: whether her affinity rose. The app has no gifts or
/// draws, so there is no draw chance to give (ADR-0021, upstream `Rewarded`'s other half).
public struct Reward: Sendable, Hashable {
    public var affinityUp: Bool

    public init(affinityUp: Bool) {
        self.affinityUp = affinityUp
    }
}

/// Where a visit is: her lines being written, waiting for a drink, or stopped before a call
/// that failed.
public enum BarStep: String, Sendable, Hashable {
    case writing, waiting, failed
}

/// A visit under way (GLOSSARY.md「光顾」): who came, why, what about, each of her orders and
/// what was served, and what each call so far asked for and what was written.
public struct BarVisit: Sendable {
    public var id: String
    public var character: CharacterConfig
    public var enteredAt: Date
    public var reason: VisitReason
    public var topic: BarTopic
    /// How many drinks she has.
    public var cups: Int
    /// What her orders are drawn knowing.
    public var known: Known
    /// The first part of every call's prompt.
    public var shared: String
    /// The second part.
    public var about: String
    /// Her facts `topic` found, as told in `about`.
    public var facts: [String]
    /// What she was told of the day, as told in `about`.
    public var today: [String]
    public var remembered: BarPrompt.Remembered
    public var orders: [BarOrder]
    public var servings: [Serving]
    /// What each call so far asked for, and what was written.
    public var written: [(ask: String, lines: [BarLine])]
    /// Whether she has had as much as she holds.
    public var drunk: Bool
    public var step: BarStep
    /// What the call it is at asks for, to try it again should it fail.
    public var asking: String
    /// When it was last touched: come in, served, tried again, or a call of it over.
    public var touched: Date
    /// How many calls of it were made: the latest is the one its step is of.
    public var calls: Int

    public init(
        id: String = UUID().uuidString,
        character: CharacterConfig,
        enteredAt: Date,
        reason: VisitReason,
        topic: BarTopic,
        cups: Int,
        known: Known = Known(),
        shared: String = "",
        about: String = "",
        facts: [String] = [],
        today: [String] = [],
        remembered: BarPrompt.Remembered = .init(),
        orders: [BarOrder] = [],
        servings: [Serving] = [],
        written: [(ask: String, lines: [BarLine])] = [],
        drunk: Bool = false,
        step: BarStep = .writing,
        asking: String = "",
        touched: Date? = nil,
        calls: Int = 0
    ) {
        self.id = id
        self.character = character
        self.enteredAt = enteredAt
        self.reason = reason
        self.topic = topic
        self.cups = cups
        self.known = known
        self.shared = shared
        self.about = about
        self.facts = facts
        self.today = today
        self.remembered = remembered
        self.orders = orders
        self.servings = servings
        self.written = written
        self.drunk = drunk
        self.step = step
        self.asking = asking
        self.touched = touched ?? enteredAt
        self.calls = calls
    }

    /// Whether she is waiting for a drink: she has ordered one more than was served.
    public var ordering: Bool { orders.count > servings.count }

    /// The prompt of the call it is at.
    public var prompt: [BarChatMessage] {
        BarPrompt.prompt(shared: shared, visit: about, written: written, ask: asking)
    }

    /// Every line of it so far, for the page to catch up on.
    public var lines: [BarLine] { written.flatMap(\.lines) }
}
