import Foundation
import Testing
import ZIPFoundation
@testable import EidolonCore

@Suite("Static stand")
struct StaticStandTests {
    private func makeEidolon() throws -> (Eidolon, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "eidolon-static-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try Eidolon(location: .init(root: root)), root)
    }

    private func makeStand(in parent: URL, contentSetID: String) throws -> URL {
        let staging = parent.appending(path: "stand-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging.appending(path: "images"), withIntermediateDirectories: true)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        try image.write(to: staging.appending(path: "images/calm.png"))
        var files: [String: StaticStandManifest.FileRecord] = [
            "images/calm.png": .init(size: image.count, crc32: CRC32.hex(image))
        ]
        let manifest = StaticStandManifest(
            formatVersion: 1,
            franchise: "totsulover",
            contentSetID: contentSetID,
            createdAt: "2026-11-12T00:00:00Z",
            characters: [
                .init(
                    id: "mano",
                    characterKey: "totsulover:mano",
                    expressions: ["calm": "images/calm.png"]
                )
            ],
            files: files
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: staging.appending(path: "manifest.json"))
        files.removeAll()
        let output = parent.appending(path: "stand.eidolonpkg")
        let archive = try Archive(url: output, accessMode: .create)
        for path in [staging.appending(path: "manifest.json"), staging.appending(path: "images/calm.png")] {
            try archive.addEntry(
                with: path.lastPathComponent == "calm.png" ? "images/calm.png" : "manifest.json",
                fileURL: path
            )
        }
        return output
    }

    @Test("static stand installs only for the matching content set")
    func binding() async throws {
        let (eidolon, root) = try makeEidolon()
        var contentOptions = Fixture.Options()
        contentOptions.franchise = "totsulover"
        contentOptions.contentSetID = "totsulover.sakura.v1"
        contentOptions.characterKeys = ["totsulover:mano", "totsulover:hiori"]
        try await eidolon.installContent(
            bundleAt: try Fixture.makeBundle(in: root, options: contentOptions),
            franchise: "totsulover"
        )
        let stand = try makeStand(in: root, contentSetID: "totsulover.sakura.v1")
        let info = try await eidolon.installStaticStand(bundleAt: stand)
        #expect(info.contentSetID == "totsulover.sakura.v1")
        #expect(try await eidolon.staticStandExpressions(characterID: "mano")?["calm"] != nil)
    }

    @Test("static stand rejects a different content family")
    func mismatch() async throws {
        let (eidolon, root) = try makeEidolon()
        var contentOptions = Fixture.Options()
        contentOptions.franchise = "totsulover"
        contentOptions.contentSetID = "totsulover.sakura.v1"
        contentOptions.characterKeys = ["totsulover:mano", "totsulover:hiori"]
        try await eidolon.installContent(
            bundleAt: try Fixture.makeBundle(in: root, options: contentOptions),
            franchise: "totsulover"
        )
        let stand = try makeStand(in: root, contentSetID: "another.set")
        await #expect(throws: EidolonError.self) {
            try await eidolon.installStaticStand(bundleAt: stand)
        }
    }
}
