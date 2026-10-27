import Foundation
import GRDB

public enum RetrievalNeed: String, Sendable, Codable, Hashable {
    case nothing
    case memories
    case references
    case recall
}

public enum ReferenceKind: String, Sendable, Hashable {
    case episode
    case fact
    case work

    var heading: String {
        switch self {
        case .episode: "剧情"
        case .fact: "角色资料"
        case .work: "作品资料"
        }
    }
}

public struct Reference: Sendable, Hashable {
    public var kind: ReferenceKind
    public var text: String
    public var title: String
    public var similarity: Double
}

public struct RetrievalResult: Sendable, Hashable {
    public var references: String?
    public var memories: String?
    public var recalled: Bool = false
    /// What it found and what each fallback cost, for the turn's trace.
    public var trace = RetrievalTrace()

    public static let none = RetrievalResult()
}

/// What one part of retrieval produced: the prompt section, the candidates it weighed,
/// and where it could not go on.
struct RetrievalOutcome {
    var text: String?
    var candidates: [RetrievalCandidate] = []
    var degradation: [String] = []
}

/// The reranker's scores below which a candidate is left out of the prompt (upstream
/// `rerank.RerankThresholds`).
public struct RerankThresholds: Sendable, Equatable {
    public var references: Double
    public var memories: Double
}

/// Every number retrieval goes by (upstream `retrieval.py`).
public enum RetrievalRules {
    public static let maxReferences = 5
    public static let candidatesPerSource = 12
    public static let fallbackReferences = 3
    public static let recallEpisodes = 2
    public static let recallEntries = 3
    public static let recallEpisodeChars = 3000
    public static let maxMemories = 5

    /// What counts as relevant enough depends on the reranker model (upstream
    /// `rerank.KNOWN_THRESHOLDS`). A model never calibrated gets the 4B's.
    static let rerankerThresholds: [String: RerankThresholds] = [
        "Qwen/Qwen3-Reranker-0.6B": RerankThresholds(references: 0.3, memories: 0.01),
        "Qwen/Qwen3-Reranker-4B": RerankThresholds(references: 0.7, memories: 0.005),
    ]
    static let fallbackRerankerModel = "Qwen/Qwen3-Reranker-4B"

    public static func thresholds(for model: String?) -> RerankThresholds {
        rerankerThresholds[model ?? ""] ?? rerankerThresholds[fallbackRerankerModel]!
    }
}

/// The tool the chat model can call to look an episode up itself (upstream
/// `RECALL_STORY_TOOL`): offered on every turn retrieval is available, and forbidden on
/// the round after it was called.
public enum RecallStoryTool {
    public static let name = "recall_story"

    public static let definition = ChatTool(
        name: name,
        description: "回顾剧情：在你亲身经历过的原作剧情中查找和某件事有关的剧情，返回它在你的剧情目录中的位置"
            + "（哪张卡或哪个活动）和剧情内容。当制作人问起「那次……是怎么回事」这类过去的事、"
            + "而你想不起具体经过时使用；闲聊时不需要。",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string(
                        "要回顾的事，写成一句概括，例如「拍写真集的那次」「W.I.N.G. 决赛」"
                    ),
                ]),
            ]),
            "required": .array([.string("query")]),
        ])
    )

    /// Added to the tool result the model reads just before the round that forbids tool
    /// calls; without it the model writes out its own tool-call markup as the reply.
    public static let lastRoundNote = "（这一轮不能再调用任何工具了，请现在就回答制作人。上面想起来的内容如果答不上他的问题，"
        + "就像一时记不清那样自然地说，不要提到查找、工具、记录或剧情库。）"
}

/// The retrieval itself: one query vector, the nearest candidates of each source, reranked
/// together, thresholded, and written as the prompt sections (upstream `retrieval.py`).
struct RetrievalEngine {
    let eidolon: Eidolon
    let character: CharacterConfig
    let world: WorldSetting?
    let embedder: (any EmbeddingProvider)?
    let reranker: (any RerankProvider)?
    let timeZone: TimeZone

