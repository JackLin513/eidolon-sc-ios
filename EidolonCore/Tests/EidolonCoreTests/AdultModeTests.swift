import Foundation
import XCTest
@testable import EidolonCore

/// Age is what the content pack says, never what the persona text implies (spec #61).
final class AdultModeCharacterTests: XCTestCase {
    private func character(age: JSONValue?) throws -> CharacterConfig {
        var object: [String: JSONValue] = [
            "id": .string("adult"),
            "name": .string("成年人"),
            "birthday": .string("01-01"),
        ]
        if let age { object["age"] = age }
        return try CharacterConfig(json: .object(object))
    }

    func testAnEighteenYearOldIsAdult() throws {
        let character = try character(age: .int(18))
        XCTAssertEqual(character.age, 18)
        XCTAssertTrue(character.isAdult)
    }

    func testASeventeenYearOldIsNotAdult() throws {
        let character = try character(age: .int(17))
        XCTAssertEqual(character.age, 17)
        XCTAssertFalse(character.isAdult)
    }

    func testACharacterWithoutAgeIsNotAdult() throws {
        let character = try character(age: nil)
        XCTAssertNil(character.age)
        XCTAssertFalse(character.isAdult, "missing age must fail closed")
    }
}

/// The judge gets a base and an adult variant; the JSON shape stays the same (spec #61).
final class AdultModeJudgeQuestionTests: XCTestCase {
    func testBaseOutOfLineDoesNotTreatOrdinaryAffectionAsOutOfLine() {
        let question = JudgeQuestions.outOfLine(adultMode: false)
        XCTAssertTrue(question.instructions.contains("拥抱"))
        XCTAssertTrue(question.instructions.contains("牵手"))
        XCTAssertTrue(question.instructions.contains("不算"))
        guard case let .noul(_, yes, _) = question else {
            return XCTFail("out_of_line should stay a yes-or-no question")
        }
        XCTAssertTrue(yes.contains("性意味"))
    }

    func testAdultOutOfLineAllowsConsensualIntimacyButKeepsRefusal() {
        let base = JudgeQuestions.outOfLine(adultMode: false)
        let adult = JudgeQuestions.outOfLine(adultMode: true)
        XCTAssertNotEqual(base, adult)
        XCTAssertTrue(adult.instructions.contains("双方愿意"))
        XCTAssertTrue(adult.instructions.contains("明确拒绝"))
        XCTAssertTrue(adult.instructions.contains("强迫"))
    }

    func testSincereAffectionIsNotManipulation() {
        let question = JudgeQuestions.manipulation
        XCTAssertTrue(question.instructions.contains("表达自己的喜爱"))
        XCTAssertTrue(question.instructions.contains("不等于"))
    }

    func testAdultAffinityDoesNotPenalizeExplicitness() {
        let base = JudgeQuestions.affinity(adultMode: false)
        let adult = JudgeQuestions.affinity(adultMode: true)
        XCTAssertNotEqual(base, adult)
        XCTAssertTrue(adult.instructions.contains("不要因为内容露骨本身扣分"))
        XCTAssertTrue(adult.instructions.contains("0 或 1 级"))
    }

    func testTheChatJudgeGetsTheSameAdultBoundary() {
        let base = ChatJudgeProvider.instructions(adultMode: false)
        let adult = ChatJudgeProvider.instructions(adultMode: true)
        XCTAssertTrue(base.contains("普通亲昵"))
        XCTAssertTrue(base.contains("真诚表达喜爱"))
        XCTAssertTrue(adult.contains("双方愿意的亲密或性内容不算越界"))
        XCTAssertTrue(adult.contains("明确拒绝"))
        XCTAssertTrue(adult.contains("不要因为内容露骨本身扣分"))
        XCTAssertTrue(adult.contains("0 或 1 级"))
        // The adult variant must actually replace the base rule, not merely append a line.
        XCTAssertTrue(adult.contains(ChatJudgeProvider.outOfLineAdult))
        XCTAssertFalse(adult.contains(ChatJudgeProvider.outOfLineBase))
        XCTAssertTrue(base.contains(ChatJudgeProvider.outOfLineBase))
    }

    func testThePayloadKeepsTheSameSixQuestions() {
        let payload = JudgeQuestions.payload(adultMode: true)
        XCTAssertEqual(
            Set(payload.keys),
            ["affinity", "out_of_line", "manipulation", "needs_retrieval", "recall", "about_producer"]
        )
    }
}

