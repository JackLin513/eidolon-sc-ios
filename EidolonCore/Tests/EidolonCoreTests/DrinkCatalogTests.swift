import Foundation
import XCTest
@testable import EidolonCore

/// The drink catalog (GLOSSARY.md「饮品」「材料」) and what the bar counter holds against it.
final class DrinkCatalogTests: XCTestCase {
    static func fixture(_ name: String) throws -> JSONValue {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Resources"))
        return try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    }

    private func catalog() throws -> DrinkCatalog {
        try DrinkCatalog(json: Self.fixture("drinks"))
    }

    // MARK: - The catalogue as upstream has it

    func testReadsTheOriginalTwentyEightDrinksInFileOrder() throws {
        let catalog = try catalog()

        XCTAssertEqual(catalog.drinks.count, 28)
        XCTAssertEqual(catalog.mixed.count, 24)
        XCTAssertEqual(catalog.drinks.first?.id, "sugar-rush")
        XCTAssertEqual(catalog.drinks.first?.nameJa, "シュガーラッシュ")
        XCTAssertEqual(catalog.drinks.filter(\.isBottled).count, 4)
    }

    func testReadsAnOptionalKarmotrineAsOptional() throws {
        let catalog = try catalog()
        let sugar = try XCTUnwrap(catalog.drink(id: "sugar-rush"))

        XCTAssertNil(sugar.recipe?.karmotrine)
        XCTAssertEqual(sugar.recipe?.method, .mix)
        XCTAssertTrue(sugar.doubles)
    }

    func testBottledDrinksCarryTheirKarmotrine() throws {
        let catalog = try catalog()
        let tea = try XCTUnwrap(catalog.drink(id: "mulan-tea"))

        XCTAssertTrue(tea.isBottled)
        XCTAssertEqual(tea.bottledKarmotrine, 0)
        XCTAssertNil(tea.page)
    }

    // MARK: - Matching what is at the counter

    func testAMixtureOfARecipeIsThatDrink() throws {
        let catalog = try catalog()
        let recipe = try XCTUnwrap(catalog.drink(id: "sugar-rush")?.recipe)

        let served = try XCTUnwrap(catalog.match(Mixture(
            adelhyde: recipe.adelhyde, bronsonExtract: recipe.bronsonExtract,
            powderedDelta: recipe.powderedDelta, flanergide: recipe.flanergide,
            karmotrine: recipe.karmotrine ?? 0, ice: recipe.ice, aged: recipe.aged,
            method: recipe.method
        )))

        XCTAssertEqual(served.drink.id, "sugar-rush")
        XCTAssertFalse(served.big)
    }

    func testEveryPartDoubledIsTheBigGlassWithItsKarmotrineDoubled() throws {
        let catalog = try catalog()
        let recipe = try XCTUnwrap(catalog.drink(id: "bad-touch")?.recipe)
        let karmotrine = try XCTUnwrap(recipe.karmotrine)

        let served = try XCTUnwrap(catalog.match(Mixture(
            adelhyde: recipe.adelhyde * 2, bronsonExtract: recipe.bronsonExtract * 2,
            powderedDelta: recipe.powderedDelta * 2, flanergide: recipe.flanergide * 2,
            karmotrine: karmotrine * 2, ice: recipe.ice, aged: recipe.aged,
            method: recipe.method
        )))

        XCTAssertEqual(served.drink.id, "bad-touch")
        XCTAssertTrue(served.big)
        XCTAssertEqual(served.karmotrine, karmotrine * 2)
    }

    func testADrinkBigAlreadyHasNoDoubledGlass() throws {
        let catalog = try catalog()
        let piano = try XCTUnwrap(catalog.drink(id: "piano-man")?.recipe)
        XCTAssertTrue(piano.big)
        XCTAssertFalse(try XCTUnwrap(catalog.drink(id: "piano-man")).doubles)

        let doubled = catalog.match(Mixture(
            adelhyde: piano.adelhyde * 2, bronsonExtract: piano.bronsonExtract * 2,
            powderedDelta: piano.powderedDelta * 2, flanergide: piano.flanergide * 2,
            karmotrine: (piano.karmotrine ?? 0) * 2, ice: piano.ice, aged: piano.aged,
            method: piano.method
        ))

        XCTAssertNil(doubled, "Piano Man has no doubled glass")
    }

    func testWhereKarmotrineIsOptionalAnyAmountIsStillThatDrink() throws {
        let catalog = try catalog()
        let sugar = try XCTUnwrap(catalog.drink(id: "sugar-rush")?.recipe)

        for karmotrine in [0, 1, 4] {
            let served = try XCTUnwrap(catalog.match(Mixture(
                adelhyde: sugar.adelhyde, bronsonExtract: sugar.bronsonExtract,
                powderedDelta: sugar.powderedDelta, flanergide: sugar.flanergide,
                karmotrine: karmotrine, ice: sugar.ice, aged: sugar.aged, method: sugar.method
            )))
            XCTAssertEqual(served.drink.id, "sugar-rush")
            XCTAssertEqual(served.karmotrine, karmotrine)
            XCTAssertEqual(served.alcoholic, karmotrine > 0)
        }
    }

