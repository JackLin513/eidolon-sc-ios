import Foundation
import GRDB

/// Something about the producer worth keeping across conversations, written in Chinese,
/// with the character it was told to — its source character (upstream `memory.py`).
public struct MemoryRecord: Sendable, Hashable, Identifiable {
    public var id: String
    /// The character the producer said it to; all characters share the producer's memories.
    public var sourceCharacterID: String?
    public var text: String
    public var createdAt: String
    /// What replaced it, if anything: a superseded memory is kept and listed, but neither
    /// found nor recalled.
    public var supersededBy: String?

    public init(
        id: String,
        sourceCharacterID: String?,
        text: String,
        createdAt: String,
        supersededBy: String? = nil
    ) {
        self.id = id
        self.sourceCharacterID = sourceCharacterID
        self.text = text
        self.createdAt = createdAt
        self.supersededBy = supersededBy
    }

    public var holds: Bool { supersededBy == nil }
}

/// One memory the background model wrote down, and the memories it was shown that this
/// one supersedes (numbered from 1).
struct NewMemory: Sendable, Hashable {
    var text: String
    var supersedes: [Int]
}

/// What the background model is asked and how its answer is read (upstream `memory.py`).
enum MemoryExtraction {
    static let shownMemories = 20
    static let exchangeHistory = 4
    static let maxNewMemories = 5
    static let maxLength = 200

    static let instructions = """
        你负责替《偶像大师 闪耀色彩》283 事务所的偶像们（还有事务员）记住关于制作人的事。制作人就是正在和她们对话的用户。
        读下面的对话，从制作人最新的一句话里找出值得长期记住的、关于制作人本人的信息。

        只记过后仍有意义的事。
        要记的：制作人自己透露的个人情况、喜好、经历、计划、身边的人和宠物、希望偶像记住的事；会持续几天、朋友过后会问起的近况，例如生病、考试、面试、搬家、出差。
        不要记的：当天就会过去的状态（例如累、困、饿、无聊、心情不好）和一时的情绪，同一句话里还说了值得记的事时只记那件事、不记这种状态；寒暄；偶像说的话；原作剧情和偶像的设定；制作人向偶像提的问题。

        每条记忆是一句能单独看懂的中文陈述，以「制作人」开头，例如「制作人养了一只叫小白的猫」。提到「明天」「下周六」这样的相对时间时，换算成具体日期写下来。

        「已经记住的事」按编号列出了和这轮对话最相关的记忆，写之前先对照：
        - 和已经记住的一样的，不要再写。
        - 更新或修正了已经记住的事（例如搬了家、换了工作），写一条单独看也完整的新记忆，写清从什么变成了什么，例如「制作人从大阪搬到了东京」，并在 supersedes 里写上被它取代的记忆的编号，可以写多个。
        - 补充了已经记住的事的细节（例如说出了猫的名字），写一条把细节合进去的完整记忆，取代原来那条。
        - 一件事只变了一部分的，新记忆要把仍然成立的部分也写进去，例如原来记着养了一只猫和一只狗、现在狗去世了，就写「制作人的狗去世了，现在还养着那只猫」，取代原来那条。
        - 两件事可以同时成立的（例如喜欢喝咖啡，最近也开始喝茶），新的照常写，不取代旧的。

        只输出 JSON，格式为 {"memories": [{"text": "……", "supersedes": [编号]}]}，不取代任何记忆时 supersedes 写 []；没有值得记住的就输出 {"memories": []}。
        """

    /// The exchange as the model reads it: today, what is already remembered, the last
    /// messages, then the line being judged and her answer to it.
    static func prompt(
        characterName: String,
        history: [StoredMessage],
        text: String,
        reply: String,
        shown: [MemoryRecord],
        now: Date,
        timeZone: TimeZone
    ) -> [PromptMessage] {
        var lines = ["今天是 \(date(now, in: timeZone))（制作人所在时区）。", "", "# 已经记住的事"]
        if shown.isEmpty {
            lines.append("（还没有）")
        } else {
            for (index, memory) in shown.enumerated() {
                lines.append("\(index + 1). \(memory.text)")
            }
        }
        lines += ["", "# 制作人和\(characterName)的对话"]
        for message in history.suffix(exchangeHistory) {
            if message.role == "user" {
                lines.append("制作人：\(message.text ?? "")")
            } else {
                lines.append("\(characterName)：\(shownText(message))")
            }
        }
        lines.append("制作人（最新的一句话）：\(text)")
        lines.append("\(characterName)：\(reply)")
        return [
            PromptMessage(.system, instructions),
            PromptMessage(.user, lines.joined(separator: "\n")),
        ]
    }

