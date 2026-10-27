import Foundation
import GRDB

extension Eidolon {
    nonisolated var contentDirectory: URL { location.contentDirectory }

    // MARK: - Story

    func storyCandidates(queryVector: [Float], characterID: String, limit: Int) throws -> [Reference] {
        let passages = try contentDatabase().passages(characterID: characterID)
        return passages
            .map { passage in
                Reference(
                    kind: .episode,
                    text: passage.text,
                    title: passage.episodeID,
                    similarity: RetrievalEngine.cosine(queryVector, RetrievalEngine.decode(passage.embedding))
                )
            }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }

    /// The recall prompt: the episodes, their dialogue and where they sit in her catalog,
    /// then the work facts.
    func recallPrompt(
        query: String,
        episodeIDs: [String],
        entries: [Reference],
        characterID: String
    ) async throws -> String {
        var lines = ["# 回顾剧情：\(query)"]
        if episodeIDs.isEmpty {
            lines.append("剧情库里没有记录这段经过，但这不等于这件事没有发生过。"
                + "不要编造经过，也不要说没有这回事；可以坦率地说细节记不太清了")
        } else {
            lines.append("下面是你经历过的剧情中和这件事最相关的，按相关程度排列。用自己的话回忆经过，不要照搬台词。"
                + "剧情里没有记录制作人当时选了哪个选项，不要断言制作人当时说了什么或选了什么。")
        }
        if !entries.isEmpty {
            lines.append("「作品资料」是和这件事有关的演出或唱片的事实。"
                + "作品资料里只有名称、日期、会场、出演者这类事实，没有台上或当时具体发生了什么，不要编造。")
        }
        for id in episodeIDs {
            guard let episode = try contentDatabase().episode(id: id) else { continue }
            lines += ["", "## \(episode.category) / \(episode.source) /「\(episode.title)」"]
            let siblings = try contentDatabase().episodeTitles(sourcesLike: episode.source)
            if siblings.count > 1 {
                lines.append("（\(episode.source)中你出场的剧情依次是：\(siblings.map { "「\($0)」" }.joined())）")
            }
            lines.append(try contentDatabase().transcript(episodeID: id, limit: RetrievalRules.recallEpisodeChars))
        }
        for entry in entries {
            lines += ["", "## 作品资料", entry.text]
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Facts and work facts

    /// The vectors for `entries`, embedded once and kept in the user library, by model.
    func cachedVectors(
        scope: String,
        entries: [(id: String, text: String)],
        embedder: (any EmbeddingProvider)?
    ) async throws -> [[Float]] {
        guard let embedder else { return entries.map { _ in [] } }
        let model = (try? installedContentInfo()?.embeddingModel) ?? ""
        let existing: [(String, Data)] = try await userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT entry_id, embedding FROM fact_vectors WHERE scope = ? AND model = ?",
                arguments: [scope, model]
            ).map { row in
                (row["entry_id"] as String, row["embedding"] as Data)
            }
        }
        var cache: [String: [Float]] = [:]
        for (entryID, data) in existing {
            cache[entryID] = RetrievalEngine.decode(data)
        }
        let missing = entries.filter { cache[$0.id] == nil }
        if !missing.isEmpty {
            let vectors = try await embedder.embed(missing.map(\.text))
            var rows: [(String, Data)] = []
            for (entry, vector) in zip(missing, vectors) {
                rows.append((entry.id, Self.data(vector)))
                cache[entry.id] = vector
            }
            let batch = rows
            try await userQueue.write { db in
                for (entryID, data) in batch {
                    try db.execute(
                        sql: """
                            INSERT OR REPLACE INTO fact_vectors(scope, entry_id, model, embedding)
                            VALUES (?, ?, ?, ?)
                            """,
                        arguments: [scope, entryID, model, data]
                    )
                }
            }
        }
        return entries.map { cache[$0.id] ?? [] }
    }

    static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Memories

