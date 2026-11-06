import XCTest
@testable import EidolonCore

/// 欢迎页的两个纯判断（spec #118）：这一次要不要放，以及素材缺哪几样。
final class WelcomeTests: XCTestCase {
    func testWithoutAContentBundleItAlwaysOpensTheWelcomePage() {
        XCTAssertTrue(WelcomeLaunch.shouldPresent(seen: false, hasContentBundle: false))
        XCTAssertTrue(WelcomeLaunch.shouldPresent(seen: true, hasContentBundle: false))
    }

    func testWithAContentBundleItOpensOnlyTheFirstTime() {
        XCTAssertTrue(WelcomeLaunch.shouldPresent(seen: false, hasContentBundle: true))
        XCTAssertFalse(WelcomeLaunch.shouldPresent(seen: true, hasContentBundle: true))
    }

    func testNothingIsMissingWhenEverythingIsThere() {
        XCTAssertEqual(
            WelcomeAssetCheck.missing(page: true, roster: true, greetings: true),
            []
        )
    }

    func testEachMissingPieceIsNamed() {
        XCTAssertEqual(
            WelcomeAssetCheck.missing(page: false, roster: true, greetings: true),
            [.page]
        )
        XCTAssertEqual(
            WelcomeAssetCheck.missing(page: true, roster: false, greetings: false),
            [.roster, .greetings]
        )
    }
}
