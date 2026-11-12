import Foundation

/// One selectable value on an appearance dimension. `values` carries the dimension
/// values this option contributes, so the same option type can serve SC's card/look
/// hierarchy and totsulover's independent outfit/pose axes.
public struct AppearanceOption: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var values: [String: String]

    public init(id: String, title: String, values: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.values = values
    }
}

public struct AppearanceDimension: Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var options: [AppearanceOption]

    public init(id: String, title: String, options: [AppearanceOption]) {
        self.id = id
        self.title = title
        self.options = options
    }
}

/// What the wardrobe and the call screen carry between each other. It is deliberately
/// renderer-agnostic: the Spine adapter reads `outfit`/`look`, the static adapter reads
/// `outfit`/`pose`, and both share this value.
public struct AppearanceSelection: Sendable, Hashable {
    public var characterID: String
    public var values: [String: String]
    public var emotion: StandEmotion

    public init(
        characterID: String,
        values: [String: String] = [:],
        emotion: StandEmotion = .calm
    ) {
        self.characterID = characterID
        self.values = values
        self.emotion = emotion
    }

    public var outfit: String? { values["outfit"] }
    public var pose: String? { values["pose"] }
    public var look: String? { values["look"] }

    /// A stable key for remembering the selected appearance per character.
    public var storageKey: String {
        values.keys.sorted().map { "\($0)=\(values[$0] ?? "")" }.joined(separator: "&")
    }
}
