import Foundation

/// Which presentation backend draws a character. `spine-webgl` is the built-in 2D player;
/// `unity-uaal` is the optional embedded 3D player; `avatar` is the page-level fallback
/// when no renderer can draw.
public struct RuntimeID: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let spineWebGL = RuntimeID("spine-webgl")
    public static let unityUaaL = RuntimeID("unity-uaal")
    public static let realityKit = RuntimeID("realitykit")
    public static let vnLayered = RuntimeID("vn-layered")
    /// Not implemented: kept only as a negative example for the later multi-franchise work.
    public static let unreal = RuntimeID("unreal")
    /// Never a renderer: the page shows the avatar instead.
    public static let avatar = RuntimeID("avatar")

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The producer's choice for how a character is drawn. `auto` prefers 3D when the build
/// and the content actually provide it, and otherwise stays on 2D.
public enum RuntimePreference: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case auto
    case spine = "2d"
    case unity = "3d"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: "自动"
        case .spine: "2D 立绘"
        case .unity: "3D 立绘"
        }
    }
}

/// How she should look at one instant, independent of which animation names a backend uses.
/// The 2D adapter turns this back into `StandDirection` + the outfit's animation table; the
/// 3D adapter sends it as its own messages.
public struct PresentationFrame: Codable, Sendable, Hashable {
    public var emotion: StandEmotion
    public var speaking: Bool
    public var looking: Bool
    public var nod: StandNod?
    public var framing: StandFraming
    public var reducedMotion: Bool

    public init(
        emotion: StandEmotion,
        speaking: Bool,
        looking: Bool,
        nod: StandNod? = nil,
        framing: StandFraming,
        reducedMotion: Bool = false
    ) {
        self.emotion = emotion
        self.speaking = speaking
        self.looking = looking
        self.nod = nod
        self.framing = framing
        self.reducedMotion = reducedMotion
    }

    /// The frame for a `StandDirection`, which is what the call's director produces.
    public init(_ direction: StandDirection, framing: StandFraming, reducedMotion: Bool) {
        self.init(
            emotion: direction.mood,
            speaking: direction.speaking,
            looking: direction.looking,
            nod: direction.nod,
            framing: framing,
            reducedMotion: reducedMotion
        )
    }
}

/// What a backend can actually do, after it has prepared. The package's declaration is an
/// upper bound; only this measured value drives the UI.
public struct RuntimeCapabilities: Codable, Sendable, Hashable {
    public var expressions: Set<StandEmotion>
    public var framings: Set<StandFraming>
    public var fullBleed: Bool
    public var outfitSwitch: Bool
    public var snapshot: Bool
    public var lipSync: Bool
    public var gaze: Bool
    public var gesture: Bool
    public var engine: String?

    public init(
        expressions: Set<StandEmotion> = Set(StandEmotion.allCases),
        framings: Set<StandFraming> = Set(StandFraming.allCases),
        fullBleed: Bool = false,
        outfitSwitch: Bool = true,
        snapshot: Bool = true,
        lipSync: Bool = true,
        gaze: Bool = true,
        gesture: Bool = true,
        engine: String? = nil
    ) {
        self.expressions = expressions
        self.framings = framings
        self.fullBleed = fullBleed
        self.outfitSwitch = outfitSwitch
        self.snapshot = snapshot
        self.lipSync = lipSync
        self.gaze = gaze
        self.gesture = gesture
        self.engine = engine
    }

    /// The built-in 2D player: a lower-stage stand, not full-bleed, with every expression
    /// and framing the Spine table knows.
    public static let spine2D = RuntimeCapabilities(engine: "spine-webgl/3.6")

    /// The embedded 3D player: full-screen, same expressions, outfit switch through the
    /// model package.
    public static let unity3D = RuntimeCapabilities(
        fullBleed: true,
        // The embedded scene has no snapshot API; thumbnails fall back to the card.
        snapshot: false,
        engine: "unity-uaal"
    )

    public func supports(_ emotion: StandEmotion) -> Bool { expressions.contains(emotion) }
    public func supports(_ framing: StandFraming) -> Bool { framings.contains(framing) }
}

