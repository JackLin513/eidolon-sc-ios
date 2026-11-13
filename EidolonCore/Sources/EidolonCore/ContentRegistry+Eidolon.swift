import Foundation
import Darwin
import ZIPFoundation

extension Eidolon {
    /// The active package's franchise. `Content/current` always points at this package.
    public var activeFranchise: String { activeContentFranchise }

    /// All installed content packages, sorted by franchise for stable UI/tests.
    public var installedContentPackages: [InstalledContentPackage] {
        contentPackages.values
            .map { InstalledContentPackage(franchise: $0.franchise, kind: $0.kind, info: $0) }
            .sorted { $0.franchise < $1.franchise }
    }

    /// Install one content-kind package under `Content/<franchise>/current`, then make it
    /// active if there was no active package yet. The legacy `install` is the shiny twin.
    @discardableResult
    public func installContent(
        bundleAt url: URL,
        franchise: String,
        kind: ContentKind = .content,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> ContentBundleInfo {
        let franchise = ContentRegistryState.normalizedFranchise(franchise)
        guard kind == .content else {
            throw EidolonError.invalidBundle("内容包路由只接受 content，收到 \(kind.rawValue)")
        }
        try loadContentPackagesIfNeeded()
        try migrateLegacyCurrentIfNeeded()
        let packageRoot = location.contentRoot.appendingPathComponent(franchise, isDirectory: true)
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let installer = ContentBundleInstaller(
            contentRoot: packageRoot,
            userDatabasePath: location.userDatabase,
            fileManager: .default
        )
        var info = try installer.install(url, expectedKind: .content, progress: progress)
        info.franchise = franchise
        info.kind = kind.rawValue
        if let existing = contentPackages.values.first(where: { $0.franchise != franchise }),
           existing.embeddingModel != info.embeddingModel
            || existing.embeddingDimensions != info.embeddingDimensions {
            throw EidolonError.invalidBundle(
                "向量模型/维度不一致：已装 \(existing.embeddingModel)/\(existing.embeddingDimensions)，"
                    + "新包 \(info.embeddingModel)/\(info.embeddingDimensions)"
            )
        }
        let hadActive = contentPackages[activeContentFranchise] != nil
        contentPackages[franchise] = info
        do {
            if !hadActive {
                try activateContent(franchise: franchise)
            }
            try persistContentPackages()
        } catch {
            contentPackages.removeValue(forKey: franchise)
            throw error
        }
        return info
    }

    /// Install a content package using the manifest's own franchise/kind. The legacy
    /// `install` is a `shiny`-only convenience; the app's file importer uses this so a
    /// Sakura package does not overwrite Shiny.
    @discardableResult
    public func installContentPackage(
        bundleAt url: URL,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> ContentBundleInfo {
        let manifest = try ContentBundleInstaller.readManifest(from: url)
        if let declared = manifest.franchise, !declared.isEmpty {
            guard let keys = manifest.characters.characterKeys,
                  keys.count == manifest.characters.ids.count,
                  Set(keys.compactMap { $0.split(separator: ":", maxSplits: 1).last.map(String.init) })
                    == Set(manifest.characters.ids)
            else {
                throw EidolonError.invalidBundle("多包内容包必须写与角色 id 对应的 characters.characterKeys")
            }
        }
        let franchise = ContentRegistryState.normalizedFranchise(manifest.franchise)
        let kind: ContentKind
        if let raw = manifest.kind, !raw.isEmpty {
            guard let parsed = ContentKind(rawValue: raw) else {
                throw EidolonError.invalidBundle("不支持的内容包 kind：\(raw)")
            }
            kind = parsed
        } else {
            kind = .content
        }
        return try installContent(bundleAt: url, franchise: franchise, kind: kind, progress: progress)
    }


    /// Switch the active package by repointing the `Content/current` symlink. The user
    /// database is deliberately not migrated here; Phase B owns composite user data.
    public func activateContent(franchise: String) throws {
        let franchise = ContentRegistryState.normalizedFranchise(franchise)
        try loadContentPackagesIfNeeded()
        try migrateLegacyCurrentIfNeeded()
        let target = packageRoot(franchise).appendingPathComponent("current", isDirectory: true)
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw EidolonError.contentNotInstalled
        }
        try writeCurrentLink(franchise: franchise)
        activeContentFranchise = franchise
        invalidateStandCaches()
        try saveAppState(ContentRegistryState.activeFranchiseKey, franchise)
        if let info = contentPackages[franchise] {
            let encoded = try JSONEncoder().encode(info)
            try saveAppState("content.bundle", String(decoding: encoded, as: UTF8.self))
        }
        content = try openContent()
        installFranchisePrompt(franchise: franchise)
        cachedWorld = nil
        worldCached = false
    }

    public func installedContentInfo(franchise: String) throws -> ContentBundleInfo? {
        try loadContentPackagesIfNeeded()
        return contentPackages[ContentRegistryState.normalizedFranchise(franchise)]
    }

    /// Move a pre-registry `Content/current` directory into `Content/shiny/current` and
    /// replace it with a symlink, once. Existing single-package installs keep working.
    func migrateLegacyCurrentIfNeeded() throws {
        let fm = FileManager.default
        let current = location.contentDirectory
        guard fm.fileExists(atPath: current.path),
              (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { return }
        let shiny = packageRoot(ContentRegistryState.legacyFranchise)
            .appendingPathComponent("current", isDirectory: true)
        try fm.createDirectory(at: shiny.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: shiny.path) {
            try fm.moveItem(at: current, to: shiny)
            do {
                try writeCurrentLink(franchise: ContentRegistryState.legacyFranchise)
            } catch {
                try? fm.moveItem(at: shiny, to: current)
                throw error
            }
        } else {
            try fm.removeItem(at: current)
            try writeCurrentLink(franchise: ContentRegistryState.legacyFranchise)
        }
    }

    func loadContentPackagesIfNeeded() throws {
        guard contentPackages.isEmpty else { return }
        if let stored = try appState(ContentRegistryState.packagesKey),
           let data = stored.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: ContentBundleInfo].self, from: data) {
            contentPackages = decoded
        }
        if let active = try appState(ContentRegistryState.activeFranchiseKey), !active.isEmpty {
            activeContentFranchise = active
        } else if let info = try installedContentInfoLegacy() {
            contentPackages[ContentRegistryState.legacyFranchise] = info
            activeContentFranchise = ContentRegistryState.legacyFranchise
        }
        try repairContentLinkIfNeeded()
        installFranchisePrompt(franchise: activeContentFranchise)
    }

