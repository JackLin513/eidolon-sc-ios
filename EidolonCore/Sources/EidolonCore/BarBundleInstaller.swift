import Foundation
import ZIPFoundation

/// Unpacks, validates and installs a bar bundle beside the content and stand bundles
/// (ADR-0021). A bar package is all or nothing: the previous bar directory stays in charge
/// on any failure, so a half-copied bar is never shown.
struct BarBundleInstaller {
    let contentRoot: URL
    let fileManager: FileManager

    var barDirectory: URL { contentRoot.appendingPathComponent("bar", isDirectory: true) }
    var previousDirectory: URL {
        contentRoot.appendingPathComponent("bar-previous", isDirectory: true)
    }

    /// The pictures every bar needs: the frame, the counter's parts, the mixer. A package
    /// without one of them would draw a broken bar, so it is refused rather than installed.
    static let requiredImages = [
        "frame.png", "barground.png", "fan.png", "scanlines.png", "shaker.png",
        "ice.png", "age.png", "reset.png", "mix_yes.png", "mix_no.png", "slot.png",
        "gauge.png", "gauge_on.png", "arrow_0.png", "intro_0.png", "recipe_intro.png",
        "recipe_bg.png", "recipe_1.png",
    ]

    /// A package path without the leading `bar/`: the installed bar directory is the
    /// package's `bar/`, so the prefix comes off or the file lands one directory too deep.
    static func relative(_ path: String) -> String {
        path.hasPrefix("bar/") ? String(path.dropFirst("bar/".count)) : path
    }

    func install(_ bundleURL: URL, progress: ((ImportProgress) -> Void)? = nil) throws
        -> BarBundleInfo
    {
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw EidolonError.unreadableBundle("文件不存在")
        }
        let staging = contentRoot.appendingPathComponent(
            ".bar-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        try extract(bundleURL, to: staging, progress: progress)

        let manifest = try readManifest(in: staging)
        try validateManifest(manifest)
        try validateFiles(manifest, in: staging, progress: progress)
        try validateImages(manifest, in: staging)
        try swapIn(staging)

        return BarBundleInfo(
            formatVersion: manifest.formatVersion,
            installedAt: ISO8601DateFormatter().string(from: Date()),
            imageCount: manifest.images,
            fontCount: manifest.fonts.count,
            trackCount: manifest.tracks.count,
            sfxCount: manifest.sfx.count,
            manifest: manifest
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
        let root = destination.standardizedFileURL.path + "/"
        for (index, entry) in entries.enumerated() {
            // The package's paths start at the bar itself (`bar/img/…`), and the bar's own
            // directory is the one being installed: the prefix comes off, or the pictures
            // would land one directory too deep to be found.
            let path = Self.relative(entry.path)
            guard !path.isEmpty else { continue }
            let target = destination.appendingPathComponent(path)
            guard target.standardizedFileURL.path.hasPrefix(root) else {
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

    // MARK: - Validation

    private func readManifest(in directory: URL) throws -> BarManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            throw EidolonError.invalidBundle("缺少 manifest.json")
        }
        do {
            return try JSONDecoder().decode(BarManifest.self, from: data)
        } catch {
            throw EidolonError.invalidBundle("manifest.json 无法解析：\(error.localizedDescription)")
        }
    }

    private func validateManifest(_ manifest: BarManifest) throws {
        guard manifest.formatVersion == BarManifest.supportedFormatVersion else {
            throw EidolonError.unsupportedVersion(
                "酒吧素材包格式版本 \(manifest.formatVersion)，本 App 支持 "
                    + "\(BarManifest.supportedFormatVersion)"
            )
        }
        guard manifest.kind == .bar else {
            throw EidolonError.invalidBundle("不是酒吧素材包")
        }
        guard manifest.images > 0 else {
            throw EidolonError.invalidContent("酒吧素材包里没有画面")
        }
        // Sound is optional on purpose: a package without it installs, and the jukebox then
        // stays grey (docs/design/bar-room.md). The manifest still has to say what it has.
        guard manifest.tracks.count <= manifest.files.count,
              manifest.sfx.count <= manifest.files.count
        else {
            throw EidolonError.invalidBundle("manifest 里列出的音轨比文件还多")
        }
    }

    private func validateFiles(
        _ manifest: BarManifest,
        in directory: URL,
        progress: ((ImportProgress) -> Void)?
    ) throws {
        guard !manifest.files.isEmpty else {
            throw EidolonError.invalidBundle("manifest 没有列出文件")
        }
        let root = directory.standardizedFileURL.path + "/"
        progress?(ImportProgress(
            phase: .validating,
            completed: 0,
            total: manifest.files.count
        ))
        for (index, (path, record)) in manifest.files.sorted(by: { $0.key < $1.key }).enumerated() {
            // The same prefix comes off here: the picture is at `img/frame.png` in the
            // installed bar, whatever the package called it.
            let relative = Self.relative(path)
            let url = directory.appendingPathComponent(relative).standardizedFileURL
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
            progress?(ImportProgress(
                phase: .validating,
                completed: index + 1,
                total: manifest.files.count
            ))
        }
    }

    private func validateImages(_ manifest: BarManifest, in directory: URL) throws {
        for name in Self.requiredImages {
            let path = "bar/img/\(name)"
            guard manifest.files[path] != nil,
                  fileManager.fileExists(
                      atPath: directory.appendingPathComponent(Self.relative(path)).path
                  )
            else {
                throw EidolonError.invalidContent("酒吧素材包缺少 \(name)")
            }
        }
    }

    // MARK: - Swapping

    private func swapIn(_ staging: URL) throws {
        if fileManager.fileExists(atPath: previousDirectory.path) {
            try fileManager.removeItem(at: previousDirectory)
        }
        let hadCurrent = fileManager.fileExists(atPath: barDirectory.path)
        if hadCurrent {
            try fileManager.moveItem(at: barDirectory, to: previousDirectory)
        }
        do {
            try fileManager.moveItem(at: staging, to: barDirectory)
        } catch {
            if hadCurrent {
                try? fileManager.moveItem(at: previousDirectory, to: barDirectory)
            }
            throw error
        }
    }
}
