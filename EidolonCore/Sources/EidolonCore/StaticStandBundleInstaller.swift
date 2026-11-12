import Foundation
import ZIPFoundation

/// Installs a static (PNG-per-expression) stand package under one franchise root.
struct StaticStandBundleInstaller {
    let contentRoot: URL
    let fileManager: FileManager

    var standDirectory: URL { contentRoot.appendingPathComponent("static-stand", isDirectory: true) }
    var previousDirectory: URL { contentRoot.appendingPathComponent("static-stand-previous", isDirectory: true) }

    func install(
        _ bundleURL: URL,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> StaticStandBundleInfo {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw EidolonError.unreadableBundle("文件不存在")
        }
        let staging = contentRoot.appendingPathComponent(".static-stand-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try extract(bundleURL, to: staging, progress: progress)
        let manifest = try readManifest(in: staging)
        try validateManifest(manifest)
        try validateFiles(manifest, in: staging, progress: progress)
        try validateCharacters(manifest, in: staging)
        try swapIn(staging)

        return StaticStandBundleInfo(
            formatVersion: manifest.formatVersion,
            franchise: manifest.franchise,
            contentSetID: manifest.contentSetID,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            characterCount: manifest.characters.count,
            expressionCount: manifest.characters.reduce(0) { total, character in
                total + (character.bases ?? []).reduce(0) { $0 + $1.expressions.count }
                    + (character.bases == nil ? character.expressions.count : 0)
            },
            mode: manifest.mode,
            baseCount: manifest.characters.reduce(0) { $0 + ($1.bases?.count ?? 0) }
        )
    }

    private func extract(
        _ bundleURL: URL,
        to destination: URL,
        progress: ((ImportProgress) -> Void)?
    ) throws {
        guard let archive = try? Archive(url: bundleURL, accessMode: .read) else {
            throw EidolonError.unreadableBundle("不是有效的 zip")
        }
        let entries = Array(archive)
        progress?(ImportProgress(phase: .extracting, completed: 0, total: entries.count))
        for (index, entry) in entries.enumerated() {
            let target = destination.appendingPathComponent(entry.path)
            let resolved = target.standardizedFileURL.path
            guard resolved.hasPrefix(destination.standardizedFileURL.path + "/") else {
                throw EidolonError.invalidBundle("包含超出目录的路径 \(entry.path)")
            }
            try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: target)
            progress?(ImportProgress(phase: .extracting, completed: index + 1, total: entries.count))
        }
    }

    private func readManifest(in directory: URL) throws -> StaticStandManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("缺少 manifest.json")
        }
        do {
            return try JSONDecoder().decode(StaticStandManifest.self, from: data)
        } catch {
            throw EidolonError.invalidBundle("manifest.json 无法解析：\(error.localizedDescription)")
        }
    }

    private func validateManifest(_ manifest: StaticStandManifest) throws {
        guard (1...StaticStandManifest.supportedFormatVersion).contains(manifest.formatVersion) else {
            throw EidolonError.unsupportedVersion("静态立绘包格式版本 \(manifest.formatVersion)")
        }
        guard manifest.kind == .stand else { throw EidolonError.invalidBundle("不是立绘包") }
        guard manifest.mode == .full else {
            throw EidolonError.invalidBundle("静态立绘包首版只支持 full")
        }
        guard manifest.renderer == "static" else {
            throw EidolonError.invalidBundle("不支持的立绘渲染器：\(manifest.renderer)")
        }
        guard !manifest.franchise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EidolonError.invalidBundle("静态立绘包缺少 franchise")
        }
        guard !manifest.characters.isEmpty else { throw EidolonError.invalidContent("立绘包里没有角色") }
        var ids = Set<String>()
        for character in manifest.characters {
            guard !character.id.isEmpty else { throw EidolonError.invalidContent("角色缺少 id") }
            guard ids.insert(character.id).inserted else { throw EidolonError.invalidContent("角色 \(character.id) 重复") }
            if manifest.formatVersion >= 2 {
                let bases = character.bases ?? []
                guard !bases.isEmpty else { throw EidolonError.invalidContent("角色 \(character.id) 没有 outfit/pose 底图") }
                var baseIDs = Set<String>()
                for base in bases {
                    guard !base.id.isEmpty, !base.outfit.isEmpty, !base.pose.isEmpty else {
                        throw EidolonError.invalidContent("角色 \(character.id) 的底图标识不完整")
                    }
                    guard baseIDs.insert(base.id).inserted else {
                        throw EidolonError.invalidContent("角色 \(character.id) 的底图 \(base.id) 重复")
                    }
                    guard !base.expressions.isEmpty else {
                        throw EidolonError.invalidContent("角色 \(character.id) 的底图 \(base.id) 没有表情")
                    }
                    for (emotion, path) in base.expressions {
                        guard !emotion.isEmpty, !path.isEmpty else {
                            throw EidolonError.invalidContent("角色 \(character.id) 的底图 \(base.id) 表情映射不完整")
                        }
                    }
                }
            } else {
                guard !character.expressions.isEmpty else { throw EidolonError.invalidContent("角色 \(character.id) 没有表情") }
                for (emotion, path) in character.expressions {
                    guard !emotion.isEmpty, !path.isEmpty else { throw EidolonError.invalidContent("角色 \(character.id) 的表情映射不完整") }
                }
            }
        }
    }

    private func validateFiles(
        _ manifest: StaticStandManifest,
        in directory: URL,
        progress: ((ImportProgress) -> Void)?
    ) throws {
        guard !manifest.files.isEmpty else { throw EidolonError.invalidBundle("manifest 没有列出文件") }
        let root = directory.standardizedFileURL.path + "/"
        for (index, (path, record)) in manifest.files.enumerated() {
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(root) else { throw EidolonError.invalidBundle("包含超出目录的路径 \(path)") }
            guard let data = try? Data(contentsOf: url) else { throw EidolonError.invalidBundle("缺少文件 \(path)") }
            guard data.count == record.size else { throw EidolonError.invalidBundle("文件 \(path) 大小不符") }
            if let expected = record.crc32, CRC32.hex(data) != expected {
                throw EidolonError.invalidBundle("文件 \(path) 校验失败")
            }
            progress?(ImportProgress(phase: .validating, completed: index + 1, total: manifest.files.count))
        }
    }

    private func validateCharacters(_ manifest: StaticStandManifest, in directory: URL) throws {
        for character in manifest.characters {
            for path in character.allExpressions.values {
                guard fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) else {
                    throw EidolonError.invalidBundle("角色 \(character.id) 的表情文件 \(path) 不在包里")
                }
            }
        }
    }

    private func swapIn(_ staging: URL) throws {
        if fileManager.fileExists(atPath: previousDirectory.path) {
            try fileManager.removeItem(at: previousDirectory)
        }
        let hadCurrent = fileManager.fileExists(atPath: standDirectory.path)
        if hadCurrent { try fileManager.moveItem(at: standDirectory, to: previousDirectory) }
        do {
            try fileManager.moveItem(at: staging, to: standDirectory)
        } catch {
            if hadCurrent { try? fileManager.moveItem(at: previousDirectory, to: standDirectory) }
            throw error
        }
    }
}
