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
        /// Where the bar package's pictures, font and sound are installed; empty until one
        /// is imported (ADR-0021).
        public var barDirectory: URL { contentRoot.appendingPathComponent("bar", isDirectory: true) }
        /// Where the optional 3D model package is installed; empty until one is imported.
        public var model3DDirectory: URL { contentRoot.appendingPathComponent("model3d", isDirectory: true) }
    }

    public nonisolated let location: Location

    let userQueue: DatabaseQueue
    var content: ContentDatabase?
    /// Installed content packages keyed by franchise. Kept in actor state and persisted in
    /// `app_state`; the active package is also mirrored at `Content/current` as a symlink.
    var contentPackages: [String: ContentBundleInfo] = [:]
    var activeContentFranchise = "shiny"

    /// The active franchise's Spine stand. There is intentionally no global
    /// `Content/stand`: each franchise owns its own stand package.
    var standDirectory: URL {
        location.contentRoot
            .appendingPathComponent(activeContentFranchise, isDirectory: true)
            .appendingPathComponent("stand", isDirectory: true)
    }
    /// The world setting, parsed once per installed bundle: it is 1.3 MB, read on the main
    /// path of every turn otherwise.
    var cachedWorld: WorldSetting?
    var worldCached = false
    /// What earlier turns are still writing down, per job, so the next turn can wait a
    /// while for it (ADR-0009).
    var memoryJobs: [Int64: Task<Void, Never>] = [:]
    /// Photos whose reply has not been written yet, and the one image queue all photos and
    /// moments share.
    var photoDrafts: [String: PhotoDraft] = [:]
    let imageQueue = ImageQueue()
    /// What conversations are being named.
    var titleJobs: [String: Task<Void, Never>] = [:]
    /// The stand package's character map, read once per install.
    private var cachedStandConfigs: [String: StandConfig]?

    /// Drop franchise-scoped stand caches after switching the active content package.
    func invalidateStandCaches() {
        cachedStandConfigs = nil
    }

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
        try Self.failPendingPhotos(userQueue)
        try Self.removeOrphanPhotoFiles(userQueue, in: location.userDirectory)
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
        try loadContentPackagesIfNeeded()
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
        try installContent(bundleAt: url, franchise: "shiny", kind: .content, progress: progress)
    }

    /// Installs a stand bundle beside the content bundle, atomically. On any failure the
    /// previous stand directory stays in place (ADR-0020).
    @discardableResult
    public func installStand(
        bundleAt url: URL,
        franchise: String? = nil,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> StandBundleInfo {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let manifest = try StandBundleInstaller.readManifest(from: url)
        if let contentSetID = contentPackages[franchise]?.contentSetID,
           let standSetID = manifest.contentSetID,
           contentSetID != standSetID {
            throw EidolonError.invalidBundle("立绘包绑定 \(standSetID)，当前内容包是 \(contentSetID)")
        }
        let standRoot = location.contentRoot.appendingPathComponent(franchise, isDirectory: true)
        let installer = StandBundleInstaller(
            contentRoot: standRoot,
            fileManager: .default
        )
        let installedDirectory = standRoot.appendingPathComponent("stand", isDirectory: true)
        do {
            let info = try installer.install(url, progress: progress)
            try saveStandInfo(info, franchise: franchise)
            do {
                try StandIndex.scan(at: installedDirectory)
                    .write(to: installedDirectory)
            } catch {
                // Never leave an old index next to a new stand tree; the lazy rebuild
                // will make a correct one next time.
                try? FileManager.default.removeItem(
                    at: installedDirectory.appendingPathComponent("index.json")
                )
            }
            cachedStandConfigs = nil
            return info
        } catch {
            try? FileManager.default.removeItem(
                at: installedDirectory.appendingPathComponent("index.json")
            )
            throw error
        }
    }

    /// Moves the old all-in-one content bundle's stand tree into the separate stand
    /// directory and writes its manifest, once. If anything fails, the legacy tree stays
    /// where it is and `stand(for:)` keeps reading it.
    @discardableResult
    public func migrateLegacyStandIfNeeded() throws -> StandBundleInfo? {
        let fileManager = FileManager.default
        try loadContentPackagesIfNeeded()
        try migrateGlobalStandIfNeeded()
        let franchise = ContentRegistryState.legacyFranchise
        let target = location.contentRoot
            .appendingPathComponent(franchise, isDirectory: true)
            .appendingPathComponent("stand", isDirectory: true)
        guard !fileManager.fileExists(atPath: target.path),
              try installedStandInfo(franchise: franchise) == nil,
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
        try fileManager.moveItem(at: staging, to: target)
        try? fileManager.removeItem(at: legacy)

        let info = StandBundleInfo(
            formatVersion: manifest.formatVersion,
            installedAt: manifest.createdAt,
            characterCount: entries.count,
            outfitCount: countStandOutfits(in: target, fileManager: fileManager),
            mode: .full
        )
        try saveStandInfo(info, franchise: franchise)
        try? StandIndex.scan(at: target).write(to: target)
        cachedStandConfigs = nil
        return info
    }

    /// Installs a bar package (pictures, font, sound) beside the content and stand
    /// bundles, atomically. On any failure the previous bar stays in place (ADR-0021).
    @discardableResult
    public func installBar(
        bundleAt url: URL,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> BarBundleInfo {
        let installer = BarBundleInstaller(
            contentRoot: location.contentRoot,
            fileManager: .default
        )
        let info = try installer.install(url, progress: progress)
        try saveBarInfo(info)
        return info
    }

    /// What the installed bar package holds. Nil until one is imported: the bar then asks
    /// for its package instead of drawing a broken room.
    public func installedBarInfo() throws -> BarBundleInfo? {
        let stored: String? = try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = 'bar.bundle'"
            )
        }
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        let info = try? JSONDecoder().decode(BarBundleInfo.self, from: data)
        // The record alone is not enough: the directory may have been cleared underneath it.
        guard info != nil, FileManager.default.fileExists(atPath: location.barDirectory.path)
        else { return nil }
        return info
    }

    private func saveBarInfo(_ info: BarBundleInfo) throws {
        let encoded = try JSONEncoder().encode(info)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state(key, value) VALUES('bar.bundle', ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [String(decoding: encoded, as: UTF8.self)]
            )
        }
    }

    // MARK: - The bar's preferences

    /// The volumes and scanlines the app last kept; the defaults until it keeps any.
    public func barSettings() throws -> BarSettings {
        let stored: String? = try appState("bar.settings")
        return BarSettings(stored: stored.flatMap(Self.decode(BarSettings.Stored.self)))
    }

    public func saveBarSettings(_ settings: BarSettings) throws {
        try saveAppState("bar.settings", Self.encode(BarSettings.stored(settings)))
    }

    /// The jukebox's 12 slots and how its player plays, each part read as it should be: what
    /// the record says, or the defaults when it says nothing or nothing usable.
    public func barJukebox(_ audio: BarAudio) throws -> BarJukebox.State {
        let stored: String? = try appState("bar.jukebox")
        return BarJukebox.read(stored.flatMap(Self.decode(BarJukebox.State.self)), audio)
    }

    public func saveBarJukebox(_ state: BarJukebox.State) throws {
        try saveAppState("bar.jukebox", Self.encode(state))
    }

    /// Whether a visit done at `now` would still be rewarded: none done on the device's day yet
    /// (ADR-0021). The roster's bar card says so without opening the bar.
    public func barRewardToday(now: Date = Date(), timeZone: TimeZone = .current) throws -> Bool {
        let day = BarDates.day(of: now, in: timeZone)
        return try userQueue.read { try !BarRecords.doneOn($0, day: day) }
    }

    /// Whether the tutorial has been walked through: done or skipped.
    public func barTutorialWalked() throws -> Bool {
        try appState("bar.tutorial") == "true"
    }

    public func saveBarTutorialWalked() throws {
        try saveAppState("bar.tutorial", "true")
    }

    func appState(_ key: String) throws -> String? {
        try userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [key])
        }
    }

    func saveAppState(_ key: String, _ value: String) throws {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state(key, value) VALUES(?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }

    static func decode<T: Decodable>(_ type: T.Type) -> (String) -> T? {
        { text in
            (try? JSONDecoder().decode(T.self, from: Data(text.utf8)))
        }
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public func installedStandInfo(franchise: String? = nil) throws -> StandBundleInfo? {
        let normalized = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let stored: String? = try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = ?",
                arguments: ["stand.bundle.\(normalized)"]
            )
        }
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        let directory = location.contentRoot
            .appendingPathComponent(normalized, isDirectory: true)
            .appendingPathComponent("stand", isDirectory: true)
        guard FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("manifest.json").path
        ) else { return nil }
        return try? JSONDecoder().decode(StandBundleInfo.self, from: data)
    }

    /// Installs a `model3d` package beside the content/stand packages, atomically. The
    /// package is validated (manifest, file sizes/checksums, engine version) before it can
    /// replace the installed one.
    @discardableResult
    public func installModel3D(
        bundleAt url: URL,
        expectedEngineVersion: String? = nil,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> Model3DBundleInfo {
        let installer = Model3DBundleInstaller(
            contentRoot: location.contentRoot,
            fileManager: .default
        )
        let info = try installer.install(
            url,
            expectedEngineVersion: expectedEngineVersion,
            progress: progress
        )
        try saveAppState("model3d.bundle", Self.encode(info))
        return info
    }

    public func installedModel3DInfo() throws -> Model3DBundleInfo? {
        let stored: String? = try userQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM app_state WHERE key = 'model3d.bundle'"
            )
        }
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Model3DBundleInfo.self, from: data)
    }

    /// The installed model package, its directory and decoded manifest, when there is one.
    public func installedModel3D() throws -> (
        info: Model3DBundleInfo, directory: URL, manifest: Model3DManifest
    )? {
        guard let info = try installedModel3DInfo() else { return nil }
        let directory = location.model3DDirectory
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Model3DManifest.self, from: data)
        else { return nil }
        return (info, directory, manifest)
    }

    /// The stand package's character-to-outfit map; empty when no stand bundle is
    /// installed. The paths in it are relative to the stand directory.
    public func standConfigs() throws -> [String: StandConfig] {
        if let cachedStandConfigs { return cachedStandConfigs }
        let url = standDirectory.appendingPathComponent("manifest.json")
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
        if let index = StandIndex.read(at: standDirectory) { return index }
        let index = try StandIndex.scan(at: standDirectory)
        try index.write(to: standDirectory)
        return index
    }

    public func standIndexData() throws -> Data {
        try standIndex().encoded()
    }

    // MARK: - The bar

    /// The bar over this app's library, reading this app's content bundle (ADR-0021). There
    /// is one bar, as there is one user; it is open whenever the app is.
    public func barRoom() -> BarRoom {
        let queue = userQueue
        let directory = location.contentDirectory
        let world = try? loadWorld()
        let holidays = try? holidayTable()
        return BarRoom(
            userQueue: queue,
            source: {
                // Read on every step, so a visit under way writes on the bundle it came in
                // on; the content is small and validated on the way in.
                let content = try BarContent(directory: directory)
                return BarContentSource(
                    content: content,
                    directory: directory,
                    world: world,
                    holidays: holidays
                )
            }
        )
    }

    /// Where the bar's pictures, pixel font and sound are, and what the package holds. Nil
    /// until one is installed: the bar then asks for it (ADR-0021).
    public func installedBar() throws -> (info: BarBundleInfo, directory: URL)? {
        guard let info = try installedBarInfo() else { return nil }
        return (info, location.barDirectory)
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

    /// The installed bundle's place pool; nil for a bundle before places.
    public func places() throws -> PlacePool? {
        try requireContent()
        return try PlacePool.load(in: location.contentDirectory)
    }

    /// The installed bundle's photo tag table; nil for a bundle before photos.
    public func photoTags() throws -> PhotoTagTable? {
        try requireContent()
        return try PhotoTagTable.load(in: location.contentDirectory)
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
                SELECT character_id, role, preview, event_kind, gift_id, created_at,
                       has_photo FROM (
                    SELECT character_id, role, preview, event_kind, gift_id, created_at,
                           has_photo,
                           ROW_NUMBER() OVER (
                               PARTITION BY character_id
                               ORDER BY created_at DESC, written DESC
                           ) AS rn
                    FROM (
                        SELECT c.character_id AS character_id,
                               m.role AS role,
                               COALESCE(NULLIF(m.zh, ''), NULLIF(m.ja, ''), NULLIF(m.text, '')) AS preview,
                               NULL AS event_kind,
                               NULL AS gift_id,
                               m.created_at AS created_at,
                               m.rowid AS written,
                               EXISTS (
                                   SELECT 1 FROM photos p
                                   WHERE p.message_id = m.id AND p.status = 'ready'
                               ) AS has_photo
                        FROM messages m
                        JOIN conversations c ON c.id = m.conversation_id
                        UNION ALL
                        SELECT c.character_id,
                               'character',
                               COALESCE(NULLIF(r.zh, ''), NULLIF(r.ja, '')),
                               NULL,
                               NULL,
                               r.created_at,
                               r.rowid,
                               0
                        FROM reach_outs r
                        JOIN conversations c ON c.id = r.conversation_id
                        UNION ALL
                        SELECT c.character_id,
                               'event',
                               NULL,
                               e.kind,
                               e.gift_id,
                               e.created_at,
                               e.id,
                               0
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
                    lastGiftID: row["gift_id"],
                    unseenReachOut: false,
                    hasPhoto: (row["has_photo"] as Int? ?? 0) == 1
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

    /// Her stand: from the separately installed stand package when it has her, otherwise
    /// from the legacy content bundle (ADR-0018, ADR-0020). nil when neither carries a
    /// usable stand for her.
    public func stand(for characterID: String) -> CharacterStand? {
        guard let character = try? characters().first(where: { $0.id == characterID })
        else { return nil }

        for source in standSources(for: character, configs: (try? standConfigs()) ?? [:]) {
            if let found = StandResolver(roots: [source.root]).stand(for: source.config) {
                return found
            }
        }
        return nil
    }

    /// Every character whose stand can actually be opened, answered in one shot before the
    /// character list reaches the UI. `AppModel` reads it alongside the character list so
    /// the chat toolbar never changes after its first layout (spec #44). It shares the
    /// lookup order with `stand(for:)`, but only checks files, so no outfit list is parsed.
    public func characterIDsWithStands() -> Set<String> {
        let characters = (try? characters()) ?? []
        let configs = (try? standConfigs()) ?? [:]
        var ids: Set<String> = []
        for character in characters {
            let sources = standSources(for: character, configs: configs)
            let found = sources.contains { source in
                StandResolver(roots: [source.root]).hasStand(for: source.config)
            }
            if found { ids.insert(character.id) }
        }
        return ids
    }

    /// Where her stand may come from, in lookup order: the stand package first, then the
    /// legacy content bundle (ADR-0020). Both `stand(for:)` and `characterIDsWithStands()`
    /// walk this list, so the picker and the toolbar can never disagree.
    private func standSources(
        for character: CharacterConfig,
        configs: [String: StandConfig]
    ) -> [(config: StandConfig, root: URL)] {
        var sources: [(config: StandConfig, root: URL)] = []
        if let config = configs[character.id] {
            sources.append((config, standDirectory))
        }
        if let config = character.stand {
            sources.append((config, location.contentDirectory))
        }
        return sources
    }

    // MARK: - Plumbing

    func requireContent() throws {
        guard try usableContentInfo() != nil else {
            throw EidolonError.contentNotInstalled
        }
    }

    func openContent() throws -> ContentDatabase {
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

    /// The first registry versions kept one global `Content/stand`. Move it under the
    /// legacy franchise once and rewrite the old global app-state key. No global stand
    /// path remains as an interface.
    private func migrateGlobalStandIfNeeded() throws {
        let fileManager = FileManager.default
        let legacy = location.contentRoot.appendingPathComponent("stand", isDirectory: true)
        let target = location.contentRoot
            .appendingPathComponent(ContentRegistryState.legacyFranchise, isDirectory: true)
            .appendingPathComponent("stand", isDirectory: true)
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: target.path)
        else {
            if !fileManager.fileExists(atPath: legacy.path) {
                try? userQueue.write { db in
                    try db.execute(sql: "DELETE FROM app_state WHERE key = 'stand.bundle'")
                }
            }
            return
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: legacy, to: target)

        if let data = try? Data(contentsOf: target.appendingPathComponent("manifest.json")),
           let manifest = try? JSONDecoder().decode(StandManifest.self, from: data) {
            let info = StandBundleInfo(
                formatVersion: manifest.formatVersion,
                installedAt: manifest.createdAt,
                characterCount: manifest.characters.count,
                outfitCount: countStandOutfits(in: target, fileManager: fileManager),
                mode: manifest.mode,
                contentSetID: manifest.contentSetID
            )
            try saveStandInfo(info, franchise: ContentRegistryState.legacyFranchise)
        }
        try userQueue.write { db in
            try db.execute(sql: "DELETE FROM app_state WHERE key = 'stand.bundle'")
        }
    }

    private func saveStandInfo(_ info: StandBundleInfo, franchise: String) throws {
        let encoded = try JSONEncoder().encode(info)
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_state(key, value) VALUES(?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: ["stand.bundle.\(franchise)", String(decoding: encoded, as: UTF8.self)]
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
