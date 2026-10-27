import Foundation

/// The `manifest.json` inside a content bundle (ADR-0003).
public struct ContentManifest: Codable, Sendable, Hashable {
    /// The bundle format this app reads. Version 2 added birthdays, idol numbers and the
    /// holiday table, so a version-1 bundle has to be exported again.
    public static let supportedFormatVersion = 2

    public struct Embedding: Codable, Sendable, Hashable {
        public var model: String
        public var dimensions: Int
    }

    public struct Characters: Codable, Sendable, Hashable {
        public var count: Int
        public var ids: [String]
    }

    public struct FileRecord: Codable, Sendable, Hashable {
        public var size: Int
        public var crc32: String?
    }

    public var formatVersion: Int
    public var contentSchemaVersion: Int
    public var createdAt: String
    public var embedding: Embedding
    public var content: [String: Int]
    public var characters: Characters
    public var files: [String: FileRecord]?

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case contentSchemaVersion = "content_schema_version"
        case createdAt = "created_at"
        case embedding
        case content
        case characters
        case files
    }
}

/// What the app knows about the bundle it has installed.
public struct ContentBundleInfo: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var contentSchemaVersion: Int
    public var installedAt: String
    public var embeddingModel: String
    public var embeddingDimensions: Int
    public var episodeCount: Int
    public var passageCount: Int
    public var characterCount: Int
    /// How many outfits the bundle carries under `stand/idols/`.
    public var standOutfitCount: Int

    public init(
        formatVersion: Int,
        contentSchemaVersion: Int,
        installedAt: String,
        embeddingModel: String,
        embeddingDimensions: Int,
        episodeCount: Int,
        passageCount: Int,
        characterCount: Int,
        standOutfitCount: Int = 0
    ) {
        self.formatVersion = formatVersion
        self.contentSchemaVersion = contentSchemaVersion
        self.installedAt = installedAt
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.episodeCount = episodeCount
        self.passageCount = passageCount
        self.characterCount = characterCount
        self.standOutfitCount = standOutfitCount
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion
        case contentSchemaVersion
        case installedAt
        case embeddingModel
        case embeddingDimensions
        case episodeCount
        case passageCount
        case characterCount
        case standOutfitCount
    }

    /// Bundles installed by an older app have no stand count.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        contentSchemaVersion = try container.decode(Int.self, forKey: .contentSchemaVersion)
        installedAt = try container.decode(String.self, forKey: .installedAt)
        embeddingModel = try container.decode(String.self, forKey: .embeddingModel)
        embeddingDimensions = try container.decode(Int.self, forKey: .embeddingDimensions)
        episodeCount = try container.decode(Int.self, forKey: .episodeCount)
        passageCount = try container.decode(Int.self, forKey: .passageCount)
        characterCount = try container.decode(Int.self, forKey: .characterCount)
        standOutfitCount = try container.decodeIfPresent(Int.self, forKey: .standOutfitCount) ?? 0
    }

    /// Whether this build reads what was installed. A bundle from another format or
    /// content schema is imported again rather than run on half-understood (ADR-0003):
    /// the app would otherwise fail later, or silently miss what the new format added.
    public var isCurrent: Bool {
        formatVersion == ContentManifest.supportedFormatVersion
            && contentSchemaVersion == ContentSchema.version
    }
}
