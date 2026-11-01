import XCTest
@testable import EidolonCore

/// The three ways a turn can be asked to write (spec #60): the old short spoken lines,
/// the text atmospheric mode, and a call.
final class ReplyFormatTests: XCTestCase {
    func testRichTextAsksForSceneBlocksAndLongerLines() {
        let prompt = ReplyFormatInstructions.richText
        XCTAssertTrue(prompt.contains("<scene>"))
        XCTAssertTrue(prompt.contains("2–3 句"))
        XCTAssertTrue(prompt.contains("场景块"))
        XCTAssertFalse(prompt.contains("通常只回一两句"))
    }

    func testTextStyleKeepsTheUpstreamInstructions() {
        XCTAssertEqual(
            ReplyStyle.text.formatInstructions(voiceModel: nil),
            ReplyFormatInstructions.text
        )
        XCTAssertEqual(
            ReplyStyle.call.formatInstructions(voiceModel: "drama-3"),
            ReplyFormatInstructions.directed
        )
        XCTAssertEqual(
            ReplyStyle.call.formatInstructions(voiceModel: "s2.1-pro-free"),
            ReplyFormatInstructions.text
        )
    }

    func testRichTextStyleDoesNotChangeWithTheVoiceModel() {
        XCTAssertEqual(
            ReplyStyle.richText.formatInstructions(voiceModel: "drama-3"),
            ReplyFormatInstructions.richText
        )
    }
}
