import Foundation
import XCTest
@testable import EidolonCore

/// The recipe book: its tabs, the categories under them and the cards' order (upstream
/// `lib/barRecipeBook.ts` and its vitest, against the content bundle's own catalog).
final class BarRecipeBookTests: XCTestCase {
    private func drinks() throws -> [Drink] {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "drinks", withExtension: "json", subdirectory: "Resources")
        )
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        return try DrinkCatalog(json: json).drinks
    }

    private func names(_ tab: BarRecipeBook.Tab, _ category: String?, _ drinks: [Drink]) -> [String] {
        BarRecipeBook.drinksIn(tab, category, drinks).map(\.name)
    }

    private func click(_ drinks: [Drink], _ actions: BarRecipeBook.Action...) -> BarRecipeBook.State {
        actions.reduce(BarRecipeBook.State.cover) { BarRecipeBook.apply($0, $1, drinks) }
    }

    // MARK: - categories

    /// No 「A」: a category lists six at most, so the four bottled drinks (the only ones starting
    /// with A) never make a category of their own. Upstream's vitest still expects the 「A」 — it was
    /// written before the rule and contradicts the spec （`.scratch/bar-room`「每类最多 6 款」）;
    /// `categories` follows the spec.
    func testByNameAreTheInitialsOfTheDrinksWithACardInOrder() throws {
        XCTAssertEqual(BarRecipeBook.categories(.name, try drinks()), ["B", "C", "F", "G", "M", "P", "S", "Z"])
    }

    func testByFlavorAndByKindAreTheMenusFiveEachInItsOrder() throws {
        XCTAssertEqual(BarRecipeBook.categories(.flavor, try drinks()), ["sweet", "bitter", "sour", "spicy", "bubbly"])
        XCTAssertEqual(BarRecipeBook.categories(.kind, try drinks()), ["girly", "manly", "classic", "classy", "promo"])
    }

    func testTheBottledHaveNone() throws {
        XCTAssertEqual(BarRecipeBook.categories(.bottle, try drinks()), [])
    }

    // MARK: - drinksIn

    func testALetterListsTheDrinksItStartsByNameSixAtMost() throws {
        let drinks = try drinks()
        XCTAssertEqual(names(.name, "B", drinks), [
            "Bad Touch", "Beer", "Bleeding Jane", "Bloom Light", "Blue Fairy", "Brandtini",
        ])
        XCTAssertEqual(names(.name, "Z", drinks), ["Zen Star"])
    }

    func testAFlavorOrAKindListsItsDrinksWithACardNotTheBottled() throws {
        let drinks = try drinks()
        XCTAssertEqual(names(.flavor, "bitter", drinks), [
            "Grizzly Temple", "Gut Punch", "Piledriver", "Sunshine Cloud", "Suplex",
        ])
        XCTAssertEqual(names(.kind, "classic", drinks), ["Beer", "Bleeding Jane", "Frothy Water"])
    }

    func testNoCategoryListsMoreThanSix() throws {
        let drinks = try drinks()
        for tab in [BarRecipeBook.Tab.name, .flavor, .kind] {
            for category in BarRecipeBook.categories(tab, drinks) {
                XCTAssertLessThanOrEqual(BarRecipeBook.drinksIn(tab, category, drinks).count, 6)
            }
        }
    }

    func testTheBottledTabListsTheFourBottledDrinks() throws {
        XCTAssertEqual(names(.bottle, nil, try drinks()), ["Absinthe", "Rum", "Mulan Tea", "A Fedora"])
    }

    func testNothingBeforeACategoryIsPicked() throws {
        XCTAssertEqual(names(.flavor, nil, try drinks()), [])
    }

    // MARK: - recipeBook

    func testItGoesTabCategoryDrink() throws {
        let drinks = try drinks()
        let state = click(drinks, .tab(.kind), .category("promo"), .drink("zen-star"))

        XCTAssertEqual(state, BarRecipeBook.State(tab: .kind, category: "promo", drink: "zen-star"))
        XCTAssertEqual(BarRecipeBook.pageOf(state, drinks)?.n, 24)
        XCTAssertEqual(BarRecipeBook.pageOf(state, drinks)?.of, 24)
    }

    func testATabClickedFromAnywhereOpensItsCategoriesAndAlreadyThereChangesNothing() throws {
        let drinks = try drinks()
        let open = click(drinks, .tab(.name), .category("S"), .drink("suplex"))
        XCTAssertEqual(
            BarRecipeBook.apply(open, .tab(.flavor), drinks),
            BarRecipeBook.State(tab: .flavor)
        )
        let back = BarRecipeBook.apply(open, .tab(.name), drinks)
        XCTAssertEqual(back, BarRecipeBook.State(tab: .name))
        XCTAssertEqual(BarRecipeBook.apply(back, .tab(.name), drinks), back)
    }

    func testTheCardsTurnInTheirPagesOrderWhateverTheCategory() throws {
        let drinks = try drinks()
        let sugar = click(drinks, .tab(.flavor), .category("sweet"), .drink("sugar-rush"))
        XCTAssertEqual(BarRecipeBook.pageOf(sugar, drinks)?.n, 21)
        XCTAssertEqual(BarRecipeBook.apply(sugar, .page(1), drinks).drink, "sunshine-cloud")
        XCTAssertEqual(BarRecipeBook.apply(sugar, .page(-1), drinks).drink, "sparkle-star")
    }

    func testItDoesNotTurnRoundPastEitherEnd() throws {
        let drinks = try drinks()
        let first = click(drinks, .tab(.name), .category("B"), .drink("bad-touch"))
        XCTAssertEqual(BarRecipeBook.pageOf(first, drinks)?.n, 1)
        XCTAssertEqual(BarRecipeBook.apply(first, .page(-1), drinks), first)
        let last = click(drinks, .tab(.name), .category("Z"), .drink("zen-star"))
        XCTAssertEqual(BarRecipeBook.apply(last, .page(1), drinks), last)
    }

    func testABottledDrinkOpensWithoutACardToTurn() throws {
        let drinks = try drinks()
        let rum = click(drinks, .tab(.bottle), .drink("rum"))
        XCTAssertEqual(rum.drink, "rum")
        XCTAssertNil(BarRecipeBook.pageOf(rum, drinks))
        XCTAssertEqual(BarRecipeBook.apply(rum, .page(1), drinks), rum)
    }

    func testOnlyWhatThePageListsCanBeClicked() throws {
        let drinks = try drinks()
        let sweet = click(drinks, .tab(.flavor), .category("sweet"))
        XCTAssertEqual(BarRecipeBook.apply(sweet, .drink("suplex"), drinks), sweet)
        XCTAssertEqual(BarRecipeBook.apply(.cover, .category("sweet"), drinks), .cover)
    }
}
