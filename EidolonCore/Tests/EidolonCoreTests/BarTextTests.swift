import XCTest
@testable import EidolonCore

/// The text box: a line laid out in pages of four rows, and how much of a page is typed out
/// (upstream `lib/barText.ts` and its vitest).
final class BarTextTests: XCTestCase {
    /// Like the pixel font: CJK a whole square, the rest half of one.
    private func measure(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { sum, scalar in
            sum + (scalar.value >= 0x2e80 ? 12 : 6)
        }
    }

    private let names = BarTextNames(her: "真乃")

    private func pages(_ line: BarTextLine) -> [BarTextPage] {
        BarText.paginate(line, names: names, measure: measure)
    }

    // MARK: - 文本框分页

    func testTheProducersLineIsOneRowWithTheNameAtItsStart() {
        XCTAssertEqual(pages(.producer(zh: "欢迎光临。")), [
            BarTextPage(rows: [BarTextRow(name: "制作人：", text: "欢迎光临。", subtitle: false)]),
        ])
    }

    func testHerLineIsHerJapaneseAndThenItsChineseSubtitle() {
        XCTAssertEqual(pages(.her(ja: "こんばんは。", zh: "晚上好。")), [
            BarTextPage(rows: [
                BarTextRow(name: "真乃：", text: "こんばんは。", subtitle: false),
                BarTextRow(name: nil, text: "晚上好。", subtitle: true),
            ]),
        ])
    }

    func testALongLineWrapsAndTheNameTakesTheFirstRowsWidth() {
        // 400 wide: the first row has 「制作人：」's 48 taken off, so 29 characters fit; after
        // it 33 a row.
        let zh = String(repeating: "一", count: 29) + String(repeating: "二", count: 33)
            + String(repeating: "三", count: 5)

        XCTAssertEqual(pages(.producer(zh: zh))[0].rows.map(\.text), [
            String(repeating: "一", count: 29),
            String(repeating: "二", count: 33),
            String(repeating: "三", count: 5),
        ])
    }

    func testTheJapaneseAndTheSubtitleWrapOnTheirOwn() {
        let ja = String(repeating: "あ", count: 30) + String(repeating: "い", count: 3)
        let zh = String(repeating: "中", count: 33) + "文"

        XCTAssertEqual(
            pages(.her(ja: ja, zh: zh))[0].rows.map { [$0.text, $0.subtitle ? "1" : "0"] },
            [
                [String(repeating: "あ", count: 30), "0"],
                [String(repeating: "い", count: 3), "0"],
                [String(repeating: "中", count: 33), "1"],
                ["文", "1"],
            ]
        )
    }

    func testALatinWordIsNotBrokenButAVeryLongOneIs() {
        let zh = String(repeating: "一", count: 27) + "我要 Sugar Rush"

        XCTAssertEqual(pages(.producer(zh: zh))[0].rows.map(\.text), [
            String(repeating: "一", count: 27) + "我要",
            "Sugar Rush",
        ])
        XCTAssertEqual(
            pages(.producer(zh: String(repeating: "a", count: 70)))[0].rows.map(\.text),
            [String(repeating: "a", count: 58), String(repeating: "a", count: 12)]
        )
    }

    func testClosingPunctuationHangsPastTheRowsEnd() {
        let zh = String(repeating: "一", count: 29) + "。"

        XCTAssertEqual(pages(.producer(zh: zh))[0].rows.map(\.text), [zh])
    }

    /// It hangs into the box's 6 px margin and no further: a row already 396 wide keeps its
    /// mark for the next row rather than drawing it outside the box.
    func testClosingPunctuationHangsOnlyIntoTheBoxsMargin() {
        let zh = String(repeating: "中", count: 33) + "。"

        XCTAssertEqual(
            pages(.her(ja: "あ", zh: zh))[0].rows.map(\.text),
            ["あ", String(repeating: "中", count: 33), "。"]
        )
    }

    func testPastFourRowsItPagesAndTheRowsOnHaveNoName() {
        let ja = String(repeating: "あ", count: 30 + 33 + 33)
        let zh = String(repeating: "中", count: 40)
        let paged = pages(.her(ja: ja, zh: zh))
        let (first, second) = (paged[0], paged[1])

        XCTAssertEqual(
            first.rows.map { ["\($0.name ?? "-")", "\($0.text.count)", $0.subtitle ? "1" : "0"] },
            [["真乃：", "30", "0"], ["-", "33", "0"], ["-", "33", "0"], ["-", "33", "1"]]
        )
        XCTAssertEqual(second.rows.map { ["\($0.name ?? "-")", "\($0.text.count)", $0.subtitle ? "1" : "0"] },
                       [["-", "7", "1"]])
    }

    // MARK: - 打字

    private var producer: BarTextPage {
        pages(.producer(zh: "一二三四五六七八九十"))[0]
    }

    private var her: BarTextPage {
        pages(.her(ja: "あいうえおかきくけこ", zh: "甲乙丙丁戊"))[0]
    }

    func testThirtyCharactersASecond() {
        let typing = BarText.Typing(startedAt: 1)
        XCTAssertEqual(BarText.typedChars(producer, typing, now: 1), 0)
        XCTAssertEqual(BarText.typedChars(producer, typing, now: 1.1), 3)
        XCTAssertEqual(BarText.typedChars(producer, typing, now: 1.25), 7)
        XCTAssertEqual(BarText.typedChars(producer, typing, now: 6), 10)
    }

    func testWhenItIsTypedOut() {
        let typing = BarText.Typing(startedAt: 1)
        XCTAssertEqual(BarText.typedOutAt(producer, typing), 1.334, accuracy: 0.0005)
        XCTAssertFalse(BarText.isTypedOut(producer, typing, now: 1.333))
        XCTAssertTrue(BarText.isTypedOut(producer, typing, now: 1.334))
    }

    func testATapTypesItOutAtOnce() {
        let typing = BarText.Typing(startedAt: 1, finished: true)
        XCTAssertEqual(BarText.typedChars(producer, typing, now: 1), 10)
        XCTAssertTrue(BarText.isTypedOut(producer, typing, now: 1))
    }

    func testTheNameIsThereFromTheStartAndTheTextUpToWhatIsTyped() {
        XCTAssertEqual(BarText.shownRows(producer, typed: 3), [
            BarTextRow(name: "制作人：", text: "一二三", subtitle: false),
        ])
    }

    func testHerSubtitleKeepsPaceWithHerJapaneseAndTheTypingTakesAsLongAsTheJapanese() {
        XCTAssertEqual(BarText.typedChars(her, .init(startedAt: 0), now: 10), 10)
        XCTAssertEqual(BarText.shownRows(her, typed: 4).map(\.text), ["あいうえ", "甲乙"])
        XCTAssertEqual(BarText.shownRows(her, typed: 10).map(\.text), ["あいうえおかきくけこ", "甲乙丙丁戊"])
    }

    func testAPageOfTheSubtitleAloneTypesOutAsThat() {
        let rest = pages(.her(ja: String(repeating: "あ", count: 30 + 33 + 33), zh: String(repeating: "中", count: 40)))[1]

        XCTAssertEqual(BarText.typedChars(rest, .init(startedAt: 0), now: 10), 7)
        XCTAssertEqual(BarText.shownRows(rest, typed: 2).map(\.text), ["中中"])
    }
}
