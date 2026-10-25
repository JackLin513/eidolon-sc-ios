import Foundation
import GRDB
import XCTest
@testable import EidolonCore

struct FixedJudge: JudgeProvider {
    var judged: Judged
    var need: RetrievalNeed = .nothing

    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        JudgeVerdict(affinity: judged, need: need)
    }
}

struct FailingJudge: JudgeProvider {
    func judge(
        characterName: String,
        history: [PromptMessage],
        said: String
    ) async throws -> JudgeVerdict {
        throw ChatProviderError.status(500, "boom")
    }
}

final class AffinityTests: XCTestCase {
    func testTierBoundaries() {
        XCTAssertEqual(AffinityTier.of(0), .cold)
        XCTAssertEqual(AffinityTier.of(19.9), .cold)
        XCTAssertEqual(AffinityTier.of(20), .distant)
        XCTAssertEqual(AffinityTier.of(40), .trust)
        XCTAssertEqual(AffinityTier.of(64.9), .trust)
        XCTAssertEqual(AffinityTier.of(65), .close)
        XCTAssertEqual(AffinityTier.of(85), .intimate)
        XCTAssertEqual(AffinityTier.of(100), .intimate)
        XCTAssertEqual(AffinityTier.trust.title, "信任")
    }

    func testRecoveryIsTenADayUpToNormal() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let low = Affinity(value: 30, at: start)
        XCTAssertEqual(low.recovered(now: start.addingTimeInterval(86_400)).value, 40, accuracy: 0.001)
        XCTAssertEqual(low.recovered(now: start.addingTimeInterval(86_400 * 5)).value, 50, accuracy: 0.001)
        let high = Affinity(value: 70, at: start)
        XCTAssertEqual(high.recovered(now: start.addingTimeInterval(86_400 * 5)).value, 70, accuracy: 0.001)
    }

    func testCooldownBeginsAtTheLowestAndEndsAtTen() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cooled = Affinity(value: 6, at: start).stepped(-10)
        XCTAssertEqual(cooled.value, 0, accuracy: 0.001)
        XCTAssertTrue(cooled.cooling)
        let until = try XCTUnwrap(cooled.cooldownUntil)
        XCTAssertEqual(until.timeIntervalSince(start), 86_400, accuracy: 1)

        let recovered = cooled.recovered(now: start.addingTimeInterval(86_400))
        XCTAssertEqual(recovered.value, 10, accuracy: 0.001)
        XCTAssertFalse(recovered.cooling)
        XCTAssertNil(recovered.cooldownUntil)
    }

    func testJudgedSteps() {
        XCTAssertEqual(Judged(level: 0).step, -1.5)
        XCTAssertEqual(Judged(level: 1).step, -0.5)
        XCTAssertEqual(Judged(level: 2).step, 0)
        XCTAssertEqual(Judged(level: 3).step, 0.1)
        XCTAssertEqual(Judged(level: 4).step, 0.2)
        XCTAssertEqual(Judged(level: 4, outOfLine: true).step, -10)
        XCTAssertEqual(Judged(level: 4, manipulation: true).step, 0)
        // What she minds is counted apart from the step: out of line hurts most, then by
        // level (upstream LEVEL_HURTS).
        XCTAssertEqual(Judged(level: 0).hurt, 5)
        XCTAssertEqual(Judged(level: 1).hurt, 2)
        XCTAssertEqual(Judged(level: 2).hurt, 0)
        XCTAssertEqual(Judged(level: 3).hurt, 0)
        XCTAssertEqual(Judged(level: 4).hurt, 0)
        XCTAssertEqual(Judged(level: 4, outOfLine: true).hurt, 10)
        XCTAssertEqual(Judged(level: 0, outOfLine: true).hurt, 10)
        XCTAssertEqual(Judged(level: 4).feeling, "制作人刚才说的话让你很开心，觉得被在意。")
        XCTAssertNil(Judged(level: 2).feeling)
        XCTAssertEqual(Judged(level: 0, outOfLine: true).feeling, AffinityPrompt.outOfLineFeeling)
    }

    func testEndsAndWarns() {
        let outOfLine = Judged(level: 0, outOfLine: true)
        XCTAssertEqual(
            ends(judged: outOfLine, cools: false, outOfLineBefore: 1, hurtBefore: [0]),
            .outOfLine
        )
        XCTAssertNil(ends(judged: outOfLine, cools: false, outOfLineBefore: 0, hurtBefore: [0]))

        let hurts = [5.0, 5.0]
        XCTAssertEqual(
            ends(judged: Judged(level: 0), cools: false, outOfLineBefore: 0, hurtBefore: hurts),
            .fedUp
        )
        XCTAssertFalse(warns(judged: Judged(level: 0), cools: false, outOfLineBefore: 0, hurtBefore: hurts))
        XCTAssertTrue(warns(judged: Judged(level: 0), cools: false, outOfLineBefore: 0, hurtBefore: [5]))

        // Six upset turns (two each) reach the line; five do not.
        XCTAssertEqual(
            ends(
                judged: Judged(level: 1),
                cools: false,
                outOfLineBefore: 0,
                hurtBefore: Array(repeating: 2.0, count: 5)
            ),
            .fedUp
        )
        XCTAssertNil(ends(
            judged: Judged(level: 1),
            cools: false,
            outOfLineBefore: 0,
            hurtBefore: Array(repeating: 2.0, count: 4)
        ))
        XCTAssertEqual(
            ends(judged: Judged(level: 2), cools: true, outOfLineBefore: 0, hurtBefore: []),
            .cooldown
        )
    }

    func testTheDailyAllowanceIsCutAndRounded() {
        XCTAssertEqual(AffinityRules.limited(0.2, left: AffinityRules.gainsPerDay), 0.2)
        // What three good turns leave is a hair short of a fourth in floating point; it
        // still lets the last one in, to the ninth decimal.
        XCTAssertEqual(AffinityRules.limited(0.2, left: AffinityRules.gainsPerDay - 0.4), 0.2)
        XCTAssertEqual(AffinityRules.limited(0.2, left: 0.1), 0.1)
        XCTAssertEqual(AffinityRules.limited(0.2, left: 0), 0)
        XCTAssertEqual(AffinityRules.limited(0.2, left: -0.1), 0)
        // What she loses is never cut.
        XCTAssertEqual(AffinityRules.limited(-1.5, left: 0.6), -1.5)
    }

    func testAffinityLines() {
        let close = AffinityPrompt.lines(tier: .close, judged: Judged(level: 4))
        XCTAssertTrue(close.contains { $0.contains("比平时更近") })
        XCTAssertTrue(close.contains { $0.contains("轻轻带一句想念") })
        XCTAssertTrue(close.last?.contains("很开心") ?? false)

        let trust = AffinityPrompt.lines(tier: .trust, judged: nil)
        XCTAssertTrue(trust.isEmpty)

        let parting = AffinityPrompt.lines(tier: .trust, judged: nil, parting: .parts)
        XCTAssertEqual(parting, [AffinityPrompt.partings[.parts]!])

        let warning = AffinityPrompt.lines(tier: .trust, judged: nil, warning: .parts)
        XCTAssertEqual(warning, [AffinityPrompt.warnings[.parts]!])
    }

    func testJudgeParsesItsContract() throws {
        XCTAssertEqual(
            try ChatJudgeProvider.parse(
                #"{"level": 4, "out_of_line": false, "manipulation": false, "retrieval": "none"}"#
            ),
            JudgeVerdict(affinity: Judged(level: 4), need: .nothing)
        )
        XCTAssertEqual(
            try ChatJudgeProvider.parse(
                "```json\n{\"level\": 0, \"out_of_line\": true, \"retrieval\": \"recall\"}\n```"
            ),
            JudgeVerdict(affinity: Judged(level: 0, outOfLine: true), need: .recall)
        )
        XCTAssertEqual(
            try ChatJudgeProvider.parse(
                #"{"level": null, "manipulation": true, "retrieval": "memories"}"#
            ),
            JudgeVerdict(affinity: Judged(level: 2, manipulation: true), need: .memories)
        )
        XCTAssertThrowsError(try ChatJudgeProvider.parse(#"{"level": 9}"#))
        XCTAssertThrowsError(try ChatJudgeProvider.parse("ごめんなさい、判断できません"))
    }

    func testNowPromptCarriesTheAffinityLines() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let text = NowPrompt.text(
            now: now,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            talking: .typing,
            affinityLines: ["制作人刚才说的话让你有点开心。"],
            lastContact: nil,
            birthday: nil
        )
        XCTAssertTrue(text.hasPrefix("# 此刻"))
        XCTAssertTrue(text.contains("制作人正在用文字和你聊天"))
        XCTAssertTrue(text.hasSuffix("制作人刚才说的话让你有点开心。"))
    }
}

