import Foundation
import XCTest
@testable import EidolonCore

final class BackgroundModelRoutingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonBackground-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMemoryUsesTheBackgroundProviderWhileTheReplyUsesTheChatProvider() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        let chat = MemoryChatProvider(memory: nil)
        let background = MemoryChatProvider(
            memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#
        )
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "我养了一只猫",
            provider: chat,
            background: background,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}
        await eidolon.settleMemories()

        XCTAssertEqual(chat.extractionPrompts.count, 0)
        XCTAssertEqual(background.extractionPrompts.count, 1)
        let memories = try await eidolon.memories()
        XCTAssertEqual(memories.map(\.text), ["制作人养了一只猫"])
    }

    func testWithoutABackgroundProviderTheChatModelWritesTheMemory() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        let chat = MemoryChatProvider(
            memory: #"{"memories": [{"text": "制作人喜欢咖啡"}]}"#
        )
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "我喜欢咖啡",
            provider: chat,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}
        await eidolon.settleMemories()

        XCTAssertEqual(chat.extractionPrompts.count, 1)
        let memories = try await eidolon.memories()
        XCTAssertEqual(memories.map(\.text), ["制作人喜欢咖啡"])
    }
}