    /// The producer's still-holding memories nearest the turn. A memory written down but
    /// left unembedded is embedded here, the next time memories are searched.
    func memoryCandidates(
        queryVector: [Float],
        limit: Int,
        embedder: (any EmbeddingProvider)?,
        characterID: String? = nil
    ) async throws -> [MemoryCandidate] {
        let model = embedder?.model ?? (try? installedContentInfo()?.embeddingModel) ?? ""
        let rows: [(id: String, text: String, source: String?, createdAt: String, vector: Data?)] =
            try await userQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                        SELECT m.id, m.text, m.source_character_id, m.created_at, v.embedding
                        FROM memories m
                        LEFT JOIN memory_vectors v ON v.memory_id = m.id AND v.model = ?
                        WHERE m.superseded_by IS NULL
                          AND (? IS NULL OR m.source_character_id = ?)
                        """,
                    arguments: [model, characterID, characterID]
                ).map { row in
                    (
                        id: row["id"],
                        text: row["text"],
                        source: row["source_character_id"],
                        createdAt: row["created_at"],
                        vector: row["embedding"]
                    )
                }
            }

        var vectors: [String: [Float]] = [:]
        for row in rows {
            if let data: Data = row.vector { vectors[row.id] = RetrievalEngine.decode(data) }
        }
        let missing = rows.filter { vectors[$0.id] == nil }
        if let embedder, !missing.isEmpty,
           let embedded = try? await embedder.embed(missing.map(\.text)),
           embedded.count == missing.count {
            try? await userQueue.write { db in
                for (row, vector) in zip(missing, embedded) {
                    try db.execute(
                        sql: """
                            INSERT INTO memory_vectors(memory_id, model, embedding) VALUES (?, ?, ?)
                            ON CONFLICT(memory_id, model) DO UPDATE SET embedding = excluded.embedding
                            """,
                        arguments: [row.id, model, RetrievalEngine.encode(vector)]
                    )
                }
            }
            for (row, vector) in zip(missing, embedded) { vectors[row.id] = vector }
        }

        return rows
            .compactMap { row in
                guard let vector = vectors[row.id] else { return nil }
                return MemoryCandidate(
                    id: row.id,
                    text: row.text,
                    sourceCharacterID: row.source,
                    createdAt: row.createdAt,
                    similarity: RetrievalEngine.cosine(queryVector, vector)
                )
            }
            .sorted { $0.similarity > $1.similarity }
            .prefix(limit)
            .map { $0 }
    }

    func memoriesPrompt(
        _ memories: [MemoryCandidate],
        characterID: String,
        timeZone: TimeZone,
        opening: String = memoriesOpening
    ) async throws -> String {
        try await memoriesPrompt(
            memories.map(\.record),
            characterID: characterID,
            timeZone: timeZone,
            opening: opening
        )
    }

    static let memoriesOpening = "下面是制作人以前说过的、和这句话可能有关的事，按相关程度排列，"
        + "和话题无关的可以忽略。像平时记得这些事一样自然地提起，不要逐条复述。"

    func memoriesPrompt(
        _ memories: [MemoryRecord],
        characterID: String,
        timeZone: TimeZone,
        opening: String
    ) async throws -> String {
        let names = Dictionary(uniqueKeysWithValues: try characters().map { ($0.id, $0.name) })
        var lines = ["# 关于制作人的记忆", opening]
        for memory in memories {
            let when = Self.day(memory.createdAt, in: timeZone)
            if memory.sourceCharacterID == characterID {
                lines.append("- \(memory.text)（\(when)，制作人对你说的）")
            } else {
                let name = memory.sourceCharacterID.flatMap { names[$0] } ?? "别的偶像"
                lines.append("- \(memory.text)（\(when)，制作人对\(name)说的，你是听\(name)说的："
                    + "提起时要用转述的口吻，例如「听\(name)说……」，不要说成是制作人亲口告诉你的）")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func day(_ stamp: String, in timeZone: TimeZone) -> String {
        guard let date = Eidolon.parseTimestamp(stamp) else { return stamp }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }
}

extension ContentDatabase {
    func passages(characterID: String) throws -> [(episodeID: String, text: String, embedding: Data)] {
        try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT p.episode_id, p.text, p.embedding
                    FROM episode_passages p
                    JOIN episode_cast c ON c.episode_id = p.episode_id
                    WHERE c.character_id = ?
                    """,
                arguments: [characterID]
            ).map { row in
                (episodeID: row["episode_id"], text: row["text"], embedding: row["embedding"])
            }
        }
    }

    func episode(id: String) throws -> (category: String, source: String, title: String)? {
        try queue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT category, source, title FROM episodes WHERE id = ?",
                arguments: [id]
            ) else { return nil }
            return (row["category"], row["source"], row["title"])
        }
    }

    func episodeTitles(sourcesLike source: String) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT title FROM episodes WHERE source = ? ORDER BY id",
                arguments: [source]
            )
        }
    }

    func transcript(episodeID: String, limit: Int) throws -> String {
        let lines = try queue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT speaker, ja, zh FROM episode_lines
                    WHERE episode_id = ? ORDER BY seq
                    """,
                arguments: [episodeID]
            )
        }
        var text = ""
        for line in lines {
            let speaker: String? = line["speaker"]
            let ja: String = line["ja"]
            let zh: String? = line["zh"]
            var said = speaker.map { "\($0)：\(ja)" } ?? ja
            if let zh, !zh.isEmpty { said += "（\(zh)）" }
            if text.count + said.count > limit {
                return (text.isEmpty ? String(said.prefix(limit)) : text) + "……（后略）"
            }
            text += said + "\n"
        }
        return text.trimmingCharacters(in: .newlines)
    }
}
