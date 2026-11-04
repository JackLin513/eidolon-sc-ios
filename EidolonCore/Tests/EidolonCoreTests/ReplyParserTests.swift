import XCTest
@testable import EidolonCore

final class ReplyParserTests: XCTestCase {
    func testParsesSegmentsAcrossChunks() {
        var parser = ReplyParser()
        var deltas: [String] = []

        for chunk in ["<ja>こん", "にちは</ja><zh>你", "好</zh>"] {
            for event in parser.feed(chunk) {
                if case let .delta(block, language, text) = event {
                    XCTAssertEqual(block, 0)
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

final class ReplyParserBlockTests: XCTestCase {
    func testSceneBlocksKeepTheirOrder() {
        var parser = ReplyParser()
        var events: [String] = []
        for event in parser.feed(
            "<scene>她把杯子放下。</scene><ja>……おかえり。</ja><zh>……欢迎回来。</zh><scene>她别过脸。</scene>"
        ) {
            switch event {
            case let .sceneDelta(block, text): events.append("scene\(block):\(text)")
            case let .delta(block, language, text): events.append("\(language.rawValue)\(block):\(text)")
            case .speechDelta, .photoTag: break
            }
        }
        XCTAssertEqual(events, [
            "scene0:她把杯子放下。",
            "ja1:……おかえり。",
            "zh1:……欢迎回来。",
            "scene2:她别过脸。",
        ])
        XCTAssertEqual(parser.blocks, [
            .scene("她把杯子放下。"),
            .line(ReplySegment(ja: "……おかえり。", zh: "……欢迎回来。")),
            .scene("她别过脸。"),
        ])
        XCTAssertEqual(parser.segments, [ReplySegment(ja: "……おかえり。", zh: "……欢迎回来。")])
    }

    func testSceneAcrossChunksAndFinish() {
        var parser = ReplyParser()
        for chunk in ["<sce", "ne>她低下", "头。</sc", "ene><ja>うん</ja><zh>嗯</zh>"] {
            _ = parser.feed(chunk)
        }
        _ = parser.finish()
        XCTAssertEqual(parser.blocks, [
            .scene("她低下头。"),
            .line(ReplySegment(ja: "うん", zh: "嗯")),
        ])
    }

    func testSceneOnlyReplyHasNoSegments() {
        var parser = ReplyParser()
        _ = parser.feed("<scene>她只是看着窗外。</scene>")
        _ = parser.finish()
        XCTAssertEqual(parser.blocks, [.scene("她只是看着窗外。")])
        XCTAssertTrue(parser.segments.isEmpty)
    }

    func testSceneBlocksAreShownWithoutDeliveryCues() {
        var parser = ReplyParser()
        var shown = ""
        for event in parser.feed("<scene>[softly] 她低下头。</scene>") {
            if case let .sceneDelta(_, text) = event { shown += text }
        }
        _ = parser.finish()
        XCTAssertEqual(shown, "她低下头。")
        XCTAssertEqual(parser.blocks, [.scene("她低下头。")])
    }

    func testUntaggedReplyStillVoicesItsWords() {
        var parser = ReplyParser()
        var shown = ""
        var voiced = ""
        for event in parser.feed("[shyly] ありがとう") {
            switch event {
            case let .delta(_, _, text): shown += text
            case let .speechDelta(_, text): voiced += text
            case .sceneDelta, .photoTag: break
            }
        }
        for event in parser.finish() {
            switch event {
            case let .delta(_, _, text): shown += text
            case let .speechDelta(_, text): voiced += text
            case .sceneDelta, .photoTag: break
            }
        }
        XCTAssertEqual(parser.blocks, [.line(ReplySegment(ja: "[shyly] ありがとう", zh: ""))])
        XCTAssertEqual(shown, "ありがとう")
        XCTAssertTrue(voiced.contains("ありがとう"), "a call would not voice an untagged reply")
    }

    func testOldFormatHasOnlyLineBlocks() {
        var parser = ReplyParser()
        _ = parser.feed("<ja>ひとつ</ja><zh>一</zh>")
        _ = parser.finish()
        XCTAssertEqual(parser.blocks, [.line(ReplySegment(ja: "ひとつ", zh: "一"))])
    }
}
