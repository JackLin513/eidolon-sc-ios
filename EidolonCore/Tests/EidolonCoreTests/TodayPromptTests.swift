import Foundation
import XCTest
@testable import EidolonCore

/// What she is told of the day it is in Tokyo, kept word for word with upstream `today.py`
/// (ADR-0004): her birthday, the others' birthdays in idol order, Japan's holiday, and the
/// live days she stood on in years before. Pure functions, no network.
final class TodayPromptTests: XCTestCase {
    private func day(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: text), "bad date \(text)")
    }

    private func character(
        _ id: String,
        _ name: String,
        idolID: Int? = nil,
        birthday: String? = nil
    ) -> CharacterConfig {
        CharacterConfig(
            id: id,
            name: name,
            idolID: idolID,
            birthday: birthday.flatMap(Birthday.init)
        )
    }

    private func live(
        _ name: String,
        _ days: [(date: String, venue: String)],
        performers: [String] = ["櫻木真乃"]
    ) -> WorldSetting.Live {
        WorldSetting.Live(
            name: name,
            days: days.map {
                WorldSetting.LiveDay(
                    date: $0.date,
                    venue: $0.venue,
                    performers: performers,
                    absent: nil
                )
            }
        )
    }

    private let herBirthdayLine =
        "今天是你的生日。可以自然地提起一两次，不要每句都提；不向制作人要礼物；制作人祝福你就接受。"

    // MARK: - Her birthday

    func testSheAlwaysKnowsHerBirthday() {
        XCTAssertEqual(
            TodayPrompt.herBirthday(Birthday(month: 4, day: 25)),
            "你的生日是4月25日。"
        )
    }

    func testHerBirthdayIsToldOnlyOnTheDay() throws {
        let mano = character("mano", "櫻木真乃", idolID: 1, birthday: "04-25")
        let onTheDay = TodayPrompt.lines(
            now: try day("2026-04-25T10:05:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: []
        )
        XCTAssertEqual(onTheDay, [herBirthdayLine])

        let theNextDay = TodayPrompt.lines(
            now: try day("2026-04-26T10:05:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: []
        )
        XCTAssertEqual(theNextDay, [])
    }

    func testFebruary29BirthdayFallsOnFebruary28InACommonYear() throws {
        let character = character("mano", "櫻木真乃", birthday: "02-29")
        let commonYear = TodayPrompt.lines(
            now: try day("2027-02-28T12:00:00+09:00"),
            character: character,
            characters: [character],
            herLives: []
        )
        XCTAssertEqual(commonYear, [herBirthdayLine])

        let leapYear = TodayPrompt.lines(
            now: try day("2028-02-28T12:00:00+09:00"),
            character: character,
            characters: [character],
            herLives: []
        )
        XCTAssertEqual(leapYear, [])

        let leapDay = TodayPrompt.lines(
            now: try day("2028-02-29T12:00:00+09:00"),
            character: character,
            characters: [character],
            herLives: []
        )
        XCTAssertEqual(leapDay, [herBirthdayLine])
    }

    // MARK: - The others

    func testOthersBirthdaysAreListedInIdolOrderWithoutHer() throws {
        let mano = character("mano", "櫻木真乃", idolID: 1, birthday: "12-25")
        let staff = character("hazuki", "七草はづき", idolID: 91, birthday: "12-25")
        let tenka = character("tenka", "大崎甜花", idolID: 15, birthday: "12-25")
        let amana = character("amana", "大崎甘奈", idolID: 14, birthday: "12-25")
        // Out of idol order on purpose: the line lists them by number, her excluded.
        let characters = [staff, tenka, mano, amana]

        let lines = TodayPrompt.lines(
            now: try day("2026-12-25T12:00:00+09:00"),
            character: mano,
            characters: characters,
            herLives: []
        )
        XCTAssertEqual(lines, [herBirthdayLine, "今天是大崎甘奈、大崎甜花、七草はづき的生日。你知道这件事，制作人提起时能接上；不用主动提。"])
    }

    /// Her unit mates' birthdays are the ones she may bring up herself; the other idols'
    /// she is only to know of (upstream `today.py`).
    func testUnitMatesBirthdaysAreToldApartFromTheOthers() throws {
        let mano = character("mano", "櫻木真乃", idolID: 1, birthday: "04-25")
        let hiori = character("hiori", "風野灯織", idolID: 2, birthday: "12-25")
        let amana = character("amana", "大崎甘奈", idolID: 14, birthday: "12-25")

        let lines = TodayPrompt.lines(
            now: try day("2026-12-25T12:00:00+09:00"),
            character: mano,
            characters: [mano, hiori, amana],
            unitMates: ["風野灯織"],
            herLives: []
        )
        XCTAssertEqual(lines, [
            "今天是你的组合伙伴風野灯織的生日。可以顺口提一句，不要替她们向制作人要祝福，也不要催制作人做什么。",
            "今天是大崎甘奈的生日。你知道这件事，制作人提起时能接上；不用主动提。",
        ])
    }

    func testOthersWithoutAnIdolNumberComeFirstAsGiven() throws {
        let mano = character("mano", "櫻木真乃", idolID: 2, birthday: "02-02")
        let first = character("first", "甲", birthday: "01-01")
        let second = character("second", "乙", birthday: "01-01")
        let numbered = character("numbered", "丙", idolID: 1, birthday: "01-01")

        let lines = TodayPrompt.lines(
            now: try day("2026-01-01T12:00:00+09:00"),
            character: mano,
            characters: [numbered, second, mano, first],
            herLives: []
        )
        // Numbered idols come after those without a number, who keep the order given.
        XCTAssertEqual(lines, ["今天是乙、甲、丙的生日。你知道这件事，制作人提起时能接上；不用主动提。"])
    }

    // MARK: - Holidays

    func testHolidayIsToldOnItsDay() throws {
        let mano = character("mano", "櫻木真乃", birthday: "04-25")
        let holidays = HolidayTable(names: ["2026-11-03": "文化の日"])
        let lines = TodayPrompt.lines(
            now: try day("2026-11-03T12:00:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: [],
            holidays: holidays
        )
        XCTAssertEqual(lines, ["今天是日本的节假日：文化の日。制作人提起再说，不用主动提。"])

        let otherDay = TodayPrompt.lines(
            now: try day("2026-11-04T12:00:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: [],
            holidays: holidays
        )
        XCTAssertEqual(otherDay, [])
    }

    // MARK: - Live days in years before

    func testPastLiveDayOnThisDayIsToldAsPast() throws {
        let mano = character("mano", "櫻木真乃", birthday: "04-25")
        let tour = live(
            "3rd LIVE TOUR PIECE ON PLANET",
            [
                ("2021-04-03", "日本ガイシホール"),
                ("2021-04-04", "日本ガイシホール"),
                ("2021-04-24", "東京ガーデンシアター"),
                ("2021-04-25", "東京ガーデンシアター"),
            ]
        )
        let lines = TodayPrompt.lines(
            now: try day("2026-04-25T10:05:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: [(tour, tour.days)]
        )
        XCTAssertEqual(
            lines,
            [herBirthdayLine]
                + ["今天是5年前你站上「3rd LIVE TOUR PIECE ON PLANET」第4天的日子"
                    + "（2021年4月25日，東京ガーデンシアター）。那是过去的事，今天没有这场演出；"
                    + "可以当回忆顺口提一句，不要说成今天的事。"]
        )
    }

    func testSingleDayLiveHasNoDayNumber() throws {
        let mano = character("mano", "櫻木真乃", birthday: "04-25")
        let party = live("SUMMER PARTY 2019", [("2019-08-18", "パシフィコ横浜国立大ホール")])
        let lines = TodayPrompt.lines(
            now: try day("2026-08-18T10:05:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: [(party, party.days)]
        )
        XCTAssertEqual(
            lines,
            ["今天是7年前你站上「SUMMER PARTY 2019」的日子"
                + "（2019年8月18日，パシフィコ横浜国立大ホール）。那是过去的事，今天没有这场演出；"
                + "可以当回忆顺口提一句，不要说成今天的事。"]
        )
    }

    func testSameDayLiveDaysAreEarliestFirst() throws {
        let mano = character("mano", "櫻木真乃", birthday: "04-25")
        let later = live("LATER", [("2021-04-25", "東京ガーデンシアター")])
        let earlier = live("EARLIER", [("2019-04-25", "東京ドーム")])
        let lines = TodayPrompt.lines(
            now: try day("2026-04-25T10:05:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: [(later, later.days), (earlier, earlier.days)]
        )
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[1].hasPrefix("今天是7年前你站上「EARLIER」"))
        XCTAssertTrue(lines[2].hasPrefix("今天是5年前你站上「LATER」"))
    }

    func testThisYearAndLaterLiveDaysAreNotTold() throws {
        let mano = character("mano", "櫻木真乃", birthday: "04-25")
        let todayLive = live("TODAY", [("2026-04-25", "Kアリーナ横浜")])
        let lines = TodayPrompt.lines(
            now: try day("2026-04-25T10:05:00+09:00"),
            character: mano,
            characters: [mano],
            herLives: [(todayLive, todayLive.days)]
        )
        XCTAssertEqual(lines, [herBirthdayLine])
    }

    // MARK: - Order and the day she lives by

    func testOrderFollowsUpstream() throws {
        let mano = character("mano", "櫻木真乃", idolID: 1, birthday: "04-25")
        let hiori = character("hiori", "風野灯織", idolID: 2, birthday: "04-25")
        let tour = live("TOUR", [("2021-04-25", "東京ガーデンシアター")])
        let lines = TodayPrompt.lines(
            now: try day("2026-04-25T10:05:00+09:00"),
            character: mano,
            characters: [mano, hiori],
            herLives: [(tour, tour.days)],
            holidays: HolidayTable(names: ["2026-04-25": "テストの日"])
        )
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0], herBirthdayLine)
        XCTAssertEqual(lines[1], "今天是風野灯織的生日。你知道这件事，制作人提起时能接上；不用主动提。")
        XCTAssertEqual(lines[2], "今天是日本的节假日：テストの日。制作人提起再说，不用主动提。")
        XCTAssertTrue(lines[3].hasPrefix("今天是5年前你站上「TOUR」"))
    }

    func testTheDayIsTokyoWhicheverZoneTheProducerIsIn() throws {
        let mano = character("mano", "櫻木真乃", birthday: "04-25")
        // 15:30 UTC on 2 November is already 3 November in Tokyo.
        let lines = TodayPrompt.lines(
            now: try day("2026-11-02T15:30:00Z"),
            character: mano,
            characters: [mano],
            herLives: [],
            holidays: HolidayTable(names: ["2026-11-03": "文化の日"])
        )
        XCTAssertEqual(lines, ["今天是日本的节假日：文化の日。制作人提起再说，不用主动提。"])
    }

    // MARK: - Where the lines sit in the prompt

    func testTodayLinesComeAfterTheAffinityLines() throws {
        let text = NowPrompt.text(
            now: try day("2026-11-03T12:00:00+09:00"),
            timeZone: TodayPrompt.tokyo,
            talking: .typing,
            affinityLines: ["好感的一行"],
            lastContact: nil,
            birthday: nil,
            todayLines: ["今天的一行"]
        )
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.suffix(2)), ["好感的一行", "今天的一行"])
    }
}
