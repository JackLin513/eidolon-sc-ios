import Foundation

/// The `manifest.json` of a stand bundle. A stand bundle is a zip of her outfit lists,
/// her stand files and the character-to-default-outfit map; it installs beside the content
/// bundle, not inside it (ADR-0020).
public struct StandManifest: Codable, Sendable, Hashable {
    /// The stand bundle format this build reads.
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
        public var stand: StandConfig

        public init(id: String, stand: StandConfig) {
            self.id = id
            self.stand = stand
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
    public var createdAt: String
    public var characters: [Character]
    public var files: [String: FileRecord]

    public init(
        formatVersion: Int = StandManifest.supportedFormatVersion,
        kind: Kind = .stand,
        mode: Mode,
        createdAt: String,
        characters: [Character],
        files: [String: FileRecord]
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.mode = mode
        self.createdAt = createdAt
        self.characters = characters
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case kind
        case mode
        case createdAt = "created_at"
        case characters
        case files
    }
}

/// What the app knows about the stand bundle it installed.
public struct StandBundleInfo: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var installedAt: String
    public var characterCount: Int
    public var outfitCount: Int

    public init(
        formatVersion: Int,
        installedAt: String,
        characterCount: Int,
        outfitCount: Int
    ) {
        self.formatVersion = formatVersion
        self.installedAt = installedAt
        self.characterCount = characterCount
        self.outfitCount = outfitCount
    }
}
