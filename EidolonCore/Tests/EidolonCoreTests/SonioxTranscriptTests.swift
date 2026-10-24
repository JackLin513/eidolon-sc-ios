import Foundation
import XCTest
@testable import EidolonCore

final class SonioxTranscriptTests: XCTestCase {
    private func feed(_ json: String, into transcript: inout SonioxTranscript) throws -> [SpeechUpdate] {
        try transcript.feed(Data(json.utf8))
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