final class AffinityTurnTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonAffinity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let bundle = try Fixture.makeBundle(in: root)
        try await eidolon.install(bundleAt: bundle)
        return eidolon
    }

    private func affinity(of prompt: [PromptMessage]) -> String {
        prompt.filter { $0.role == .system }.map(\.content).joined(separator: "\n")
    }

    private func reply(_ text: String = "うん") -> RecordingChatProvider {
        RecordingChatProvider(chunks: ["<ja>\(text)</ja><zh>嗯</zh>"])
    }

    @discardableResult
    private func send(
        _ text: String,
        on eidolon: Eidolon,
        judge: (any JudgeProvider)? = nil,
        inCall: CallScope? = nil
    ) async throws -> TurnRecord {
        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: text,
            provider: reply(),
            judge: judge,
            talking: inCall == nil ? .typing : .inCall,
            inCall: inCall
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        return try XCTUnwrap(record)
    }

    func testTurnMovesAffinityAndTellsHerInTheNextPrompt() async throws {
        let eidolon = try await installedEidolon()
        let first = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "すごく素敵だね",
            provider: first,
            judge: FixedJudge(judged: Judged(level: 4))
        ) {}

        let status = try await eidolon.affinityStatus(characterID: "mano")
        XCTAssertEqual(status.tier, .trust)
        XCTAssertFalse(status.cooling)
        XCTAssertTrue(affinity(of: try XCTUnwrap(first.prompts.first)).contains("让你很开心"))

        let second = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "また話そう",
            provider: second
        ) {}
        XCTAssertTrue(affinity(of: try XCTUnwrap(second.prompts.first)).contains("# 此刻"))
    }

    /// In a call she says she will hang up; typing, she only says she does not want to go
    /// on. The call's turns keep their own count, so one turn with the hurts already there
    /// is enough to reach the warning.
    func testACallSaysSheWillHangUpWhileTypingDoesNot() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 0))

        let call = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "うるさい",
            provider: call,
            judge: judge,
            talking: .inCall,
            inCall: CallScope(outOfLine: 0, hurts: [4])
        ) {}
        let called = affinity(of: try XCTUnwrap(call.prompts.first))
        XCTAssertTrue(called.contains("你就要挂电话了"))
        XCTAssertFalse(called.contains("你就不想聊了"))

        _ = try await send("うるさい", on: eidolon, judge: judge)
        let typed = reply()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "うるさい",
            provider: typed,
            judge: judge
        ) {}
        let typing = affinity(of: try XCTUnwrap(typed.prompts.first))
        XCTAssertTrue(typing.contains("你就不想聊了"))
        XCTAssertFalse(typing.contains("你就要挂电话了"))
    }

    func testDayGainsAreCappedAtSixTenths() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 4))
        for _ in 0..<5 {
            try await send("ありがとう", on: eidolon, judge: judge)
        }
        let affinity = try await eidolon.readAffinity(characterID: "mano", now: Date())
        XCTAssertEqual(affinity.value, AffinityRules.normal + AffinityRules.gainsPerDay, accuracy: 0.001)
    }

    /// Five hurt each, twelve at the line: the third takes her there.
    func testThreeHurtingTurnsEndTheConversation() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 0))
        let first = try await send("ばか", on: eidolon, judge: judge)
        XCTAssertFalse(first.ended)
        let second = try await send("ばか", on: eidolon, judge: judge)
        XCTAssertFalse(second.ended)
        let third = try await send("ばか", on: eidolon, judge: judge)
        XCTAssertTrue(third.ended)
        XCTAssertEqual(third.hurt, 5)
    }

    /// Upstream's numbers put the end on the sixth upset turn: two each, twelve at the
    /// line, and its docstring says「upsetting her takes six」. #23's wording says eight,
    /// which those numbers never reach; upstream wins.
    func testUpsetTurnsReachTheEndLineOnTheSixth() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 1))
        for turn in 1...5 {
            let record = try await send("うるさい", on: eidolon, judge: judge)
            XCTAssertFalse(record.ended, "turn \(turn)")
        }
        let sixth = try await send("うるさい", on: eidolon, judge: judge)
        XCTAssertTrue(sixth.ended)
    }

    /// A call keeps its own count of what its turns came to, and the conversation keeps
    /// its own of its typed turns; neither counts the other's (upstream `InCall`).
    func testCallAndTypedTurnsCountApart() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 0, outOfLine: true))

        var scope = CallScope()
        let callOne = try await send("ひどい", on: eidolon, judge: judge, inCall: scope)
        XCTAssertNil(callOne.hangUp)
        XCTAssertFalse(callOne.ended)
        scope.outOfLine += callOne.outOfLine ? 1 : 0
        scope.hurts.append(callOne.hurt)

        // The conversation's first typed out-of-line turn: the call's does not count.
        let typedOne = try await send("ひどい", on: eidolon, judge: judge)
        XCTAssertNil(typedOne.hangUp)
        XCTAssertFalse(typedOne.ended)

        // The call's second reaches its own line: she would hang up, but this version
        // leaves the conversation open.
        let callTwo = try await send("ひどい", on: eidolon, judge: judge, inCall: scope)
        XCTAssertEqual(callTwo.hangUp, .outOfLine)
        XCTAssertFalse(callTwo.ended)
        let afterCall = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(afterCall?.ended, false)

        // The conversation's second typed out-of-line turn ends it; the call's two do not
        // count toward it.
        let typedTwo = try await send("ひどい", on: eidolon, judge: judge)
        XCTAssertTrue(typedTwo.ended)
        XCTAssertNil(typedTwo.hangUp)
    }

    /// A call's turn changes affinity and is kept as a message, but it has no hurt and no
    /// out-of-line mark for the typed turns to read (upstream writes NULL for both).
    func testACallTurnIsKeptWithoutHurtOrOutOfLineMark() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 0, outOfLine: true))
        let record = try await send("ひどい", on: eidolon, judge: judge, inCall: CallScope())
        XCTAssertEqual(record.hurt, 10)
        XCTAssertTrue(record.outOfLine)
        XCTAssertNil(record.hangUp)
        XCTAssertFalse(record.ended)

        let queue = try DatabaseQueue(
            path: root.appendingPathComponent("app/User/eidolon.sqlite").path
        )
        let row = try await queue.read { db -> (hurt: Int, outOfLine: Int, typed: Int)? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT hurt, out_of_line, typed FROM messages WHERE role = 'character'"
            ) else {
                return nil
            }
            return (row["hurt"], row["out_of_line"], row["typed"])
        }
        let stored = try XCTUnwrap(row)
        XCTAssertEqual(stored.hurt, 0)
        XCTAssertEqual(stored.outOfLine, 0)
        XCTAssertEqual(stored.typed, 0)
    }

    func testOutOfLineTwiceEndsTheConversation() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 0, outOfLine: true))

        var record: TurnRecord?
        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "ひどいことを言う",
            provider: reply(),
            judge: judge
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        XCTAssertEqual(record?.ended, false)
        let first = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertNotNil(first)

        for try await event in eidolon.sendTurn(
            characterID: "mano",
            text: "またひどいことを言う",
            provider: reply(),
            judge: judge
        ) {
            if case let .finished(finished) = event { record = finished }
        }
        XCTAssertEqual(record?.ended, true)
        // She ended it, but it stays the current conversation until a new one starts.
        let afterEnd = try await eidolon.currentConversation(characterID: "mano")
        XCTAssertEqual(afterEnd?.ended, true)
        let last = try await eidolon.lastConversation(characterID: "mano")
        XCTAssertEqual(last?.ended, true)
        XCTAssertEqual(last?.messages.count, 4)
    }

    func testCooldownRefusesTurnsWithAReason() async throws {
        let eidolon = try await installedEidolon()
        let userDatabase = root.appendingPathComponent("app/User/eidolon.sqlite")
        let queue = try DatabaseQueue(path: userDatabase.path)
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO affinities(character_id, value, cooling, updated_at, gained_today, gained_on)
                    VALUES ('mano', 0, 1, ?, 0, NULL)
                    """,
                arguments: [ISO8601DateFormatter().string(from: Date())]
            )
        }

        let status = try await eidolon.affinityStatus(characterID: "mano")
        XCTAssertTrue(status.cooling)

        do {
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "ねえ",
                provider: reply()
            ) {
                XCTFail("a cooling turn should be refused")
            }
            XCTFail("expected coolingDown")
        } catch let error as EidolonError {
            guard case .coolingDown = error else {
                return XCTFail("expected coolingDown, got \(error)")
            }
        }
    }

    func testFailingJudgeLeavesTheTurnAlone() async throws {
        let eidolon = try await installedEidolon()
        for try await _ in eidolon.sendTurn(
            characterID: "mano",
            text: "こんにちは",
            provider: reply(),
            judge: FailingJudge()
        ) {}
        let affinity = try await eidolon.readAffinity(characterID: "mano", now: Date())
        XCTAssertEqual(affinity.value, AffinityRules.normal, accuracy: 0.001)
    }
}
