import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// A provider that answers turns with `chat` and extraction prompts with `memory`.
final class MemoryChatProvider: ChatProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[PromptMessage]] = []

    let chat: String
    /// What the background model answers; never the JSON asked for when nil.
    let memory: String?

    init(chat: String = "<ja>うん</ja><zh>嗯</zh>", memory: String?) {
        self.chat = chat
        self.memory = memory
    }

    var prompts: [[PromptMessage]] { recorded }

    var extractionPrompts: [[PromptMessage]] {
        recorded.filter { prompt in
            prompt.contains { $0.role == .system && $0.content.contains("你负责替") }
        }
    }

    func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
        lock.lock()
        recorded.append(messages)
        lock.unlock()
        let extraction = messages.contains {
            $0.role == .system && $0.content.contains("你负责替")
        }
        let text = extraction ? memory : chat
        return AsyncThrowingStream { continuation in
            guard let text else {
                continuation.finish(throwing: ChatProviderError.invalidResponse("boom"))
                return
            }
            continuation.yield(text)
            continuation.finish()
        }
    }
}

final class MemoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonMemory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    private func send(
        _ text: String,
        to characterID: String = "mano",
        provider: any ChatProvider,
        on eidolon: Eidolon,
        judge: (any JudgeProvider)? = nil
    ) async throws {
        for try await _ in eidolon.sendTurn(
            characterID: characterID,
            text: text,
            provider: provider,
            judge: judge,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}
        await eidolon.settleMemories()
    }

    private func pendingJobs(_ eidolon: Eidolon) async throws -> Int {
        try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_jobs") ?? 0
        }
    }

    func testParseReadsTheContract() {
        XCTAssertEqual(
            MemoryExtraction.parse(#"{"memories": [{"text": "制作人养了一只猫", "supersedes": []}]}"#),
            [NewMemory(text: "制作人养了一只猫", supersedes: [])]
        )
        XCTAssertEqual(
            MemoryExtraction.parse(#"{"memories": ["制作人喜欢咖啡"]}"#),
            [NewMemory(text: "制作人喜欢咖啡", supersedes: [])]
        )
        XCTAssertEqual(
            MemoryExtraction.parse(
                #"""
                ```json
                {"memories": [{"text": "制作人从大阪搬到了东京", "supersedes": [1, 1, 2]}]}
                ```
                """#
            ),
            [NewMemory(text: "制作人从大阪搬到了东京", supersedes: [1, 2])]
        )
        XCTAssertEqual(MemoryExtraction.parse(#"{"memories": []}"#), [])
        XCTAssertNil(MemoryExtraction.parse("抱歉，我不知道"))
        XCTAssertEqual(
            MemoryExtraction.parse(
                #"{"memories": [{"text": "制作人喜欢咖啡"}, {"text": "制作人喜欢咖啡"}, {"text": " "}]}"#
            ),
            [NewMemory(text: "制作人喜欢咖啡", supersedes: [])]
        )
    }

    func testATurnWritesDownWhatHeSaidAndEmbedsIt() async throws {
        let eidolon = try await installedEidolon()
        let provider = MemoryChatProvider(
            memory: #"{"memories": [{"text": "制作人养了一只叫小白的猫", "supersedes": []}]}"#
        )

        try await send("実は猫を飼ってるんだ", provider: provider, on: eidolon)

        let memories = try await eidolon.memories()
        let memory = try XCTUnwrap(memories.first)
        XCTAssertEqual(memory.text, "制作人养了一只叫小白的猫")
        XCTAssertEqual(memory.sourceCharacterID, "mano")
        XCTAssertTrue(memory.holds)

        let prompt = try XCTUnwrap(provider.extractionPrompts.first)
        XCTAssertEqual(prompt.first?.role, .system)
        let user = try XCTUnwrap(prompt.last)
        XCTAssertTrue(user.content.contains("# 已经记住的事"))
        XCTAssertTrue(user.content.contains("（还没有）"))
        XCTAssertTrue(user.content.contains("# 制作人和櫻木真乃的对话"))
        XCTAssertTrue(user.content.contains("制作人（最新的一句话）：実は猫を飼ってるんだ"))
        XCTAssertTrue(user.content.contains("櫻木真乃：嗯"))

        let pending = try await pendingJobs(eidolon)
        XCTAssertEqual(pending, 0)
        let vectors = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vectors") ?? 0
        }
        XCTAssertEqual(vectors, 1)
    }

    func testTheSameMemoryIsNotWrittenTwice() async throws {
        let eidolon = try await installedEidolon()
        let answer = #"{"memories": [{"text": "制作人养了一只叫小白的猫", "supersedes": []}]}"#
        try await send("猫を飼ってるんだ", provider: MemoryChatProvider(memory: answer), on: eidolon)
        try await send("猫の話、前にしたっけ", provider: MemoryChatProvider(memory: answer), on: eidolon)
        let kept = try await eidolon.memories().count
        XCTAssertEqual(kept, 1)
    }

    func testANewMemorySupersedesTheOldOneWhichIsKeptButNotFound() async throws {
        let eidolon = try await installedEidolon()
        try await send(
            "猫を飼ってるんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#),
            on: eidolon
        )
        try await send(
            "名前は小白っていうんだ",
            provider: MemoryChatProvider(
                memory: #"{"memories": [{"text": "制作人养了一只叫小白的猫", "supersedes": [1]}]}"#
            ),
            on: eidolon
        )

        let memories = try await eidolon.memories()
        XCTAssertEqual(memories.map(\.text), ["制作人养了一只猫", "制作人养了一只叫小白的猫"])
        XCTAssertEqual(memories[0].supersededBy, memories[1].id)
        XCTAssertTrue(memories[1].holds)

        let found = try await eidolon.memoryCandidates(
            queryVector: [1, 0, 0, 0],
            limit: 12,
            embedder: FakeEmbedding(vector: [1, 0, 0, 0])
        )
        XCTAssertEqual(found.map(\.text), ["制作人养了一只叫小白的猫"])
    }

    func testMemoriesAreSharedAcrossCharactersAsHearsay() async throws {
        let eidolon = try await installedEidolon()
        try await send(
            "猫を飼ってるんだ",
            provider: MemoryChatProvider(memory: #"{"memories": [{"text": "制作人养了一只猫"}]}"#),
            on: eidolon
        )

        let hiori = MemoryChatProvider(chat: "<ja>そうなんだ</ja><zh>这样啊</zh>", memory: nil)
        for try await _ in eidolon.sendTurn(
            characterID: "hiori",
            text: "猫は好き？",
            provider: hiori,
            judge: FixedJudge(judged: Judged(level: 2), need: .memories),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0]),
            reranker: FakeRerank(scores: [0.9])
        ) {}
        await eidolon.settleMemories()

        let prompt = hiori.prompts.first.map { $0.map(\.content).joined() } ?? ""
        XCTAssertTrue(prompt.contains("# 关于制作人的记忆"))
        XCTAssertTrue(prompt.contains("制作人对櫻木真乃说的"))
        XCTAssertTrue(prompt.contains("你是听櫻木真乃说的"))
    }

    func testAJobCutShortRunsAtTheNextLaunch() async throws {
        let eidolon = try await installedEidolon()
        // A turn with memory off leaves the conversation and its messages behind.
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "実は引っ越したんだ",
            provider: MemoryChatProvider(chat: "<ja>へえ</ja><zh>诶</zh>", memory: nil)
        ) {}
        let current = try await eidolon.currentConversation(characterID: "mano")
        let conversation = try XCTUnwrap(current)
        let user = try XCTUnwrap(conversation.messages.first { $0.role == "user" })
        let job = try await eidolon.enqueueMemoryJob(
            conversationID: conversation.id,
            userMessageID: user.id,
            now: Date()
        )
        let queued = try await pendingJobs(eidolon)
        XCTAssertEqual(queued, 1)

        await eidolon.resumePendingMemories(
            provider: MemoryChatProvider(
                memory: #"{"memories": [{"text": "制作人搬了家"}]}"#
            ),
            embedder: FakeEmbedding(vector: [1, 0, 0, 0])
        )

        let written = try await eidolon.memories().map(\.text)
        XCTAssertEqual(written, ["制作人搬了家"])
        let left = try await pendingJobs(eidolon)
        XCTAssertEqual(left, 0)
        _ = job
    }

    func testAJobThatKeepsFailingIsGivenUpOn() async throws {
        let eidolon = try await installedEidolon()
        try await send("あのね", provider: MemoryChatProvider(memory: "ごめんなさい"), on: eidolon)
        let queued = try await pendingJobs(eidolon)
        XCTAssertEqual(queued, 1)

        for _ in 0..<2 {
            await eidolon.resumePendingMemories(
                provider: MemoryChatProvider(memory: "ごめんなさい"),
                embedder: FakeEmbedding(vector: [1, 0, 0, 0])
            )
        }
        let left = try await pendingJobs(eidolon)
        XCTAssertEqual(left, 0)
        let memories = try await eidolon.memories()
        XCTAssertTrue(memories.isEmpty)
    }

    /// The producer can forget one memory, with the vector that would have found it; one
    /// already gone is not an error (upstream `Memory.delete`).
    func testAMemoryCanBeDeleted() async throws {
        let eidolon = try await installedEidolon()
        try await addMemory("a", "制作人养了一只猫", on: eidolon)
        try await addMemory("b", "制作人喜欢咖啡", on: eidolon)

        let deleted = try await eidolon.deleteMemory(id: "a")
        XCTAssertTrue(deleted)
        let kept = try await eidolon.memories()
        XCTAssertEqual(kept.map(\.text), ["制作人喜欢咖啡"])
        let vectors = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vectors") ?? 0
        }
        XCTAssertEqual(vectors, 1)

        let again = try await eidolon.deleteMemory(id: "a")
        XCTAssertFalse(again)
    }

    /// Clearing takes them all, including what earlier turns are still writing down
    /// (upstream `Memory.clear`).
    func testAllMemoriesCanBeCleared() async throws {
        let eidolon = try await installedEidolon()
        try await addMemory("a", "制作人养了一只猫", on: eidolon)
        try await addMemory("b", "制作人喜欢咖啡", on: eidolon)
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO pending_jobs(kind, conversation_id, message_id, created_at)
                    VALUES ('memory', NULL, NULL, '2026-10-27T12:00:00.000000Z')
                    """
            )
        }

        try await eidolon.clearMemories()

        let left = try await eidolon.memories()
        XCTAssertTrue(left.isEmpty)
        let vectors = try await eidolon.userQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_vectors") ?? 0
        }
        XCTAssertEqual(vectors, 0)
        let jobs = try await pendingJobs(eidolon)
        XCTAssertEqual(jobs, 0)
    }

    private func addMemory(_ id: String, _ text: String, on eidolon: Eidolon) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO memories(id, source_character_id, text, created_at)
                    VALUES (?, 'mano', ?, '2026-10-27T12:00:00.000000Z')
                    """,
                arguments: [id, text]
            )
            try db.execute(
                sql: """
                    INSERT INTO memory_vectors(memory_id, model, embedding) VALUES (?, 'test', ?)
                    """,
                arguments: [id, Data([0, 0, 0, 0])]
            )
        }
    }

    /// ADR-0004: the background model's instructions are upstream's, word for word.
    func testTheExtractionInstructionsAreUpstreamsWordForWord() {
        XCTAssertEqual(MemoryExtraction.instructions, """
            你负责替《偶像大师 闪耀色彩》283 事务所的偶像们（还有事务员）记住关于制作人的事。制作人就是正在和她们对话的用户。
            读下面的对话，从制作人最新的一句话里找出值得长期记住的、关于制作人本人的信息。

            只记过后仍有意义的事。
            要记的：制作人自己透露的个人情况、喜好、经历、计划、身边的人和宠物、希望偶像记住的事；会持续几天、朋友过后会问起的近况，例如生病、考试、面试、搬家、出差。
            不要记的：当天就会过去的状态（例如累、困、饿、无聊、心情不好）和一时的情绪，同一句话里还说了值得记的事时只记那件事、不记这种状态；寒暄；偶像说的话；原作剧情和偶像的设定；制作人向偶像提的问题。

            每条记忆是一句能单独看懂的中文陈述，以「制作人」开头，例如「制作人养了一只叫小白的猫」。
            提到「明天」「下周六」这样的相对时间时，换算成具体日期写下来。

            「已经记住的事」按编号列出了和这轮对话最相关的记忆，写之前先对照：
            - 和已经记住的一样的，不要再写。
            - 更新或修正了已经记住的事（例如搬了家、换了工作），写一条单独看也完整的新记忆，写清从什么变成了什么，例如「制作人从大阪搬到了东京」，并在 supersedes 里写上被它取代的记忆的编号，可以写多个。
            - 补充了已经记住的事的细节（例如说出了猫的名字），写一条把细节合进去的完整记忆，取代原来那条。
            - 一件事只变了一部分的，新记忆要把仍然成立的部分也写进去，例如原来记着养了一只猫和一只狗、现在狗去世了，就写「制作人的狗去世了，现在还养着那只猫」，取代原来那条。
            - 两件事可以同时成立的（例如喜欢喝咖啡，最近也开始喝茶），新的照常写，不取代旧的。

            只输出 JSON，格式为 {"memories": [{"text": "……", "supersedes": [编号]}]}，不取代任何记忆时 supersedes 写 []；没有值得记住的就输出 {"memories": []}。
            """)
    }

    /// A memory whose telling character is gone from the configuration is named as
    /// another idol of the office (upstream `ANOTHER_IDOL`).
    func testAMemoryToldToAnotherIdolIsNamedAsSuch() async throws {
        let eidolon = try await installedEidolon()
        let prompt = try await eidolon.memoriesPrompt(
            [MemoryRecord(
                id: "m1",
                sourceCharacterID: "removed",
                text: "制作人养了一只猫",
                createdAt: "2026-10-01T00:00:00Z"
            )],
            characterID: "mano",
            timeZone: TodayPrompt.tokyo,
            opening: Eidolon.memoriesOpening
        )
        XCTAssertTrue(prompt.contains("制作人对事务所的另一位偶像说的"))
        XCTAssertTrue(prompt.contains("听事务所的另一位偶像说的"))
    }
}