    /// Her words as people see them: Chinese when the reply has it, Japanese otherwise,
    /// neither with delivery cues (upstream `Message.without_cues`).
    static func shownText(_ message: StoredMessage) -> String {
        let zh = ReplyCues.shown(message.segments.map(\.zh).joined())
        if !zh.isEmpty { return zh }
        return ReplyCues.shown(message.segments.map(\.ja).joined())
    }

    static func date(_ moment: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: moment)
        return "\(parts.year ?? 0)年\(parts.month ?? 0)月\(parts.day ?? 0)日"
    }

    /// The memories in the model's answer; `nil` when it is not the JSON asked for. One
    /// written as text alone supersedes nothing; superseded numbers must be whole ones.
    static func parse(_ answer: String) -> [NewMemory]? {
        guard let start = answer.firstIndex(of: "{"),
              let end = answer.lastIndex(of: "}"),
              start < end,
              let data = String(answer[start...end]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let memories = object["memories"] as? [Any]
        else { return nil }

        var written: [String: NewMemory] = [:]
        var order: [String] = []
        for memory in memories {
            let text: String?
            let numbers: [Int]
            if let object = memory as? [String: Any] {
                text = object["text"] as? String
                numbers = (object["supersedes"] as? [Any])?.compactMap { $0 as? Int } ?? []
            } else {
                text = memory as? String
                numbers = []
            }
            guard let text else { continue }
            let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
            guard !trimmed.isEmpty else { continue }
            if written[trimmed] == nil {
                var seen: [Int] = []
                for number in numbers where !seen.contains(number) { seen.append(number) }
                written[trimmed] = NewMemory(text: trimmed, supersedes: seen)
                order.append(trimmed)
            }
        }
        return order.prefix(maxNewMemories).compactMap { written[$0] }
    }
}

// MARK: - Keeping them

