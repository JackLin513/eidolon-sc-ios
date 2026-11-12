import Foundation

/// A small, image-based stand package. It deliberately does not reuse the Spine
/// `StandManifest`: a static stand has one PNG per expression, not outfits, atlases or
/// animation tables. It follows the same install and content-binding rules.
public struct StaticStandManifest: Codable, Sendable, Hashable {
    public static let supportedFormatVersion = 2

    public enum Kind: String, Codable, Sendable {
        case stand
    }

    public enum Mode: String, Codable, Sendable {
        case full
        case delta
    }

    /// One outfit/pose base in a v2 package. `expressions` maps the canonical emotion
    /// raw value to the package-relative image for that base. v1 packages omit bases and
    /// use `Character.expressions` as one implicit base.
    public struct Base: Codable, Sendable, Hashable {
        public var id: String
        public var outfit: String
        public var pose: String
        public var source: String?
        public var expressions: [String: String]

        public init(
            id: String,
            outfit: String,
            pose: String,
            source: String? = nil,
            expressions: [String: String]
        ) {
            self.id = id
            self.outfit = outfit
            self.pose = pose
            self.source = source
            self.expressions = expressions
        }
    }

    public struct Character: Codable, Sendable, Hashable {
        public var id: String
        public var characterKey: String?
        /// v1: Emotion raw value -> package-relative image path.
        public var expressions: [String: String]
        /// v2: explicit outfit/pose bases.
        public var bases: [Base]?

        public init(
            id: String,
            characterKey: String? = nil,
            expressions: [String: String],
            bases: [Base]? = nil
        ) {
            self.id = id
            self.characterKey = characterKey
            self.expressions = expressions
            self.bases = bases
        }

        /// Every expression in this character, v1 or v2.
        public var allExpressions: [String: String] {
            var result = expressions
            for base in bases ?? [] {
                for (emotion, path) in base.expressions where result[emotion] == nil {
                    result[emotion] = path
                }
            }
            return result
        }
    }

    public struct FileRecord: Codable, Sendable, Hashable {
        public var size: Int
        public var crc32: String?

        public init(size: Int, crc32: String? = nil) {
            self.size = size
            self.crc32 = crc32
        }
    }

    public var formatVersion: Int
    public var kind: Kind
    public var mode: Mode
    public var renderer: String
    public var franchise: String
    /// Stable content family this stand belongs to. New packages set it; old content is
    /// allowed to be unbound during migration.
    public var contentSetID: String?
    public var createdAt: String
    public var characters: [Character]
    public var files: [String: FileRecord]

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case kind
        case mode
        case renderer
        case franchise
        case contentSetID
        case createdAt = "created_at"
        case characters
        case files
    }

    public init(
        formatVersion: Int = supportedFormatVersion,
        kind: Kind = .stand,
        mode: Mode = .full,
        renderer: String = "static",
        franchise: String,
        contentSetID: String? = nil,
        createdAt: String,
        characters: [Character],
        files: [String: FileRecord]
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.mode = mode
        self.renderer = renderer
        self.franchise = franchise
        self.contentSetID = contentSetID
        self.createdAt = createdAt
        self.characters = characters
        self.files = files
    }
}

public struct StaticStandBundleInfo: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var franchise: String
    public var contentSetID: String?
    public var installedAt: String
    public var characterCount: Int
    public var expressionCount: Int
    public var mode: StaticStandManifest.Mode
    /// v2 bases; absent for old v1 records.
    public var baseCount: Int?

    public init(
        formatVersion: Int,
        franchise: String,
        contentSetID: String?,
        installedAt: String,
        characterCount: Int,
        expressionCount: Int,
        mode: StaticStandManifest.Mode,
        baseCount: Int? = nil
    ) {
        self.formatVersion = formatVersion
        self.franchise = franchise
        self.contentSetID = contentSetID
        self.installedAt = installedAt
        self.characterCount = characterCount
        self.expressionCount = expressionCount
        self.mode = mode
        self.baseCount = baseCount
    }
}
