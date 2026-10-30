import Foundation
import GRDB

/// Her facts at the bar: those of her character facts a visit's topic finds, for her to talk
/// from instead of making things up (upstream `bar_facts.py`).
///
/// What the topic says is the query: embedded, her facts nearest it reranked, the best
/// `maxFacts` kept, however relevant — the text turns' threshold is calibrated on what the
/// producer says, not on a topic. Only her facts are looked in, not the story, and her reason
/// for coming has no part in it. The query never changes, so what it finds is kept for her and
/// the topic while the app runs; failing, or taking longer than `timeout`, she comes in
/// without, and it is looked up again next time.
public struct BarFacts: Sendable {
    /// How many of her facts a visit is told.
    public static let maxFacts = 3
    /// How long looking them up may hold her coming in: past it, she comes in without.
    public static let timeout: TimeInterval = 15

    let contentDirectory: URL
    let userQueue: DatabaseQueue
    let character: CharacterConfig

    public init(contentDirectory: URL, userQueue: DatabaseQueue, character: CharacterConfig) {
        self.contentDirectory = contentDirectory
        self.userQueue = userQueue
        self.character = character
    }

    /// Her facts `topic` finds, best first; none if they cannot be looked up now.
    public func about(
        _ topic: BarTopic,
        embedder: (any EmbeddingProvider)?,
        reranker: (any RerankProvider)?
    ) async -> [String] {
        guard let embedder, let reranker else { return [] }
        let query = topic.note
        let looking = Task { try await self.lookedUp(query, embedder, reranker) }
        let timer = Task { try await Task.sleep(for: .seconds(Self.timeout)) }
        let found = await withTaskGroup(of: [String]?.self) { group in
            group.addTask { (try? await looking.value) ?? [] }
            group.addTask {
                _ = try? await timer.value
                return nil
            }
            // Whichever comes first; the other is cancelled.
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        looking.cancel()
        timer.cancel()
        return found ?? []
    }

    // MARK: - Private

    /// Her facts nearest `query`, reranked, the best `maxFacts` of them.
    private func lookedUp(
        _ query: String, _ embedder: any EmbeddingProvider, _ reranker: any RerankProvider
    ) async throws -> [String] {
        let vector = try await embedder.embedQuery(query)
        let facts = try self.facts()
        guard !facts.isEmpty else { return [] }
        let vectors = try await Self.cachedVectors(
            userQueue: userQueue, character: character, facts: facts, embedder: embedder
        )
        let near = zip(facts, vectors)
            .map { fact, score in
                Reference(
                    kind: .fact, text: fact.text, title: fact.title ?? fact.text,
                    similarity: RetrievalEngine.cosine(vector, score)
                )
            }
            .sorted { $0.similarity > $1.similarity }
            .prefix(RetrievalRules.candidatesPerSource)
            .map(\.text)
        guard !near.isEmpty else { return [] }
        let ranked = try await reranker.rerank(query: query, documents: near)
        return ranked.prefix(Self.maxFacts).compactMap { near.indices.contains($0.index) ? near[$0.index] : nil }
    }

    /// Her facts, one for each text, in file order without repetitions (upstream `_facts`).
    private func facts() throws -> [Fact] {
        guard let factsPath = character.facts else { return [] }
        let url = contentDirectory.appendingPathComponent(factsPath)
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        return Fact.parse(markdown).filter { seen.insert($0.text).inserted }
    }

    /// The vectors for `facts`, embedded once and kept in the user library under her and the
    /// model — the same cache a turn's facts use.
    private static func cachedVectors(
        userQueue: DatabaseQueue,
        character: CharacterConfig,
        facts: [Fact],
        embedder: any EmbeddingProvider
    ) async throws -> [[Float]] {
        let scope = "fact:\(character.id)"
        let model = embedder.model
        let existing: [String: [Float]] = try await userQueue.read { db in
            var cache: [String: [Float]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT entry_id, embedding FROM fact_vectors WHERE scope = ? AND model = ?",
                arguments: [scope, model]
            ) {
                cache[row["entry_id"]] = RetrievalEngine.decode(row["embedding"])
            }
            return cache
        }
        var cache = existing
        let missing = facts.filter { cache[$0.text] == nil }
        if !missing.isEmpty {
            let embedded = try await embedder.embed(missing.map(\.text))
            let rows = zip(missing, embedded).map { fact, vector -> (String, Data) in
                cache[fact.text] = vector
                return (fact.text, RetrievalEngine.encode(vector))
            }
            try await userQueue.write { db in
                for (text, data) in rows {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO fact_vectors(scope, entry_id, model, embedding)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [scope, text, model, data]
                    )
                }
            }
        }
        return facts.map { cache[$0.text] ?? [] }
    }
}
