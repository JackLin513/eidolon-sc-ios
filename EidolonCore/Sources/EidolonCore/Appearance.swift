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

/// The independent outfit/pose catalog for a v2 static stand. SC's card/look hierarchy is
/// still represented by its own source; this catalog is the totsulover side of the shared
/// selection model.
public struct AppearanceCatalog: Sendable, Hashable {
    public var characterID: String
    public var dimensions: [AppearanceDimension]

    public init(characterID: String, bases: [StaticStandManifest.Base]) {
        self.characterID = characterID
        let outfits = Set(bases.map(\.outfit)).sorted()
        let poses = Set(bases.map(\.pose)).sorted()
        dimensions = []
        if !outfits.isEmpty {
            dimensions.append(AppearanceDimension(
                id: "outfit",
                title: "衣装",
                options: outfits.map { AppearanceOption(id: $0, title: $0, values: ["outfit": $0]) }
            ))
        }
        if !poses.isEmpty {
            dimensions.append(AppearanceDimension(
                id: "pose",
                title: "姿态",
                options: poses.map { AppearanceOption(id: $0, title: $0, values: ["pose": $0]) }
            ))
        }
    }

    public func dimension(_ id: String) -> AppearanceDimension? {
        dimensions.first { $0.id == id }
    }

    public func base(
        outfit: String?,
        pose: String?,
        in bases: [StaticStandManifest.Base]
    ) -> StaticStandManifest.Base? {
        bases.first { $0.outfit == outfit && $0.pose == pose }
    }
}
