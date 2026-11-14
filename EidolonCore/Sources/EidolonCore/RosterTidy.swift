import Foundation

/// How this device tidies the roster (spec #48, upstream `ConversationDirectory`): the roles
/// pinned to the top and those put out of the list. Hidden only takes a role out of the
/// list; her reach-outs, calls, history and affinity stay as they are.
public struct RosterTidy: Sendable, Equatable {
    public private(set) var pinned: Set<String>
    public private(set) var hidden: Set<String>

    public init(pinned: Set<String> = [], hidden: Set<String> = []) {
        self.pinned = pinned
        self.hidden = hidden
    }

    public func isPinned(_ characterID: String) -> Bool { pinned.contains(characterID) }

    public func isHidden(_ characterID: String) -> Bool { hidden.contains(characterID) }

    public mutating func togglePinned(_ characterID: String) {
        if pinned.contains(characterID) { pinned.remove(characterID) } else { pinned.insert(characterID) }
    }

    public mutating func toggleHidden(_ characterID: String) {
        if hidden.contains(characterID) { hidden.remove(characterID) } else { hidden.insert(characterID) }
    }

    /// How many of `characters` are hidden: the count the list's footer says.
    public func hiddenCount(of characters: [CharacterConfig]) -> Int {
        characters.reduce(0) { count, character in
            count + (hidden.contains(character.id) ? 1 : 0)
        }
    }

    /// The roster as the list shows it: pinned first, each group in the order it came in
    /// (the list's own recent-first order), hidden left out unless `showingHidden`.
    public func arrange(_ ordered: [CharacterConfig], showingHidden: Bool) -> [CharacterConfig] {
        let visible = showingHidden ? ordered : ordered.filter { !hidden.contains($0.id) }
        return visible.filter { pinned.contains($0.id) }
            + visible.filter { !pinned.contains($0.id) }
    }
}

/// Where the tidy choices live on this device. Not in the user library: they are this
/// phone's, as upstream keeps them in the browser.
public enum RosterStore {
    static func pinnedKey(_ franchise: String) -> String { "roster.\(franchise).pinned" }
    static func hiddenKey(_ franchise: String) -> String { "roster.\(franchise).hidden" }

    public static func load(
        franchise: String = "shiny",
        from defaults: UserDefaults = .standard
    ) -> RosterTidy {
        RosterTidy(
            pinned: Set(defaults.stringArray(forKey: pinnedKey(franchise)) ?? []),
            hidden: Set(defaults.stringArray(forKey: hiddenKey(franchise)) ?? [])
        )
    }

    public static func save(
        _ tidy: RosterTidy,
        franchise: String = "shiny",
        to defaults: UserDefaults = .standard
    ) {
        defaults.set(tidy.pinned.sorted(), forKey: pinnedKey(franchise))
        defaults.set(tidy.hidden.sorted(), forKey: hiddenKey(franchise))
    }
}
