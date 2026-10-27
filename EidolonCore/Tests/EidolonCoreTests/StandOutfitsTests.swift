import Foundation
import XCTest
@testable import EidolonCore

/// Which outfit she wears (spec「衣装与换衣装」): the one chosen for her on this device,
/// what her outfit list gives it, and which outfit a call tries first.
final class StandOutfitsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suiteName = "EidolonStandOutfits-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - The choice on this device

    func testRemembersOneOutfitPerCharacterAndKeepsTheOthers() {
        let store = StandOutfitChoiceStore(defaults: defaults)

        XCTAssertNil(store.choice(for: "mano"))

        store.remember("stand/1030010010", for: "mano")
        store.remember("stand_costume/1030010010", for: "hiori")
        store.remember("stand_costume/1030010010", for: "mano")

        XCTAssertEqual(store.choice(for: "mano"), "stand_costume/1030010010")
        XCTAssertEqual(store.choice(for: "hiori"), "stand_costume/1030010010")
        XCTAssertNil(store.choice(for: "meguru"))
    }

    func testStoredChoicesThatCannotBeReadMeanNoneChosen() {
        defaults.set(Data("not json".utf8), forKey: StandOutfitChoiceStore.defaultsKey)
        let store = StandOutfitChoiceStore(defaults: defaults)

        XCTAssertNil(store.choice(for: "mano"))

        store.remember("stand/1030010010", for: "mano")
        XCTAssertEqual(store.choice(for: "mano"), "stand/1030010010")
    }

    // MARK: - What she wears

    private func outfit(_ id: String) -> StandOutfit {
        StandOutfit(
            id: id,
            directory: URL(fileURLWithPath: "/content/stand/idols/\(id)", isDirectory: true)
        )
    }

    /// Her stand with one card: `1030010010`'s everyday clothes (also her default) and its
    /// stage costume.
    private func stand(withList: Bool = true) -> CharacterStand {
        let everyday = outfit("stand/1030010010")
        let stage = outfit("stand_costume/1030010010")
        let list = withList
            ? OutfitList(
                idolID: 1,
                cards: [
                    OutfitCard(
                        id: "1030010010",
                        name: "ナチュラルモード",
                        type: "P_SR",
                        everyday: everyday,
                        stage: stage
                    )
                ]
            )
            : nil
        return CharacterStand(defaultOutfit: everyday, outfitList: list)
    }

    func testTheChosenOutfitInTheListIsWorn() {
        let worn = stand().worn(choice: "stand_costume/1030010010")

        XCTAssertEqual(worn.id, "stand_costume/1030010010")
        XCTAssertEqual(
            worn.directory.standardizedFileURL.path,
            "/content/stand/idols/stand_costume/1030010010"
        )
    }

    func testAChoiceMissingFromTheListFallsBackToTheDefault() {
        // The content bundle was updated and no longer carries the outfit she chose.
        let worn = stand().worn(choice: "stand/1099999999")

        XCTAssertEqual(worn, stand().defaultOutfit)
    }

    func testWithoutAChoiceTheDefaultIsWorn() {
        let worn = stand().worn(choice: nil)

        XCTAssertEqual(worn, stand().defaultOutfit)
    }

    func testWithoutAListTheRememberedOutfitIsStillTriedFirst() {
        // The list cannot be read (a call dialled early, or a broken file): the outfit she
        // was wearing is still tried where the bucket keeps it, before her default
        // (upstream `wornOutfit` with no cards).
        let worn = stand(withList: false).worn(choice: "stand_costume/1030010010")

        XCTAssertEqual(worn.id, "stand_costume/1030010010")
        XCTAssertEqual(
            worn.directory.standardizedFileURL.path,
            "/content/stand/idols/stand_costume/1030010010"
        )
    }

    func testWithoutAListAChoiceThatCannotBeAnOutfitFallsBackToTheDefault() {
        for choice in ["stand/../escape", "nonsense", "stand/", "stand_costume/abc", "other/123"] {
            XCTAssertEqual(
                stand(withList: false).worn(choice: choice),
                stand().defaultOutfit,
                "\(choice) is not an outfit"
            )
        }
    }

    func testWithoutAListACallTriesTheRememberedOutfitThenTheDefault() {
        XCTAssertEqual(
            stand(withList: false)
                .outfitsToTry(choice: "stand_costume/1030010010")
                .map(\.id),
            ["stand_costume/1030010010", "stand/1030010010"]
        )
    }

    func testACallTriesTheWornOutfitThenTheDefault() {
        let outfits = stand().outfitsToTry(choice: "stand_costume/1030010010")

        XCTAssertEqual(outfits.map(\.id), ["stand_costume/1030010010", "stand/1030010010"])
    }

    func testACallTriesTheDefaultOnlyOnce() {
        XCTAssertEqual(stand().outfitsToTry(choice: nil).map(\.id), ["stand/1030010010"])
        XCTAssertEqual(
            stand().outfitsToTry(choice: "stand/1030010010").map(\.id),
            ["stand/1030010010"]
        )
        // A stale choice that falls back is still just the default.
        XCTAssertEqual(
            stand().outfitsToTry(choice: "stand/1099999999").map(\.id),
            ["stand/1030010010"]
        )
    }

    // MARK: - A card

    func testACardListsItsEverydayClothesThenItsStageCostume() {
        let everyday = outfit("stand/1030010010")
        let stage = outfit("stand_costume/1030010010")
        let card = OutfitCard(
            id: "1030010010",
            name: "ナチュラルモード",
            type: "P_SR",
            everyday: everyday,
            stage: stage
        )

        XCTAssertEqual(card.looks, [.everyday, .stage])
        XCTAssertFalse(card.hasOnlyOneLook)
        XCTAssertEqual(card.outfit(for: .everyday), everyday)
        XCTAssertEqual(card.outfit(for: .stage), stage)
    }

    func testACardWithOneOutfitSaysItHasOnlyOne() {
        // A card whose two outfits are the same is listed with its everyday clothes alone.
        let everyday = outfit("stand/1030010020")
        let card = OutfitCard(id: "1030010020", name: "ぐうぜんBOOKS", type: "P_SR", everyday: everyday)

        XCTAssertEqual(card.looks, [.everyday])
        XCTAssertTrue(card.hasOnlyOneLook)
        XCTAssertNil(card.outfit(for: .stage))

        let stageOnly = OutfitCard(
            id: "1030010030",
            name: "しじまに華ひととき",
            type: "P_SR",
            stage: outfit("stand_costume/1030010030")
        )
        XCTAssertEqual(stageOnly.looks, [.stage])
        XCTAssertTrue(stageOnly.hasOnlyOneLook)
    }

    func testFindingAnOutfitGivesItsCardAndWhichOutfitItIs() {
        let everyday = outfit("stand/1030010010")
        let stage = outfit("stand_costume/1030010010")
        let second = outfit("stand/1030010020")
        let list = OutfitList(
            idolID: 1,
            cards: [
                OutfitCard(
                    id: "1030010010",
                    name: "ナチュラルモード",
                    type: "P_SR",
                    everyday: everyday,
                    stage: stage
                ),
                OutfitCard(id: "1030010020", name: "ぐうぜんBOOKS", type: "P_SR", everyday: second),
            ]
        )

        let foundStage = list.find("stand_costume/1030010010")
        XCTAssertEqual(foundStage?.card.id, "1030010010")
        XCTAssertEqual(foundStage?.look, .stage)
        XCTAssertEqual(foundStage?.outfit, stage)

        let foundEveryday = list.find("stand/1030010020")
        XCTAssertEqual(foundEveryday?.card.id, "1030010020")
        XCTAssertEqual(foundEveryday?.look, .everyday)
        XCTAssertEqual(foundEveryday?.outfit, second)

        XCTAssertNil(list.find("stand/1099999999"))
    }
}