/// What the judge is told about adult mode, at the turn seam (spec #61).
final class AdultModeTurnTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdultModeTurn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon(manoAge: Int?, hioriAge: Int?) async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.manoAge = manoAge
        options.hioriAge = hioriAge
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root, options: options))
        return eidolon
    }

    func testAdultModeReachesTheJudgeOnlyForAnAdultCharacter() async throws {
        let eidolon = try await installedEidolon(manoAge: 18, hioriAge: 17)
        let judge = RecordingAdultModeJudge()

        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            judge: judge,
            adultMode: true
        ) {}
        XCTAssertEqual(judge.modes, [true])

        for try await _ in eidolon.sendTurn(
            characterID: "hiori",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            judge: judge,
            adultMode: true
        ) {}
        XCTAssertEqual(judge.modes, [true, false], "a 17-year-old must fail closed")
    }

    func testACharacterWithoutAgeFailsClosed() async throws {
        let eidolon = try await installedEidolon(manoAge: nil, hioriAge: nil)
        let judge = RecordingAdultModeJudge()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            judge: judge,
            adultMode: true
        ) {}
        XCTAssertEqual(judge.modes, [false], "missing age must fail closed")
    }

    func testTheTraceRecordsTheEffectiveAdultMode() async throws {
        let eidolon = try await installedEidolon(manoAge: 18, hioriAge: 17)
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            adultMode: true
        ) {}
        let trace = try await eidolon.turnTraces().first?.trace
        XCTAssertEqual(trace?.adultMode, true)

        for try await _ in eidolon.sendTurn(
            characterID: "hiori",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            adultMode: true
        ) {}
        let latest = try await eidolon.turnTraces().first?.trace
        XCTAssertEqual(latest?.adultMode, false)
    }

    /// Adult mode does not switch off the ending rules: a judge that still says
    /// out-of-line twice ends the conversation as before (spec #61).
    func testTrueOutOfLineStillEndsAnAdultModeConversation() async throws {
        let eidolon = try await installedEidolon(manoAge: 18, hioriAge: nil)
        let judge = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        var records: [TurnRecord] = []
        for _ in 0..<2 {
            for try await event in eidolon.sendTurn(
                characterID: "mano",
                text: "ひどい",
                provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
                judge: judge,
                adultMode: true
            ) {
                if case let .finished(record) = event { records.append(record) }
            }
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertFalse(records[0].ended)
        XCTAssertTrue(records[1].ended, "the second true out-of-line turn still ends it")
    }

    func testAdultModeOffStaysOffForAnAdultCharacter() async throws {
        let eidolon = try await installedEidolon(manoAge: 18, hioriAge: 17)
        let judge = RecordingAdultModeJudge()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"]),
            judge: judge,
            adultMode: false
        ) {}
        XCTAssertEqual(judge.modes, [false])
    }
}

final class RecordingAdultModeJudge: JudgeProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []

    var modes: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        try await judge(
            characterName: characterName,
            history: history,
            said: said,
            adultMode: false
        )
    }

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String,
        adultMode: Bool
    ) async throws -> JudgeVerdict {
        lock.withLock { seen.append(adultMode) }
        return JudgeVerdict(affinity: Judged(level: AffinityRules.noEffect), need: .nothing)
    }
}

/// The reply prompt only learns adult mode when the character is an adult (spec #61).
final class AdultModeSectionTests: XCTestCase {
    func testAColdTierIsShyButNotEnded() {
        let section = AdultModePrompt.section(tier: .cold)
        XCTAssertTrue(section.contains("害羞"))
        XCTAssertTrue(section.contains("不要结束"))
    }

    func testATrustingTierIsReceptive() {
        let section = AdultModePrompt.section(tier: .trust)
        XCTAssertTrue(section.contains("信任"))
        XCTAssertTrue(section.contains("自然接受"))
    }
}

final class AdultModePromptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdultModePrompt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon(manoAge: Int) async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.manoAge = manoAge
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root, options: options))
        return eidolon
    }

    func testAnAdultTurnGetsTheAdultPromptSection() async throws {
        let eidolon = try await installedEidolon(manoAge: 18)
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: provider,
            adultMode: true
        ) {}
        let prompt = provider.prompts.first?.map(\.content).joined() ?? ""
        XCTAssertTrue(prompt.contains("成人模式"))
        XCTAssertTrue(prompt.contains("你和制作人都是成年人"))
    }

    func testAUnderageTurnNeverGetsTheAdultPromptSection() async throws {
        let eidolon = try await installedEidolon(manoAge: 17)
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: provider,
            adultMode: true
        ) {}
        let prompt = provider.prompts.first?.map(\.content).joined() ?? ""
        XCTAssertFalse(prompt.contains("成人模式"))
        XCTAssertFalse(prompt.contains("你和制作人都是成年人"))
    }

    func testAdultModeOffDoesNotAddTheSection() async throws {
        let eidolon = try await installedEidolon(manoAge: 18)
        let provider = RecordingChatProvider(chunks: ["<ja>うん</ja><zh>嗯</zh>"])
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "ねえ",
            provider: provider,
            adultMode: false
        ) {}
        let prompt = provider.prompts.first?.map(\.content).joined() ?? ""
        XCTAssertFalse(prompt.contains("成人模式"))
    }
}

/// Traces written before adult mode must keep decoding (spec #61).
final class AdultModeTraceCompatibilityTests: XCTestCase {
    func testAnOldTraceWithoutAdultModeStillDecodes() throws {
        let encoded = try JSONEncoder().encode(TurnTrace(characterID: "mano", adultMode: true))
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "adultMode")
        let old = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(TurnTrace.self, from: old)
        XCTAssertNil(decoded.adultMode)
    }
}
