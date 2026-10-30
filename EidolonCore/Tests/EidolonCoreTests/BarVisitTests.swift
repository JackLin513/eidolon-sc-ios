import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// A visit under way (GLOSSARY.md「光顾」; ADR-0021): who comes in, why, her lines as they
/// close, the memo and that she waits, the call made again once, her farewell in fixed lines
/// where it cannot be written, and the visit done, written down and rewarded.
final class BarVisitTests: BarTestCase {
    // MARK: - Fixtures

    private func comingIn(_ id: String = "bronson-aged") -> [String] {
        let drink = content.content.catalog.drink(id: id)!
        return [
            "<her emotion=\"happy\"><ja>こんばんは。</ja><zh>晚上好。</zh></her>",
            "<producer>欢迎。</producer>",
            "<her emotion=\"calm\" order=\"true\"><ja>\(drink.nameJa)をください。</ja>"
                + "<zh>请给我一杯 \(drink.name)。</zh></her>",
        ]
    }

    /// Her reaction to what was served and the talk after it. The producer's「请慢用。」is
    /// said by the bar itself as the call opens, so the model is not to write it again.
    private func reacting(next id: String? = nil) -> [String] {
        var lines = [
            "<her emotion=\"happy\"><ja>ありがとう。</ja><zh>谢谢。</zh></her>",
            "<producer>好喝吗？</producer>",
            "<her emotion=\"happy\"><ja>また来ますね。</ja><zh>我还会再来的。</zh></her>",
        ]
        if let id {
            let drink = content.content.catalog.drink(id: id)!
            lines.append(
                "<her order=\"true\"><ja>\(drink.nameJa)をください。</ja>"
                    + "<zh>请给我一杯 \(drink.name)。</zh></her>"
            )
        }
        return lines
    }

    /// The first of each of the fixed lines, and three drinks: her drinks are drawn from
    /// tables of percentages summing to a hundred, so 80 falls in the last of the cups.
    private static let threeDrinks: BarRandom = { count in
        count == BarRules.cups.reduce(0) { $0 + $1.1 } ? 80 : 0
    }

    /// The first of each of the fixed lines, and two drinks: 40 falls in the middle of the
    /// cups, which are one for up to 20, two for up to 80.
    private static let twoDrinks: BarRandom = { count in
        count == BarRules.cups.reduce(0) { $0 + $1.1 } ? 40 : 0
    }

    /// The visit's first order, as it was drawn: what she orders is what is served her.
    private func ordered(_ visit: BarVisit?) throws -> String {
        try XCTUnwrap(visit?.orders.first?.target.id)
    }

    private static let farewell = [
        "<producer>请慢用。</producer>",
        "<her emotion=\"happy\"><ja>また来ますね。</ja><zh>我还会再来的。</zh></her>",
    ]

    /// The mixture that is `drink`, as the mixer makes it.
    private func mixture(_ id: String) throws -> Mixture {
        let recipe = try XCTUnwrap(content.content.catalog.drink(id: id)?.recipe)
        return Mixture(
            adelhyde: recipe.adelhyde, bronsonExtract: recipe.bronsonExtract,
            powderedDelta: recipe.powderedDelta, flanergide: recipe.flanergide,
            karmotrine: recipe.karmotrine ?? 0, ice: recipe.ice, aged: recipe.aged,
            method: recipe.method
        )
    }

    /// Her order of `id`, as a call rewriting it writes it.
    private func ordering(_ id: String) -> String {
        let drink = content.content.catalog.drink(id: id)!
        return "<her emotion=\"calm\" order=\"true\"><ja>\(drink.nameJa)をください。</ja>"
            + "<zh>请给我一杯 \(drink.name)。</zh></her>"
    }
    /// The kinds of events, in order, with who said each line.
    private func kinds(_ events: [BarEvent]) -> [String] {
        events.map { event in
            switch event {
            case .visit: "visit"
            case let .line(line): "line:\(line.speaker.rawValue)\(line.order ? ":order" : "")"
            case .memo: "memo"
            case .waiting: "waiting"
            case .retrying: "retrying"
            case .done: "done"
            case .failed: "failed"
            }
        }
    }

    private func her(_ events: [BarEvent]) -> [String] {
        events.compactMap {
            if case let .line(line) = $0, line.speaker == .her { return line.zh }
            return nil
        }
    }

