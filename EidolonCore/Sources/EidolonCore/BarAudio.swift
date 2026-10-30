import Foundation

/// One track of the jukebox: the original's sound number, its file and the title it shows
/// (upstream `lib/barAudio.ts`, read from `characters/bar_audio.json`).
public struct BarTrack: Codable, Sendable, Hashable, Identifiable {
    /// The original's sound number.
    public var id: Int
    public var file: String
    public var title: String

    public init(id: Int, file: String, title: String) {
        self.id = id
        self.file = file
        self.title = title
    }
}

/// One of the bar's sound effects, by the name the bar plays it under.
public struct BarSoundEffect: Codable, Sendable, Hashable {
    public var name: String
    public var file: String

    public init(name: String, file: String) {
        self.name = name
        self.file = file
    }
}

/// The list beside the character configuration (`characters/bar_audio.json`, beside
/// `characters.json` in the content bundle): the jukebox's tracks in their order, the default
/// playlist and the sound effects.
public struct BarAudioCatalog: Codable, Sendable, Hashable {
    // The file's own names, which upstream's frontend copy shares.
    public var tracks: [BarTrack]
    public var defaultPlaylist: [Int]
    public var sfx: [BarSoundEffect]

    enum CodingKeys: String, CodingKey {
        case tracks
        case defaultPlaylist = "default_playlist"
        case sfx
    }

    public init(tracks: [BarTrack], defaultPlaylist: [Int], sfx: [BarSoundEffect]) {
        self.tracks = tracks
        self.defaultPlaylist = defaultPlaylist
        self.sfx = sfx
    }

    /// What the bar can play of the catalog, when its sound package has the files: the tracks
    /// in the jukebox's order and the default playlist, both only what is there, and the sound
    /// effects it has. Nothing without a sound package at all.
    public func available(with package: BarAudioPackage?) -> BarAudio {
        guard let package else { return BarAudio() }
        let tracks = tracks.filter { package.tracks.contains($0.id) }
        let ids = Set(tracks.map(\.id))
        return BarAudio(
            tracks: tracks,
            playlist: defaultPlaylist.filter(ids.contains),
            sfx: sfx.map(\.name).filter(package.sfx.contains)
        )
    }
}

/// What the bar can play: the tracks in the jukebox's order, the default playlist, the sound
/// effects.
public struct BarAudio: Sendable, Hashable {
    public var tracks: [BarTrack]
    public var playlist: [Int]
    public var sfx: [String]

    public init(tracks: [BarTrack] = [], playlist: [Int] = [], sfx: [String] = []) {
        self.tracks = tracks
        self.playlist = playlist
        self.sfx = sfx
    }

    /// Whether the jukebox can be used at all: one track to play.
    public var hasJukebox: Bool { !tracks.isEmpty }

    public func track(_ id: Int) -> BarTrack? {
        tracks.first { $0.id == id }
    }
}

/// What a bar sound package says it has: the track ids and sound effect names in it (upstream's
/// `bar/manifest.json`).
public struct BarAudioPackage: Codable, Sendable, Hashable {
    public var tracks: [Int]
    public var sfx: [String]

    public init(tracks: [Int], sfx: [String]) {
        self.tracks = tracks
        self.sfx = sfx
    }
}

extension BarAudioCatalog {
    /// The catalog of an installed content directory, if the bundle has one.
    public static func read(in contentDirectory: URL) throws -> BarAudioCatalog? {
        let url = contentDirectory.appendingPathComponent("characters/bar_audio.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(BarAudioCatalog.self, from: data)
        } catch {
            throw EidolonError.invalidBundle(
                "characters/bar_audio.json 无法解析：\(error.localizedDescription)"
            )
        }
    }
}
