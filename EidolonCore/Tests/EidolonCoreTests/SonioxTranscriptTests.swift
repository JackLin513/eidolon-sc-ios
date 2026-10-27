import Foundation
import XCTest
@testable import EidolonCore

final class SonioxTranscriptTests: XCTestCase {
    private func feed(_ json: String, into transcript: inout SonioxTranscript) throws -> [SpeechUpdate] {
        try transcript.feed(Data(json.utf8))
    }

    func testTheSessionHearsChineseAndJapanese() throws {
        // Upstream hears both: the producer may speak either (`language_hints=[ZH, JA]`).
        let message = try SonioxConfiguration(apiKey: "key", model: "stt-rt-v5").message()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["language_hints"] as? [String], ["zh", "ja"])
        XCTAssertEqual(object["audio_format"] as? String, "pcm_s16le")
        XCTAssertEqual(object["sample_rate"] as? Int, 16_000)
        XCTAssertEqual(object["num_channels"] as? Int, 1)
        XCTAssertEqual(object["enable_endpoint_detection"] as? Bool, true)
        XCTAssertEqual(object["model"] as? String, "stt-rt-v5")
        XCTAssertEqual(object["api_key"] as? String, "key")
    }

    func testTheRecognizerIsGivenTheNamesToListenFor() throws {
        // Upstream sends its hot words as the context's terms (`call.py`).
        let message = try SonioxConfiguration(
            apiKey: "key",
            model: "stt-rt-v5",
            terms: ["櫻木真乃", "樱木真乃"]
        ).message()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        let context = try XCTUnwrap(object["context"] as? [String: Any])
        XCTAssertEqual(context["terms"] as? [String], ["櫻木真乃", "樱木真乃"])
    }

    func testNoContextIsSentWithoutNames() throws {
        let message = try SonioxConfiguration(apiKey: "key", model: "stt-rt-v5").message()
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        )
        XCTAssertNil(object["context"])
    }

    func testOpenWordsAreShownAsTheyAreRewritten() throws {
        var transcript = SonioxTranscript()
        let first = try feed(
            #"{"tokens": [{"text": "こんに", "is_final": false}, {"text": "ちは", "is_final": false}]}"#,
            into: &transcript
        )
        XCTAssertEqual(first, [.partial("こんにちは")])
        let rewritten = try feed(
            #"{"tokens": [{"text": "こんばんは", "is_final": false}]}"#,
            into: &transcript
        )
        XCTAssertEqual(rewritten, [.partial("こんばんは")])
    }

    func testFinalTokensStayUntilTheEndToken() throws {
        var transcript = SonioxTranscript()
        let one = try feed(
            #"{"tokens": [{"text": "こんにちは、", "is_final": true}, {"text": "そう", "is_final": false}]}"#,
            into: &transcript
        )
        XCTAssertEqual(one, [.partial("こんにちは、そう")])
        let two = try feed(
            #"{"tokens": [{"text": "そうですね。", "is_final": true}]}"#,
            into: &transcript
        )
        XCTAssertEqual(two, [.partial("こんにちは、そうですね。")])
        let end = try feed(
            #"{"tokens": [{"text": "<end>", "is_final": true}]}"#,
            into: &transcript
        )
        XCTAssertEqual(end, [.final("こんにちは、そうですね。")])
    }

    func testAnEmptyEndTokenSaysNothing() throws {
        var transcript = SonioxTranscript()
        let end = try feed(#"{"tokens": [{"text": "<fin>", "is_final": true}]}"#, into: &transcript)
        XCTAssertEqual(end, [])
    }

    /// Soniox's auto-finalize may send a message holding nothing but `<fin>`; upstream
    /// ignores that message rather than taking it for the producer stopping (pipecat's
    /// `stt.py` skips the finalized token). What was said stays open until `<end>`.
    func testALoneFinDoesNotEndTheSentence() throws {
        var transcript = SonioxTranscript()
        _ = try feed(#"{"tokens": [{"text": "またね", "is_final": true}]}"#, into: &transcript)
        let fin = try feed(#"{"tokens": [{"text": "<fin>", "is_final": true}]}"#, into: &transcript)
        XCTAssertEqual(fin, [], "a lone <fin> is not the end of what was said")
        let end = try feed(#"{"tokens": [{"text": "<end>", "is_final": true}]}"#, into: &transcript)
        XCTAssertEqual(end, [.final("またね")])
    }

    func testFinishedFlushesWhatWasSaid() throws {
        var transcript = SonioxTranscript()
        _ = try feed(#"{"tokens": [{"text": "またね", "is_final": true}]}"#, into: &transcript)
        let done = try feed(#"{"tokens": [], "finished": true}"#, into: &transcript)
        XCTAssertEqual(done, [.final("またね"), .ended])
    }

    func testAServiceErrorIsThrown() {
        var transcript = SonioxTranscript()
        XCTAssertThrowsError(
            try transcript.feed(Data(#"{"error_code": "invalid_api_key", "error_message": "bad key"}"#.utf8))
        ) { error in
            XCTAssertEqual(
                error as? SonioxError,
                .service("invalid_api_key", "bad key")
            )
        }
    }
}
