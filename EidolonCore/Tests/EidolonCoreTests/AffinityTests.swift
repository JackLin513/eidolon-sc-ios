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
        XCTAssertEqual(Judged(level: 0).step, -5)
        XCTAssertEqual(Judged(level: 1).step, -2)
        XCTAssertEqual(Judged(level: 2).step, 0)
        XCTAssertEqual(Judged(level: 3).step, 1)
        XCTAssertEqual(Judged(level: 4).step, 2)
        XCTAssertEqual(Judged(level: 4, outOfLine: true).step, -10)
        XCTAssertEqual(Judged(level: 4, manipulation: true).step, 0)
        XCTAssertEqual(Judged(level: 4, outOfLine: true).hurt, 10)
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
        XCTAssertEqual(
            ends(judged: Judged(level: 2), cools: true, outOfLineBefore: 0, hurtBefore: []),
            .cooldown
        )
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

    func testDayGainsAreCappedAtSix() async throws {
        let eidolon = try await installedEidolon()
        let judge = FixedJudge(judged: Judged(level: 4))
        for _ in 0..<5 {
            for try await _ in eidolon.sendTurn(
                characterID: "mano",
                text: "ありがとう",
                provider: reply(),
                judge: judge
            ) {}
        }
        let affinity = try await eidolon.readAffinity(characterID: "mano", now: Date())
        XCTAssertEqual(affinity.value, AffinityRules.normal + AffinityRules.gainsPerDay, accuracy: 0.001)
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
