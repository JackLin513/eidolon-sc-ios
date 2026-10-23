import Foundation
import GRDB
import XCTest
@testable import EidolonCore

struct FakeEmbedding: EmbeddingProvider {
    var vector: [Float]
    var failure: Error?
    var model = "test-embed"

    func embed(_ texts: [String]) async throws -> [[Float]] {
        if let failure { throw failure }
        return texts.map { _ in vector }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        if let failure { throw failure }
        return vector
    }
}

struct FakeRerank: RerankProvider {
    var scores: [Double]
    var failure: Error?

    func rerank(query: String, documents: [String]) async throws -> [(index: Int, score: Double)] {
        if let failure { throw failure }
        return documents.indices
            .map { (index: $0, score: $0 < scores.count ? scores[$0] : 0) }
            .sorted { $0.score > $1.score }
    }
}

final class RetrievalTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonRetrieval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.vectors = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]]
        let bundle = try Fixture.makeBundle(in: root, options: options)
        try await eidolon.install(bundleAt: bundle)
        return eidolon
    }

    private func reply() -> RecordingChatProvider {
        RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
    }

    private func systemPrompt(_ provider: RecordingChatProvider) throws -> String {
        let prompt = try XCTUnwrap(provider.prompts.first)
        return prompt.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
    }

    func testCosineRanksVectors() {
        XCTAssertEqual(RetrievalEngine.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(RetrievalEngine.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(RetrievalEngine.cosine([1, 0], [2, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(RetrievalEngine.cosine([1, 0], [1]), 0, accuracy: 0.0001)
    }

    func testFactParsing() {
        let markdown = """
            # 人物
            ## 風野灯織
            她认真又固执。

            ## 八宮めぐる
            开朗。
            """
        let facts = Fact.parse(markdown)
        XCTAssertEqual(facts.count, 2)
        XCTAssertEqual(facts[0].title, "人物 / 風野灯織")
        XCTAssertEqual(facts[0].text, "她认真又固执。")
        XCTAssertEqual(facts[1].title, "人物 / 八宮めぐる")
    }

    func testReferencesReachThePrompt() async throws {
        let eidolon = try await installedEidolon()
        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "前に話してたこと覚えてる？",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9, 0.2])
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertTrue(system.contains("# 回忆与资料"))
        XCTAssertTrue(system.contains("## 剧情"))
        XCTAssertTrue(system.contains("真乃的段落"))
        XCTAssertFalse(system.contains("真乃的段落二")) // below the threshold
        XCTAssertFalse(system.contains("灯織的段落")) // another character's story
    }

    func testEmbeddingFailureSkipsRetrieval() async throws {
        let eidolon = try await installedEidolon()
        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "こんにちは",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [], failure: RetrievalServiceError.status(500, "boom")),
            reranker: FakeRerank(scores: [0.9])
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertFalse(system.contains("# 回忆与资料"))
        let snapshot = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(snapshot?.messages.count, 2) // the turn still went through
    }

    func testRerankFailureFallsBackToTheNearest() async throws {
        let eidolon = try await installedEidolon()
        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "あの話",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [], failure: RetrievalServiceError.status(500, "boom"))
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertTrue(system.contains("# 回忆与资料"))
        XCTAssertTrue(system.contains("真乃的段落"))
    }

    func testMemoriesReachThePrompt() async throws {
        let eidolon = try await installedEidolon()
        let userDatabase = root.appendingPathComponent("app/User/eidolon.sqlite")
        let queue = try DatabaseQueue(path: userDatabase.path)
        let vector = [Float]([1, 0, 0, 0])
        let data = vector.withUnsafeBufferPointer { Data(buffer: $0) }
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO memories(id, source_character_id, text, created_at) VALUES ('m1', 'hiori', '制作人养了一只猫', '2026-10-01T00:00:00Z')"
            )
            try db.execute(
                sql: "INSERT INTO memory_vectors(memory_id, model, embedding) VALUES ('m1', 'test-embed', ?)",
                arguments: [data]
            )
        }

        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "うちの猫なんだけど",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .memories),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertTrue(system.contains("# 关于制作人的记忆"))
        XCTAssertTrue(system.contains("制作人养了一只猫"))
        XCTAssertTrue(system.contains("灯織"))
        XCTAssertTrue(system.contains("转述"))
    }
}
