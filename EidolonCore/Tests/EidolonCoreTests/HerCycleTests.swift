import Foundation
import XCTest
@testable import EidolonCore

/// Her cycle (spec #52): derived from a seed and a day, the one switch, and what she is told.
final class HerCycleTests: XCTestCase {
    private var root: URL!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let seed = Data((0..<32).map { UInt8($0 & 0xFF) })

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func someCycleDay(_ seed: Data, under18: Bool = false) -> CalendarDay {
        var day = HerCycle.epoch.adding(days: -60)
        while HerCycle.day(seed: seed, under18: under18, on: day) == nil {
            day = day.adding(days: 1)
        }
        return day
    }

    private func noon(_ day: CalendarDay, in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            year: day.year, month: day.month, day: day.day, hour: 12
        ))!
    }

    private func installed() async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))
        return eidolon
    }

    // MARK: - The derivation

    func testTheSameSeedAndDayAlwaysGiveTheSameAnswer() {
        let day = someCycleDay(seed)
        XCTAssertEqual(
            HerCycle.day(seed: seed, under18: false, on: day),
            HerCycle.day(seed: seed, under18: false, on: day)
        )
    }

    func testAPeriodRunsItsDaysAndTheDaysBeforeItArePremenstrual() {
        let rhythm = HerCycle.rhythm(seed: seed)
        let cycles = HerCycle.cycles(seed: seed, under18: false, from: HerCycle.epoch, count: 24)
        for cycle in cycles {
            XCTAssertEqual(
                HerCycle.day(seed: seed, under18: false, on: cycle.firstDay),
                .period(HerPeriod(day: 1, length: cycle.period, firstDay: cycle.firstDay))
            )
            let last = cycle.firstDay.adding(days: cycle.period - 1)
            XCTAssertEqual(
                HerCycle.day(seed: seed, under18: false, on: last),
                .period(HerPeriod(day: cycle.period, length: cycle.period, firstDay: cycle.firstDay))
            )
            let before = cycle.firstDay.adding(days: cycle.period)
            let daysLeft = cycle.length - cycle.period
            if daysLeft <= rhythm.premenstrualDays {
                XCTAssertEqual(
                    HerCycle.day(seed: seed, under18: false, on: before),
                    .premenstrual(Premenstrual(daysLeft: daysLeft))
                )
            } else {
                XCTAssertNil(HerCycle.day(seed: seed, under18: false, on: before))
            }
        }
    }

    func testCyclesStayWithinTheFrozenBounds() {
        let cycles = HerCycle.cycles(
            seed: seed, under18: false, from: HerCycle.epoch, count: 200
        )
        XCTAssertEqual(cycles.count, 200)
        for cycle in cycles {
            XCTAssertTrue((21...40).contains(cycle.length), "length: \(cycle.length)")
            XCTAssertTrue((3...8).contains(cycle.period), "period: \(cycle.period)")
            XCTAssertLessThan(cycle.period, cycle.length)
        }
        let rhythm = HerCycle.rhythm(seed: seed)
        XCTAssertTrue((3...5).contains(rhythm.premenstrualDays))
    }

    func testTheDaysBeforeTheEpochGoOnBackwards() {
        var day = HerCycle.epoch.adding(days: -1)
        while HerCycle.day(seed: seed, under18: false, on: day) == nil {
            day = day.adding(days: -1)
        }
        XCTAssertEqual(
            HerCycle.day(seed: seed, under18: false, on: day),
            HerCycle.day(seed: seed, under18: false, on: day)
        )
    }

    func testFebruary29AndTheLeapDayAreNotSpecial() {
        let leap = CalendarDay(year: 2028, month: 2, day: 29)
        let ordinary = CalendarDay(year: 2026, month: 2, day: 28)
        XCTAssertEqual(
            HerCycle.day(seed: seed, under18: false, on: leap),
            HerCycle.day(seed: seed, under18: false, on: leap)
        )
        XCTAssertEqual(
            HerCycle.day(seed: seed, under18: false, on: ordinary),
            HerCycle.day(seed: seed, under18: false, on: ordinary)
        )
    }

    func testAnAgeUnderEighteenIsYoungAndMissingOrInvalidIsAdult() {
        XCTAssertTrue(HerCycle.isUnder18(17))
        XCTAssertTrue(HerCycle.isUnder18(1))
        XCTAssertFalse(HerCycle.isUnder18(18))
        XCTAssertFalse(HerCycle.isUnder18(25))
        XCTAssertFalse(HerCycle.isUnder18(nil))
        XCTAssertFalse(HerCycle.isUnder18(0))
        XCTAssertFalse(HerCycle.isUnder18(-3))
    }

    // MARK: - What she is told

    func testTheFourStatesHaveTheirOwnLines() {
        let early = CyclePrompt.lines(
            .period(HerPeriod(day: 1, length: 5, firstDay: HerCycle.epoch))
        )
        XCTAssertEqual(early.first, "你今天身体很不舒服：浑身没力气，说话比平时少、慢，偶尔会走神。"
            + "身上可能发冷、腰酸、身子发沉、只想窝着不动，喝点热的会好些。")
        XCTAssertTrue(early.last?.hasPrefix("这是你自己身体的事") == true)
        XCTAssertTrue(early.last?.contains("制作人直接问到是不是那几天时") == true)

        let late = CyclePrompt.lines(
            .period(HerPeriod(day: 4, length: 5, firstDay: HerCycle.epoch))
        )
        XCTAssertEqual(
            late.first,
            "你这几天身体还有点虚：比平时容易累，不太想出门，不过已经比前两天好多了。"
        )

        let near = CyclePrompt.lines(.premenstrual(Premenstrual(daysLeft: 2)))
        XCTAssertEqual(
            near.first,
            "你这两天特别容易烦躁、委屈，小事也会在意很久，自己也说不清为什么心情不好；"
                + "身上也可能有点发胀、睡不踏实。"
        )
        XCTAssertTrue(near.last?.contains("那几天还没到，只是快了") == true)

        let far = CyclePrompt.lines(.premenstrual(Premenstrual(daysLeft: 4)))
        XCTAssertEqual(far.first, "你这几天心情有点起伏：比平时敏感，小事也容易在意。")

        XCTAssertEqual(CyclePrompt.lines(nil), [])
    }

    func testScheduleLinesComeBeforeCycleLines() {
        let text = NowPrompt.text(
            now: Date(timeIntervalSince1970: 1_760_000_000),
            timeZone: tokyo,
            talking: .typing,
            affinityLines: [],
            lastContact: nil,
            birthday: nil,
            todayLines: ["今天"],
            scheduleLines: ["日程"],
            cycleLines: ["周期"]
        )
        let today = try? XCTUnwrap(text.range(of: "今天")?.lowerBound)
        let schedule = try? XCTUnwrap(text.range(of: "日程")?.lowerBound)
        let cycle = try? XCTUnwrap(text.range(of: "周期")?.lowerBound)
        XCTAssertNotNil(today)
        XCTAssertNotNil(schedule)
        XCTAssertNotNil(cycle)
        if let today, let schedule, let cycle {
            XCTAssertTrue(today < schedule)
            XCTAssertTrue(schedule < cycle)
        }
    }

    // MARK: - The seed and the switch

    func testTheSeedIsThirtyTwoBytesKeptForEachCharacter() async throws {
        let eidolon = try await installed()
        let mano = try await eidolon.cycleSeed(characterID: "mano")
        let hiori = try await eidolon.cycleSeed(characterID: "hiori")
        XCTAssertEqual(mano?.count, 32)
        XCTAssertEqual(hiori?.count, 32)
        XCTAssertNotEqual(mano, hiori)
        let again = try await eidolon.cycleSeed(characterID: "mano")
        let nobody = try await eidolon.cycleSeed(characterID: "nobody")
        XCTAssertEqual(mano, again)
        XCTAssertNil(nobody)

        // A new app instance on the same library reads the same seed.
        let reopened = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        let reread = try await reopened.cycleSeed(characterID: "mano")
        XCTAssertEqual(mano, reread)
    }

    /// Typing, a call and reaching out read the same prompt path, which carries the cycle
    /// lines; the bar's visit prompt does not.
    func testATurnOnACycleDayIsToldOfIt() async throws {
        let eidolon = try await installed()
        let maybeStored = try await eidolon.cycleSeed(characterID: "mano")
        let stored = try XCTUnwrap(maybeStored)
        let now = noon(someCycleDay(stored), in: tokyo)
        let provider = KindChatProvider()
        provider.chat = "<ja>うん</ja><zh>嗯</zh>"
        let stream = await eidolon.sendTurn(
            characterID: "mano", text: "你好", provider: provider,
            now: now, timeZone: tokyo
        )
        for try await _ in stream {}
        let prompts = provider.prompts.flatMap { $0.map(\.content) }.joined(separator: "\n")
        XCTAssertTrue(
            prompts.contains("你今天身体很不舒服") || prompts.contains("你这几天身体还有点虚")
                || prompts.contains("你这几天心情有点起伏") || prompts.contains("你这两天特别容易烦躁"),
            prompts
        )
    }

    func testCyclesAreOnUntilSwitchedOffAndThePositionDoesNotChange() async throws {
        let eidolon = try await installed()
        let isOn = try await eidolon.cycleEnabled()
        XCTAssertTrue(isOn)
        let maybeStored = try await eidolon.cycleSeed(characterID: "mano")
        let stored = try XCTUnwrap(maybeStored)
        let now = noon(someCycleDay(stored), in: tokyo)
        let before = try await eidolon.herCycle(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertNotNil(before)
        let onLines = try await eidolon.cycleLines(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertFalse(onLines.isEmpty)

        try await eidolon.setCycleEnabled(false)
        let isOff = try await eidolon.cycleEnabled()
        XCTAssertFalse(isOff)
        let whileOff = try await eidolon.herCycle(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertNil(whileOff)
        let linesWhileOff = try await eidolon.cycleLines(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertEqual(linesWhileOff, [])

        try await eidolon.setCycleEnabled(true)
        let back = try await eidolon.herCycle(
            characterID: "mano", now: now, timeZone: tokyo
        )
        XCTAssertEqual(back, before)
    }
}
