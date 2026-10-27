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
    var model = "Qwen/Qwen3-Reranker-0.6B"

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

    private func installedEidolon(_ given: Fixture.Options = Fixture.Options()) async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = given
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
        XCTAssertEqual(facts[0].text, "人物 / 風野灯織\n她认真又固执。")
        XCTAssertEqual(facts[1].title, "人物 / 八宮めぐる")
    }

    /// Upstream keeps the headings above an entry as its title even when one level is
    /// skipped: no blank joins them (`characters.parse_facts`).
    func testFactTitlesSkipNoHeadingLevels() {
        let facts = Fact.parse("""
            # 人物关系
            ### 風野灯織
            她认真又固执。

            ## 八宮めぐる
            开朗。
            """)
        XCTAssertEqual(facts.map(\.title), ["人物关系 / 風野灯織", "人物关系 / 八宮めぐる"])
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
        XCTAssertFalse(system.contains("「作品资料」是关于歌曲")) // no world setting
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

    /// A judge that times out or cannot be read still looks references up: upstream's
    /// `retrieval.py` retrieves anyway on `JudgeError`, and only the affinity is left alone.
    func testAFailingJudgeStillLooksReferencesUp() async throws {
        let eidolon = try await installedEidolon()
        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "前に話してたこと覚えてる？",
            provider: provider,
            judge: FailingJudge(),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9, 0.2])
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertTrue(system.contains("# 回忆与资料"))
        XCTAssertTrue(system.contains("真乃的段落"))
        let affinity = try await eidolon.readAffinity(characterID: "mano", now: Date())
        XCTAssertEqual(affinity.value, AffinityRules.normal, accuracy: 0.001)
    }

    /// Upstream names a guide only for the reference sources it has: the work facts are a
    /// source only when the content bundle carries a world setting.
    func testTheReferencesGuideFollowsTheWorldSetting() async throws {
        var options = Fixture.Options()
        options.world = .valid
        let eidolon = try await installedEidolon(options)
        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "歌について",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertTrue(system.contains("- 「剧情」是你亲身经历过的原作剧情"))
        XCTAssertTrue(system.contains("- 「角色资料」是关于你自己和身边人物的设定。"))
        XCTAssertTrue(system.contains("- 「作品资料」是关于歌曲、唱片和演出的事实"))
    }

    /// A fact is embedded and shown as its title and its text together, titled with the
    /// headings above it; skipping a heading level does not leave a blank in the title.
    func testFactsCarryTheirTitleIntoTheEmbeddingAndThePrompt() async throws {
        var options = Fixture.Options()
        options.facts = true
        let eidolon = try await installedEidolon(options)
        let provider = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "灯織はどんな人？",
            provider: provider,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0], model: "new-embed"),
            reranker: FakeRerank(scores: [0.9, 0.9, 0.9])
        ) {}

        let system = try systemPrompt(provider)
        XCTAssertTrue(system.contains("## 角色资料"))
        XCTAssertTrue(system.contains("人物关系 / 風野灯織\n她认真又固执。"))
        XCTAssertFalse(system.contains("人物关系 /  /"))

        // The facts' vectors are kept under the embedder in use, not the bundle's model.
        let model = try await eidolon.userQueue.read { db in
            try String.fetchOne(db, sql: "SELECT model FROM fact_vectors LIMIT 1")
        }
        XCTAssertEqual(model, "new-embed")
    }

    /// Recalling an episode lists only the episodes she is cast in, in the same card or
    /// event (upstream `corpus.catalog(character.id)`).
    func testRecallListsOnlyTheEpisodesSheIsCastIn() async throws {
        var options = Fixture.Options()
        options.siblingEpisode = true
        let eidolon = try await installedEidolon(options)
        let prompt = try await eidolon.recallPrompt(
            query: "写真集",
            episodeIDs: ["e1"],
            entries: [],
            characterID: "mano"
        )
        XCTAssertTrue(prompt.contains("「第一话」"))
        XCTAssertFalse(prompt.contains("「别人的一话」"))
    }

    /// What counts as relevant depends on the reranker (upstream `rerank.KNOWN_THRESHOLDS`),
    /// and a model never calibrated gets the 4B's.
    func testRerankThresholdsFollowTheModel() {
        let six = RetrievalRules.thresholds(for: "Qwen/Qwen3-Reranker-0.6B")
        XCTAssertEqual(six.references, 0.3)
        XCTAssertEqual(six.memories, 0.01)

        let four = RetrievalRules.thresholds(for: "Qwen/Qwen3-Reranker-4B")
        XCTAssertEqual(four.references, 0.7)
        XCTAssertEqual(four.memories, 0.005)

        let unknown = RetrievalRules.thresholds(for: "some/uncalibrated-model")
        XCTAssertEqual(unknown.references, 0.7)
        XCTAssertEqual(unknown.memories, 0.005)
    }

    func testTheRerankerModelSetsWhatCountsAsRelevant() async throws {
        let eidolon = try await installedEidolon()
        let fourB = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "あの話",
            provider: fourB,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(
                scores: [0.6],
                model: "Qwen/Qwen3-Reranker-4B"
            )
        ) {}
        XCTAssertFalse(try systemPrompt(fourB).contains("# 回忆与资料"))

        let sixB = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "もう一度、あの話",
            provider: sixB,
            judge: FixedJudge(judged: Judged(level: 2), need: .references),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.6])
        ) {}
        XCTAssertTrue(try systemPrompt(sixB).contains("# 回忆与资料"))
    }
}
