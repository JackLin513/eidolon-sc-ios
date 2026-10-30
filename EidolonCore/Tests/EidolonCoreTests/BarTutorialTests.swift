import XCTest
@testable import EidolonCore

/// The tutorial's state machine (upstream `lib/barTutorial.test.ts`): when the bar counter
/// opens, what her reaction is to what was served, and how it ends.
final class BarTutorialTests: XCTestCase {
    private var drinks: [Drink] = []
    private var clock: TimeInterval = 0

    override func setUpWithError() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "drinks", withExtension: "json", subdirectory: "Resources")
        )
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        drinks = try DrinkCatalog(json: json).drinks
    }

    private func later() -> TimeInterval {
        clock += 10
        return clock
    }

    /// 一句一页：只看说到哪了，不管怎么折行；框上那一句是它的中文字幕（制作人本来只有中文）。
    private func layout(_ line: BarTextLine) -> [BarTextPage] {
        let text: String
        switch line {
        case let .her(_, zh): text = zh
        case let .producer(zh): text = zh
        }
        return [BarTextPage(rows: [BarTextRow(name: nil, text: text, subtitle: false)])]
    }

    /// 框上那一句，照上游按中文字幕比（她的日语只用来显示）。
    private func said(_ state: BarTutorial) -> String? {
        guard let line = state.screen.shown?.page.line else { return nil }
        switch line {
        case let .her(_, zh): return zh
        case let .producer(zh): return zh
        }
    }

    private func begin(hasJukebox: Bool = true) -> BarTutorial {
        BarTutorial.begin(characterID: "hazuki", hasJukebox: hasJukebox, layout: layout, now: later())
    }

    /// 一直点文本框，点到调酒台打开、或者教程走完。
    private func talkThrough(_ start: BarTutorial) throws -> BarTutorial {
        var state = start
        for _ in 0..<1000 {
            if state.screen.isMixing || state.end != nil { return state }
            state = state.applying(.tap(now: later()))
        }
        XCTFail("the tutorial never stopped talking")
        throw XCTSkip("the tutorial never stopped talking")
    }

    /// 框上那一句。
    private func onBox(_ state: BarTutorial) -> String? {
        said(state)
    }

    private struct Recipe {
        var parts: [Ingredient: Int]
        var ice = false
        var blend = false
    }

    private let sugarRush = Recipe(parts: [.adelhyde: 2, .powderedDelta: 1])
    private let pianoMan = Recipe(
        parts: [.adelhyde: 2, .bronsonExtract: 3, .powderedDelta: 5, .flanergide: 5, .karmotrine: 3],
        ice: true
    )
    private let moonblast = Recipe(
        parts: [.adelhyde: 6, .powderedDelta: 1, .flanergide: 1, .karmotrine: 2],
        ice: true,
        blend: true
    )
    /// 调对了别的一杯。
    private let badTouch = Recipe(
        parts: [.bronsonExtract: 2, .powderedDelta: 2, .flanergide: 2, .karmotrine: 4],
        ice: true
    )

    /// 在开着的调酒台上照 `recipe` 调好（停下）。
    private func mix(_ start: BarTutorial, _ recipe: Recipe) -> BarTutorial {
        var actions: [BarMixer.Action] = []
        for (ingredient, count) in recipe.parts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            for _ in 0..<count { actions.append(.add(ingredient)) }
        }
        if recipe.ice { actions.append(.ice) }
        let shakenAt = later()
        actions.append(.shake(now: shakenAt))
        actions.append(.stop(
            now: shakenAt + (recipe.blend ? 6 : 1), drinks: drinks, garble: "#%!?@&*"
        ))
        return actions.reduce(start) { $0.applying(.mix($1)) }
    }

    private func serve(_ start: BarTutorial, _ recipe: Recipe) -> BarTutorial {
        mix(start, recipe).applying(.serve(now: later()))
    }

    /// The memo a lesson's bar counter opens with, for the text box.
    private func memoOf(_ id: BarTutorialSectionID) throws -> String {
        guard case let .mixer(memo, _, _) = BarTutorialLines.section(id).then else {
            throw XCTSkip("\(id) opens no counter")
        }
        return memo
    }

    // MARK: - the tutorial

    func testOpensOnHerFirstLineNoMemo() {
        let state = begin()
        XCTAssertTrue(state.screen.isVisiting)
        XCTAssertEqual(state.screen.visit?.characterID, "hazuki")
        XCTAssertEqual(onBox(state), BarTutorialLines.section(.opening).lines[0].zh)
        XCTAssertNil(state.screen.memo)
    }

    func testOpensTheBarCounterOnlyOnceTheFirstLessonIsToldWithItsMemo() throws {
        var state = begin()
        for _ in 0..<5 { state = state.applying(.tap(now: later())) }
        XCTAssertFalse(state.screen.isMixing)
        XCTAssertNil(state.screen.memo)
        state = try talkThrough(state)
        XCTAssertTrue(state.screen.isMixing)
        XCTAssertEqual(onBox(state), BarTutorialLines.section(.lesson1).lines.last?.zh)
        XCTAssertEqual(state.screen.memo, try memoOf(.lesson1))
    }

    func testKeepsTheLessonsLastLineOnTheBoxTillItIsTappedPast() {
        var state = begin()
        let last = BarTutorialLines.section(.lesson1).lines.last?.zh
        while onBox(state) != last {
            state = state.applying(.tap(now: later()))
        }
        // 早就打完了，没点也不开。
        XCTAssertFalse(state.screen.isMixing)
        clock += 60
        XCTAssertTrue(state.applying(.tap(now: later())).screen.isMixing)
    }

    // MARK: - serving

    func testGoesOnToHerReactionToSugarRushMadeRightThenTheSecondLesson() throws {
        var state = serve(try talkThrough(begin()), sugarRush)
        XCTAssertFalse(state.screen.isMixing)
        XCTAssertEqual(state.section, .firstSugarRush)
        XCTAssertEqual(onBox(state), BarTutorialLines.section(.firstSugarRush).lines[0].zh)
        state = try talkThrough(state)
        XCTAssertEqual(state.section, .lesson2)
        XCTAssertTrue(state.screen.isMixing)
        XCTAssertEqual(state.screen.memo, try memoOf(.lesson2))
    }

    func testGoesOnToHerReactionToSomethingElseThenTheSecondLessonAllTheSame() throws {
        var state = serve(try talkThrough(begin()), badTouch)
        XCTAssertEqual(state.section, .firstOther)
        XCTAssertEqual(onBox(state), BarTutorialLines.section(.firstOther).lines[0].zh)
        state = try talkThrough(state)
        XCTAssertEqual(state.section, .lesson2)
    }

    func testSkipsTheSecondLessonForPianoManStraightToTheClosing() throws {
        var state = serve(try talkThrough(begin()), pianoMan)
        XCTAssertEqual(state.section, .firstPianoMan)
        XCTAssertEqual(onBox(state), BarTutorialLines.section(.firstPianoMan).lines[0].zh)
        var sections: Set<BarTutorialSectionID> = [state.section]
        while state.end == nil {
            state = state.applying(.tap(now: later()))
            sections.insert(state.section)
        }
        XCTAssertFalse(sections.contains(.lesson2))
        XCTAssertTrue(sections.contains(.closing))
        XCTAssertEqual(state.end, .jukebox)
    }

    func testGoesOnToHerReactionToSomethingElseForTheSecondThenTheClosing() throws {
        let first = try talkThrough(serve(try talkThrough(begin()), sugarRush))
        let other = serve(first, sugarRush)
        XCTAssertEqual(other.section, .secondOther)
        let closing = try talkThrough(other.applying(.tap(now: later())))
        XCTAssertEqual(closing.end, .jukebox)
    }

    func testDoesNotTakeABrokenDrinkTheCounterStaysOpenNothingSaid() throws {
        let open = try talkThrough(begin())
        let broken = mix(open, Recipe(parts: [.karmotrine: 21]))
        XCTAssertEqual(broken.screen.mixer.shake, .stopped)
        let after = broken.applying(.serve(now: later()))
        XCTAssertEqual(after, broken)
        XCTAssertTrue(after.screen.isMixing)
        XCTAssertEqual(after.section, .lesson1)
    }

    func testDoesNotServeBeforeTheCounterOpens() {
        let state = begin()
        XCTAssertEqual(state.applying(.serve(now: later())), state)
    }

    // MARK: - the end

    /// 从头走到底，记下走过的段落。
    private func walk(hasJukebox: Bool) throws -> (state: BarTutorial, sections: [BarTutorialSectionID]) {
        var state = try talkThrough(serve(try talkThrough(begin(hasJukebox: hasJukebox)), sugarRush))
        var sections: [BarTutorialSectionID] = []
        state = serve(state, moonblast)
        while state.end == nil {
            if sections.last != state.section { sections.append(state.section) }
            state = state.applying(.tap(now: later()))
        }
        return (state, sections)
    }

    func testGoesOnToHerReactionToMoonblastThenTheJukeboxSectionToTheSetup() throws {
        let (state, sections) = try walk(hasJukebox: true)
        XCTAssertEqual(sections, [.secondMoonblast, .closing, .jukebox])
        XCTAssertEqual(state.end, .jukebox)
    }

    func testLeavesOutTheJukeboxSectionWithNoAudioStraightToTheDoor() throws {
        let (state, sections) = try walk(hasJukebox: false)
        XCTAssertEqual(sections, [.secondMoonblast, .closing])
        XCTAssertEqual(state.end, .door)
    }

    func testSkipsToTheJukeboxSetupAtOnceMidTalkOrMixing() throws {
        XCTAssertEqual(begin().applying(.skip).end, .jukebox)
        XCTAssertEqual(try talkThrough(begin()).applying(.skip).end, .jukebox)
        XCTAssertEqual(begin(hasJukebox: false).applying(.skip).end, .door)
    }

    func testTakesNothingMoreOnceEnded() {
        let ended = begin().applying(.skip)
        XCTAssertEqual(ended.applying(.tap(now: later())), ended)
    }
}
