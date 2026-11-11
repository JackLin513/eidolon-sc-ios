import Foundation
import Testing
@testable import EidolonCore

@Suite("Content registry")
struct ContentRegistryTests {
    private func makeEidolon() throws -> (Eidolon, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "eidolon-registry-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try Eidolon(location: .init(root: root)), root)
    }

    @Test("two franchises install side by side and switch without losing the first")
    func twoFranchisesSwitch() async throws {
        let (eidolon, root) = try makeEidolon()
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        let sakuraRoot = root.appending(path: "sakura-src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sakuraRoot, withIntermediateDirectories: true)
        let sakura = try Fixture.makeBundle(in: sakuraRoot)
        let info = try await eidolon.installContent(bundleAt: sakura, franchise: "totsulover")

        #expect(info.franchise == "totsulover")
        #expect(info.kind == ContentKind.content.rawValue)
        #expect(await eidolon.activeFranchise == "shiny")
        #expect(await eidolon.installedContentPackages.map(\.franchise) == ["shiny", "totsulover"])
        try await eidolon.activateContent(franchise: "totsulover")
        #expect(await eidolon.activeFranchise == "totsulover")
        #expect(try await eidolon.characters().count == 2)

        try await eidolon.activateContent(franchise: "shiny")
        #expect(await eidolon.activeFranchise == "shiny")
        #expect(try await eidolon.characters().count == 2)
        #expect(try await eidolon.usableContentInfo()?.franchise == "shiny")

        let current = root.appending(path: "Content/current")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == "shiny/current")
    }

    @Test("import routing reads franchise from the package manifest")
    func autoRouting() async throws {
        let (eidolon, root) = try makeEidolon()
        var options = Fixture.Options()
        options.franchise = "totsulover"
        options.kind = "content"
        options.characterKeys = ["totsulover:mano", "totsulover:hiori"]
        let bundle = try Fixture.makeBundle(in: root, options: options)
        let info = try await eidolon.installContentPackage(bundleAt: bundle)
        #expect(info.franchise == "totsulover")
        #expect(await eidolon.activeFranchise == "totsulover")
    }

    @Test("a non-content kind is rejected by the content route")
    func rejectsOtherKinds() async throws {
        let (eidolon, root) = try makeEidolon()
        var options = Fixture.Options()
        options.franchise = "totsulover"
        options.kind = "stand"
        options.characterKeys = ["totsulover:mano", "totsulover:hiori"]
        let bundle = try Fixture.makeBundle(in: root, options: options)
        await #expect(throws: EidolonError.self) {
            try await eidolon.installContentPackage(bundleAt: bundle)
        }
    }

    @Test("a content package reports its CharacterKey namespace")
    func characterKey() {
        let key = CharacterKey(franchise: "totsulover", localID: "sakura")
        #expect(key.description == "totsulover:sakura")
        #expect(key != CharacterKey(franchise: "shiny", localID: "sakura"))
    }

    @Test("legacy install records read as shiny/content")
    func legacyInfoDefaults() throws {
        let info = ContentBundleInfo(
            formatVersion: ContentManifest.supportedFormatVersion,
            contentSchemaVersion: ContentSchema.version,
            installedAt: "now",
            embeddingModel: "m",
            embeddingDimensions: 4,
            episodeCount: 1,
            passageCount: 1,
            characterCount: 1
        )
        #expect(info.franchise == "shiny")
        #expect(info.kind == ContentKind.content.rawValue)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ContentBundleInfo.self, from: data)
        #expect(decoded.franchise == "shiny")
        #expect(decoded.kind == ContentKind.content.rawValue)
    }
}