    func retrieve(history: [StoredMessage], text: String, need: RetrievalNeed) async -> RetrievalResult {
        var trace = RetrievalTrace(need: need.rawValue)
        guard need != .nothing else { return RetrievalResult(trace: trace) }
        guard let embedder else {
            trace.degradation.append("没有配置向量化模型，跳过检索")
            return RetrievalResult(trace: trace)
        }
        let query = Self.query(history: history, text: text)
        trace.query = query
        let vector: [Float]
        do {
            vector = try await embedder.embedQuery(query)
        } catch {
            // Replying without references or memories (ADR-0011).
            trace.degradation.append("向量化失败，跳过检索：\(error.localizedDescription)")
            return RetrievalResult(trace: trace)
        }

        switch need {
        case .nothing:
            return RetrievalResult(trace: trace)
        case .memories:
            let memories = await memoriesPrompt(query: query, vector: vector)
            trace.candidates = memories.candidates
            trace.degradation += memories.degradation
            return RetrievalResult(memories: memories.text, trace: trace)
        case .references:
            async let refs = referencesSection(query: query, vector: vector)
            async let mems = memoriesPrompt(query: query, vector: vector)
            let (references, memories) = await (refs, mems)
            trace.candidates = references.candidates + memories.candidates
            trace.degradation += references.degradation + memories.degradation
            return RetrievalResult(
                references: references.text,
                memories: memories.text,
                trace: trace
            )
        case .recall:
            let recall = await recall(query: query, text: text, vector: vector)
            trace.candidates = recall.candidates
            trace.degradation += recall.degradation
            return RetrievalResult(references: recall.text, recalled: true, trace: trace)
        }
    }

    /// What the user said after her reply before it, as people see it.
    static func query(history: [StoredMessage], text: String) -> String {
        let previous = history.last { $0.role == "character" }
        guard let previous else { return text }
        let said = ReplyCues.shown(previous.segments.map(\.ja).joined())
        return said.isEmpty ? text : "\(said)\n\(text)"
    }

    // MARK: - References

    private func referencesSection(query: String, vector: [Float]) async -> RetrievalOutcome {
        var candidates: [Reference] = []
        candidates += (try? await eidolon.storyCandidates(
            queryVector: vector, characterID: character.id, limit: RetrievalRules.candidatesPerSource
        )) ?? []
        candidates += (try? await factsCandidates(
            queryVector: vector, limit: RetrievalRules.candidatesPerSource
        )) ?? []
        candidates += (await workCandidates(queryVector: vector, limit: RetrievalRules.candidatesPerSource)) ?? []
        guard !candidates.isEmpty else { return RetrievalOutcome() }

        var outcome = RetrievalOutcome()
        outcome.candidates = candidates.map {
            RetrievalCandidate(kind: $0.kind.rawValue, title: $0.title, similarity: $0.similarity)
        }
        var relevant: [Reference] = []
        var scores: [Int: Double] = [:]
        let thresholds = RetrievalRules.thresholds(for: reranker?.model)
        if let reranker {
            do {
                let ranked = try await reranker.rerank(
                    query: query, documents: candidates.map(\.text)
                )
                for item in ranked { scores[item.index] = item.score }
                relevant = ranked
                    .filter { $0.score >= thresholds.references }
                    .prefix(RetrievalRules.maxReferences)
                    .map { candidates[$0.index] }
            } catch {
                // The nearest by their vectors, unthresholded: no threshold can tell.
                outcome.degradation.append(
                    "重排失败，取向量最近的 \(RetrievalRules.fallbackReferences) 条：\(error.localizedDescription)"
                )
                relevant = nearest(candidates, count: RetrievalRules.fallbackReferences)
            }
        } else {
            outcome.degradation.append("没有配置重排模型，取向量最近的 \(RetrievalRules.fallbackReferences) 条")
            relevant = nearest(candidates, count: RetrievalRules.fallbackReferences)
        }
        for index in candidates.indices {
            outcome.candidates[index].score = scores[index]
            outcome.candidates[index].chosen = relevant.contains(candidates[index])
        }
        outcome.text = relevant.isEmpty ? nil : Self.referencesPrompt(relevant, hasWorld: world != nil)
        return outcome
    }

    private func nearest(_ candidates: [Reference], count: Int) -> [Reference] {
        candidates.sorted { $0.similarity > $1.similarity }.prefix(count).map { $0 }
    }

