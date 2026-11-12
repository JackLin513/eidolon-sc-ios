import Foundation
import Testing
@testable import EidolonCore

@Suite("Franchise prompt")
struct FranchisePromptTests {
    @Test("a package prompt loads and replaces the built-in identity")
    func load() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "franchise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "characters"), withIntermediateDirectories: true)
        let prompt = FranchisePrompt(
            workName: "Work", organization: "Org",
            judgeScene: "JUDGE", callScene: "CALL", producerLine: "PRODUCER",
            memoryInstructions: "MEMORY", titleInstructions: "TITLE"
        )
        try JSONEncoder().encode(prompt).write(to: root.appending(path: "characters/franchise.json"))
        let loaded = try #require(FranchisePrompt.load(in: root))
        #expect(loaded.judgeScene == "JUDGE")
        #expect(loaded.producerLine == "PRODUCER")
    }
}