    // MARK: - A whole visit

    func testAVisitComesInOrdersIsServedEachDrinkAndSaysGoodbye() async throws {
        // Four reasons and topics, so that the first of each may be the one drawn; one drink,
        // so that after it is served she says goodbye.
        // Her order names a drink she does not mean, so it is rewritten in another call; the
        // rewrite answers only her order. That call is answered before those after are read.
        // Her coming in names the drink she does not mean; the rewrite names the one she
        // does, as the prompt asks.
        let chat = ScriptedChat(
            [.chunks(comingIn()), .chunks([ordering("adelhyde-flavor")]), .chunks(reacting())]
        )
        let room = room(chat, random: { _ in 0 })
        let call = try await room.enter(setup(chat))
        let cameIn = try await collect(call)

        guard case let .visit(visitID, characterID) = cameIn.first else {
            return XCTFail("she did not come in")
        }
        XCTAssertFalse(visitID.isEmpty)
        XCTAssertEqual(characterID, "mano")
        // Her line naming the wrong drink is replaced by the rewrite, which names the one
        // she means; the drink's Karmotrine being optional is said on the order card, and
        // after a rewrite no fixed line is added (upstream `_named`).
        XCTAssertEqual(
            kinds(cameIn),
            ["visit", "line:her", "line:producer", "line:her:order", "memo", "waiting"]
        )
        guard case let .memo(memo) = cameIn[4] else { return XCTFail("no memo") }
        XCTAssertTrue(memo.contains("Adelhyde Flavor"), memo)
        XCTAssertTrue(memo.contains("不要酒精"), memo)
        XCTAssertEqual(her(cameIn), ["晚上好。", "请给我一杯 Adelhyde Flavor。"])

        let served = try await collect(try await room.serve(mixture("adelhyde-flavor"), setup: setup(chat)))
        XCTAssertEqual(
            kinds(served),
            ["line:producer", "line:her", "line:producer", "line:her", "done"],
            "one drink: served, her reaction and the talk, then goodbye"
        )
        guard case .done(let reward) = served.last! else { return XCTFail("not done") }
        XCTAssertNotNil(reward, "the day's first visit is rewarded")
        XCTAssertEqual(reward?.affinityUp, true)
        XCTAssertTrue(reward?.affinityUp ?? false)
        // Three calls: hers coming in, her order rewritten where it names the wrong drink,
        // and the call after it is served. The rewrite is a call of its own, asking only for
        // her order.
        XCTAssertEqual(chat.calls, 3, "her coming in, her order rewritten, and one more")
        let prompts = chat.prompts
        XCTAssertEqual(prompts.count, 3)
        XCTAssertEqual(prompts[0].map(\.role), [.system, .system, .user])
        XCTAssertEqual(
            prompts[1].map(\.role), [.system, .system, .user],
            "the rewrite: the same opening, asking only for her order"
        )
        XCTAssertEqual(
            prompts[2].map(\.role), [.system, .system, .user, .assistant, .user],
            "the call before, with what it asked for and what was written"
        )
        // What came of the call before, as the model wrote it: her lines with the drink she
        // was told to name in both languages.
        XCTAssertTrue(prompts[2][3].content.contains("こんばんは。"), prompts[2][3].content)
        XCTAssertTrue(
            prompts[2][3].content.contains(content.content.catalog.drink(id: "adelhyde-flavor")!.name),
            prompts[2][3].content
        )
        let underWay = try await room.catchUp()
        XCTAssertTrue(underWay == nil, "done: no visit under way")
        // Written down once, rewarded.
        let records = try await room.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].characterID, "mano")
        XCTAssertEqual(records[0].orders.count, 1)
        XCTAssertTrue(records[0].rewarded)
        // Served best, of one she loves: the day's first visit raises her affection most.
        let queue = self.queue!
        let at = now!
        let affinity = try await queue.read { db in
            try Eidolon.readAffinity(db, characterID: "mano", now: at)
        }
        XCTAssertEqual(affinity.value, AffinityRules.normal + AffinityRules.servedSteps[.best]!, accuracy: 1e-9)
    }

    // MARK: - The order memo

    func testHerOrderIsHeldBackTillItNamesTheDrink() async throws {
        // Her lines, the order among them, but none marked: the last of hers is her order.
        // The rewrite she needs answers with a line that names the drink she means, and it is
        // that line which is shown, marked as her order.
        // One answer for her coming in, and one for the rewrite her order needs.
        let chat = ScriptedChat([
            .chunks(comingIn()), .chunks([ordering("adelhyde-flavor")]),
        ])
        let room = room(chat)
        let cameIn = try await collect(try await room.enter(setup(chat)))

        let shown = kinds(cameIn)
        XCTAssertEqual(shown.last, "waiting", "she waits for her drink")
        guard case let .memo(memo) = cameIn[cameIn.count - 2] else { return XCTFail("no memo") }
        XCTAssertTrue(memo.contains(content.content.catalog.drink(id: "adelhyde-flavor")!.name), memo)
        // Her order as the rewrite wrote it, held back till it named the drink she means; the
        // fixed line she adds for "without alcohol" comes only where the order is said in a
        // fixed line instead (upstream `fixed_order`), not after a rewrite.
        let orders = cameIn.compactMap { event -> String? in
            guard case let .line(line) = event, line.order else { return nil }
            return line.zh
        }
        XCTAssertEqual(orders, ["请给我一杯 Adelhyde Flavor。"], "her order, named as it should be")
    }

    // MARK: - Serving

    func testServingWhileHerLinesAreBeingWrittenIsRefused() async throws {
        // She is served nothing till her lines are written: her call answers none, so it
        // fails and is said again, and the visit stops before it rather than waiting.
        let chat = ScriptedChat(lines: [])
        let room = room(chat)
        _ = try await collect(try await room.enter(setup(chat)))

        do {
            _ = try await room.serve(mixture("bronson-aged"), setup: setup(chat))
            XCTFail("it was served")
        } catch {
            XCTAssertEqual(error as? EidolonError, .barNotWaiting)
        }
    }

    func testWhatIsBrokenIsRefusedChangingNothing() async throws {
        let visiting = ScriptedChat(lines: comingIn())
        let room = room(visiting)
        _ = try await collect(try await room.enter(setup(visiting)))
        let before = try await room.catchUp()

        // Nothing but parts the mixer cannot hold.
        do {
            _ = try await room.serve(Mixture(adelhyde: 40), setup: setup(visiting))
            XCTFail("it was served")
        } catch {
            XCTAssertEqual(error as? EidolonError, .barBrokenDrink)
        }
        let after = try await room.catchUp()
        XCTAssertEqual(after?.step, before?.step)
        XCTAssertEqual(after?.servings.count, 0, "changing nothing")
    }

    func testABottleIsServedAsItIs() async throws {
        let chat = ScriptedChat(lines: comingIn() + Self.farewell)
        let room = room(chat)
        _ = try await collect(try await room.enter(setup(chat)))

        let served = try await collect(try await room.serve(nil, bottle: "mulan-tea", setup: setup(chat)))
        XCTAssertEqual(served.first, .line(BarLine(speaker: .producer, zh: "请慢用。")))
        guard case .done = served.last else { return XCTFail("not done") }
    }

    // MARK: - Failing

    func testACallThatFailsIsMadeAgainOnceAndThenStopsTheVisit() async throws {
        // Three drinks, so the call after the first is served is not her farewell, which is
        // said in fixed lines instead of stopping the visit. Her order names a drink she does
        // not mean, so it is rewritten in a call before it, asking only for the drink she
        // does mean.
        let chat = Bot(content.content, failing: 3)
        let room = room(chat, random: Self.threeDrinks)
        _ = try await collect(try await room.enter(setup(chat)))
        let visiting = try await room.catchUp()
        let ordered = try XCTUnwrap(visiting?.orders.first?.target.id)

        let served = try await collect(try await room.serve(mixture(ordered), setup: setup(chat)))
        XCTAssertEqual(served.first, .line(BarLine(speaker: .producer, zh: "请慢用。")))
        XCTAssertTrue(served.contains(.retrying), "the page is told to clear what it sent")
        guard case .failed = served.last else { return XCTFail("not failed") }
        let stopped = try await room.catchUp()
        XCTAssertEqual(stopped?.step, .failed)
        XCTAssertEqual(stopped?.servings.count, 1, "what was served stood")
        XCTAssertEqual(chat.calls, 4, "once, and once more")
    }

    func testAFailedVisitIsTriedAgainOnTheSameOrder() async throws {
        // Two drinks, so the call after the first is served is not her farewell and the visit
        // stops before it rather than ending in fixed lines. Calls 3 and 4, the serve's two
        // tries, fail; the visit is tried again on call 5, which is her farewell.
        let chat = Bot(content.content, failing: 2)
        let room = room(chat, random: Self.twoDrinks)
        _ = try await collect(try await room.enter(setup(chat)))
        let visiting = try await room.catchUp()
        let ordered = try XCTUnwrap(visiting?.orders.first?.target.id)
        _ = try await collect(try await room.serve(mixture(ordered), setup: setup(chat)))
        let underWay = try await room.catchUp()
        let stopped = try XCTUnwrap(underWay)

        // Tried again, it is the same call: nothing is said before it (upstream `_called` is
        // given no `first`), and what it asks for is what it asked for when it failed.
        let again = try await collect(try await room.retry(setup(chat)))
        XCTAssertFalse(
            again.contains(.line(BarLine(speaker: .producer, zh: "请慢用。"))),
            "the producer says nothing again"
        )
        let asked = try XCTUnwrap(chat.prompts.last?.last?.content)
        XCTAssertEqual(asked, stopped.asking, "the same order, asked the same way")
        let wentOn = try await room.catchUp()
        XCTAssertEqual(wentOn?.step, .waiting, "she waits for her next drink")
        XCTAssertEqual(wentOn?.servings.count, 1, "what was served stood")
    }

    func testACallCutOffByTheAppGoingUnderIsKeptToBeTriedAgain() async throws {
        // The model holds the visit's call: it is still being written when the app goes under
        // and the system cuts the request off. The visit stops before that call rather than
        // being left, so that 「再试一次」 can take it on (ADR-0021: 切后台不算离开).
        let chat = HoldingChat()
        let room = room(chat)
        let call = try await room.enter(setup(chat))
        let writing = try await room.catchUp()
        XCTAssertEqual(writing?.step, .writing, "being written")

        await room.cutOff()
        call.left()

        let stopped = try await room.catchUp()
        let kept = try XCTUnwrap(stopped)
        XCTAssertEqual(kept.step, .failed, "stopped before the call, not left")
        XCTAssertEqual(kept.calls, writing?.calls, "the same call to be made again")
    }

    func testAServingWaitIsNotCutOffByTheAppGoingUnder() async throws {
        // Her lines are all written and read: nothing is being written, she waits for her
        // drink. Going under then has nothing to cut off, so the visit stays waiting rather
        // than being shown as failed with a 「再试一次」 that could not be taken
        // (ADR-0021: 切后台不算离开).
        let chat = ScriptedChat([.chunks(comingIn()), .chunks([ordering("adelhyde-flavor")])])
        let room = room(chat)
        let cameIn = try await collect(try await room.enter(setup(chat)))
        XCTAssertEqual(kinds(cameIn).last, "waiting", "she waits for her drink")
        let waiting = try await room.catchUp()
        XCTAssertEqual(waiting?.step, .waiting, "nothing being written")

        let cut = await room.cutOff()

        XCTAssertFalse(cut, "there was no call to cut off")
        let again = try await room.catchUp()
        let kept = try XCTUnwrap(again)
        XCTAssertEqual(kept.step, .waiting, "still waiting for her drink")
    }

    /// A chat model that holds its answer: a visit's call stays being written until the test
    /// has done what it wanted with it.
    private final class HoldingChat: ChatProvider, @unchecked Sendable {
        private let held = NSLock()
        private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

        func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
            AsyncThrowingStream { continuation in
                held.lock()
                continuations.append(continuation)
                held.unlock()
            }
        }
    }

    /// The model a whole visit is scripted on: her coming in, her order rewritten to the
    /// drink she means, as many failures as there are, then her farewell. Call 1 is her
    /// coming in, call 2 the rewrite, so `failing` counts from the call after those.
    private final class Bot: ChatProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[PromptMessage]] = []
        private let content: BarContent
        private let failing: Int

        init(_ content: BarContent, failing: Int) {
            self.content = content
            self.failing = failing
        }

        var prompts: [[PromptMessage]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        var calls: Int {
            lock.lock()
            defer { lock.unlock() }
            return recorded.count
        }

        func stream(messages: [PromptMessage]) -> AsyncThrowingStream<String, Error> {
            lock.lock()
            recorded.append(messages)
            let n = recorded.count
            lock.unlock()
            let asked = messages.last?.content ?? ""
            let named = content.catalog.drinks.first { asked.contains("「\($0.nameJa)」") }
            // What is asked decides what is written: her order rewritten where only it is
            // asked for, her farewell where the call is the last of her cups.
            let answer: Result<[String], Error>
            if n == 1 {
                answer = .success(Self.comingIn(content))
            } else if asked.contains("只重写点单") {
                answer = .success([Self.ordering(named ?? content.catalog.drinks[0])])
            } else if n <= failing + 2 {
                answer = .failure(ChatProviderError.notConfigured)
            } else if asked.contains("然后告别") {
                answer = .success([
                    "<her emotion=\"happy\"><ja>また来ますね。</ja><zh>我还会再来的。</zh></her>",
                ])
            } else {
                answer = .success([
                    "<her emotion=\"happy\"><ja>おいしい。</ja><zh>好喝。</zh></her>",
                    Self.ordering(named ?? content.catalog.drinks[0]),
                ])
            }
            return AsyncThrowingStream { continuation in
                switch answer {
                case let .success(lines):
                    for line in lines { continuation.yield(line) }
                    continuation.finish()
                case let .failure(error):
                    continuation.finish(throwing: error)
                }
            }
        }

        /// Her coming in, ordering `drink` by its Japanese and English names.
        static func comingIn(_ content: BarContent) -> [String] {
            // The one she does not mean, so that her order is rewritten at the call after.
            let wrong = content.catalog.drinks.first { $0.id != content.catalog.drinks[0].id }
            return Self.comingIn(content, ordering: wrong ?? content.catalog.drinks[0])
        }

        static func comingIn(_ content: BarContent, ordering drink: Drink) -> [String] {
            [
                "<her emotion=\"happy\"><ja>こんばんは。</ja><zh>晚上好。</zh></her>",
                "<producer>欢迎。</producer>",
                Self.ordering(drink),
            ]
        }

        /// Her order of `drink`, named as she should name it.
        static func ordering(_ drink: Drink) -> String {
            "<her emotion=\"calm\" order=\"true\"><ja>\(drink.nameJa)をください。</ja>"
                + "<zh>请给我一杯 \(drink.name)。</zh></her>"
        }
    }

    func testHerFarewellSaidInFixedLinesWhereItCannotBeWritten() async throws {
        // Her farewell call fails both times: she says it in fixed lines, done all the same.
        let chat = ScriptedChat([
            .chunks(comingIn()),
            .failure(ChatProviderError.notConfigured),
            .failure(ChatProviderError.notConfigured),
        ])
        let room = room(chat)
        _ = try await collect(try await room.enter(setup(chat)))

        let served = try await collect(try await room.serve(mixture("bronson-aged"), setup: setup(chat)))
        XCTAssertEqual(
            kinds(served),
            ["line:producer", "retrying", "line:her", "line:her", "done"],
            "told to clear what it sent, her reaction and her farewell in fixed lines, then done"
        )
        let underWay = try await room.catchUp()
        XCTAssertTrue(underWay == nil)
        let records = try await room.records()
        XCTAssertEqual(records.count, 1)
    }

    // MARK: - Leaving and idling

    func testAVisitLeftIsWrittenNoFurtherAndNotWrittenDown() async throws {
        let chat = ScriptedChat(lines: comingIn())
        let room = room(chat)
        _ = try await collect(try await room.enter(setup(chat)))

        try await room.leave()

        let underWay = try await room.catchUp()
        XCTAssertTrue(underWay == nil)
        let records = try await room.records()
        XCTAssertTrue(records.isEmpty, "a visit left before it is done is not")
        do {
            _ = try await room.serve(mixture("bronson-aged"), setup: setup(chat))
            XCTFail("it was served")
        } catch {
            XCTAssertEqual(error as? EidolonError, .barVisitGone)
        }
    }

    func testAVisitUntouchedForHalfAnHourIsGone() async throws {
        let chat = ScriptedChat(lines: comingIn())
        let room = room(chat)
        _ = try await collect(try await room.enter(setup(chat)))

        tick(BarRules.idle - 1)
        let justBefore = try await room.catchUp()
        XCTAssertNotNil(justBefore)

        tick(1)
        let after = try await room.catchUp()
        XCTAssertNil(after, "untouched for `idle`: gone")
        do {
            _ = try await room.serve(mixture("bronson-aged"), setup: setup(chat))
            XCTFail("it was served")
        } catch {
            XCTAssertEqual(error as? EidolonError, .barVisitGone)
        }
    }

    func testComingInAgainDoesAwayWithTheOneBefore() async throws {
        // Only the first call's answers, so the second answers none: what it does then is
        // not this test's matter.
        let chat = ScriptedChat(lines: comingIn())
        let room = room(chat)
        _ = try await collect(try await room.enter(setup(chat)))
        let cameInFirst = try await room.catchUp()
        let first = try XCTUnwrap(cameInFirst).id

        _ = try await collect(try await room.enter(setup(chat)))
        let cameInSecond = try await room.catchUp()
        let second = try XCTUnwrap(cameInSecond).id

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(chat.calls, 4, "two calls for each of the two visits")
        let records = try await room.records()
        XCTAssertTrue(records.isEmpty, "neither was done")
    }

    // MARK: - Closed

    func testClosedNobodyComesIn() async throws {
        let chat = ScriptedChat(lines: [])
        let room = room(chat, open: { false })

        do {
            _ = try await room.enter(setup(chat))
            XCTFail("she came in")
        } catch {
            XCTAssertEqual(error as? EidolonError, .barClosed)
        }
        XCTAssertEqual(chat.calls, 0)
    }

    // MARK: - Coming in

    func testWhoComesInIsTheSameAllDayUntilAVisitIsDone() async throws {
        // Two of them: the day's, whoever else could have come, until one is done.
        let day = BarRecords.day(now, in: Self.timeZone)
        let chosen = BarRoom.ofTheDay(day, 2)
        XCTAssertEqual(chosen, BarRoom.ofTheDay(day, 2), "by the day alone")
        XCTAssertNotEqual(BarRoom.ofTheDay("2026-10-29", 2), BarRoom.ofTheDay("2026-10-30", 2))

        // Only the first call's answers, so the second answers none: what it does then is
        // not this test's matter.
        let chat = ScriptedChat(lines: comingIn())
        let room = room(chat)
        let first = try await collect(try await room.enter(setup(chat)))
        let second = try await collect(try await room.enter(setup(chat)))
        let comeIn = ["mano", "hiori"]
        XCTAssertEqual(first.first, .visit(visitID: firstVisit(first), characterID: comeIn[chosen]))
        XCTAssertEqual(second.first, .visit(visitID: firstVisit(second), characterID: comeIn[chosen]))
        let status = try await room.status()
        XCTAssertTrue(status.rewardToday)
    }

    /// The visit's identifier, from her coming in.
    private func firstVisit(_ events: [BarEvent]) -> String {
        guard case let .visit(visitID, _) = events.first else { return "" }
        return visitID
    }

    func testSheComesInOnNoneOfHerLatestThreeReasons() async throws {
        // Three visits done, on reasons 1, 2 and 3: the next is on 4, the only one left. One
        // of them was done today, so today's visit is not the day's first and is not
        // rewarded.
        let queue = self.queue!
        let at = now!
        let today = BarRecords.day(at, in: Self.timeZone)
        try await queue.write { db in
            for n in 1...3 {
                try BarRecords.insert(
                    db, characterID: "mano", enteredAt: at, leftAt: at,
                    enteredOn: n == 3 ? today : "2026-09-2\(n)",
                    reason: "reason-\(n)", topic: "topic-\(n)", servings: [], drunk: false,
                    rewarded: n == 1
                )
            }
        }
        let chat = ScriptedChat(lines: comingIn())
        let room = room(chat)
        let cameIn = try await collect(try await room.enter(setup(chat)))
        XCTAssertEqual(cameIn.first, .visit(visitID: firstVisit(cameIn), characterID: "mano"))
        let about = try XCTUnwrap(chat.prompts.first?.dropFirst().first?.content)

        XCTAssertTrue(about.contains("reason 4 的说明"), "the one reason she has not come in on")
        XCTAssertFalse(about.contains("reason 3 的说明"), "she has come in on it")
        let status = try await room.status()
        XCTAssertFalse(status.rewardToday, "a visit was done today")
    }
}