extension Eidolon {
    /// Every memory, oldest first, superseded ones included: what the producer has told
    /// her idols, and what has since been replaced.
    public func memories() throws -> [MemoryRecord] {
        try userQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT id, source_character_id, text, created_at, superseded_by
                    FROM memories ORDER BY created_at ASC, rowid ASC
                    """
            ).map { row in
                MemoryRecord(
                    id: row["id"],
                    sourceCharacterID: row["source_character_id"],
                    text: row["text"],
                    createdAt: row["created_at"],
                    supersededBy: row["superseded_by"]
                )
            }
        }
    }

    /// Forgets one of the producer's memories, and the vector that would find it; false
    /// when there is no such memory (upstream `Memory.delete`).
    @discardableResult
    public func deleteMemory(id: String) async throws -> Bool {
        // What earlier turns are still writing down is written before this, as upstream
        // settles first, so it cannot bring the memory back afterwards.
        await settleMemories()
        return try await userQueue.write { db in
            try db.execute(
                sql: "DELETE FROM memory_vectors WHERE memory_id = ?",
                arguments: [id]
            )
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }

    /// Forgets everything, including what turns so far are still writing down (upstream
    /// `Memory.clear`): what was queued but not written is dropped with them.
    public func clearMemories() async throws {
        await settleMemories()
        try await userQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_vectors")
            try db.execute(sql: "DELETE FROM memories")
            try db.execute(sql: "DELETE FROM pending_jobs WHERE kind = 'memory'")
        }
    }

    /// The producer's still-holding memories nearest the turn, for the background model to
    /// check before writing; their latest when nothing can be embedded.
    func memoriesForWriting(query: String, embedder: (any EmbeddingProvider)?) async -> [MemoryRecord] {
        if let embedder, let vector = try? await embedder.embedQuery(query),
           let nearest = try? await memoryCandidates(
               queryVector: vector,
               limit: MemoryExtraction.shownMemories,
               embedder: embedder
           ), !nearest.isEmpty {
            return nearest.map { $0.record }
        }
        return ((try? memories()) ?? []).filter(\.holds).suffix(MemoryExtraction.shownMemories)
    }

    /// Queues a turn's memories before anything is written, so that a write cut short by
    /// the app being closed is run again at the next launch.
    @discardableResult
    func enqueueMemoryJob(
        conversationID: String,
        userMessageID: String,
        now: Date
    ) throws -> Int64 {
        try userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_jobs(kind, conversation_id, message_id, created_at)
                    VALUES ('memory', ?, ?, ?)
                    """,
                arguments: [conversationID, userMessageID, Self.timestamp(now)]
            )
            return db.lastInsertedRowID
        }
    }

    /// Runs the job after the turn has been shown, in a task of its own.
    func scheduleMemoryJob(_ jobID: Int64, provider: any ChatProvider, embedder: (any EmbeddingProvider)?) {
        let task = Task {
            await self.runMemoryJob(jobID, provider: provider, embedder: embedder)
        }
        memoryJobs[jobID] = task
    }

    /// Waits a while for what earlier turns are still writing down, so the next turn can
    /// remember what the producer just said (upstream `SETTLE_TIMEOUT`).
    func settleMemories(timeout: Duration = .seconds(5)) async {
        let tasks = Array(memoryJobs.values)
        guard !tasks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for task in tasks { await task.value }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// Runs whatever writing down was cut short last time, in order.
    public func resumePendingMemories(
        provider: any ChatProvider,
        embedder: (any EmbeddingProvider)?
    ) async {
        let jobs: [Int64] = (try? await userQueue.read { db in
            try Int64.fetchAll(
                db,
                sql: "SELECT id FROM pending_jobs WHERE kind = 'memory' ORDER BY id"
            )
        }) ?? []
        for job in jobs {
            await runMemoryJob(job, provider: provider, embedder: embedder)
        }
    }

    func runMemoryJob(_ jobID: Int64, provider: any ChatProvider, embedder: (any EmbeddingProvider)?) async {
        defer { memoryJobs[jobID] = nil }
        guard let job = try? await userQueue.read({ db -> (conversation: String, message: String, attempts: Int)? in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT conversation_id, message_id, attempts FROM pending_jobs
                    WHERE id = ? AND kind = 'memory'
                    """,
                arguments: [jobID]
            ) else { return nil }
            return (row["conversation_id"], row["message_id"], row["attempts"])
        }) else { return }

        do {
            let conversationID = job.conversation
            let userMessageID = job.message
            guard let exchange = try exchange(
                conversationID: conversationID,
                userMessageID: userMessageID
            ) else {
                try await dropMemoryJob(jobID)
                return
            }
            let name = (try? characters().first { $0.id == exchange.characterID })?.name
                ?? exchange.characterID
            let query = RetrievalEngine.query(history: exchange.history, text: exchange.text)
            let shown = await memoriesForWriting(query: query, embedder: embedder)
            let prompt = MemoryExtraction.prompt(
                characterName: name,
                history: exchange.history,
                text: exchange.text,
                reply: exchange.reply,
                shown: shown,
                now: exchange.now,
                timeZone: exchange.timeZone
            )
            var answer = ""
            for try await chunk in provider.stream(messages: prompt) {
                answer += chunk
            }
            guard let written = MemoryExtraction.parse(answer) else {
                throw MemoryError.unreadableAnswer
            }
            let added = try addMemories(
                conversationID: conversationID,
                characterID: exchange.characterID,
                written: written,
                shown: shown,
                now: exchange.now
            )
            await embedMemories(added, embedder: embedder)
            try await dropMemoryJob(jobID)
        } catch {
            // Left for the next launch; a model that keeps failing is not retried forever.
            try? await userQueue.write { db in
                try db.execute(
                    sql: "UPDATE pending_jobs SET attempts = ? WHERE id = ?",
                    arguments: [job.attempts + 1, jobID]
                )
                try db.execute(
                    sql: "DELETE FROM pending_jobs WHERE id = ? AND attempts >= 3",
                    arguments: [jobID]
                )
            }
        }
    }

    private func dropMemoryJob(_ jobID: Int64) async throws {
        try await userQueue.write { db in
            try db.execute(sql: "DELETE FROM pending_jobs WHERE id = ?", arguments: [jobID])
        }
    }

    private struct Exchange {
        var characterID: String
        var history: [StoredMessage]
        var text: String
        var reply: String
        var now: Date
        var timeZone: TimeZone
    }

    /// The exchange a job is about: the conversation, where the user message sits, and the
    /// messages before it.
    private func exchange(conversationID: String, userMessageID: String) throws -> Exchange? {
        let timeZone = try producerProfile().timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return try userQueue.read { db -> Exchange? in
            guard let characterID = try String.fetchOne(
                db,
                sql: "SELECT character_id FROM conversations WHERE id = ?",
                arguments: [conversationID]
            ) else { return nil }
            let messages = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, role, text, segments, created_at FROM messages
                    WHERE conversation_id = ? ORDER BY created_at ASC, rowid ASC
                    """,
                arguments: [conversationID]
            ).map(StoredMessage.init(row:))
            guard let index = messages.firstIndex(where: { $0.id == userMessageID }) else {
                return nil
            }
            let reply = messages[(index + 1)...].first { $0.role == "character" }
            let text = messages[index].text ?? ""
            return Exchange(
                characterID: characterID,
                history: Array(messages[..<index]),
                text: text,
                reply: reply.map(MemoryExtraction.shownText) ?? "",
                now: Eidolon.parseTimestamp(messages[index].createdAt) ?? Date(),
                timeZone: timeZone
            )
        }
    }

    /// Writes down what the producer said, in one transaction: a memory already kept is
    /// left alone (or holds again if it was superseded), and each new memory supersedes
    /// the memories it names among those shown.
    private func addMemories(
        conversationID: String,
        characterID: String,
        written: [NewMemory],
        shown: [MemoryRecord],
        now: Date
    ) throws -> [MemoryRecord] {
        try userQueue.write { db in
            let stamp = Self.timestamp(now)
            var added: [MemoryRecord] = []
            for memory in written {
                let kept = try Row.fetchOne(
                    db,
                    sql: "SELECT id, superseded_by FROM memories WHERE text = ?",
                    arguments: [memory.text]
                )
                let id: String
                if let kept {
                    id = kept["id"]
                    if kept["superseded_by"] as String? == nil { continue }
                    try db.execute(
                        sql: "UPDATE memories SET superseded_by = NULL WHERE id = ?",
                        arguments: [id]
                    )
                } else {
                    id = UUID().uuidString
                    try db.execute(
                        sql: """
                            INSERT INTO memories(id, source_character_id, conversation_id, text, created_at)
                            VALUES (?, ?, (SELECT id FROM conversations WHERE id = ?), ?, ?)
                            """,
                        arguments: [id, characterID, conversationID, memory.text, stamp]
                    )
                    added.append(MemoryRecord(
                        id: id,
                        sourceCharacterID: characterID,
                        text: memory.text,
                        createdAt: stamp
                    ))
                }
                for number in memory.supersedes where number >= 1 && number <= shown.count {
                    let target = shown[number - 1]
                    guard target.id != id else { continue }
                    try db.execute(
                        sql: """
                            UPDATE memories SET superseded_by = ? WHERE id = ? AND superseded_by IS NULL
                            """,
                        arguments: [id, target.id]
                    )
                }
            }
            return added
        }
    }

    /// Embeds what was just written down, so the next turn can find it. A memory left
    /// unembedded is embedded the next time memories are searched.
    private func embedMemories(_ memories: [MemoryRecord], embedder: (any EmbeddingProvider)?) async {
        guard let embedder, !memories.isEmpty else { return }
        let model = embedder.model
        guard let vectors = try? await embedder.embed(memories.map(\.text)) else { return }
        guard vectors.count == memories.count else { return }
        try? await userQueue.write { db in
            for (memory, vector) in zip(memories, vectors) {
                try db.execute(
                    sql: """
                        INSERT INTO memory_vectors(memory_id, model, embedding) VALUES (?, ?, ?)
                        ON CONFLICT(memory_id, model) DO UPDATE SET embedding = excluded.embedding
                        """,
                    arguments: [memory.id, model, RetrievalEngine.encode(vector)]
                )
            }
        }
    }
}

enum MemoryError: Error {
    case unreadableAnswer
}

extension MemoryCandidate {
    var record: MemoryRecord {
        MemoryRecord(
            id: id,
            sourceCharacterID: sourceCharacterID,
            text: text,
            createdAt: createdAt
        )
    }
}
