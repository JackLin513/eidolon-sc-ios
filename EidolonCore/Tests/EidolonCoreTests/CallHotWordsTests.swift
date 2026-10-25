import Foundation
import XCTest
@testable import EidolonCore

final class CallHotWordsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EidolonCoreHotWords-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - The words

    func testTheJapaneseNameTheChineseNameAndTheUnitsAreTheWords() {
        let characters = [
            CharacterConfig(id: "mano", name: "櫻木真乃", nameZh: "樱木真乃"),
            CharacterConfig(id: "hiori", name: "風野灯織"),
        ]
        XCTAssertEqual(
            CallHotWords.terms(characters: characters, units: ["illumination STARS"]),
            ["櫻木真乃", "樱木真乃", "風野灯織", "illumination STARS"]
        )
    }

    func testAWordIsListedOnce() {
        // Different characters can offer the same word, and a unit can repeat one; the
        // services take the list as a set, so it is said once.
        let characters = [
            CharacterConfig(id: "one", name: "灯織", nameZh: "樱木真乃"),
            CharacterConfig(id: "two", name: "櫻木真乃", nameZh: "櫻木真乃"),
        ]
        XCTAssertEqual(
            CallHotWords.terms(characters: characters, units: ["樱木真乃"]),
            ["灯織", "樱木真乃", "櫻木真乃"]
        )
    }

    func testSingleCharactersAreLeftOut() {
        // A single character would have ordinary words heard as names.
        let characters = [CharacterConfig(id: "one", name: "真", nameZh: "乃")]
        XCTAssertEqual(CallHotWords.terms(characters: characters, units: ["灯"]), [])
    }

    func testWordsTheServicesDoNotTakeWholeAreLeftOut() {
        let tooLong = String(repeating: "あ", count: 16)
        let longest = String(repeating: "あ", count: 15)
        let tooManyWords = "one two three four five six seven eight"
        let mostWords = "one two three four five six seven"
        XCTAssertEqual(
            CallHotWords.terms(
                characters: [CharacterConfig(id: "long", name: tooLong)],
                units: [longest, tooManyWords, mostWords]
            ),
            [longest, mostWords]
        )
    }

    func testSpacesAroundAWordAreTrimmedAndABlankOneIsLeftOut() {
        let characters = [CharacterConfig(id: "one", name: "  櫻木真乃 ")]
        XCTAssertEqual(CallHotWords.terms(characters: characters, units: ["   "]), ["櫻木真乃"])
    }

    // MARK: - The bundle

    func testTheBundleOffersItsNames() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        // The fixture keeps two names; it has no world setting, so there are no units.
        let words = try await eidolon.callHotWords()
        XCTAssertEqual(words, ["櫻木真乃", "樱木真乃", "風野灯織"])
    }
}
