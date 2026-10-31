import Foundation
import XCTest
@testable import EidolonCore

/// The seven guide blocks and the 28-day diagram (spec #53), ported from upstream.
final class CycleGuideTests: XCTestCase {
    func testTheSevenBlocksAreInOrder() {
        XCTAssertEqual(CycleGuide.blocks.map(\.title), [
            "怎么算的", "基础知识", "青春期", "经前和经期", "常见健康问题", "怎么体贴", "常见误区",
        ])
    }

    func testIdsAreUniqueAndTheIrregularLinkPointsAtPuberty() {
        let ids = CycleGuide.blocks.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(
            CycleGuide.blocks.first { $0.id == CycleGuide.irregularBlockID }?.title,
            "青春期"
        )
    }

    func testEverySentenceHasAnHTTPSource() {
        for block in CycleGuide.blocks {
            for part in block.parts {
                for sentence in part.sentences {
                    XCTAssertFalse(sentence.sources.isEmpty, sentence.text)
                    for source in sentence.sources {
                        XCTAssertTrue(source.href.hasPrefix("https://"), sentence.text)
                    }
                }
            }
        }
    }

    func testTheDiagramIsTwentyEightDaysWithThePeriodOvulationAndFertileDays() {
        let days = CycleGuide.diagramDays()
        XCTAssertEqual(days.count, 28)
        XCTAssertEqual(Set(days[0..<5].map(\.kind)), [.period])
        XCTAssertEqual(days[14].day, 15)
        XCTAssertEqual(days[14].kind, .ovulation)
        XCTAssertEqual(days[9].kind, .fertile)
        XCTAssertEqual(days[15].kind, .fertile)
        XCTAssertNil(days[8].kind)
        XCTAssertNil(days[16].kind)
    }
}
