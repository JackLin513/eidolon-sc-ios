import Foundation
import GRDB
import XCTest
@testable import EidolonCore

/// Gifts, draws, the backpack and the reset card (spec #63, #65).
final class GiftTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonGifts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func installedEidolon(includeGifts: Bool = true) async throws -> Eidolon {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(
            bundleAt: try Fixture.makeBundle(
                in: root,
                options: .init(includeGifts: includeGifts)
            )
        )
        return eidolon
    }

    /// A Beijing noon, so the day boundary is never in question.
    private func noon(_ day: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = GiftRules.dayTimeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return try XCTUnwrap(formatter.date(from: "\(day) 12:00"))
    }

    private func day(_ date: Date, minus days: Int = 0) -> String {
        GiftRules.day(date.addingTimeInterval(-Double(days) * 86_400))
    }

    private func setBalance(
        on eidolon: Eidolon,
        draws: Int,
        givenOn: String
    ) async throws {
        try await eidolon.userQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO gift_balances (id, draws, given_on, reset_cards)
                    VALUES (1, ?, ?, 0)
                    ON CONFLICT (id) DO UPDATE SET
                        draws = excluded.draws,
                        given_on = excluded.given_on
                    """,
                arguments: [draws, givenOn]
            )
        }
    }

    private func backpack(_ state: GiftState) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: state.backpack.map { ($0.gift.id, $0.count) })
    }

    // MARK: - The catalog

    func testInstallingABundleWithGiftsReadsTheCatalogAndLikedGifts() async throws {
        let eidolon = try await installedEidolon()
        let catalog = try await eidolon.giftCatalog()
        XCTAssertEqual(catalog?.gifts.count, Fixture.gifts.count)
        XCTAssertEqual(catalog?.gift(id: "cake")?.name, "蛋糕")
        XCTAssertEqual(catalog?.gift(id: "preserved-flower")?.rarity, .rare)

        let characters = try await eidolon.characters()
        XCTAssertEqual(
            characters.first { $0.id == "mano" }?.likedGifts,
            ["potted-plant", "black-tea"]
        )
    }

    func testABundleWithoutIllustrationsStillInstallsAndFallsBackToSymbols() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(
            bundleAt: try Fixture.makeBundle(
                in: root,
                options: .init(includeGifts: true, missingGiftArt: true)
            )
        )
        let catalog = try await eidolon.giftCatalog()
        XCTAssertNotNil(catalog?.gift(id: "preserved-flower"))
        XCTAssertNil(eidolon.giftArtURL(for: "preserved-flower"))
        XCTAssertNotNil(eidolon.giftArtURL(for: "cake"))
    }

    func testAnOlderBundleWithoutGiftsStillInstalls() async throws {
        let eidolon = try await installedEidolon(includeGifts: false)
        let catalog = try await eidolon.giftCatalog()
        XCTAssertNil(catalog)
        let state = try await eidolon.giftState()
        XCTAssertTrue(state.catalogMissing)
        XCTAssertEqual(state.draws, GiftRules.drawsPerDay)
        XCTAssertTrue(state.backpack.isEmpty)
    }

    func testADrawNeedsTheCatalog() async throws {
        let eidolon = try await installedEidolon(includeGifts: false)
        do {
            _ = try await eidolon.drawGifts(random: ScriptedGiftRandom([1, 0]))
            XCTFail("a draw without a catalog should fail")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .giftCatalogMissing)
            XCTAssertEqual(error.errorDescription, "内容包没有礼物目录")
        }
    }

    func testTheCatalogRejectsDuplicateIdentifiers() {
        let gifts = [
            Gift(id: "cake", name: "蛋糕", category: .food, rarity: .common),
            Gift(id: "cake", name: "另一块蛋糕", category: .food, rarity: .uncommon),
            Gift(id: "flower", name: "花", category: .flower, rarity: .rare),
        ]
        XCTAssertThrowsError(try GiftCatalog(gifts: gifts)) { error in
            XCTAssertTrue("\(error)".contains("重复"), "\(error)")
        }
    }

    func testEveryRarityNeedsAGiftThatIsNotRetired() {
        let gifts = [
            Gift(id: "cake", name: "蛋糕", category: .food, rarity: .common),
            Gift(id: "book", name: "书", category: .trinket, rarity: .uncommon),
            Gift(id: "flower", name: "花", category: .flower, rarity: .rare, retired: true),
        ]
        XCTAssertThrowsError(try GiftCatalog(gifts: gifts)) { error in
            XCTAssertTrue("\(error)".contains("rare"), "\(error)")
        }
    }

    func testTheCatalogRejectsABadEntry() throws {
        let uncommon: [String: JSONValue] = [
            "id": .string("book"),
            "name": .string("书"),
            "category": .string("trinket"),
            "rarity": .string("uncommon"),
        ]
        let rare: [String: JSONValue] = [
            "id": .string("flower"),
            "name": .string("花"),
            "category": .string("flower"),
            "rarity": .string("rare"),
        ]
        func parse(_ object: [String: JSONValue]) throws -> GiftCatalog {
            try GiftCatalog(
                data: JSONEncoder().encode(
                    JSONValue.object(["gifts": .array([.object(object), .object(uncommon), .object(rare)])])
                )
            )
        }
        let valid: [String: JSONValue] = [
            "id": .string("cake"),
            "name": .string("蛋糕"),
            "category": .string("food"),
            "rarity": .string("common"),
        ]
        XCTAssertNoThrow(try parse(valid))
        XCTAssertThrowsError(try parse(valid.merging(["id": .string("Cake")]) { _, new in new }))
        XCTAssertThrowsError(try parse(valid.merging(["category": .string("snack")]) { _, new in new }))
        XCTAssertThrowsError(try parse(valid.merging(["rarity": .string("legendary")]) { _, new in new }))
        XCTAssertThrowsError(try parse(valid.merging(["name": .string("  ")]) { _, new in new }))
        XCTAssertThrowsError(try parse(valid.merging(["retired": .string("yes")]) { _, new in new }))
    }

    func testLikedGiftsAreChecked() throws {
        let catalog = try GiftCatalog(gifts: [
            Gift(id: "cake", name: "蛋糕", category: .food, rarity: .common),
            Gift(id: "book", name: "书", category: .trinket, rarity: .uncommon),
            Gift(id: "flower", name: "花", category: .flower, rarity: .rare),
        ])
        func character(_ liked: [String]) -> CharacterConfig {
            CharacterConfig(id: "mano", name: "真乃", likedGifts: liked)
        }
        XCTAssertNoThrow(try catalog.validateLikedGifts([character(["cake"])]))
        XCTAssertNoThrow(try catalog.validateLikedGifts([character(["cake", "book", "flower"])]))
        XCTAssertThrowsError(try catalog.validateLikedGifts([character([])]))
        XCTAssertThrowsError(try catalog.validateLikedGifts([character(["cake", "cake"])]))
        XCTAssertThrowsError(try catalog.validateLikedGifts([character(["cake", "book", "flower", "cake"])]))
        XCTAssertThrowsError(try catalog.validateLikedGifts([character(["cake", "nope"])]))
        XCTAssertThrowsError(try catalog.validateLikedGifts([character(["flower"])]))
    }

    // MARK: - Chances

    func testAFirstReadGivesTheDaysTwoChancesAndReadingAgainGivesNone() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")

        let first = try await eidolon.giftState(at: now)
        XCTAssertFalse(first.catalogMissing)
        XCTAssertEqual(first.draws, 2)
        XCTAssertEqual(first.maxDraws, 7)
        XCTAssertEqual(first.resetCards, 0)
        XCTAssertTrue(first.backpack.isEmpty)
        XCTAssertEqual(first.nextRefill, try noon("2026-03-11").addingTimeInterval(-12 * 3600))

        let again = try await eidolon.giftState(at: now.addingTimeInterval(60))
        XCTAssertEqual(again.draws, 2, "reading twice in a day gives nothing more")
    }

    func testEachNewDayAddsTwoChancesUpToSeven() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")
        let yesterday = day(now, minus: 1)

        try await setBalance(on: eidolon, draws: 5, givenOn: yesterday)
        var state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 7)

        try await setBalance(on: eidolon, draws: 6, givenOn: yesterday)
        state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 7)

        try await setBalance(on: eidolon, draws: 7, givenOn: yesterday)
        state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 7)

        try await setBalance(on: eidolon, draws: 9, givenOn: yesterday)
        state = try await eidolon.giftState(at: now)
        XCTAssertEqual(
            state.draws,
            9,
            "chances from achievements are never brought down to the daily cap"
        )
    }

    func testAnEmptyGivenOnGivesTodaysChances() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")

        try await setBalance(on: eidolon, draws: 0, givenOn: "")
        var state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 2, "an unstamped balance gets today's chances")

        try await setBalance(on: eidolon, draws: 9, givenOn: "")
        state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 9, "an over-cap balance is not brought down")
    }

    func testMissedDaysAreGivenWhenTheProducerComesBack() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")

        try await setBalance(on: eidolon, draws: 0, givenOn: day(now, minus: 3))
        var state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 6, "three missed days give six chances")

        try await setBalance(on: eidolon, draws: 1, givenOn: day(now, minus: 30))
        state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 7)
    }

    func testDebugAddingDrawsHasNoCapAndDoesNotDraw() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")

        var draws = try await eidolon.debugAddGiftDraws(10, now: now)
        XCTAssertEqual(draws, 12, "the day's two chances are given first, then ten added")
        draws = try await eidolon.debugAddGiftDraws(1, now: now)
        XCTAssertEqual(draws, 13)

        let state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.draws, 13, "a later read never brings a debug balance down")
        XCTAssertTrue(state.backpack.isEmpty, "adding chances does not draw")
    }

    // MARK: - Drawing

    func testADrawUsesTheScriptedNumberAndStacksInTheBackpack() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")
        try await setBalance(on: eidolon, draws: 3, givenOn: day(now))

        let loaded = try await eidolon.giftCatalog()
        let catalog = try XCTUnwrap(loaded)
        let cake = try XCTUnwrap(catalog.gift(id: "cake"))
        let first = try await eidolon.drawGifts(random: ScriptedGiftRandom([1, 0]), at: now)
        XCTAssertEqual(first.results, [.gift(cake)])
        XCTAssertEqual(first.drawsLeft, 2)
        XCTAssertEqual(first.resetCards, 0)

        let second = try await eidolon.drawGifts(random: ScriptedGiftRandom([1, 0]), at: now)
        XCTAssertEqual(second.drawsLeft, 1)

        let state = try await eidolon.giftState(at: now)
        XCTAssertEqual(backpack(state)["cake"], 2)
        XCTAssertEqual(state.draws, 1)

        _ = try await eidolon.drawGifts(random: ScriptedGiftRandom([1, 1]), at: now)
        do {
            _ = try await eidolon.drawGifts(random: ScriptedGiftRandom([1, 0]), at: now)
            XCTFail("a draw with no chances should fail")
        } catch let error as EidolonError {
            XCTAssertEqual(error, .noDraws)
            XCTAssertEqual(error.errorDescription, "没有抽奖次数了")
        }
    }

    func testAResetCardIsDrawnAtTheFirstPercent() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")
        try await setBalance(on: eidolon, draws: 1, givenOn: day(now))

        let draw = try await eidolon.drawGifts(random: ScriptedGiftRandom([0]), at: now)
        XCTAssertEqual(draw.results, [.resetCard])
        XCTAssertEqual(draw.drawsLeft, 0)
        XCTAssertEqual(draw.resetCards, 1)
        let state = try await eidolon.giftState(at: now)
        XCTAssertTrue(state.backpack.isEmpty)
    }

    func testTheOddsBoundariesAreWhereTheNumbersSay() async throws {
        let eidolon = try await installedEidolon()
        let loaded = try await eidolon.giftCatalog()
        let catalog = try XCTUnwrap(loaded)

        func drawn(_ number: Int) throws -> GiftRarity? {
            let result = try Eidolon.drawOne(
                from: catalog,
                random: ScriptedGiftRandom([number, 0])
            )
            return result.gift?.rarity
        }
        XCTAssertEqual(try Eidolon.drawOne(from: catalog, random: ScriptedGiftRandom([0])), .resetCard)
        XCTAssertEqual(try drawn(1), .common)
        XCTAssertEqual(try drawn(69), .common)
        XCTAssertEqual(try drawn(70), .uncommon)
        XCTAssertEqual(try drawn(94), .uncommon)
        XCTAssertEqual(try drawn(95), .rare)
        XCTAssertEqual(try drawn(99), .rare)
    }

    func testEachGiftInARarityIsPickedByItsPoolIndex() throws {
        let cake = Gift(id: "cake", name: "蛋糕", category: .food, rarity: .common)
        let tea = Gift(id: "tea", name: "红茶", category: .drink, rarity: .common)
        let catalog = try GiftCatalog(gifts: [
            cake,
            tea,
            Gift(id: "book", name: "书", category: .trinket, rarity: .uncommon),
            Gift(id: "flower", name: "花", category: .flower, rarity: .rare),
        ])
        XCTAssertEqual(
            try Eidolon.drawOne(from: catalog, random: ScriptedGiftRandom([1, 0])),
            .gift(cake)
        )
        XCTAssertEqual(
            try Eidolon.drawOne(from: catalog, random: ScriptedGiftRandom([1, 1])),
            .gift(tea)
        )
    }

    func testRetiredGiftsAreNotInAnyDrawPool() async throws {
        let eidolon = try await installedEidolon()
        let loaded = try await eidolon.giftCatalog()
        let catalog = try XCTUnwrap(loaded)
        XCTAssertEqual(catalog.drawable(.common).map(\.id), ["cake", "black-tea"])
        XCTAssertFalse(catalog.drawable(.common).contains { $0.id == "pudding" })
    }

    func testAllDrawsUsesEveryChanceInOrder() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")
        try await setBalance(on: eidolon, draws: 3, givenOn: day(now))
        let loaded = try await eidolon.giftCatalog()
        let catalog = try XCTUnwrap(loaded)

        let draw = try await eidolon.drawGifts(
            all: true,
            random: ScriptedGiftRandom([1, 0, 0, 70, 0]),
            at: now
        )
        XCTAssertEqual(draw.results.count, 3)
        XCTAssertEqual(draw.results[0], .gift(try XCTUnwrap(catalog.gift(id: "cake"))))
        XCTAssertEqual(draw.results[1], .resetCard)
        XCTAssertEqual(draw.results[2], .gift(try XCTUnwrap(catalog.gift(id: "potted-plant"))))
        XCTAssertEqual(draw.drawsLeft, 0)
        XCTAssertEqual(draw.resetCards, 1)

        let state = try await eidolon.giftState(at: now)
        XCTAssertEqual(backpack(state), ["cake": 1, "potted-plant": 1])
    }

    func testTheBackpackKeepsCatalogOrderAcrossCategories() async throws {
        let eidolon = try await installedEidolon()
        let now = try noon("2026-03-10")
        try await setBalance(on: eidolon, draws: 3, givenOn: day(now))

        _ = try await eidolon.drawGifts(
            all: true,
            random: ScriptedGiftRandom([70, 0, 1, 0, 95, 0]),
            at: now
        )
        let state = try await eidolon.giftState(at: now)
        XCTAssertEqual(state.backpack.map(\.gift.id), ["cake", "potted-plant", "preserved-flower"])
        XCTAssertEqual(state.backpack.map(\.count), [1, 1, 1])
    }

    // MARK: - Reset card

}

/// Numbers in the order the draw asks for them, so a test can hit an odds boundary.
final class ScriptedGiftRandom: GiftRandom, @unchecked Sendable {
    private var values: [Int]
    private var next = 0

    init(_ values: [Int]) {
        self.values = values
    }

    func int(below bound: Int) -> Int {
        precondition(bound > 0)
        guard next < values.count else { return 0 }
        defer { next += 1 }
        return values[next]
    }
}
