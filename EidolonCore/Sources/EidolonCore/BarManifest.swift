import Foundation

/// The `manifest.json` of a bar bundle. The bar is a separate package beside the content
/// and the stand bundles (ADR-0021): its pictures, its font and its sound, installed as a
/// whole. `tools/export_bar_bundle.py` writes it.
public struct BarManifest: Codable, Sendable, Hashable {
    /// The bar bundle format this build reads.
    public static let supportedFormatVersion = 1

    public enum Kind: String, Codable, Sendable {
        case bar
    }

    public struct FileRecord: Codable, Sendable, Hashable {
        public var size: Int
        public var crc32: String?

        public init(size: Int, crc32: String? = nil) {
            self.size = size
            self.crc32 = crc32
        }
    }

    public var formatVersion: Int = BarManifest.supportedFormatVersion
    public var kind: Kind = .bar
    public var createdAt: String = ""
    /// How many pictures are in `bar/img/`; the manifest's file list is what is checked.
    public var images: Int
    /// The font files shipped, e.g. `fusion-pixel-12px-zh_hans.woff2`.
    public var fonts: [String]
    /// The jukebox tracks actually packaged, by the ids `bar_audio.json` uses. Empty when
    /// the package carries no sound: the jukebox then stays grey.
    public var tracks: [Int]
    /// The sound effects actually packaged, by their `bar_audio.json` names.
    public var sfx: [String]
    public var files: [String: FileRecord]

    public init(
        formatVersion: Int = BarManifest.supportedFormatVersion,
        kind: Kind = .bar,
        createdAt: String = "",
        images: Int = 0,
        fonts: [String] = [],
        tracks: [Int] = [],
        sfx: [String] = [],
        files: [String: FileRecord] = [:]
    ) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.createdAt = createdAt
        self.images = images
        self.fonts = fonts
        self.tracks = tracks
        self.sfx = sfx
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case kind
        case createdAt = "created_at"
        case images
        case fonts
        case tracks
        case sfx
        case files
    }
}

/// What the app knows about the bar package it installed. The app asks for the package
/// until `installedBarInfo()` returns one.
public struct BarBundleInfo: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var installedAt: String
    public var imageCount: Int
    public var fontCount: Int
    public var trackCount: Int
    public var sfxCount: Int
    /// The package's manifest itself, kept beside the summary: which tracks and sounds it
    /// carries, for the bar to play just those.
    public var manifest: BarManifest

    public init(
        formatVersion: Int,
        installedAt: String,
        imageCount: Int,
        fontCount: Int,
        trackCount: Int,
        sfxCount: Int,
        manifest: BarManifest = BarManifest()
    ) {
        self.formatVersion = formatVersion
        self.installedAt = installedAt
        self.imageCount = imageCount
        self.fontCount = fontCount
        self.trackCount = trackCount
        self.sfxCount = sfxCount
        self.manifest = manifest
    }

    /// The bar can play its own sound only when the package carries it.
    public var hasAudio: Bool { trackCount > 0 || sfxCount > 0 }
}