    /// Rebuild a missing/broken/absolute `Content/current` link. Simulator app updates can
    /// change the data-container UUID; an absolute symlink then points into the old one.
    func repairContentLinkIfNeeded() throws {
        let fm = FileManager.default
        let franchise = activeContentFranchise
        let target = packageRoot(franchise).appendingPathComponent("current", isDirectory: true)
        guard fm.fileExists(atPath: target.path) else { return }
        let current = location.contentDirectory
        let relative = "\(franchise)/current"
        if let destination = try? fm.destinationOfSymbolicLink(atPath: current.path),
           destination == relative {
            return
        }
        try writeCurrentLink(franchise: franchise)
    }

    /// Replace `Content/current` atomically. The link is relative so a simulator data
    /// container UUID change does not break it.
    private func writeCurrentLink(franchise: String) throws {
        let fm = FileManager.default
        let current = location.contentDirectory
        let temporary = location.contentRoot.appendingPathComponent(".current-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: "\(franchise)/current")
        guard rename(temporary.path, current.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    private func installedContentInfoLegacy() throws -> ContentBundleInfo? {
        guard let stored = try appState("content.bundle"),
              let data = stored.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(ContentBundleInfo.self, from: data)
    }

    private func persistContentPackages() throws {
        let data = try JSONEncoder().encode(contentPackages)
        try saveAppState(ContentRegistryState.packagesKey, String(decoding: data, as: UTF8.self))
    }

    private func packageRoot(_ franchise: String) -> URL {
        location.contentRoot.appendingPathComponent(franchise, isDirectory: true)
    }
}

extension Eidolon {
    /// Install a static (PNG-per-expression) stand under the content's franchise and bind
    /// it to the content's `contentSetID` when both packages declare one.
    @discardableResult
    public func installStaticStand(
        bundleAt url: URL,
        franchise: String? = nil,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> StaticStandBundleInfo {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        guard let content = contentPackages[franchise] else {
            throw EidolonError.contentNotInstalled
        }
        let installer = StaticStandBundleInstaller(
            contentRoot: packageRoot(franchise),
            fileManager: .default
        )
        let info = try installer.install(url, progress: progress)
        guard info.franchise == franchise else {
            throw EidolonError.invalidBundle("立绘包 franchise 为 \(info.franchise)，当前内容包为 \(franchise)")
        }
        if let contentSetID = content.contentSetID, !contentSetID.isEmpty,
           let standSetID = info.contentSetID, !standSetID.isEmpty,
           contentSetID != standSetID {
            throw EidolonError.invalidBundle(
                "立绘包绑定 \(standSetID)，当前内容包是 \(contentSetID)"
            )
        }
        let data = try JSONEncoder().encode(info)
        try saveAppState("static-stand.bundle.\(franchise)", String(decoding: data, as: UTF8.self))
        return info
    }

    /// The active content package's franchise prompt pack, if it has one.
    public func franchisePrompt(franchise: String? = nil) -> FranchisePrompt? {
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let root = packageRoot(franchise).appendingPathComponent("current", isDirectory: true)
        return FranchisePrompt.load(in: root)
    }

    func installFranchisePrompt(franchise: String? = nil) {
        FranchisePromptContext.current = franchisePrompt(franchise: franchise) ?? .shiny
    }

    public func installedStaticStandInfo(franchise: String? = nil) throws -> StaticStandBundleInfo? {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        guard let stored = try appState("static-stand.bundle.\(franchise)"),
              let data = stored.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(StaticStandBundleInfo.self, from: data)
    }

    /// Expression image paths for one character, read from the installed static stand.
    /// The preview uses this directly; no runtime protocol is needed for the first test.
    public func staticStandExpressions(
        characterID: String,
        franchise: String? = nil
    ) throws -> [String: URL]? {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let directory = packageRoot(franchise).appendingPathComponent("static-stand", isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(StaticStandManifest.self, from: data),
              let character = manifest.characters.first(where: { $0.id == characterID })
        else { return nil }
        var result: [String: URL] = [:]
        for (emotion, path) in character.allExpressions {
            result[emotion] = directory.appendingPathComponent(path)
        }
        return result
    }

    /// Characters the installed static stand actually declares. Used for the per-character
    /// wardrobe capability check instead of treating every character as drawable.
    public func staticStandCharacterIDs(franchise: String? = nil) throws -> Set<String> {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let directory = packageRoot(franchise).appendingPathComponent("static-stand", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(StaticStandManifest.self, from: data)
        else { return [] }
        return Set(manifest.characters.map(\.id))
    }

    /// v2 outfit/pose bases for one character. Empty for a v1 package.
    public func staticStandBases(
        characterID: String,
        franchise: String? = nil
    ) throws -> [StaticStandManifest.Base]? {
        try loadContentPackagesIfNeeded()
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let directory = packageRoot(franchise).appendingPathComponent("static-stand", isDirectory: true)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(StaticStandManifest.self, from: data),
              let character = manifest.characters.first(where: { $0.id == characterID })
        else { return nil }
        return character.bases
    }

    /// One v2 base's emotion images, resolved under the installed static stand.
    public func staticStandExpressions(
        characterID: String,
        baseID: String,
        franchise: String? = nil
    ) throws -> [String: URL]? {
        guard let bases = try staticStandBases(characterID: characterID, franchise: franchise),
              let base = bases.first(where: { $0.id == baseID })
        else { return nil }
        let franchise = ContentRegistryState.normalizedFranchise(franchise ?? activeContentFranchise)
        let directory = packageRoot(franchise).appendingPathComponent("static-stand", isDirectory: true)
        var result: [String: URL] = [:]
        for (emotion, path) in base.expressions {
            result[emotion] = directory.appendingPathComponent(path)
        }
        return result
    }
}
