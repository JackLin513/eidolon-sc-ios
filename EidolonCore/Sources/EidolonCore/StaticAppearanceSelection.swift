import Foundation

/// The last static appearance chosen per character, on this device only. This is user
/// preference, not content: like the Spine outfit choice it lives in UserDefaults.
public struct StaticAppearanceSelection: Codable, Hashable, Sendable {
    public var outfit: String?
    public var pose: String?
    public var emotion: StandEmotion

    public init(outfit: String? = nil, pose: String? = nil, emotion: StandEmotion = .calm) {
        self.outfit = outfit
        self.pose = pose
        self.emotion = emotion
    }
}

public struct StaticAppearanceStore: @unchecked Sendable {
    public static let defaultsKey = "eidolon.staticAppearance"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func selection(for characterID: String) -> StaticAppearanceSelection {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let all = try? JSONDecoder().decode([String: StaticAppearanceSelection].self, from: data),
              let found = all[characterID]
        else { return StaticAppearanceSelection() }
        return found
    }

    public func remember(_ selection: StaticAppearanceSelection, for characterID: String) {
        var all: [String: StaticAppearanceSelection] = [:]
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([String: StaticAppearanceSelection].self, from: data) {
            all = decoded
        }
        all[characterID] = selection
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
