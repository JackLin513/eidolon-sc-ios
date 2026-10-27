import Foundation
import XCTest
@testable import EidolonCore

/// How names are said in her voice (GLOSSARY.md「读音」): the bundle's `characters/readings.json`
/// becomes the pronunciation dictionary every Fish Audio request carries.
final class ReadingsTests: XCTestCase {
    private let json = """
        {"readings":[
          {"written":"櫻木真乃","kana":"さくらぎ まの","phonemes":"sa0ku1ra1gi0ma1no0"},
          {"written":"283プロ","kana":"つばさプロ","phonemes":""}
        ]}
        """

    func testTheFileIsReadAsTheExporterWritesIt() throws {
        let readings = try Readings(data: Data(json.utf8))
        XCTAssertEqual(readings.entries, [
            Reading(written: "櫻木真乃", kana: "さくらぎ まの", phonemes: "sa0ku1ra1gi0ma1no0"),
            Reading(written: "283プロ", kana: "つばさプロ", phonemes: ""),
        ])
    }

    /// Only entries with phonemes are sent: an undrafted reading would tell Fish Audio to
    /// say nothing (upstream `pronunciation_dictionary`).
    func testOnlyEntriesWithPhonemesMakeTheDictionary() throws {
        let readings = try Readings(data: Data(json.utf8))
        XCTAssertEqual(readings.pronunciationDictionary, [
            PronunciationDictionary(items: [
                PronunciationItem(
                    key: "櫻木真乃",
                    value: "sa0ku1ra1gi0ma1no0",
                    caseSensitive: true
                ),
            ]),
        ])
    }

    func testNothingDraftedMeansNoDictionary() throws {
        let readings = try Readings(data: Data(#"{"readings":[{"written":"283プロ","kana":"つばさプロ","phonemes":""}]}"#.utf8))
        XCTAssertNil(readings.pronunciationDictionary)
    }

    /// The shape Fish Audio takes (upstream `readings.pronunciation_dictionary`): one group
    /// of items, each matched as written and case-sensitively.
    func testTheDictionaryGoesIntoTheRequestAsFishAudioExpects() throws {
        let readings = try Readings(data: Data(json.utf8))
        let request = FishSpeechRequest(
            text: "櫻木真乃です",
            referenceID: "voice-1",
            readings: readings
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let body = try XCTUnwrap(object as? [String: Any])

        XCTAssertEqual(body["text"] as? String, "櫻木真乃です")
        XCTAssertEqual(body["reference_id"] as? String, "voice-1")
        XCTAssertEqual(body["format"] as? String, "mp3")
        XCTAssertEqual(body["normalize"] as? Bool, true)
        let dictionary = try XCTUnwrap(body["pronunciation_dictionary"] as? [[String: Any]])
        let items = try XCTUnwrap(dictionary.first?["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?["key"] as? String, "櫻木真乃")
        XCTAssertEqual(items.first?["value"] as? String, "sa0ku1ra1gi0ma1no0")
        XCTAssertEqual(items.first?["case_sensitive"] as? Bool, true)
    }

    func testARequestWithoutDraftedReadingsHasNoDictionary() throws {
        let request = FishSpeechRequest(
            text: "こんにちは",
            referenceID: "voice-1",
            readings: Readings()
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request))
        let body = try XCTUnwrap(object as? [String: Any])
        XCTAssertNil(body["pronunciation_dictionary"])
    }

    func testABrokenFileIsRefused() {
        XCTAssertThrowsError(try Readings(data: Data(#"{"readings":"oops"}"#.utf8)))
        XCTAssertThrowsError(
            try Readings(data: Data(#"{"readings":[{"written":"櫻木真乃"}]}"#.utf8))
        )
        XCTAssertThrowsError(try Readings(data: Data("not json".utf8)))
    }

    func testAFileWithoutReadingsHasNone() throws {
        XCTAssertEqual(try Readings(data: Data("{}".utf8)).entries, [])
    }
}
