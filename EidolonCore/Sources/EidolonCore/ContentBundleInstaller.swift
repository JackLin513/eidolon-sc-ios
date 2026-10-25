import Foundation
import ZIPFoundation

/// Unpacks, validates and atomically installs a content bundle (ADR-0003).
/// Nothing here touches the user library except the install record.
struct ContentBundleInstaller {
    let contentRoot: URL
    let userDatabasePath: URL
    let fileManager: FileManager

    var currentDirectory: URL { contentRoot.appendingPathComponent("current", isDirectory: true) }
    var previousDirectory: URL { contentRoot.appendingPathComponent("previous", isDirectory: true) }

    func install(_ bundleURL: URL) throws -> ContentBundleInfo {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw EidolonError.unreadableBundle("文件不存在")
        }
        let staging = contentRoot.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try extract(bundleURL, to: staging)

        let manifest = try readManifest(in: staging)
        try validateManifest(manifest)
        try validateFiles(manifest, in: staging)
        try validateHolidays(in: staging)
        let characters = try readCharacters(in: staging)
        try validateCharacters(manifest, characters, in: staging)

        let database = try ContentDatabase(contentDirectory: staging, userDatabasePath: userDatabasePath)
        let counts = try validateDatabase(database, manifest: manifest)

        try swapIn(staging)

