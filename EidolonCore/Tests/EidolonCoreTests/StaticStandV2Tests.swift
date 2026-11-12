import Foundation
import Testing
import ZIPFoundation
@testable import EidolonCore

@Suite("Static stand v2")
struct StaticStandV2Tests {
    private func makeEidolon() throws -> (Eidolon, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "eidolon-static-v2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try Eidolon(location: .init(root: root)), root)
    }

    private func makeStand(in parent: URL) throws -> URL {
        let staging = parent.appending(path: "stand-v2-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging.appending(path: "images"), withIntermediateDirectories: true)
        var files: [String: StaticStandManifest.FileRecord] = [:]
        var calm = Data()
        for (name, byte) in [("calm", 1), ("happy", 2)] {
            let data = Data([0x89, 0x50, 0x4E, 0x47, UInt8(byte)])
            try data.write(to: staging.appending(path: "images/\(name).png"))
            files["images/\(name).png"] = .init(size: data.count, crc32: CRC32.hex(data))
            if name == "calm" { calm = data }
        }
        let base = StaticStandManifest.Base(
            id: "A.A",
            outfit: "A",
            pose: "A",
            source: "S",
            expressions: ["calm": "images/calm.png", "happy": "images/happy.png"]
        )
        let manifest = StaticStandManifest(
            formatVersion: 2,
            franchise: "totsulover",
            createdAt: "2026-11-12T00:00:00Z",
            characters: [.init(id: "sakura", expressions: [:], bases: [base])],
            files: files
        )
        try JSONEncoder().encode(manifest).write(to: staging.appending(path: "manifest.json"))
        let output = parent.appending(path: "stand-v2.eidolonpkg")
        let archive = try Archive(url: output, accessMode: .create)
        try archive.addEntry(with: "manifest.json", fileURL: staging.appending(path: "manifest.json"))
        for name in ["calm", "happy"] {
            try archive.addEntry(with: "images/\(name).png", fileURL: staging.appending(path: "images/\(name).png"))
        }
        return output
    }

    @Test("v2 bases survive install and resolve their own expression paths")
    func v2Bases() async throws {
        let (eidolon, root) = try makeEidolon()
        var options = Fixture.Options()
        options.franchise = "totsulover"
        options.characterKeys = ["totsulover:sakura"]
        try await eidolon.installContent(
            bundleAt: try Fixture.makeBundle(in: root, options: options),
            franchise: "totsulover"
        )
        let bundle = try makeStand(in: root)
        let info = try await eidolon.installStaticStand(bundleAt: bundle)
        #expect(info.formatVersion == 2)
        #expect(info.baseCount == 1)
        let bases = try #require(try await eidolon.staticStandBases(characterID: "sakura"))
        #expect(bases.map(\.id) == ["A.A"])
        let images = try #require(try await eidolon.staticStandExpressions(characterID: "sakura", baseID: "A.A"))
        #expect(images["calm"] != nil)
        #expect(images["happy"] != nil)
    }

    @Test("v1 packages still decode as one implicit base")
    func v1Compatibility() throws {
        let data = try JSONEncoder().encode(StaticStandManifest(
            formatVersion: 1,
            franchise: "totsulover",
            createdAt: "2026-11-12T00:00:00Z",
            characters: [.init(id: "sakura", expressions: ["calm": "images/calm.png"])],
            files: [:]
        ))
        let decoded = try JSONDecoder().decode(StaticStandManifest.self, from: data)
        #expect(decoded.formatVersion == 1)
        #expect(decoded.characters.first?.allExpressions["calm"] == "images/calm.png")
    }
}
