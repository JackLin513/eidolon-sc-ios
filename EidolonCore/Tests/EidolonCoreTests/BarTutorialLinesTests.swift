import XCTest
@testable import EidolonCore

/// The tutorial's written lines (upstream `lib/barTutorialLines.test.ts`): they fit the text
/// box, only the two lessons open the bar counter, every section is walked to, and what it
/// teaches and leaves out.
final class BarTutorialLinesTests: XCTestCase {
    private let sections = BarTutorialSectionID.allCases

    /// 像素字下大致占几个全角字：ASCII 半个，其余一个。
    private func width(_ text: String) -> Double {
        text.reduce(0) { $0 + ($1.unicodeScalars.allSatisfy { $0.isASCII } ? 0.5 : 1) }
    }

    /// 文本框 412 宽、13px 字：一行按 30 个全角字算，留点余地。
    private let row = 30.0
    private func rows(_ text: String) -> Int { Int((width(text) / row).rounded(.up)) }

    /// 从 `from` 照 `then` 往下走能到的段（上酒的每种结果都走一遍）。
    private func reachable(from start: BarTutorialSectionID) -> Set<BarTutorialSectionID> {
        var seen: Set<BarTutorialSectionID> = []
        func walk(_ id: BarTutorialSectionID) {
            guard seen.insert(id).inserted else { return }
            switch BarTutorialLines.section(id).then {
            case let .section(next): walk(next)
            case let .mixer(_, reactions, other):
                for next in reactions.values { walk(next) }
                walk(other)
            case .done: break
            }
        }
        walk(start)
        return seen
    }

    /// 从 `from` 走到底经过的段；上酒时按 `served` 的饮品 id 接（不在反应里的算 other）。
    private func path(_ served: [String]) -> [BarTutorialSectionID] {
        var out: [BarTutorialSectionID] = []
        var id: BarTutorialSectionID? = BarTutorialLines.start
        var cups = served
        while let current = id {
            out.append(current)
            switch BarTutorialLines.section(current).then {
            case let .section(next): id = next
            case let .mixer(_, reactions, other):
                let drink = cups.removeFirst()
                id = reactions[drink] ?? other
            case .done: id = nil
            }
        }
        return out
    }

    func testEverySectionHasLinesAndEveryLineFitsOnePage() {
        for id in sections {
            let lines = BarTutorialLines.section(id).lines
            XCTAssertFalse(lines.isEmpty, "\(id)")
            for line in lines {
                XCTAssertFalse(line.zh.trimmingCharacters(in: .whitespaces).isEmpty, "\(id)")
                if line.who == .her {
                    XCTAssertFalse(line.ja.trimmingCharacters(in: .whitespaces).isEmpty, "\(id)")
                }
                // 名字接冒号在同一行开头（她「はづき：」，制作人的名字按 8 个字算）；
                // 她的日语、中文各自折行；最多 4 行。
                let used = line.who == .her
                    ? rows("はづき：" + line.ja) + rows(line.zh)
                    : rows("一二三四五六七：" + line.zh)
                XCTAssertLessThanOrEqual(used, 4, line.zh)
            }
        }
    }

    func testOnlyTheTwoLessonsOpenTheBarCounter() {
        var mixers: [BarTutorialSectionID: BarTutorialThen] = [:]
        for id in sections {
            if case .mixer = BarTutorialLines.section(id).then { mixers[id] = BarTutorialLines.section(id).then }
        }
        XCTAssertEqual(Set(mixers.keys), [.lesson1, .lesson2])
        XCTAssertEqual(
            mixers[.lesson1],
            .mixer(
                memo: "她要 Sugar Rush。配方在配方书里查，调坏了就点重做。",
                reactions: ["sugar-rush": .firstSugarRush, "piano-man": .firstPianoMan],
                other: .firstOther
            )
        )
        XCTAssertEqual(
            mixers[.lesson2],
            .mixer(
                memo: "她要 Moonblast。按了调制，等满 5 秒再停，还要加冰。",
                reactions: ["moonblast": .secondMoonblast],
                other: .secondOther
            )
        )
    }

    func testTheMemosAreTheProducersNotesToSelfThatFitWhileMixing() throws {
        for (id, drink) in [(BarTutorialSectionID.lesson1, "Sugar Rush"), (.lesson2, "Moonblast")] {
            guard case let .mixer(memo, _, _) = BarTutorialLines.section(id).then else {
                return XCTFail("\(id) opens no counter")
            }
            XCTAssertTrue(memo.contains(drink), "\(id)")
            XCTAssertLessThanOrEqual(rows(memo), 4, memo)
        }
    }

    func testEverySectionIsWalkedToAndEveryPathLeadsToTheEnding() {
        XCTAssertEqual(reachable(from: BarTutorialLines.start), Set(sections))
        let tail: [BarTutorialSectionID] = [.closing, .jukebox]
        XCTAssertEqual(
            path(["sugar-rush", "moonblast"]),
            [.opening, .lesson1, .firstSugarRush, .lesson2, .secondMoonblast] + tail
        )
        XCTAssertEqual(Array(path(["sugar-rush", "sugar-rush"]).suffix(3)), [.secondOther] + tail)
        XCTAssertEqual(
            path(["blue-fairy", "moonblast"]),
            [.opening, .lesson1, .firstOther, .lesson2, .secondMoonblast] + tail
        )
        XCTAssertEqual(Array(path(["blue-fairy", "piano-man"]).suffix(3)), [.secondOther] + tail)
    }

    func testPianoManForTheFirstSkipsTheSecondLessonAndNothingTellsOfIt() {
        XCTAssertEqual(path(["piano-man"]), [.opening, .lesson1, .firstPianoMan, .closing, .jukebox])
        func said(_ id: BarTutorialSectionID) -> String {
            BarTutorialLines.section(id).lines
                .map { ($0.who == .her ? $0.ja : "") + $0.zh }
                .joined()
        }
        let pattern = "ムーンブラスト|Moonblast|ブレンド|调和|もう一杯|再来一杯"
        for id in [BarTutorialSectionID.firstPianoMan, .closing, .jukebox] {
            XCTAssertNil(said(id).range(of: pattern, options: .regularExpression), "\(id)")
        }
    }

    /// 不讲讨厌的口味、上得最好、醉的门槛、电视、快捷键、离开。
    func testLeavesOutWhatItDoesNotTeach() {
        let all = sections.map { id -> String in
            let section = BarTutorialLines.section(id)
            let memo = if case let .mixer(memo, _, _) = section.then { memo } else { "" }
            return ([memo] + section.lines.map { ($0.who == .her ? [$0.ja, $0.zh] : [$0.zh]).joined() })
                .joined(separator: "\n")
        }.joined(separator: "\n")
        XCTAssertNil(
            all.range(of: "讨厌|苦手|嫌い|最好|ベスト|门槛|電視|电视|テレビ|快捷键|キーボード|键盘|Shift|离开|退出",
                      options: .regularExpression)
        )
    }

    func testTheJukeboxLinesSayTheTwelveComeFirst() {
        let said = BarTutorialLines.section(.jukebox).lines.map(\.zh).joined()
        XCTAssertNotNil(said.range(of: "12 首", options: .regularExpression))
    }
}