    static func referencesPrompt(_ references: [Reference], hasWorld: Bool) -> String {
        var lines = [
            "# 回忆与资料",
            "下面是和制作人这句话可能有关的内容，按相关程度排列，和话题无关的可以忽略。",
            "- 「剧情」是你亲身经历过的原作剧情，可以像回忆往事一样自然地提起，不要照搬台词。"
                + "剧情里没有记录制作人当时选了哪个选项，不要断言制作人当时说了什么或选了什么。",
            "- 「角色资料」是关于你自己和身边人物的设定。",
        ]
        // The work facts are a reference source only when the bundle carries a world
        // setting (upstream `open_reference_sources`).
        if hasWorld {
            lines.append(
                "- 「作品资料」是关于歌曲、唱片和演出的事实，可以照着回答；日期在今天之后的，是还没发售或还没举办的。"
                    + "作品资料里只有名称、日期、会场、出演者这类事实，没有台上或当时具体发生了什么，不要编造。"
            )
        }
        for reference in references {
            lines += ["", "## \(reference.kind.heading)", reference.text]
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Recall

    private func recall(query: String, text: String, vector: [Float]) async -> RetrievalOutcome {
        let story = (try? await eidolon.storyCandidates(
            queryVector: vector, characterID: character.id, limit: RetrievalRules.candidatesPerSource
        )) ?? []
        let entries = (await workCandidates(
            queryVector: vector, limit: RetrievalRules.candidatesPerSource, recallOnly: true
        )) ?? []
        return await recallText(asked: text, query: query, story: story, entries: entries)
    }

    /// The recall-story tool: what the chat model itself asked to look up, with its own
    /// query and the story alone — the lives and releases come only with a judged recall.
    func recallStoryTool(query: String) async -> String {
        guard let embedder else { return Self.cannotRecall }
        let vector: [Float]
        do {
            vector = try await embedder.embedQuery(query)
        } catch {
            return Self.cannotRecall
        }
        let story = (try? await eidolon.storyCandidates(
            queryVector: vector, characterID: character.id, limit: RetrievalRules.candidatesPerSource
        )) ?? []
        return await recallText(asked: query, query: query, story: story, entries: []).text
            ?? Self.cannotRecall
    }

    private static let cannotRecall = "暂时想不起来，现在查不到剧情。不要编造经过，可以坦率地说记不太清了。"

    private func recallText(
        asked: String,
        query: String,
        story: [Reference],
        entries: [Reference]
    ) async -> RetrievalOutcome {
        let documents = story.map(\.text) + entries.map(\.text)

        var episodeIDs: [String] = []
        var workEntries: [Reference] = []
        var outcome = RetrievalOutcome()
        outcome.candidates = (story + entries).map {
            RetrievalCandidate(kind: $0.kind.rawValue, title: $0.title, similarity: $0.similarity)
        }
        var scores: [Int: Double] = [:]
        let nearest = {
            episodeIDs = Array(story.sorted { $0.similarity > $1.similarity }.prefix(1).map(\.title))
            workEntries = Array(entries.prefix(1))
        }
        if let reranker, !documents.isEmpty {
            do {
                let ranked = try await reranker.rerank(query: query, documents: documents)
                for item in ranked { scores[item.index] = item.score }
                let threshold = RetrievalRules.thresholds(for: reranker.model).references
                for item in ranked where item.score >= threshold {
                    if item.index < story.count {
                        if episodeIDs.count < RetrievalRules.recallEpisodes,
                           !episodeIDs.contains(story[item.index].title) {
                            episodeIDs.append(story[item.index].title)
                        }
                    } else if workEntries.count < RetrievalRules.recallEntries {
                        workEntries.append(entries[item.index - story.count])
                    }
                }
            } catch {
                outcome.degradation.append("重排失败，取向量最近的：\(error.localizedDescription)")
                nearest()
            }
        } else {
            if reranker == nil {
                outcome.degradation.append("没有配置重排模型，取向量最近的")
            }
            nearest()
        }
        for index in outcome.candidates.indices {
            outcome.candidates[index].score = scores[index]
        }
        for index in outcome.candidates.indices {
            outcome.candidates[index].chosen =
                story.indices.contains(index)
                    ? episodeIDs.contains(story[index].title)
                    : workEntries.contains { $0.title == outcome.candidates[index].title }
        }

        if episodeIDs.isEmpty && workEntries.isEmpty {
            outcome.text = "没有想起和「\(asked)」有关的剧情：剧情库里没有记录这段经过，但这不等于这件事没有发生过。"
                + "不要编造经过，也不要说没有这回事；可以坦率地说细节记不太清了，或者问问制作人。"
            return outcome
        }
        let prompt = (try? await eidolon.recallPrompt(
            query: asked,
            episodeIDs: episodeIDs,
            entries: workEntries,
            characterID: character.id
        )) ?? nil
        outcome.text = prompt ?? Self.cannotRecall
        return outcome
    }

    // MARK: - Memories

    private func memoriesPrompt(query: String, vector: [Float]) async -> RetrievalOutcome {
        var outcome = RetrievalOutcome()
        guard let candidates = try? await eidolon.memoryCandidates(
            queryVector: vector,
            limit: RetrievalRules.candidatesPerSource,
            embedder: embedder
        ), !candidates.isEmpty else { return outcome }

        outcome.candidates = candidates.map {
            RetrievalCandidate(
                kind: "memory",
                title: String($0.text.prefix(40)),
                similarity: $0.similarity
            )
        }
        var best: [MemoryCandidate]
        var scores: [Int: Double] = [:]
        if let reranker {
            do {
                let ranked = try await reranker.rerank(
                    query: query, documents: candidates.map(\.text)
                )
                for item in ranked { scores[item.index] = item.score }
                best = ranked
                    .filter { $0.score >= RetrievalRules.thresholds(for: reranker.model).memories }
                    .prefix(RetrievalRules.maxMemories)
                    .map { candidates[$0.index] }
            } catch {
                // A memory the reranker never judged might be one the user never said.
                outcome.degradation.append(
                    "记忆重排失败，不带记忆回复：\(error.localizedDescription)"
                )
                return outcome
            }
        } else {
            outcome.degradation.append("没有配置重排模型，记忆按向量最近取")
            best = Array(candidates.sorted { $0.similarity > $1.similarity }
                .prefix(RetrievalRules.maxMemories))
        }
        for index in candidates.indices {
            outcome.candidates[index].score = scores[index]
            outcome.candidates[index].chosen = best.contains(candidates[index])
        }
        guard !best.isEmpty else { return outcome }
        outcome.text = try? await eidolon.memoriesPrompt(
            best,
            characterID: character.id,
            timeZone: timeZone
        )
        return outcome
    }

    // MARK: - Facts and work facts, embedded and cached in the user library

    private func factsCandidates(queryVector: [Float], limit: Int) async throws -> [Reference] {
        guard let factsPath = character.facts else { return [] }
        let url = eidolon.contentDirectory.appendingPathComponent(factsPath)
        guard let markdown = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let facts = Fact.parse(markdown)
        guard !facts.isEmpty else { return [] }
        let vectors = try await eidolon.cachedVectors(
            scope: "fact:\(character.id)",
            entries: facts.map { (id: $0.text, text: $0.text) },
            embedder: embedder
        )
        return Self.nearest(
            zip(facts, vectors).map { fact, vector in
                Reference(kind: .fact, text: fact.text, title: fact.title ?? fact.text,
                          similarity: Self.cosine(queryVector, vector))
            },
            limit: limit
        )
    }

    private func workCandidates(
        queryVector: [Float],
        limit: Int,
        recallOnly: Bool = false
    ) async -> [Reference]? {
        guard let world else { return nil }
        let entries = world.entries().filter { entry in
            !recallOnly || entry.kind == "live" || entry.kind == "release"
        }
        guard !entries.isEmpty else { return nil }
        guard let vectors = try? await eidolon.cachedVectors(
            scope: "work",
            entries: entries.map { (id: $0.title, text: $0.text) },
            embedder: embedder
        ) else { return nil }
        return Self.nearest(
            zip(entries, vectors).map { entry, vector in
                Reference(kind: .work, text: entry.text, title: entry.title,
                          similarity: Self.cosine(queryVector, vector))
            },
            limit: limit
        )
    }

    private static func nearest(_ references: [Reference], limit: Int) -> [Reference] {
        references.sorted { $0.similarity > $1.similarity }.prefix(limit).map { $0 }
    }

    // MARK: - Maths

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<a.count {
            let x = Double(a[i]), y = Double(b[i])
            dot += x * y
            na += x * x
            nb += y * y
        }
        let denominator = (na * nb).squareRoot()
        return denominator == 0 ? 0 : dot / denominator
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

struct Fact: Sendable, Hashable {
    var title: String?
    var text: String

    /// Split a facts file into entries: the text under each heading, titled with the
    /// headings above it (e.g. `人物关系 / 風野灯織`), the title and text together in
    /// `text` (upstream `characters.parse_facts`). Headings with nothing under them make
    /// no entry, and a heading level skipped leaves no blank in the title.
    static func parse(_ markdown: String) -> [Fact] {
        var facts: [Fact] = []
        var titles: [String] = []
        var body: [String] = []
        func flush() {
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let title = titles.isEmpty ? nil : titles.joined(separator: " / ")
                facts.append(Fact(
                    title: title,
                    text: title.map { "\($0)\n\(text)" } ?? text
                ))
            }
            body = []
        }
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let match = text.range(
                of: #"^#{1,6}\s+(.+?)\s*#*\s*$"#,
                options: .regularExpression
            ) {
                flush()
                let heading = String(text[match]).replacingOccurrences(
                    of: #"^#{1,6}\s+"#, with: "", options: .regularExpression
                ).replacingOccurrences(
                    of: #"\s*#*\s*$"#, with: "", options: .regularExpression
                )
                let level = text.prefix { $0 == "#" }.count
                if titles.count >= level { titles.removeSubrange((level - 1)...) }
                titles.append(heading.trimmingCharacters(in: .whitespaces))
            } else {
                body.append(text)
            }
        }
        flush()
        return facts
    }
}

struct MemoryCandidate: Sendable, Hashable {
    var id: String
    var text: String
    var sourceCharacterID: String?
    var createdAt: String
    var similarity: Double
}
