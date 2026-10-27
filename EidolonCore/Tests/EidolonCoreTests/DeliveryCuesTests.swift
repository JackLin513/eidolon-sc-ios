import XCTest
@testable import EidolonCore

/// What people see and what the voice hears in a reply full of delivery cues, against
/// upstream `delivery_cues.py` run on the same lines (ADR-0004).
final class DeliveryCuesTests: XCTestCase {
    /// Each case with what upstream `without_cues` and `voiced` gave for it.
    private let cases: [(line: String, shown: String, voiced: String)] = [
        ("[shyly] えへへ（小声で）ありがとう", "えへへありがとう", "[shyly]えへへありがとう"),
        ("(happy) うれしい", "うれしい", "うれしい"),
        ("これは<whisper>内緒</whisper>だよ", "これは内緒だよ", "これは<whisper>内緒</whisper>だよ"),
        ("【嬉しそうに】そうなんだ", "そうなんだ", "そうなんだ"),
        ("[嬉しそうに] そうなんだ", "そうなんだ", "そうなんだ"),
        ("<|speaker:0|>こんにちは", "こんにちは", "こんにちは"),
        ("そっか……[disappointed] 行けないんだ。", "そっか…… 行けないんだ。", "そっか……[disappointed] 行けないんだ。"),
        ("これは<emphasis>大事</emphasis>な話", "これは大事な話", "これは<emphasis>大事</emphasis>な話"),
        ("<whisper>内緒</whisper>だよ", "内緒だよ", "<whisper>内緒</whisper>だよ"),
        (" [shyly]  えへへ  ", "えへへ", "[shyly]えへへ"),
        ("abc (x) def", "abc  def", "abc  def"),
        ("[shyly, glancing away] え、えっと……ありがとう。", "え、えっと……ありがとう。", "[shyly, glancing away]え、えっと……ありがとう。"),
        ("a [unclosed", "a [unclosed", "a [unclosed"),
        ("<unclosed>tag", "tag", "tag"),
        ("普通の文です。", "普通の文です。", "普通の文です。"),
        ("[small laugh] これ、<whisper>みんなには内緒</whisper>だよ？", "これ、みんなには内緒だよ？", "[small laugh]これ、<whisper>みんなには内緒</whisper>だよ？"),
        ("]。abc", "]。abc", "]。abc"),
        ("（小声で）", "", ""),
    ]

    func testShownMatchesUpstreamDeliveryCues() {
        for testCase in cases {
            XCTAssertEqual(
                ReplyCues.shown(testCase.line),
                testCase.shown,
                "shown of \(testCase.line)"
            )
        }
    }

    func testVoicedKeepsWellFormedCuesAndDropsEverythingElse() {
        for testCase in cases {
            XCTAssertEqual(
                ReplyCues.voiced(testCase.line),
                testCase.voiced,
                "voiced of \(testCase.line)"
            )
        }
    }

    /// Paired tags are for the model that reads them: anything else is given the words
    /// without them (upstream `spoken_by`).
    func testSpokenByKeepsPairedTagsOnlyForDrama3() {
        for testCase in cases {
            let voiced = testCase.voiced
            let expected = voiced
                .replacingOccurrences(of: "<whisper>", with: "")
                .replacingOccurrences(of: "</whisper>", with: "")
                .replacingOccurrences(of: "<emphasis>", with: "")
                .replacingOccurrences(of: "</emphasis>", with: "")
            XCTAssertEqual(ReplyCues.spoken(voiced, by: "s2.1-pro-free"), expected)
            XCTAssertEqual(ReplyCues.spoken(voiced, by: nil), expected)
            XCTAssertEqual(ReplyCues.spoken(voiced, by: "drama-3"), voiced)
        }
    }

    /// A cue split across chunks is held back until it closes, so no half cue ever shows,
    /// and the shown stream is the same however the reply was chunked.
    func testChunkingNeverLeaksAHalfCue() {
        for testCase in cases {
            let markup = Array("<ja>\(testCase.line)</ja>")
            XCTAssertEqual(
                shownStream(of: markup, splitAt: nil),
                testCase.shown,
                "whole reply of \(testCase.line)"
            )
            for split in 1..<markup.count {
                XCTAssertEqual(
                    shownStream(of: markup, splitAt: split),
                    testCase.shown,
                    "split at \(split) of \(testCase.line)"
                )
            }
        }
    }

    func testTheVoicedStreamIsWhatUpstreamVoices() {
        let line = "[small laugh] これ、<whisper>みんなには内緒</whisper>だよ？"
        var parser = ReplyParser()
        var voiced = ""
        for event in parser.feed("<ja>\(line)</ja>") {
            if case let .speechDelta(_, text) = event { voiced += text }
        }
        for event in parser.finish() {
            if case let .speechDelta(_, text) = event { voiced += text }
        }
        XCTAssertEqual(voiced, ReplyCues.voiced(line))
    }

    /// What is stored keeps the cues as the model wrote them, for the voice and for the
    /// traces; only the screen and the speech stream are filtered.
    func testTheStoredReplyKeepsItsCues() {
        var parser = ReplyParser()
        _ = parser.feed("<ja>[shyly] ありがとう</ja><zh>谢谢</zh>")
        _ = parser.finish()
        XCTAssertEqual(parser.segments.first?.ja, "[shyly] ありがとう")
    }

    private func shownStream(of markup: [Character], splitAt split: Int?) -> String {
        var parser = ReplyParser()
        var shown = ""
        let chunks: [String]
        if let split {
            chunks = [
                String(markup[..<split]),
                String(markup[split...]),
            ]
        } else {
            chunks = [String(markup)]
        }
        for chunk in chunks {
            for event in parser.feed(chunk) {
                if case let .delta(_, _, text) = event { shown += text }
            }
        }
        for event in parser.finish() {
            if case let .delta(_, _, text) = event { shown += text }
        }
        return shown
    }
}
