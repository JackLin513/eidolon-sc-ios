import Foundation

/// The `manifest.json` inside a content bundle (ADR-0003).
public struct ContentManifest: Codable, Sendable, Hashable {
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

    public init(
        formatVersion: Int,
        contentSchemaVersion: Int,
        installedAt: String,
        embeddingModel: String,
        embeddingDimensions: Int,
        episodeCount: Int,
        passageCount: Int,
        characterCount: Int
    ) {
        self.formatVersion = formatVersion
        self.contentSchemaVersion = contentSchemaVersion
        self.installedAt = installedAt
        self.embeddingModel = embeddingModel
        self.embeddingDimensions = embeddingDimensions
        self.episodeCount = episodeCount
        self.passageCount = passageCount
        self.characterCount = characterCount
    }
}
