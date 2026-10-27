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

    /// The readings file is the source of names said in a call, and the Chinese given name
    /// — her Chinese name without the characters of her Japanese surname — is added too
    /// (upstream `hot_words.py`). Lone surnames are left out: they would catch ordinary words.
    func testTheReadingsAndTheChineseGivenNameAreWords() {
        let characters = [
            CharacterConfig(id: "mano", name: "櫻木真乃", nameZh: "樱木真乃"),
            CharacterConfig(id: "hiori", name: "風野灯織", nameZh: "风野灯织"),
        ]
        let readings = Readings(entries: [
            Reading(written: "櫻木真乃", kana: "さくらぎ まの", phonemes: ""),
            Reading(written: "櫻木", kana: "さくらぎ", phonemes: ""),
            Reading(written: "真乃", kana: "まの", phonemes: ""),
            Reading(written: "風野灯織", kana: "かざの ひおり", phonemes: ""),
            Reading(written: "風野", kana: "かざの", phonemes: ""),
        ])

        XCTAssertEqual(
            CallHotWords.terms(readings: readings, characters: characters, units: []),
            ["櫻木真乃", "真乃", "風野灯織", "樱木真乃", "风野灯织", "灯织"]
        )
    }

    /// The surname is as many characters as the Japanese reading starts her name with,
    /// however long that is（有栖川夏葉 → 夏叶, not 川夏叶).
    func testALongerSurnameIsTakenWhole() {
        let characters = [CharacterConfig(id: "arisa", name: "有栖川夏葉", nameZh: "有栖川夏叶")]
        let readings = Readings(entries: [
            Reading(written: "有栖川夏葉", kana: "ありすがわ なつは", phonemes: ""),
            Reading(written: "有栖川", kana: "ありすがわ", phonemes: ""),
            Reading(written: "夏葉", kana: "なつは", phonemes: ""),
        ])

        XCTAssertEqual(
            CallHotWords.terms(readings: readings, characters: characters, units: []),
            ["有栖川夏葉", "夏葉", "有栖川夏叶", "夏叶"]
        )
    }

    /// A reading not starting any character's name is not a surname; it is kept like any
    /// other reading (`283プロ`).
    func testAReadingThatIsNotASurnameIsKept() {
        let readings = Readings(entries: [
            Reading(written: "283プロ", kana: "つばさプロ", phonemes: ""),
        ])
        XCTAssertEqual(
            CallHotWords.terms(readings: readings, characters: [], units: []),
            ["283プロ"]
        )
    }

    // MARK: - The bundle

    func testTheBundleOffersItsNames() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root))

        // The fixture keeps two names; it has no world setting, so there are no units.
        let words = try await eidolon.callHotWords()
        XCTAssertEqual(words, ["櫻木真乃", "樱木真乃", "風野灯織"])
    }

    /// With a readings file the bundle also offers the readings and the Chinese given
    /// names, and reads the file for Fish Audio's dictionary.
    func testTheBundleOffersItsReadingsAndGivenNames() async throws {
        let eidolon = try Eidolon(location: .init(root: root.appendingPathComponent("app")))
        var options = Fixture.Options()
        options.includeReadings = true
        try await eidolon.install(bundleAt: try Fixture.makeBundle(in: root, options: options))

        let readings = try await eidolon.readings()
        XCTAssertEqual(
            readings.entries.map(\.written),
            ["櫻木真乃", "櫻木", "真乃", "風野灯織", "風野"]
        )
        let words = try await eidolon.callHotWords()
        XCTAssertEqual(
            words,
            ["櫻木真乃", "真乃", "風野灯織", "樱木真乃"]
        )
    }
}
