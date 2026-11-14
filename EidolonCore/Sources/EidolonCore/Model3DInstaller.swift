import CryptoKit
import Foundation
import ZIPFoundation

/// Unpacks, validates and atomically installs a `model3d` package beside the content
/// bundle. The package's own `manifest.json` is the source of truth; the installer checks
/// every declared file's size and SHA-256 before swapping the directory in.
struct Model3DBundleInstaller {
    let contentRoot: URL
    let fileManager: FileManager

    func directory(_ franchise: String) -> URL {
        contentRoot
            .appendingPathComponent(franchise, isDirectory: true)
            .appendingPathComponent("model3d", isDirectory: true)
    }

    func previousDirectory(_ franchise: String) -> URL {
        contentRoot
            .appendingPathComponent(franchise, isDirectory: true)
            .appendingPathComponent("model3d-previous", isDirectory: true)
    }

    func install(
        _ bundleURL: URL,
        expectedEngineVersion: String? = nil,
        progress: ((ImportProgress) -> Void)? = nil
    ) throws -> Model3DBundleInfo {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw EidolonError.unreadableBundle("文件不存在")
        }
        let staging = contentRoot.appendingPathComponent(
            ".model3d-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try extract(bundleURL, to: staging, progress: progress)
        let manifest = try readManifest(in: staging)
        do {
            try manifest.validate(expectedEngineVersion: expectedEngineVersion)
        } catch let error as Model3DManifestError {
            throw EidolonError.invalidBundle(error.description)
        }
        try validateFiles(manifest, in: staging, progress: progress)
        try swapIn(staging, franchise: manifest.franchise)

        return Model3DBundleInfo(
            formatVersion: manifest.formatVersion,
            franchise: manifest.franchise,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            characterCount: manifest.characters.count,
            fileCount: manifest.files.count,
            engineVersion: manifest.runtime.engineVersion
        )
    }

    // MARK: - Unpacking

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
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: target)
            let completed = index + 1
            if completed == entries.count || completed % 25 == 0 {
                progress?(ImportProgress(
                    phase: .extracting,
                    completed: completed,
                    total: entries.count
                ))
            }
        }
    }

    private func readManifest(in directory: URL) throws -> Model3DManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("缺少 manifest.json")
        }
        do {
            return try JSONDecoder().decode(Model3DManifest.self, from: data)
        } catch {
            throw EidolonError.invalidBundle("manifest.json 无法解析：\(error.localizedDescription)")
        }
    }

    // MARK: - Validation

    private func validateFiles(
        _ manifest: Model3DManifest,
        in directory: URL,
        progress: ((ImportProgress) -> Void)?
    ) throws {
        progress?(ImportProgress(phase: .validating, completed: 0, total: manifest.files.count))
        for (index, file) in manifest.files.enumerated() {
            let url = directory.appendingPathComponent(file.path)
            guard fileManager.fileExists(atPath: url.path) else {
                throw EidolonError.invalidBundle("缺少文件 \(file.path)")
            }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard size == file.size else {
                throw EidolonError.invalidBundle("文件大小不匹配 \(file.path)")
            }
            let data = try Data(contentsOf: url)
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == file.sha256.lowercased() else {
                throw EidolonError.invalidBundle("文件校验值不匹配 \(file.path)")
            }
            let completed = index + 1
            if completed == manifest.files.count || completed % 25 == 0 {
                progress?(ImportProgress(
                    phase: .validating,
                    completed: completed,
                    total: manifest.files.count
                ))
            }
        }
    }

    private func swapIn(_ staging: URL, franchise: String) throws {
        let directory = directory(franchise)
        let previous = previousDirectory(franchise)
        try fileManager.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: previous.path) {
            try fileManager.removeItem(at: previous)
        }
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.moveItem(at: directory, to: previous)
        }
        do {
            try fileManager.moveItem(at: staging, to: directory)
        } catch {
            if fileManager.fileExists(atPath: previous.path) {
                try? fileManager.moveItem(at: previous, to: directory)
            }
            throw error
        }
        try? fileManager.removeItem(at: previous)
    }
}

/// What the app knows about the installed `model3d` package.
public struct Model3DBundleInfo: Codable, Sendable, Hashable {
    public var formatVersion: Int
    public var franchise: String
    public var installedAt: String
    public var characterCount: Int
    public var fileCount: Int
    public var engineVersion: String?

    public init(
        formatVersion: Int,
        franchise: String,
        installedAt: String,
        characterCount: Int,
        fileCount: Int,
        engineVersion: String?
    ) {
        self.formatVersion = formatVersion
        self.franchise = franchise
        self.installedAt = installedAt
        self.characterCount = characterCount
        self.fileCount = fileCount
        self.engineVersion = engineVersion
    }
}
