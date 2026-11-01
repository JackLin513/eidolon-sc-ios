import XCTest

/// Settings → calendar for the producer's birthday (spec #55): picking February 29 saves it,
/// the calendar hint and the birthday event use it without a restart.
final class ProducerProfileUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    func testFebruary29IsSavedAndShownInTheCalendar() throws {
        let settings = app.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no settings button")
        settings.tap()

        let toggle = app.switches["settings.birthdayOn"].firstMatch
        for _ in 0..<8 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no birthday toggle")
        if (toggle.value as? String) != "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }

        let picker = app.datePickers["settings.birthday"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no birthday picker")
        for _ in 0..<4 where !picker.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(picker.isHittable, "birthday picker is not on screen")
        picker.tap()
        sleep(1)

        let monthHeader = app.buttons["DatePicker.Show"]
        XCTAssertTrue(monthHeader.waitForExistence(timeout: 5), "the date picker did not open")
        for _ in 0..<12 where !((monthHeader.value as? String) ?? "").contains("年2月") {
            let number = Self.monthNumber((monthHeader.value as? String) ?? "")
            if number > 2 {
                app.buttons["DatePicker.PreviousMonth"].tap()
            } else {
                app.buttons["DatePicker.NextMonth"].tap()
            }
        }
        XCTAssertTrue(((monthHeader.value as? String) ?? "").contains("年2月"))
        let day = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '2月29日'")).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5), "February 29 is not selectable")
        day.tap()
        if app.buttons["关闭弹出式窗口"].exists {
            app.buttons["关闭弹出式窗口"].tap()
        }

        app.buttons["保存"].tap()
        let saved = app.alerts["已保存"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10), "settings did not save")
        saved.buttons["好"].tap()
        app.buttons["完成"].tap()

        let calendar = app.buttons["日历"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "no calendar button")
        calendar.tap()

        XCTAssertTrue(
            app.staticTexts["你的生日：2月29日"].waitForExistence(timeout: 10),
            "calendar has no birthday hint"
        )

        let month = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '[0-9]{4}年[0-9]+月'")
        ).firstMatch
        XCTAssertTrue(month.waitForExistence(timeout: 5), "calendar has no month title")
        let year = Int(month.label.prefix { $0 != "年" }) ?? 2026
        let target = "\(year + 1)年2月"
        for _ in 0..<24 where month.label != target {
            app.buttons["下个月"].tap()
        }
        XCTAssertEqual(month.label, target)
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS '制作人的生日'")
            ).firstMatch.waitForExistence(timeout: 5),
            "the producer's birthday is not on the calendar"
        )
    }

    private static func monthNumber(_ text: String) -> Int {
        text.split(separator: "年").last?
            .split(separator: "月").first
            .flatMap { Int($0) } ?? 0
    }
}
