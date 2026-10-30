import Foundation
import XCTest
@testable import EidolonCore

/// Builds small bar packages for the bar-package tests: the pictures the bar refuses to do
/// without, the font, and optionally sound.
enum BarPackageFixture {
    static func makeBundle(
        in parent: URL,
        formatVersion: Int = BarManifest.supportedFormatVersion,
        kind: BarManifest.Kind = .bar,
        skipImages: Set<String> = [],
        withAudio: Bool = false,
        corruptCRC: Bool = false
    ) throws -> URL {
        let staging = parent.appendingPathComponent(
            "bar-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        var files: [String: Data] = [:]
        for name in BarBundleInstaller.requiredImages where !skipImages.contains(name) {
            files["bar/img/\(name)"] = Data("png \(name)".utf8)
        }
        for name in ["fusion-pixel-12px-zh_hans.woff2", "OFL-fusion-pixel.txt"] {
            files["bar/fonts/\(name)"] = Data("font \(name)".utf8)
        }
        var tracks: [Int] = []
        var sfx: [String] = []
        if withAudio {
            tracks = [32, 2]
            sfx = ["addingredient", "iceadd"]
            files["bar/audio/tracks/032_hopes_and_dreams.ogg"] = Data("track 32".utf8)
            files["bar/audio/tracks/002_a_neon_glow.ogg"] = Data("track 2".utf8)
            for name in sfx {
                files["bar/audio/sfx/\(name).ogg"] = Data("sfx \(name)".utf8)
            }
        }

        var records: [String: BarManifest.FileRecord] = [:]
        for (path, data) in files {
            var crc = CRC32.hex(data)
            if corruptCRC, path == "bar/img/frame.png" {
                crc = "deadbeef"
            }
            records[path] = BarManifest.FileRecord(size: data.count, crc32: crc)
        }
        let manifest = BarManifest(
            formatVersion: formatVersion,
            kind: kind,
            createdAt: "2026-10-28T00:00:00+00:00",
            images: files.keys.filter { $0.hasPrefix("bar/img/") }.count,
            fonts: ["fusion-pixel-12px-zh_hans.woff2", "OFL-fusion-pixel.txt"]
                .filter { files["bar/fonts/\($0)"] != nil },
            tracks: tracks,
            sfx: sfx,
            files: records
        )
        try JSONEncoder().encode(manifest)
            .write(to: staging.appendingPathComponent("manifest.json"))

        for (path, data) in files {
            let url = staging.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        return try Fixture.zip(
            staging,
            to: parent.appendingPathComponent("bar-\(UUID().uuidString).eidolonpkg")
        )
    }
}

final class BarBundleTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonBarBundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: Fixture.makeBundle(in: root))
        return eidolon
    }

    func testABarPackageInstallsItsPicturesFontsAndRecord() async throws {
        let eidolon = try await installedEidolon()
        let before = try await eidolon.installedBarInfo()
        XCTAssertNil(before)

        let progress = ProgressRecorder()
        let info = try await eidolon.installBar(
            bundleAt: BarPackageFixture.makeBundle(in: root, withAudio: true),
            progress: { progress.add($0) }
        )
        XCTAssertEqual(info.imageCount, BarBundleInstaller.requiredImages.count)
        XCTAssertEqual(info.fontCount, 2)
        XCTAssertEqual(info.trackCount, 2)
        XCTAssertEqual(info.sfxCount, 2)
        XCTAssertTrue(info.hasAudio)

        let barDirectory = eidolon.location.barDirectory
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: barDirectory.appendingPathComponent("img/frame.png").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: barDirectory.appendingPathComponent(
                    "fonts/fusion-pixel-12px-zh_hans.woff2"
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: barDirectory.appendingPathComponent(
                    "audio/sfx/iceadd.ogg"
                ).path
            )
        )

        XCTAssertTrue(progress.all.contains { $0.phase == .extracting })
        XCTAssertTrue(progress.all.contains { $0.phase == .validating && $0.completed == $0.total })

        let installed = try await eidolon.installedBarInfo()
        XCTAssertEqual(installed?.formatVersion, BarManifest.supportedFormatVersion)
        XCTAssertEqual(installed?.trackCount, 2)
    }

    func testAPackageWithoutSoundInstallsAndSaysSo() async throws {
        let eidolon = try await installedEidolon()
        let info = try await eidolon.installBar(bundleAt: BarPackageFixture.makeBundle(in: root))
        XCTAssertFalse(info.hasAudio)
        let installed = try await eidolon.installedBarInfo()
        XCTAssertEqual(installed?.hasAudio, false)
    }

    func testABadPackageKeepsThePreviousBar() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.installBar(bundleAt: BarPackageFixture.makeBundle(in: root, withAudio: true))

        let badBundles = [
            try BarPackageFixture.makeBundle(in: root, corruptCRC: true),
            try BarPackageFixture.makeBundle(in: root, formatVersion: 99),
            try BarPackageFixture.makeBundle(in: root, skipImages: ["frame.png"]),
        ]
        for bundle in badBundles {
            do {
                try await eidolon.installBar(bundleAt: bundle)
                XCTFail("a bad bar package must not install")
            } catch {}
        }

        let kept = try await eidolon.installedBarInfo()
        XCTAssertEqual(kept?.trackCount, 2)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: eidolon.location.barDirectory
                    .appendingPathComponent("audio/sfx/iceadd.ogg").path
            )
        )
    }

    func testAPackageMissingAPictureIsRefused() async throws {
        let eidolon = try await installedEidolon()
        let bundle = try BarPackageFixture.makeBundle(in: root, skipImages: ["frame.png"])
        do {
            try await eidolon.installBar(bundleAt: bundle)
            XCTFail("a bar without its frame must not install")
        } catch let error as EidolonError {
            guard case .invalidContent(let message) = error else {
                return XCTFail("expected invalidContent, got \(error)")
            }
            XCTAssertTrue(message.contains("frame.png"), message)
        }
        let info = try await eidolon.installedBarInfo()
        XCTAssertNil(info)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: eidolon.location.barDirectory.path)
        )
    }

    func testClearingTheDirectoryForgetsTheBar() async throws {
        let eidolon = try await installedEidolon()
        try await eidolon.installBar(bundleAt: BarPackageFixture.makeBundle(in: root))
        try FileManager.default.removeItem(at: eidolon.location.barDirectory)
        let info = try await eidolon.installedBarInfo()
        XCTAssertNil(info)
    }
}
