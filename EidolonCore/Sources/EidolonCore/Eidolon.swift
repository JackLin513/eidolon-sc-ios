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
    }

    public nonisolated let location: Location

    let userQueue: DatabaseQueue
    private var content: ContentDatabase?
    /// What earlier turns are still writing down, per job, so the next turn can wait a
    /// while for it (ADR-0009).
    var memoryJobs: [Int64: Task<Void, Never>] = [:]
    /// What conversations are being named.
    var titleJobs: [String: Task<Void, Never>] = [:]

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

    /// True until a bundle has been installed successfully.
    public func needsContentBundle() throws -> Bool {
        try installedContentInfo() == nil
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
    public func install(bundleAt url: URL) throws -> ContentBundleInfo {
        let installer = ContentBundleInstaller(
            contentRoot: location.contentRoot,
            userDatabasePath: location.userDatabase,
            fileManager: .default
        )
        let info = try installer.install(url)
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
        return info
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
            // The latest thing said, her reach-outs included: that is what the list shows.
            let latest = try Row.fetchAll(db, sql: """
                SELECT character_id, role, preview, created_at FROM (
                    SELECT character_id, role, preview, created_at,
                           ROW_NUMBER() OVER (
                               PARTITION BY character_id
                               ORDER BY created_at DESC, written DESC
                           ) AS rn
                    FROM (
                        SELECT c.character_id AS character_id,
                               m.role AS role,
                               COALESCE(NULLIF(m.zh, ''), NULLIF(m.ja, ''), NULLIF(m.text, '')) AS preview,
                               m.created_at AS created_at,
                               m.rowid AS written
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversation_id
                        UNION ALL
                        SELECT c.character_id,
                               'character',
                               COALESCE(NULLIF(r.zh, ''), NULLIF(r.ja, '')),
                               r.created_at,
                               r.rowid
                        FROM reach_outs r
                        JOIN conversations c ON c.id = r.conversation_id
                    )
                ) WHERE rn = 1
                """)
            for row in latest {
                let characterID: String = row["character_id"]
                result[characterID] = LatestActivity(
                    lastMessagePreview: row["preview"],
                    lastMessageRole: row["role"],
                    lastMessageAt: row["created_at"],
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
    public func stand(for characterID: String) -> CharacterStand? {
        guard let character = try? characters().first(where: { $0.id == characterID }),
              let config = character.stand
        else { return nil }

        let root = location.contentDirectory
        let listURL = root.appendingPathComponent(config.outfitListPath)
        let list = (try? Data(contentsOf: listURL)).flatMap { data in
            OutfitList(data: data, at: listURL)
        }
        return CharacterStand(
            defaultOutfit: StandOutfit(
                id: config.defaultOutfitID,
                directory: root.appendingPathComponent(config.defaultOutfitPath, isDirectory: true)
            ),
            outfitList: list
        )
    }

    // MARK: - Plumbing

    private func requireContent() throws {
        guard try installedContentInfo() != nil else {
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
}
