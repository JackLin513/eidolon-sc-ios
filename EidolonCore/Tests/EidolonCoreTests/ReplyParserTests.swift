import XCTest
@testable import EidolonCore

final class ReplyParserTests: XCTestCase {
    func testParsesSegmentsAcrossChunks() {
        var parser = ReplyParser()
        var deltas: [String] = []

        for chunk in ["<ja>こん", "にちは</ja><zh>你", "好</zh>"] {
            for event in parser.feed(chunk) {
                if case let .delta(segment, language, text) = event {
                    XCTAssertEqual(segment, 0)
                    _ = language
                    deltas.append(text)
                }
            }
        }
        XCTAssertEqual(deltas.joined(), "こんにちは你好")
        XCTAssertEqual(parser.segments, [ReplySegment(ja: "こんにちは", zh: "你好")])
    }

    func testKeepsCuesInSegmentsButStripsThemFromDeltas() {
        var parser = ReplyParser()
        var shown = ""
        for event in parser.feed("<ja>[shyly] ありがとう</ja><zh>谢谢</zh>") {
            if case let .delta(_, _, text) = event { shown += text }
        }
        XCTAssertFalse(shown.contains("[shyly]"))
        XCTAssertTrue(shown.contains("ありがとう"))
        XCTAssertEqual(parser.segments.first?.ja, "[shyly] ありがとう")
        XCTAssertEqual(parser.segments.first?.zh, "谢谢")
    }

    func testFinishFlushesAnOpenTag() {
        var parser = ReplyParser()
        _ = parser.feed("<ja>まだ途中")
        _ = parser.finish()
        XCTAssertEqual(parser.segments, [ReplySegment(ja: "まだ途中", zh: "")])
    }

    func testTextWithoutTagsBecomesOneJapaneseSegment() {
        var parser = ReplyParser()
        _ = parser.feed("タグを忘れた返事")
        _ = parser.finish()
        XCTAssertEqual(parser.segments.count, 1)
        XCTAssertEqual(parser.segments[0].ja, "タグを忘れた返事")
    }

    func testSeveralSegments() {
        var parser = ReplyParser()
        _ = parser.feed("<ja>ひとつ</ja><zh>一</zh><ja>ふたつ</ja><zh>二</zh>")
        _ = parser.finish()
        XCTAssertEqual(
            parser.segments,
            [ReplySegment(ja: "ひとつ", zh: "一"), ReplySegment(ja: "ふたつ", zh: "二")]
        )
    }
}
