import Foundation

/// A small, image-based stand package. It deliberately does not reuse the Spine
/// `StandManifest`: a static stand has one PNG per expression, not outfits, atlases or
/// animation tables. It follows the same install and content-binding rules.
public struct StaticStandManifest: Codable, Sendable, Hashable {
    public static let supportedFormatVersion = 1

    public enum Kind: String, Codable, Sendable {
        case stand
    }

    public enum Mode: String, Codable, Sendable {
        case full
        case delta
    }

    public struct Character: Codable, Sendable, Hashable {
        public var id: String
        public var characterKey: String?
        /// Emotion raw value -> package-relative image path.
        public var expressions: [String: String]

        public init(id: String, characterKey: String? = nil, expressions: [String: String]) {
            self.id = id
            self.characterKey = characterKey
            self.expressions = expressions
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

    public init(
        formatVersion: Int,
        franchise: String,
        contentSetID: String?,
        installedAt: String,
        characterCount: Int,
        expressionCount: Int,
        mode: StaticStandManifest.Mode
    ) {
        self.formatVersion = formatVersion
        self.franchise = franchise
        self.contentSetID = contentSetID
        self.installedAt = installedAt
        self.characterCount = characterCount
        self.expressionCount = expressionCount
        self.mode = mode
    }
}
