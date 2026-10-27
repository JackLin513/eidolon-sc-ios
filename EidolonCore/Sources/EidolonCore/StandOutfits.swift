import Foundation

/// Which of a card's outfits (GLOSSARY.md「衣装」): her everyday clothes on it, or its stage
/// costume. The order is the order the card shows them in.
public enum OutfitLook: String, Sendable, Hashable, CaseIterable {
    case everyday
    case stage
}

public extension OutfitCard {
    /// What this card carries, everyday clothes first; a card with only one is listed with
    /// just that one.
    var looks: [OutfitLook] {
        OutfitLook.allCases.filter { outfit(for: $0) != nil }
    }

    /// Whether the card has one outfit in all, so its switch is greyed out (upstream
    /// 「只有一套」).
    var hasOnlyOneLook: Bool { looks.count == 1 }

    /// The outfit on this side of the card, when it has one.
    func outfit(for look: OutfitLook) -> StandOutfit? {
        switch look {
        case .everyday: everyday
        case .stage: stage
        }
    }
}

public extension OutfitList {
    /// Where an outfit is in her list: its card, and which of the card's outfits it is.
    func find(_ outfitID: String) -> (card: OutfitCard, look: OutfitLook, outfit: StandOutfit)? {
        for card in cards {
            for look in OutfitLook.allCases {
                if let outfit = card.outfit(for: look), outfit.id == outfitID {
                    return (card, look, outfit)
                }
            }
        }
        return nil
    }
}

/// The outfit chosen for her on this device (spec「衣装与换衣装」), one per character.
/// It lives in `UserDefaults` because losing it is harmless: she falls back to her
/// default outfit, and the choice is only ever this device's (ADR-0010 keeps keys out,
/// not preferences like this one).
public struct StandOutfitChoiceStore: @unchecked Sendable {
    /// Where the choices sit, the same key upstream uses in its local storage.
    public static let defaultsKey = "eidolon.standOutfits"

    /// `UserDefaults` is thread-safe but not marked `Sendable`; the store is a thin value
    /// over it and carries no mutable state of its own.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The outfit chosen for her, or nil when none is or what is stored cannot be read.
    public func choice(for characterID: String) -> String? {
        Self.choices(in: defaults)[characterID]
    }

    /// Remember the outfit chosen for her, keeping the other characters' choices. Whether
    /// it still loads does not matter here: a call that cannot load it falls back to her
    /// default outfit without forgetting the choice.
    public func remember(_ outfitID: String, for characterID: String) {
        var choices = Self.choices(in: defaults)
        choices[characterID] = outfitID
        guard let data = try? JSONEncoder().encode(choices) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func choices(in defaults: UserDefaults) -> [String: String] {
        guard let data = defaults.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return stored
    }
}

extension OutfitList {
    /// The outfit with this number, as her list carries it; nil when the list does not.
    func outfit(withID id: String) -> StandOutfit? {
        find(id)?.outfit
    }
}

public extension CharacterStand {
    /// The outfit she wears: the one chosen for her when her list still has it, otherwise
    /// her default outfit. When the list cannot be read, the choice is still tried where the
    /// bundle keeps outfits, so a call dialled early or with a broken list keeps the outfit
    /// she was wearing (upstream `wornOutfit` with no cards). A choice that cannot load is
    /// not forgotten — only not worn.
    func worn(choice: String?) -> StandOutfit {
        guard let choice else { return defaultOutfit }
        if let chosen = outfitList?.outfit(withID: choice) {
            return chosen
        }
        if outfitList == nil, let remembered = Self.rememberedOutfit(choice, beside: defaultOutfit) {
            return remembered
        }
        return defaultOutfit
    }

    /// Where an outfit number sits beside her default outfit: `stand/<enza>` or
    /// `stand_costume/<enza>`, under the same `idols` directory. An id that is not one of
    /// those shapes is refused rather than turned into a path.
    static func rememberedOutfit(_ id: String, beside defaultOutfit: StandOutfit) -> StandOutfit? {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              parts[0] == "stand" || parts[0] == "stand_costume",
              !parts[1].isEmpty,
              parts[1].allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        let idols = defaultOutfit.directory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return StandOutfit(id: id, directory: idols.appendingPathComponent(id, isDirectory: true))
    }

    /// The outfits a call tries, in order: the one she wears, then her default outfit. One
    /// attempt when they are the same, so her default is never loaded twice.
    func outfitsToTry(choice: String?) -> [StandOutfit] {
        let worn = worn(choice: choice)
        let same = worn.directory.standardizedFileURL == defaultOutfit.directory.standardizedFileURL
        return same ? [worn] : [worn, defaultOutfit]
    }
}