/// Why a renderer cannot draw. The page treats every case the same: fall back and keep the
/// call going.
public enum RuntimeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case loadFailed(String)
    case contentMissing(String)
    case capabilityMissing(String)

    public var description: String {
        switch self {
        case .unavailable(let reason): "运行时不可用：\(reason)"
        case .loadFailed(let reason): "加载失败：\(reason)"
        case .contentMissing(let reason): "内容缺失：\(reason)"
        case .capabilityMissing(let reason): "能力不足：\(reason)"
        }
    }
}

/// What a renderer reports after it prepared: the measured capabilities and where the
/// character sits, so the page can frame her without knowing the backend.
public struct RuntimeReport: Codable, Sendable, Hashable {
    public var resolved: RuntimeCapabilities
    public var bounds: StandBounds
    public var extent: StandBounds?

    public init(resolved: RuntimeCapabilities, bounds: StandBounds, extent: StandBounds? = nil) {
        self.resolved = resolved
        self.bounds = bounds
        self.extent = extent
    }
}

/// What a content package asks for: a preferred runtime, an optional exact engine version,
/// and the order to try when the preferred one is unavailable.
public struct RuntimeRequirement: Codable, Sendable, Hashable {
    public var preferred: RuntimeID
    public var engineVersion: String?
    public var fallbacks: [RuntimeID]

    public init(
        preferred: RuntimeID,
        engineVersion: String? = nil,
        fallbacks: [RuntimeID] = [.spineWebGL, .avatar]
    ) {
        self.preferred = preferred
        self.engineVersion = engineVersion
        self.fallbacks = fallbacks
    }

    /// The built-in 2D package requirement.
    public static let spine2D = RuntimeRequirement(preferred: .spineWebGL)

    /// Prefer the optional 3D runtime, then fall back to the built-in 2D player.
    public static let unityPreferred = RuntimeRequirement(
        preferred: .unityUaaL,
        fallbacks: [.spineWebGL, .avatar]
    )
}

/// Pure resolution of a requirement against the runtimes compiled into this build.
public enum RuntimeResolver {
    /// The requirement's preference followed by its fallbacks, without duplicates.
    public static func order(_ requirement: RuntimeRequirement) -> [RuntimeID] {
        var result: [RuntimeID] = []
        for id in [requirement.preferred] + requirement.fallbacks where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    /// The first runtime in the requirement's order that this build has.
    public static func resolve(
        _ requirement: RuntimeRequirement,
        available: Set<RuntimeID>
    ) -> RuntimeID? {
        order(requirement).first { available.contains($0) }
    }
}

/// A license/source note carried by a content package. It is metadata, not a legal conclusion.
public struct LegalNotice: Codable, Sendable, Hashable {
    public var source: String?
    public var license: String?
    public var notes: String?

    public init(source: String? = nil, license: String? = nil, notes: String? = nil) {
        self.source = source
        self.license = license
        self.notes = notes
    }
}

/// The kinds of package this app installs. `model3d` is the S1 addition; `universe` is
/// reserved for the later crossover work and is not installed in S1.
public enum ContentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case content
    case stand
    case bar
    case model3d
    case universe
}

/// The common header every package carries, independent of kind. Existing content/stand/bar
/// manifests stay as they are; this is the shape the new `model3d` manifest and the future
/// multi-package work share.
public struct PackageHeader: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var kind: ContentKind
    /// The franchise this package belongs to; nil for packages written before S3.
    public var franchise: String?
    public var runtime: RuntimeRequirement?
    public var capabilities: RuntimeCapabilities?
    public var legal: LegalNotice?

    public init(
        formatVersion: Int,
        kind: ContentKind,
        franchise: String? = nil,
        runtime: RuntimeRequirement? = nil,
        capabilities: RuntimeCapabilities? = nil,
        legal: LegalNotice? = nil
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.franchise = franchise
        self.runtime = runtime
        self.capabilities = capabilities
        self.legal = legal
    }

    /// The franchise used by packages from before the multi-franchise work.
    public var resolvedFranchise: String { franchise ?? "shiny" }
}
