import XCTest

/// Walks the bar tutorial on a simulator as far as the first mix and drives the two things the
/// tutorial stalls on: the recipe book's tabs and dragging an ingredient into the shaker.
///
/// Needs a simulator that already has the content pack and the bar pack imported (see
/// `README.md` 「测试」); the app launches straight into the bar through
/// `SIMCTL_CHILD_EIDOLON_OPEN_BAR`.
final class BarTutorialUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["EIDOLON_OPEN_BAR"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    /// 配方书的按键: tapping a tab turns the page.
    func testRecipeBookTabsTakeTaps() throws {
        try openCounter()

        XCTAssertTrue(element("按口味").isHittable, "配方书的「按口味」看不见")
        element("按口味").tap()

        XCTAssertTrue(
            element("甜味饮品").waitForExistence(timeout: 2),
            "点了「按口味」之后配方书没有翻到口味那一页"
        )
    }

    /// 拿起调酒: a bottle dragged to the shaker goes in — its cells count up, and the drop is
    /// not left short of the shaker because the drag's points are the wrong ones.
    func testDraggingAnIngredientPutsItInTheShaker() throws {
        try openCounter()

        let adelhyde = element("Adelhyde，0 份")
        XCTAssertTrue(adelhyde.exists, "调酒台上没有 Adelhyde")
        adelhyde.press(forDuration: 0.5, thenDragTo: element("摇酒器"))

        XCTAssertTrue(
            element("Adelhyde，1 份").waitForExistence(timeout: 3),
            "把 Adelhyde 拖进摇酒器之后，它仍然是 0 份"
        )
    }

    // MARK: - Walking the tutorial

    /// 教程, then tap the text box until 调酒 opens the recipe book (the counter comes with it).
    private func openCounter() throws {
        let tutorial = element("教程")
        XCTAssertTrue(tutorial.waitForExistence(timeout: 20), "没能到店门口")
        tutorial.tap()

        for _ in 0..<40 {
            if element("按口味").exists { return }
            element("继续").tap()
        }
        XCTFail("点了 40 下文本框，调酒那一节还是没开")
    }

    /// Anything by its label, whatever SwiftUI calls the element.
    private func element(_ label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
    }
}