    func testAGlassOtherwiseThanTheRecipeIsBroken() throws {
        let catalog = try catalog()
        let beer = try XCTUnwrap(catalog.drink(id: "beer")?.recipe)

        // The ice, the ageing and the method are all part of the recipe.
        XCTAssertNil(catalog.match(Mixture(
            adelhyde: beer.adelhyde, bronsonExtract: beer.bronsonExtract,
            powderedDelta: beer.powderedDelta, flanergide: beer.flanergide,
            ice: !beer.ice, aged: beer.aged, method: beer.method
        )))
        XCTAssertNil(catalog.match(Mixture(
            adelhyde: beer.adelhyde, bronsonExtract: beer.bronsonExtract,
            powderedDelta: beer.powderedDelta, flanergide: beer.flanergide,
            ice: beer.ice, aged: beer.aged, method: .blend
        )))
        XCTAssertNil(catalog.match(Mixture(
            adelhyde: beer.adelhyde + 1, bronsonExtract: beer.bronsonExtract,
            powderedDelta: beer.powderedDelta, flanergide: beer.flanergide,
            ice: beer.ice, aged: beer.aged, method: beer.method
        )))
    }

    func testAMixtureOverWhatTheMixerHoldsIsBroken() throws {
        let catalog = try catalog()

        XCTAssertNil(catalog.match(Mixture(adelhyde: 21)))
        XCTAssertNil(catalog.match(Mixture(adelhyde: 10, bronsonExtract: 10, karmotrine: 1)))
        XCTAssertNil(catalog.match(Mixture(adelhyde: -1)))
    }

    func testABottleIsServedAsItIs() throws {
        let catalog = try catalog()

        let served = try XCTUnwrap(catalog.match(bottle: "mulan-tea"))
        XCTAssertEqual(served.drink.id, "mulan-tea")
        XCTAssertFalse(served.big)
        XCTAssertFalse(served.alcoholic)

        // Only bottled drinks, and only ones there are.
        XCTAssertNil(catalog.match(bottle: "sugar-rush"))
        XCTAssertNil(catalog.match(bottle: "no-such-drink"))
    }

    func testTheFlamingMoaiIsNotInTheCatalog() throws {
        let catalog = try catalog()

        XCTAssertNil(catalog.drink(id: "flaming-moai"))
        XCTAssertNil(catalog.match(bottle: "flaming-moai"))
    }

    // MARK: - Broken content is refused

    func testRefusesTwoDrinksWhoseRecipesOverlap() throws {
        let drink = Drink(
            id: "one", name: "One", nameJa: "ワン", shortName: "One", flavor: .sweet,
            kind: .girly, description: "一",
            recipe: Recipe(
                adelhyde: 1, bronsonExtract: 0, powderedDelta: 0, flanergide: 0,
                karmotrine: nil, ice: true, aged: false, method: .mix
            )
        )
        let other = Drink(
            id: "two", name: "Two", nameJa: "ツー", shortName: "Two", flavor: .bitter,
            kind: .manly, description: "二",
            recipe: Recipe(
                adelhyde: 1, bronsonExtract: 0, powderedDelta: 0, flanergide: 0,
                karmotrine: 3, ice: true, aged: false, method: .mix
            )
        )

        XCTAssertThrowsError(try DrinkCatalog(drinks: [drink, other])) { error in
            XCTAssertTrue("\(error)".contains("配方重合"))
        }
    }

    func testOverlappingBigGlassesAreRefusedToo() throws {
        let recipe = Recipe(
            adelhyde: 1, bronsonExtract: 0, powderedDelta: 0, flanergide: 0,
            karmotrine: 0, ice: false, aged: false, method: .mix
        )
        let one = Drink(
            id: "one", name: "One", nameJa: "ワン", shortName: "One", flavor: .sweet,
            kind: .girly, description: "一", recipe: recipe
        )
        let two = Drink(
            id: "two", name: "Two", nameJa: "ツー", shortName: "Two", flavor: .bitter,
            kind: .manly, description: "二", recipe: recipe
        )

        XCTAssertThrowsError(try DrinkCatalog(drinks: [one, two]))
    }

    func testRefusesADrinkMissingWhatItNeeds() throws {
        let json = JSONValue.object(["drinks": .array([.object(["id": .string("x")])])])

        XCTAssertThrowsError(try DrinkCatalog(json: json)) { error in
            XCTAssertTrue("\(error)".contains("缺少"))
        }
    }

    func testRefusesTwoDrinksOfOneIdentifier() throws {
        let json = try Self.fixture("drinks")
        var entries = try XCTUnwrap(json.objectValue?["drinks"]?.arrayValue)
        entries.append(try XCTUnwrap(entries.first))

        XCTAssertThrowsError(try DrinkCatalog(json: .object(["drinks": .array(entries)]))) { error in
            XCTAssertTrue("\(error)".contains("重复"))
        }
    }

    func testRefusesABigGlassOverWhatTheMixerHoldsUnlessItIsBigAlready() throws {
        let json = JSONValue.object(["drinks": .array([.object([
            "id": .string("x"), "name": .string("X"), "name_ja": .string("エックス"),
            "short_name": .string("X"), "flavor": .string("sweet"), "kind": .string("girly"),
            "description": .string("一"), "method": .string("mix"), "karmotrine": .int(10),
            "adelhyde": .int(1), "bronson_extract": .int(0), "powdered_delta": .int(0),
            "flanergide": .int(0), "ice": .bool(false), "aged": .bool(false), "page": .int(1),
        ])])])

        XCTAssertThrowsError(try DrinkCatalog(json: json)) { error in
            XCTAssertTrue("\(error)".contains("big = true"))
        }
    }
}