        let info = ContentBundleInfo(
            formatVersion: manifest.formatVersion,
            contentSchemaVersion: manifest.contentSchemaVersion,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            embeddingModel: manifest.embedding.model,
            embeddingDimensions: manifest.embedding.dimensions,
            episodeCount: counts["episodes"] ?? 0,
            passageCount: counts["episode_passages"] ?? 0,
            characterCount: characters.count
        )
        return info
    }

    // MARK: - Unpacking

    private func extract(_ bundleURL: URL, to destination: URL) throws {
        guard let archive = try? Archive(url: bundleURL, accessMode: .read) else {
            throw EidolonError.unreadableBundle("不是有效的 zip")
        }
        for entry in archive {
            let target = destination.appendingPathComponent(entry.path)
            let resolved = target.standardizedFileURL.path
            guard resolved.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw EidolonError.invalidBundle("包含超出目录的路径 \(entry.path)")
            }
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
        }
    }

    // MARK: - Validation

    private func readManifest(in directory: URL) throws -> ContentManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("缺少 manifest.json")
        }
        do {
            return try JSONDecoder().decode(ContentManifest.self, from: data)
        } catch {
            throw EidolonError.invalidBundle("manifest.json 无法解析：\(error.localizedDescription)")
        }
    }

    private func validateManifest(_ manifest: ContentManifest) throws {
        guard manifest.formatVersion == ContentManifest.supportedFormatVersion else {
            let hint = manifest.formatVersion < ContentManifest.supportedFormatVersion
                ? "，需要用新版 tools/export_content_bundle.py 重新导出"
                : "，请更新 App"
            throw EidolonError.unsupportedVersion(
                "内容包格式版本 \(manifest.formatVersion)，本 App 支持 "
                    + "\(ContentManifest.supportedFormatVersion)\(hint)"
            )
        }
        guard manifest.contentSchemaVersion == ContentSchema.version else {
            throw EidolonError.unsupportedVersion(
                "内容库 schema 版本 \(manifest.contentSchemaVersion)，本 App 支持 \(ContentSchema.version)"
            )
        }
        guard manifest.embedding.dimensions > 0, !manifest.embedding.model.isEmpty else {
            throw EidolonError.invalidBundle("缺少向量模型或维度")
        }
        guard manifest.characters.count == manifest.characters.ids.count else {
            throw EidolonError.invalidBundle("角色数量与 id 列表不一致")
        }
    }

    private func validateFiles(_ manifest: ContentManifest, in directory: URL) throws {
        guard let files = manifest.files, !files.isEmpty else {
            throw EidolonError.invalidBundle("manifest 没有列出文件")
        }
        for (path, record) in files {
            let url = directory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else {
                throw EidolonError.invalidBundle("缺少文件 \(path)")
            }
            guard data.count == record.size else {
                throw EidolonError.invalidBundle("文件 \(path) 大小不符")
            }
            if let expected = record.crc32, CRC32.hex(data) != expected {
                throw EidolonError.invalidBundle("文件 \(path) 校验失败")
            }
        }
    }

    private func validateHolidays(in directory: URL) throws {
        let url = directory.appendingPathComponent("content/holidays.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle(
                "缺少日本节假日表 content/holidays.json，需要用新版导出脚本重新导出"
            )
        }
        let table: HolidayTable
        do {
            table = try HolidayTable(data: data)
        } catch {
            throw EidolonError.invalidBundle("日本节假日表无法解析：\(error.localizedDescription)")
        }
        guard !table.names.isEmpty else {
            throw EidolonError.invalidBundle("日本节假日表是空的")
        }
    }

    private func readCharacters(in directory: URL) throws -> [CharacterConfig] {
        let url = directory.appendingPathComponent("characters/characters.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("缺少 characters/characters.json")
        }
        do {
            let values = try JSONDecoder().decode([JSONValue].self, from: data)
            return try values.map(CharacterConfig.init(json:))
        } catch let error as EidolonError {
            throw error
        } catch {
            throw EidolonError.invalidBundle("角色内容无法解析：\(error.localizedDescription)")
        }
    }

    private func validateCharacters(
        _ manifest: ContentManifest,
        _ characters: [CharacterConfig],
        in directory: URL
    ) throws {
        let ids = Set(characters.map(\.id))
        guard characters.count == manifest.characters.count else {
            throw EidolonError.invalidBundle(
                "角色数量为 \(characters.count)，manifest 声明 \(manifest.characters.count)"
            )
        }
        guard ids == Set(manifest.characters.ids) else {
            throw EidolonError.invalidBundle("角色 id 与 manifest 不一致")
        }
        for character in characters {
            for path in [character.sheet, character.facts, character.avatar, character.background]
                .compactMap({ $0 })
            {
                if !fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) {
                    throw EidolonError.invalidBundle("角色 \(character.id) 引用的 \(path) 不在包里")
                }
            }
        }
    }

    private func validateDatabase(
        _ database: ContentDatabase,
        manifest: ContentManifest
    ) throws -> [String: Int] {
        guard try database.integrityCheck() == "ok" else {
            throw EidolonError.invalidContent("完整性检查失败")
        }
        let version = try database.schemaVersion()
        guard version == ContentSchema.version else {
            throw EidolonError.unsupportedVersion(
                "内容库 schema 版本 \(version)，本 App 支持 \(ContentSchema.version)"
            )
        }
        let counts = try database.counts()
        for (table, expected) in manifest.content where counts[table] != expected {
            throw EidolonError.invalidContent(
                "\(table) 有 \(counts[table] ?? 0) 条，manifest 声明 \(expected)"
            )
        }
        guard (counts["episode_passages"] ?? 0) > 0 else {
            throw EidolonError.invalidContent("剧情库是空的")
        }
        let shape = try database.embeddingShape()
        guard shape.unembedded == 0 else {
            throw EidolonError.invalidContent("有 \(shape.unembedded) 个段落没有向量")
        }
        guard shape.models == [manifest.embedding.model] else {
            throw EidolonError.invalidContent(
                "段落向量模型为 \(shape.models.joined(separator: "、"))，manifest 声明 \(manifest.embedding.model)"
            )
        }
        guard shape.dimensions == [manifest.embedding.dimensions] else {
            throw EidolonError.invalidContent(
                "段落向量维度为 \(shape.dimensions)，manifest 声明 \(manifest.embedding.dimensions)"
            )
        }
        return counts
    }

    // MARK: - Swapping

    private func swapIn(_ staging: URL) throws {
        if fileManager.fileExists(atPath: previousDirectory.path) {
            try fileManager.removeItem(at: previousDirectory)
        }
        let hadCurrent = fileManager.fileExists(atPath: currentDirectory.path)
        if hadCurrent {
            try fileManager.moveItem(at: currentDirectory, to: previousDirectory)
        }
        do {
            try fileManager.moveItem(at: staging, to: currentDirectory)
        } catch {
            if hadCurrent {
                try? fileManager.moveItem(at: previousDirectory, to: currentDirectory)
            }
            throw error
        }
    }
}
