import XCTest

/// Opens the pages added for schedule and cycles on a device or simulator with the content
/// bundle already imported. It draws nothing new; it only walks the navigation and checks the
/// controls the pages need are there.
final class ScheduleCycleUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testCyclePageOpensFromSettingsAndTheRecordForm() throws {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "conversation list has no settings button")
        settings.tap()

        let cycles = app.buttons["查看周期"]
        for _ in 0..<4 where !cycles.exists {
            app.swipeUp()
        }
        XCTAssertTrue(cycles.waitForExistence(timeout: 10), "settings has no 查看周期 row")
        cycles.tap()

        XCTAssertTrue(app.navigationBars["周期"].waitForExistence(timeout: 10), "cycle page did not open")
        XCTAssertTrue(app.staticTexts["讲解"].exists, "cycle page has no guide")
        XCTAssertTrue(app.staticTexts["记下的经期"].exists, "cycle page has no record list")

        app.buttons["记一次经期"].tap()
        XCTAssertTrue(
            app.navigationBars["记一次经期"].waitForExistence(timeout: 5),
            "record form did not open"
        )
        app.buttons["取消"].tap()
    }

    func testCalendarWeeklyBoardOpensAndAPlacementCanBeDrafted() throws {
        let calendar = app.buttons["日历"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "conversation list has no calendar button")
        calendar.tap()

        let weekly = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '本周工作'")
        ).firstMatch
        XCTAssertTrue(weekly.waitForExistence(timeout: 10), "calendar has no 本周工作 row")
        weekly.tap()

        XCTAssertTrue(app.navigationBars["她的日程"].waitForExistence(timeout: 10), "board did not open")
        XCTAssertTrue(app.staticTexts["上午"].exists, "board has no slots")
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '待排'")).firstMatch.exists,
            "board has no pending summary"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '还能排'")).firstMatch.exists,
            "board has no free-cell count"
        )
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS '24 点后作废'")).firstMatch.exists,
            "board has no expiry line"
        )
        // Next week is wholly to come, so a card always has somewhere to go.
        let nextWeek = app.buttons["schedule.week.next"]
        nextWeek.tap()
        XCTAssertTrue(nextWeek.isSelected, "next week did not switch")
        let card = app.buttons.matching(identifier: "schedule.card").firstMatch
        if !card.waitForExistence(timeout: 10) {
            XCTAssertTrue(
                app.staticTexts["这周没有工作"].exists,
                "no job cards, and not the empty week either"
            )
            return
        }
        let loaded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == true"), object: card
        )
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 10), .completed)
        card.tap()
        XCTAssertEqual(card.value as? String, "已选中", "card was not selected")

        let free = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '空闲'")
        ).firstMatch
        XCTAssertTrue(free.waitForExistence(timeout: 5), "no free cell after choosing a card")
        free.tap()

        let save = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH '保存这一周'")
        ).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), "save button did not appear")
        XCTAssertTrue(save.isEnabled, "save button is not enabled after a draft")

        let draft = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '草稿'")
        ).firstMatch
        XCTAssertTrue(draft.exists, "draft cell is not there")
        draft.tap()
        XCTAssertFalse(save.isEnabled, "save button is still enabled after taking the draft back")
    }

    func testHerScheduleOpensFromTheChatMenu() throws {
        let mano = app.staticTexts["櫻木真乃"].firstMatch
        XCTAssertTrue(mano.waitForExistence(timeout: 10), "conversation list has no 櫻木真乃")
        mano.tap()

        let more = app.buttons["更多"]
        XCTAssertTrue(more.waitForExistence(timeout: 10), "chat has no more menu")
        more.tap()
        let schedule = app.buttons["她的日程"]
        XCTAssertTrue(schedule.waitForExistence(timeout: 5), "chat menu has no 她的日程")
        schedule.tap()
        XCTAssertTrue(app.navigationBars["她的日程"].waitForExistence(timeout: 10), "her board did not open")
    }
}
