import Foundation
import ZIPFoundation

/// Unpacks, validates and atomically installs a stand bundle beside the content bundle
/// (ADR-0020). A full bundle replaces the stand directory; the previous one is kept for
/// rollback. A delta bundle is not handled here yet.
struct StandBundleInstaller {
    let contentRoot: URL
    let fileManager: FileManager

    var standDirectory: URL { contentRoot.appendingPathComponent("stand", isDirectory: true) }
    var previousDirectory: URL {
        contentRoot.appendingPathComponent("stand-previous", isDirectory: true)
    }

    func install(_ bundleURL: URL) throws -> StandBundleInfo {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw EidolonError.unreadableBundle("文件不存在")
        }
        let staging = contentRoot.appendingPathComponent(
            ".stand-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try extract(bundleURL, to: staging)

        let manifest = try readManifest(in: staging)
        try validateManifest(manifest)
        try validateFiles(manifest, in: staging)
        try validateCharacters(manifest, in: staging)
        let outfitCount = countOutfits(in: staging)

        try swapIn(staging)

        return StandBundleInfo(
            formatVersion: manifest.formatVersion,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            characterCount: manifest.characters.count,
            outfitCount: outfitCount
        )
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

    private func readManifest(in directory: URL) throws -> StandManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("缺少 manifest.json")
        }
        do {
            return try JSONDecoder().decode(StandManifest.self, from: data)
        } catch {
            throw EidolonError.invalidBundle("manifest.json 无法解析：\(error.localizedDescription)")
        }
    }

    private func validateManifest(_ manifest: StandManifest) throws {
        guard manifest.formatVersion == StandManifest.supportedFormatVersion else {
            throw EidolonError.unsupportedVersion(
                "立绘包格式版本 \(manifest.formatVersion)，本 App 支持 "
                    + "\(StandManifest.supportedFormatVersion)"
            )
        }
        guard manifest.kind == .stand else {
            throw EidolonError.invalidBundle("不是立绘包")
        }
        guard manifest.mode == .full else {
            throw EidolonError.invalidBundle("增量立绘包暂未支持")
        }
        guard !manifest.characters.isEmpty else {
            throw EidolonError.invalidContent("立绘包里没有角色")
        }
        var seen = Set<String>()
        for character in manifest.characters {
            guard !character.id.isEmpty else {
                throw EidolonError.invalidContent("立绘包里有角色没有编号")
            }
            guard seen.insert(character.id).inserted else {
                throw EidolonError.invalidContent("立绘包里的角色 \(character.id) 重复")
            }
        }
    }

    private func validateFiles(_ manifest: StandManifest, in directory: URL) throws {
        guard !manifest.files.isEmpty else {
            throw EidolonError.invalidBundle("manifest 没有列出文件")
        }
        let root = directory.standardizedFileURL.path + "/"
        for (path, record) in manifest.files {
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root) else {
                throw EidolonError.invalidBundle("包含超出目录的路径 \(path)")
            }
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

    private func validateCharacters(_ manifest: StandManifest, in directory: URL) throws {
        for character in manifest.characters {
            let defaultDirectory = directory.appendingPathComponent(
                character.stand.defaultOutfitPath,
                isDirectory: true
            )
            for name in OutfitList.files {
                guard fileManager.fileExists(
                    atPath: defaultDirectory.appendingPathComponent(name).path
                ) else {
                    throw EidolonError.invalidContent(
                        "角色 \(character.id) 的默认衣装缺少 \(name)"
                    )
                }
            }
            let listURL = directory.appendingPathComponent(character.stand.outfitListPath)
            guard fileManager.fileExists(atPath: listURL.path) else {
                throw EidolonError.invalidContent(
                    "角色 \(character.id) 的衣装清单不存在"
                )
            }
        }
    }

    /// Each outfit directory holds exactly one `data.json`, so counting those counts the
    /// outfits without trusting a separate count in the manifest.
    private func countOutfits(in directory: URL) -> Int {
        let idols = directory.appendingPathComponent("idols", isDirectory: true)
        guard let enumerator = fileManager.enumerator(at: idols, includingPropertiesForKeys: nil)
        else { return 0 }
        var count = 0
        for case let url as URL in enumerator where url.lastPathComponent == "data.json" {
            count += 1
        }
        return count
    }

    // MARK: - Swapping

    private func swapIn(_ staging: URL) throws {
        if fileManager.fileExists(atPath: previousDirectory.path) {
            try fileManager.removeItem(at: previousDirectory)
        }
        let hadCurrent = fileManager.fileExists(atPath: standDirectory.path)
        if hadCurrent {
            try fileManager.moveItem(at: standDirectory, to: previousDirectory)
        }
        do {
            try fileManager.moveItem(at: staging, to: standDirectory)
        } catch {
            if hadCurrent {
                try? fileManager.moveItem(at: previousDirectory, to: standDirectory)
            }
            throw error
        }
    }
}
