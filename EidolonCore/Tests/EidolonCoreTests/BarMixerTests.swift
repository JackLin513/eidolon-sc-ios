import Foundation
import XCTest
@testable import EidolonCore

/// The bar counter (upstream `lib/barMixer.ts` and its vitest).
final class BarMixerTests: XCTestCase {
    /// The content bundle's catalog, in file order.
    private func catalog() throws -> [Drink] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "drinks", withExtension: "json", subdirectory: "Resources")
        )
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return try DrinkCatalog(json: json).drinks
    }

    private func drink(_ id: String, _ drinks: [Drink]) throws -> Drink {
        try XCTUnwrap(drinks.first { $0.id == id }, id)
    }

    /// The mixer with `parts` put in, on ice and aged as given.
    private func filled(
        _ parts: [Ingredient: Int], ice: Bool = false, aged: Bool = false
    ) -> BarMixer.State {
        var state = BarMixer.empty
        for ingredient in Ingredient.allCases {
            for _ in 0..<(parts[ingredient] ?? 0) {
                state = BarMixer.apply(state, .add(ingredient))
            }
        }
        if ice { state = BarMixer.apply(state, .ice) }
        if aged { state = BarMixer.apply(state, .aged) }
        return state
    }

    /// `state` shaken for `milliseconds` and stopped.
    private func shaken(
        _ state: BarMixer.State, _ milliseconds: Double, garble: String = "##20%!!",
        drinks: [Drink]
    ) -> BarMixer.State {
        let started = BarMixer.apply(state, .shake(now: 1))
        return BarMixer.apply(
            started, .stop(now: 1 + milliseconds / 1000, drinks: drinks, garble: garble)
        )
    }

    /// The recipe of a mixed drink put in, `times` over, optional Karmotrine as `k` parts.
    private func recipeOf(
        _ drink: Drink, times: Int = 1, k: Int = 0, _ drinks: [Drink]
    ) throws -> BarMixer.State {
        let recipe = try XCTUnwrap(drink.recipe, drink.id)
        let karmotrine = recipe.karmotrine.map { $0 * times } ?? k
        let parts: [Ingredient: Int] = [
            .adelhyde: recipe.adelhyde * times,
            .bronsonExtract: recipe.bronsonExtract * times,
            .powderedDelta: recipe.powderedDelta * times,
            .flanergide: recipe.flanergide * times,
            .karmotrine: karmotrine,
        ]
        let filling = filled(parts, ice: recipe.ice, aged: recipe.aged)
        let milliseconds = recipe.method == .blend
            ? BarMixer.fastAfter * 1000 : BarMixer.fastAfter * 1000 - 1
        return shaken(filling, milliseconds, drinks: drinks)
    }

    private func ids(_ served: Served?) -> [String] {
        guard let served else { return ["nil"] }
        return [served.drink.id, served.big ? "big" : "small"]
    }

    // MARK: - 加料

    func testPartsGoInOneAtATimeUpToTwentyInAll() throws {
        var state = filled([.adelhyde: 15, .karmotrine: 5])
        XCTAssertEqual(state.parts(.adelhyde), 15)
        XCTAssertEqual(state.parts(.karmotrine), 5)
        let full = state
        state = BarMixer.apply(state, .add(.flanergide))
        XCTAssertEqual(state, full)
        XCTAssertEqual(BarMixer.totalParts(full), BarMixer.capacity)
    }

    func testAPartComesOutDownToNone() {
        let one = filled([.bronsonExtract: 1])
        let none = BarMixer.apply(one, .remove(.bronsonExtract))
        XCTAssertEqual(none.parts(.bronsonExtract), 0)
        XCTAssertEqual(BarMixer.apply(none, .remove(.bronsonExtract)), none)
    }

    func testIceAndAgeingAreSwitched() {
        let on = filled([:], ice: true, aged: true)
        XCTAssertTrue(on.ice)
        XCTAssertTrue(on.aged)
        let off = BarMixer.apply(BarMixer.apply(on, .ice), .aged)
        XCTAssertFalse(off.ice)
        XCTAssertFalse(off.aged)
    }

    func testOnceShakingNothingGoesInOrOutAndIceAndAgeingAreFixed() {
        let shaking = BarMixer.apply(filled([.adelhyde: 2]), .shake(now: 0))
        for action in [
            BarMixer.Action.add(.adelhyde), .remove(.adelhyde), .ice, .aged,
        ] {
            XCTAssertEqual(BarMixer.apply(shaking, action), shaking, "\(action)")
        }
    }

    // MARK: - 摇

    func testAnEmptyShakerIsNotShaken() {
        let empty = BarMixer.empty
        XCTAssertEqual(BarMixer.apply(empty, .shake(now: 0)), empty)
    }

    func testUnderFiveSecondsIsMixedAndFiveOnBlended() throws {
        let shaking = BarMixer.apply(filled([.adelhyde: 2, .powderedDelta: 1]), .shake(now: 1000))
        XCTAssertEqual(BarMixer.shakeStage(shaking, now: 1000 + BarMixer.fastAfter - 1), .slow)
        XCTAssertEqual(BarMixer.shakeStage(shaking, now: 1000 + BarMixer.fastAfter), .fast)
        let mixed = shaken(filled([.adelhyde: 2, .powderedDelta: 1]), BarMixer.fastAfter * 1000 - 1,
                           drinks: try catalog())
        XCTAssertEqual(mixed.method, .mix)
        let blended = shaken(filled([.adelhyde: 2, .powderedDelta: 1]), BarMixer.fastAfter * 1000,
                             drinks: try catalog())
        XCTAssertEqual(blended.method, .blend)
        XCTAssertEqual(BarMixer.shakeStage(.init(), now: 0), .still)
        XCTAssertEqual(
            BarMixer.shakeStage(shaken(filled([.adelhyde: 1]), 0, drinks: try catalog()), now: 99_999),
            .stopped
        )
    }

    func testStillItCannotBeStopped() throws {
        let still = filled([.adelhyde: 1])
        XCTAssertEqual(BarMixer.apply(still, .stop(now: 0, drinks: try catalog(), garble: "")), still)
    }

    func testResetPoursItAllAwayAndAnEmptyOneIsNotPoured() {
        let made = shaken(filled([.adelhyde: 2, .powderedDelta: 1], ice: true), 10, drinks: [])
        let poured = BarMixer.apply(made, .reset)
        XCTAssertEqual(poured, BarMixer.empty)
        XCTAssertEqual(BarMixer.apply(poured, .reset), poured)
        XCTAssertEqual(BarMixer.apply(filled([:], aged: true), .reset), BarMixer.empty)
    }

    // MARK: - 匹配

    func testTheCatalogIsTheOriginalsTwentyFourMixedAndFourBottled() throws {
        let drinks = try catalog()
        XCTAssertEqual(drinks.filter { $0.recipe != nil }.count, 24)
        XCTAssertEqual(drinks.filter(\.isBottled).count, 4)
    }

    func testEveryRecipeMatchesItsOwnDrink() throws {
        let drinks = try catalog()
        for one in drinks where one.recipe != nil {
            let made = try recipeOf(one, drinks).made
            XCTAssertEqual(ids(made), [one.id, "small"], one.id)
        }
    }

    func testEveryDrinkThatIsNotBigDoubledIsItsBigGlass() throws {
        let drinks = try catalog()
        for one in drinks where one.doubles {
            let made = try recipeOf(one, times: 2, drinks).made
            XCTAssertEqual(ids(made), [one.id, "big"], one.id)
        }
    }

    func testADrinkBigAlreadyHasNoDoubledOne() throws {
        let drinks = try catalog()
        let bigs = drinks.filter { $0.recipe?.big == true }
        XCTAssertEqual(bigs.map(\.id).sorted(), ["marsblast", "piano-man", "piano-woman", "zen-star"])
        for one in bigs {
            let made = try recipeOf(one, drinks).made
            XCTAssertEqual(ids(made), [one.id, "small"], one.id)
            let recipe = try XCTUnwrap(one.recipe)
            let doubled = Mixture(
                adelhyde: recipe.adelhyde * 2, bronsonExtract: recipe.bronsonExtract * 2,
                powderedDelta: recipe.powderedDelta * 2, flanergide: recipe.flanergide * 2,
                karmotrine: (recipe.karmotrine ?? 0) * 2, ice: recipe.ice, aged: recipe.aged,
                method: recipe.method
            )
            XCTAssertNil(BarMixer.matchDrink(drinks, doubled), one.id)
        }
    }

    func testOptionalKarmotrineMakesTheDrinkHoweverManyParts() throws {
        let drinks = try catalog()
        let sugar = try drink("sugar-rush", drinks)
        XCTAssertEqual(ids(try recipeOf(sugar, k: 5, drinks).made), [sugar.id, "small"])
        XCTAssertEqual(ids(try recipeOf(sugar, times: 2, k: 3, drinks).made), [sugar.id, "big"])
    }

    func testAPartOfTheRecipeOffBreaksIt() throws {
        let drinks = try catalog()
        let sugar: [Ingredient: Int] = [.adelhyde: 2, .powderedDelta: 1]
        XCTAssertNotNil(shaken(filled(sugar), 10, drinks: drinks).made)
        XCTAssertNil(shaken(filled([.adelhyde: 2, .powderedDelta: 1, .flanergide: 1]), 10, drinks: drinks).made)
        XCTAssertNil(shaken(filled(sugar, ice: true), 10, drinks: drinks).made)
        // Sugar Rush aged is Sparkle Star.
        XCTAssertEqual(shaken(filled(sugar, aged: true), 10, drinks: drinks).made?.drink.id, "sparkle-star")
        XCTAssertNil(shaken(filled(sugar), BarMixer.fastAfter * 1000, drinks: drinks).made)
        // Moonblast's Karmotrine is not optional: one part off is not it.
        let moon: [Ingredient: Int] = [.adelhyde: 6, .powderedDelta: 1, .flanergide: 1, .karmotrine: 1]
        XCTAssertNil(shaken(filled(moon, ice: true), BarMixer.fastAfter * 1000, drinks: drinks).made)
    }

    func testTheHiddenFlamingMoaiIsNotInTheCatalogAndBreaks() throws {
        let parts: [Ingredient: Int] = [
            .adelhyde: 1, .bronsonExtract: 1, .powderedDelta: 2, .flanergide: 3, .karmotrine: 5,
        ]
        XCTAssertNil(shaken(filled(parts), 10, drinks: try catalog()).made)
    }

    // MARK: - 瓶装

    func testABottleGoesInOnlyAnEmptyShaker() throws {
        let drinks = try catalog()
        let absinthe = try drink("absinthe", drinks)
        let withBottle = BarMixer.apply(BarMixer.empty, .bottle(absinthe))
        XCTAssertEqual(withBottle.bottle, absinthe)
        let notEmpty = filled([.adelhyde: 1])
        XCTAssertEqual(BarMixer.apply(notEmpty, .bottle(absinthe)), notEmpty)
        XCTAssertEqual(BarMixer.apply(withBottle, .bottle(try drink("rum", drinks))), withBottle)
        let iced = filled([:], ice: true)
        XCTAssertEqual(BarMixer.apply(iced, .bottle(absinthe)), iced)
    }

    func testAMixedDrinkIsNotBroughtIn() throws {
        let drinks = try catalog()
        let empty = BarMixer.empty
        XCTAssertEqual(BarMixer.apply(empty, .bottle(try drink("beer", drinks))), empty)
    }

    func testAfterABottleNothingGoesInAndResetPoursItAway() throws {
        let drinks = try catalog()
        let withBottle = BarMixer.apply(BarMixer.empty, .bottle(try drink("absinthe", drinks)))
        for action in [BarMixer.Action.add(.karmotrine), .ice, .aged, .shake(now: 0)] {
            XCTAssertEqual(BarMixer.apply(withBottle, action), withBottle, "\(action)")
        }
        XCTAssertEqual(BarMixer.apply(withBottle, .reset), BarMixer.empty)
    }

    // MARK: - 上酒

    func testOnlyStoppedAndNotBrokenIsServedAndABottleAsSoonAsItIsIn() throws {
        let drinks = try catalog()
        let mixture = filled([.adelhyde: 2, .powderedDelta: 1])
        XCTAssertFalse(BarMixer.canServe(mixture))
        XCTAssertFalse(BarMixer.canServe(BarMixer.apply(mixture, .shake(now: 0))))
        XCTAssertTrue(BarMixer.canServe(shaken(mixture, 10, drinks: drinks)))
        XCTAssertFalse(BarMixer.canServe(shaken(filled([.adelhyde: 1]), 10, drinks: drinks)))
        XCTAssertTrue(
            BarMixer.canServe(BarMixer.apply(BarMixer.empty, .bottle(try drink("rum", drinks))))
        )
    }

    func testWhatIsServedOfAMixtureIsItsPartsIceAgeingAndMethod() throws {
        let moon = filled([.adelhyde: 6, .powderedDelta: 1, .flanergide: 1, .karmotrine: 2], ice: true)
        let served = BarMixer.served(shaken(moon, 6000, drinks: try catalog())).mixture

        XCTAssertEqual(
            served,
            Mixture(
                adelhyde: 6, bronsonExtract: 0, powderedDelta: 1, flanergide: 1, karmotrine: 2,
                ice: true, aged: false, method: .blend
            )
        )
    }

    func testWhatIsServedOfABottleIsTheBottle() throws {
        let drinks = try catalog()
        let state = BarMixer.apply(BarMixer.empty, .bottle(try drink("a-fedora", drinks)))

        XCTAssertEqual(BarMixer.served(state).bottle, "a-fedora")
        XCTAssertNil(BarMixer.served(state).mixture)
    }

    func testBrokenAsTheBarFoundItShowsItsGarble() throws {
        let made = shaken(filled([.adelhyde: 2, .powderedDelta: 1]), 10, drinks: try catalog())
        let broken = BarMixer.apply(made, .broken(garble: "%%!!?#0"))
        XCTAssertNil(broken.made)
        XCTAssertFalse(BarMixer.canServe(broken))
        XCTAssertEqual(BarMixer.slotText(broken), "%%!!?#0")
        let bottled = BarMixer.apply(
            BarMixer.apply(BarMixer.empty, .bottle(try drink("rum", try catalog()))),
            .broken(garble: "@@")
        )
        XCTAssertNil(bottled.bottle)
        XCTAssertNil(bottled.made)
        XCTAssertFalse(BarMixer.canServe(bottled))
    }

    // MARK: - 份数槽写什么

    func testTheSlotSaysNothingBeforeItIsStopped() {
        XCTAssertNil(BarMixer.slotText(filled([.adelhyde: 3])))
        XCTAssertNil(BarMixer.slotText(BarMixer.apply(filled([.adelhyde: 3]), .shake(now: 0))))
    }

    func testStoppedTheSlotSaysTheShortName() throws {
        let drinks = try catalog()
        XCTAssertEqual(
            BarMixer.slotText(try recipeOf(try drink("fluffy-dream", drinks), drinks)),
            "Flff Dream"
        )
    }

    func testBrokenTheSlotSaysGarble() throws {
        let broken = shaken(filled([.adelhyde: 1]), 10, garble: "#%!0?@&", drinks: try catalog())
        XCTAssertEqual(BarMixer.slotText(broken), "#%!0?@&")
    }

    func testABottleTheSlotSaysItsShortName() throws {
        let drinks = try catalog()
        let state = BarMixer.apply(BarMixer.empty, .bottle(try drink("a-fedora", drinks)))
        XCTAssertEqual(BarMixer.slotText(state), "Plumfume")
    }
}
