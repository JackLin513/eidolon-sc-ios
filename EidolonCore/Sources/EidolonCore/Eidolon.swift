import Foundation
import GRDB

/// The single seam the app and its tests drive (ADR-0013): install a content
/// bundle, read what it contains, and later send turns. Everything the core
/// needs from outside is injected through its initialiser.
public actor Eidolon {
    public struct Location: Sendable, Hashable {
        public var root: URL

        public init(root: URL) {
            self.root = root
        }

        var contentRoot: URL { root.appendingPathComponent("Content", isDirectory: true) }
        var userDirectory: URL { root.appendingPathComponent("User", isDirectory: true) }
        var userDatabase: URL { userDirectory.appendingPathComponent("eidolon.sqlite") }
        /// The installed bundle's directory: where her stand's files are read from (ADR-0018).
        public var contentDirectory: URL { contentRoot.appendingPathComponent("current", isDirectory: true) }
        /// Where a separate stand package will be installed; empty until one is imported.
        public var standDirectory: URL { contentRoot.appendingPathComponent("stand", isDirectory: true) }
    }

    public nonisolated let location: Location

    let userQueue: DatabaseQueue
    private var content: ContentDatabase?
    /// The world setting, parsed once per installed bundle: it is 1.3 MB, read on the main
    /// path of every turn otherwise.
    var cachedWorld: WorldSetting?
    var worldCached = false
    /// What earlier turns are still writing down, per job, so the next turn can wait a
    /// while for it (ADR-0009).
    var memoryJobs: [Int64: Task<Void, Never>] = [:]
    /// What conversations are being named.
    var titleJobs: [String: Task<Void, Never>] = [:]
    /// The stand package's character map, read once per install.
    private var cachedStandConfigs: [String: StandConfig]?

    public init(location: Location) throws {
        self.location = location
        try FileManager.default.createDirectory(
            at: location.contentRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: location.userDirectory,
            withIntermediateDirectories: true
        )
        userQueue = try DatabaseQueue(path: location.userDatabase.path)
        try UserSchema.migrate(userQueue)
    }

    // MARK: - Content bundle

    /// True until a bundle this build can read has been installed successfully.
    public func needsContentBundle() throws -> Bool {
        try usableContentInfo() == nil
    }

    /// The installed bundle's record, when this build reads it. A bundle installed by
    /// another format or content schema stays on disk but is not used: the app asks for
    /// a new import instead (ADR-0003).
    public func usableContentInfo() throws -> ContentBundleInfo? {
        guard let info = try installedContentInfo(), info.isCurrent else { return nil }
        return info
    }

    public func installedContentInfo() throws -> ContentBundleInfo? {
        let stored: String? = try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = 'content.bundle'"
            )
        }
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ContentBundleInfo.self, from: data)
    }

    /// Installs a bundle atomically. On any failure the previously installed
    /// bundle stays in place (ADR-0003).
    @discardableResult
    public func install(
        bundleAt url: URL,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> ContentBundleInfo {
        let installer = ContentBundleInstaller(
            contentRoot: location.contentRoot,
            userDatabasePath: location.userDatabase,
            fileManager: .default
        )
        let info = try installer.install(url, progress: progress)
        let encoded = try JSONEncoder().encode(info)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state(key, value) VALUES('content.bundle', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [String(decoding: encoded, as: UTF8.self)]
            )
        }
        content = try openContent()
        // Another bundle's world is not this one's.
        cachedWorld = nil
        worldCached = false
        return info
    }

    /// Installs a stand bundle beside the content bundle, atomically. On any failure the
    /// previous stand directory stays in place (ADR-0020).
    @discardableResult
    public func installStand(
        bundleAt url: URL,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> StandBundleInfo {
        let installer = StandBundleInstaller(
            contentRoot: location.contentRoot,
            fileManager: .default
        )
        let info = try installer.install(url, progress: progress)
        try saveStandInfo(info)
        try? StandIndex.scan(at: location.standDirectory).write(to: location.standDirectory)
        cachedStandConfigs = nil
        return info
    }

    /// Moves the old all-in-one content bundle's stand tree into the separate stand
    /// directory and writes its manifest, once. If anything fails, the legacy tree stays
    /// where it is and `stand(for:)` keeps reading it.
    @discardableResult
    public func migrateLegacyStandIfNeeded() throws -> StandBundleInfo? {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: location.standDirectory.path),
              try installedStandInfo() == nil,
              try usableContentInfo() != nil
        else { return nil }

        let legacy = location.contentDirectory.appendingPathComponent("stand", isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path) else { return nil }
        let characters = try characters()
        let entries = characters.compactMap { character -> StandManifest.Character? in
            guard let config = character.stand else { return nil }
            return StandManifest.Character(id: character.id, stand: config)
        }
        guard !entries.isEmpty else { return nil }

        let staging = location.contentRoot.appendingPathComponent(
            ".stand-migration-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try fileManager.copyItem(
            at: legacy,
            to: staging.appendingPathComponent("stand", isDirectory: true)
        )
        let manifest = StandManifest(
            mode: .full,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            characters: entries,
            files: try standFileRecords(in: staging, fileManager: fileManager)
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: staging.appendingPathComponent("manifest.json"))

        guard !fileManager.fileExists(atPath: location.standDirectory.path) else { return nil }
        try fileManager.moveItem(at: staging, to: location.standDirectory)
        try? fileManager.removeItem(at: legacy)

        let info = StandBundleInfo(
            formatVersion: manifest.formatVersion,
            installedAt: manifest.createdAt,
            characterCount: entries.count,
            outfitCount: countStandOutfits(in: location.standDirectory, fileManager: fileManager)
        )
        try saveStandInfo(info)
        try? StandIndex.scan(at: location.standDirectory).write(to: location.standDirectory)
        cachedStandConfigs = nil
        return info
    }

    public func installedStandInfo() throws -> StandBundleInfo? {
        let stored: String? = try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = 'stand.bundle'"
            )
        }
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StandBundleInfo.self, from: data)
    }

    /// The stand package's character-to-outfit map; empty when no stand bundle is
    /// installed. The paths in it are relative to the stand directory.
    public func standConfigs() throws -> [String: StandConfig] {
        if let cachedStandConfigs { return cachedStandConfigs }
        let url = location.standDirectory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(StandManifest.self, from: data),
              manifest.kind == .stand
        else {
            cachedStandConfigs = [:]
            return [:]
        }
        var configs: [String: StandConfig] = [:]
        for character in manifest.characters {
            configs[character.id] = character.stand
        }
        cachedStandConfigs = configs
        return configs
    }

    /// Every installed stand file and its checksum; rebuilt once when an older install
    /// predates the index. The exporter reads this to make a delta bundle.
    public func standIndex() throws -> StandIndex {
        if let index = StandIndex.read(at: location.standDirectory) { return index }
        let index = try StandIndex.scan(at: location.standDirectory)
        try index.write(to: location.standDirectory)
        return index
    }

    public func standIndexData() throws -> Data {
        try standIndex().encoded()
    }

    // MARK: - Reading the content

    public func characters() throws -> [CharacterConfig] {
        try requireContent()
        let url = location.contentDirectory.appendingPathComponent("characters/characters.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("当前内容包缺少 characters/characters.json")
        }
        let values = try JSONDecoder().decode([JSONValue].self, from: data)
        return try values.map(CharacterConfig.init(json:))
    }

    public func episodeCount(characterID: String) throws -> Int {
        try requireContent()
        return try contentDatabase().episodeCount(characterID: characterID)
    }

    /// The names as the story says them, for Fish Audio and the recognizer. A bundle with
    /// no readings file has none, as upstream reads a missing `readings.toml`.
    public func readings() throws -> Readings {
        try requireContent()
        let url = location.contentDirectory.appendingPathComponent("characters/readings.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Readings() }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EidolonError.invalidBundle(
                "读不到 characters/readings.json：\(error.localizedDescription)"
            )
        }
        return try Readings(data: data)
    }

    /// Japan's holidays, as the installed bundle exported them.
    public func holidayTable() throws -> HolidayTable {
        try requireContent()
        let url = location.contentDirectory.appendingPathComponent("content/holidays.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("当前内容包缺少 content/holidays.json")
        }
        return try HolidayTable(data: data)
    }

    /// The latest message and unseen reach-out per character, keyed by character id.
    /// Both live in the user library, so this is empty until the first conversation.
    public func latestActivities() throws -> [String: LatestActivity] {
        try userQueue.read { db in
            var result: [String: LatestActivity] = [:]
            // The latest thing said or done, her reach-outs and conversation events
            // included: that is what the list shows.
            let latest = try Row.fetchAll(db, sql: """
                SELECT character_id, role, preview, event_kind, created_at FROM (
                    SELECT character_id, role, preview, event_kind, created_at,
                           ROW_NUMBER() OVER (
                               PARTITION BY character_id
                               ORDER BY created_at DESC, written DESC
                           ) AS rn
                    FROM (
                        SELECT c.character_id AS character_id,
                               m.role AS role,
                               COALESCE(NULLIF(m.zh, ''), NULLIF(m.ja, ''), NULLIF(m.text, '')) AS preview,
                               NULL AS event_kind,
                               m.created_at AS created_at,
                               m.rowid AS written
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversation_id
                        UNION ALL
                        SELECT c.character_id,
                               'character',
                               COALESCE(NULLIF(r.zh, ''), NULLIF(r.ja, '')),
                               NULL,
                               r.created_at,
                               r.rowid
                        FROM reach_outs r
                        JOIN conversations c ON c.id = r.conversation_id
                        UNION ALL
                        SELECT c.character_id,
                               'event',
                               NULL,
                               e.kind,
                               e.created_at,
                               e.id
                        FROM conversation_events e
                        JOIN conversations c ON c.id = e.conversation_id
                    )
                ) WHERE rn = 1
                """)
            for row in latest {
                let characterID: String = row["character_id"]
                result[characterID] = LatestActivity(
                    lastMessagePreview: row["preview"],
                    lastMessageRole: row["role"],
                    lastMessageAt: row["created_at"],
                    lastEventKind: row["event_kind"],
                    unseenReachOut: false
                )
            }

            let unseen = try Row.fetchAll(db, sql: """
                SELECT c.character_id AS character_id, COUNT(*) AS count
                FROM reach_outs r
                JOIN conversations c ON c.id = r.conversation_id
                WHERE r.seen = 0
                GROUP BY c.character_id
                """)
            for row in unseen {
                let characterID: String = row["character_id"]
                var activity = result[characterID] ?? LatestActivity()
                activity.unseenReachOut = (row["count"] as Int) > 0
                result[characterID] = activity
            }
            return result
        }
    }

    /// The avatar file inside the installed bundle, if she has one.
    public func avatarURL(for characterID: String) -> URL? {
        guard let character = try? characters().first(where: { $0.id == characterID }),
              let path = character.avatar
        else { return nil }
        let url = location.contentDirectory.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Her stand: the default outfit and, when her list reads and its files are in
    /// the bundle, the outfits she can change into, all under the installed bundle
    /// (ADR-0018). nil when the bundle carries no stand for her.
    /// Her stand: from the separately installed stand package when it has her, otherwise
    /// from the legacy content bundle (ADR-0018, ADR-0020). nil when neither carries a
    /// usable stand for her.
    public func stand(for characterID: String) -> CharacterStand? {
        guard let character = try? characters().first(where: { $0.id == characterID })
        else { return nil }

        if let config = try? standConfigs()[characterID],
           let found = StandResolver(roots: [location.standDirectory]).stand(for: config) {
            return found
        }
        guard let config = character.stand else { return nil }
        return StandResolver(roots: [location.contentDirectory]).stand(for: config)
    }

    // MARK: - Plumbing

    private func requireContent() throws {
        guard try usableContentInfo() != nil else {
            throw EidolonError.contentNotInstalled
        }
    }

    private func openContent() throws -> ContentDatabase {
        try ContentDatabase(
            contentDirectory: location.contentDirectory,
            userDatabasePath: location.userDatabase
        )
    }

    func contentDatabase() throws -> ContentDatabase {
        if let content { return content }
        let opened = try openContent()
        content = opened
        return opened
    }

    private func saveStandInfo(_ info: StandBundleInfo) throws {
        let encoded = try JSONEncoder().encode(info)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state(key, value) VALUES('stand.bundle', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [String(decoding: encoded, as: UTF8.self)]
            )
        }
    }

    private func standFileRecords(
        in directory: URL,
        fileManager: FileManager
    ) throws -> [String: StandManifest.FileRecord] {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [:] }
        var records: [String: StandManifest.FileRecord] = [:]
        let base = directory.standardizedFileURL.pathComponents
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                ?? false
            if isDirectory { continue }
            let relative = url.standardizedFileURL.pathComponents
                .dropFirst(base.count)
                .joined(separator: "/")
            guard !relative.isEmpty, let data = try? Data(contentsOf: url) else { continue }
            records[relative] = StandManifest.FileRecord(
                size: data.count,
                crc32: CRC32.hex(data)
            )
        }
        return records
    }

    private func countStandOutfits(in directory: URL, fileManager: FileManager) -> Int {
        let idols = directory.appendingPathComponent("stand/idols", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: idols,
            includingPropertiesForKeys: nil
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.lastPathComponent == "data.json" {
            count += 1
        }
        return count
    }
}
