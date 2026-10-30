import Foundation
import XCTest
@testable import EidolonCore

/// How well a drink is served her, and whether she is drunk by it (GLOSSARY.md「判定」
/// 「醉」; ticket 52-02, upstream `bar_rules.judged` and `bar_rules.drunk`), and the memo
/// of what she wants (`BarOrder.memo`).
final class BarServingTests: BarTestCase {
    private var mano: CharacterConfig { content.content.characters[0] }
    private var hiori: CharacterConfig { content.content.characters[1] }

    private func served(_ id: String, big: Bool = false) throws -> Served {
        let drink = try XCTUnwrap(content.content.catalog.drink(id: id))
        let parts = drink.recipe?.karmotrine ?? drink.bottledKarmotrine
        return Served(drink: drink, big: big, karmotrine: big ? parts * 2 : parts)
    }

    // MARK: - How well it is served

    func testTheDrinkSheNamedIsRightNeverBest() throws {
        // Naming it is enough: what she names is right, and never best, which is only for
        // how she asks rather than what she names (upstream `_best`).
        let drink = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        let serving = try BarRules.judged(
            BarOrder(target: drink), try served("adelhyde-flavor"), mano
        )
        XCTAssertEqual(serving.tier, .right)
        XCTAssertNil(serving.wrong, "right is not wrong")
    }

    func testAnotherDrinkThanTheOneSheNamedIsWrong() throws {
        // Named: only the one she named answers it, however much like it another is.
        let target = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        let serving = try BarRules.judged(
            BarOrder(target: target), try served("mulan-tea"), mano
        )
        XCTAssertEqual(serving.tier, .wrong)
        XCTAssertEqual(serving.wrong, .off, "quite off")
    }

    func testTheOneSheLovesIsBestWhereSheAsksByItsFlavor() throws {
        // Asks by flavor: any of it is right, and the one she loves is best.
        let sweet = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        let order = BarOrder(target: sweet, phrasing: .flavor, said: [.flavor])
        XCTAssertEqual(try BarRules.judged(order, try served("adelhyde-flavor"), mano).tier, .best)
        let right = try BarRules.judged(
            BarOrder(target: sweet, phrasing: .conditions, said: [.flavor]),
            try served("mulan-tea"), mano
        )
        XCTAssertEqual(right.tier, .right, "right, but not the one she loves")
    }

    func testTheFlavorSheDislikesIsWrongWhateverElseItIs() throws {
        // The spicy one is what she dislikes, named or not: wrong, and wrong for that.
        let target = try XCTUnwrap(content.content.catalog.drink(id: "flanergide-on-ice"))
        let serving = try BarRules.judged(
            BarOrder(target: target, phrasing: .flavor, said: [.flavor]),
            try served("flanergide-on-ice"), mano
        )
        XCTAssertEqual(serving.tier, .wrong)
        XCTAssertEqual(serving.wrong, .disliked)
    }

    func testADrinkNotMeetingWhatSheSaidOfItIsWrong() throws {
        // She asks for it with ice; what is served has none.
        let target = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        let order = BarOrder(target: target, phrasing: .conditions, said: [.ice])
        let serving = try BarRules.judged(order, try served("adelhyde-flavor"), mano)
        XCTAssertEqual(serving.tier, .wrong)
        XCTAssertNotNil(serving.wrong)
    }

    func testWhatIsRightWhereNothingWouldHaveBeenBest() throws {
        // Nothing would be better for her order: the sweet one of the kind, either drink
        // served of it is as good as it gets, so it is right, not best.
        let target = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        let order = BarOrder(target: target, phrasing: .flavor, said: [.flavor])
        let hasBest = try BarRules.hasBest(order, mano, content.content.catalog)
        let serving = try BarRules.judged(order, try served("adelhyde-flavor"), mano)
        XCTAssertEqual(serving.tier, hasBest ? .best : .right)
    }

    // MARK: - Drunk

    func testSheIsDrunkAtWhatSheHolds() throws {
        // Mano holds her drink badly: 8 parts of Karmotrine in the visit. Each of the shots
        // served is 2 parts, so the fourth has her there.
        var servings: [Serving] = []
        for n in 1...4 {
            servings.append(
                Serving(
                    order: BarOrder(target: try XCTUnwrap(content.content.catalog.drink(id: "bronson-aged"))),
                    served: try served("bronson-aged"), tier: .right
                )
            )
            XCTAssertEqual(
                try BarRules.drunk(mano, servings: servings), n == 4,
                "\(n) of them: \(n * 2) parts, and she holds \(BarRules.drunkAt[.weak]!)"
            )
        }
    }

    func testADoubledGlassCountsTwiceTheKarmotrine() throws {
        let target = try XCTUnwrap(content.content.catalog.drink(id: "bronson-aged"))
        let one = Serving(order: BarOrder(target: target), served: try served("bronson-aged"), tier: .right)
        let big = Serving(
            order: BarOrder(target: target), served: try served("bronson-aged", big: true), tier: .right
        )
        // Two parts a glass against four: she holds 8, so the one is not drunk by two of
        // them either, and the doubled one is drunk by the second.
        XCTAssertFalse(try BarRules.drunk(mano, servings: [one, one]))
        XCTAssertFalse(try BarRules.drunk(mano, servings: [big]), "four parts, short of eight")
        XCTAssertTrue(try BarRules.drunk(mano, servings: [big, big]))
    }

    func testSheWhoIsNotServedWhatWouldMakeHerDrunkIsNot() throws {
        // Nothing without Karmotrine in it ever does.
        let target = try XCTUnwrap(content.content.catalog.drink(id: "mulan-tea"))
        let tea = Serving(order: BarOrder(target: target), served: try served("mulan-tea"), tier: .right)
        XCTAssertEqual(try served("mulan-tea").karmotrine, 1, "the bottle's own")
        XCTAssertFalse(try BarRules.drunk(hiori, servings: Array(repeating: tea, count: 3)))
    }

    // MARK: - The memo

    func testTheMemoSaysWhatSheWants() throws {
        let sweet = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        XCTAssertEqual(
            BarOrder(target: sweet).memo(subtitle: ""), "她要 \(sweet.name)。",
            "by name: nothing of it said beyond the name"
        )
        XCTAssertEqual(
            BarOrder(target: sweet, phrasing: .nameBig, said: []).memo(subtitle: ""),
            "她要 \(sweet.name)，大杯。", "a big glass is what she asks, so it is said"
        )
        XCTAssertEqual(
            BarOrder(target: sweet, phrasing: .myFavorite, said: []).memo(subtitle: ""),
            "她要她喜欢的。", "by the template, with nothing of it said beyond it"
        )
        XCTAssertEqual(
            BarOrder(target: sweet, phrasing: .flavor, said: [.flavor]).memo(subtitle: ""),
            "她要甜的。"
        )
    }

    func testTheMemoOfAnAnalogyIsWhatSheSaid() throws {
        // Said as the producer made it up, so the memo quotes her rather than the drink.
        let sweet = try XCTUnwrap(content.content.catalog.drink(id: "adelhyde-flavor"))
        let memo = BarOrder(target: sweet, phrasing: .analogy, said: [.flavor])
            .memo(subtitle: "像她妈妈做的糖水")
        XCTAssertEqual(memo, "她说：「像她妈妈做的糖水」")
    }
}
