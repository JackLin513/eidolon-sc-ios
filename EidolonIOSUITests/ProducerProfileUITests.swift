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
        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "no settings tab")
        settings.tap()

        let toggle = app.switches["settings.birthdayOn"].firstMatch
        for _ in 0..<8 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no birthday toggle")
        setSwitch(toggle, on: true)

        let picker = app.datePickers["settings.birthday"].firstMatch
        // The form is lazy: a picker below the fold may not exist until it is scrolled to.
        for _ in 0..<3 where !picker.exists {
            app.swipeUp()
        }
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
        app.tabBars.buttons["对话"].tap()

        let calendar = app.buttons["日历"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 10), "no calendar button")
        calendar.tap()

        XCTAssertTrue(
            app.staticTexts["你的生日：2月29日"].waitForExistence(timeout: 10),
            "calendar has no birthday hint"
        )

        showNextFebruary()
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS '制作人的生日'")
            ).firstMatch.waitForExistence(timeout: 5),
            "the producer's birthday is not on the calendar"
        )

        // Turning it off removes both the hint and the event without a restart.
        app.buttons["完成"].tap()
        let settingsAgain = app.tabBars.buttons["设置"]
        XCTAssertTrue(settingsAgain.waitForExistence(timeout: 10))
        settingsAgain.tap()
        let toggleAgain = app.switches["settings.birthdayOn"].firstMatch
        for _ in 0..<8 where !toggleAgain.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(toggleAgain.waitForExistence(timeout: 5))
        setSwitch(toggleAgain, on: false)
        app.buttons["保存"].tap()
        let savedAgain = app.alerts["已保存"]
        XCTAssertTrue(savedAgain.waitForExistence(timeout: 10), "turning the birthday off did not save")
        savedAgain.buttons["好"].tap()
        app.tabBars.buttons["对话"].tap()

        let calendarAgain = app.buttons["日历"]
        XCTAssertTrue(calendarAgain.waitForExistence(timeout: 10))
        calendarAgain.tap()
        XCTAssertFalse(
            app.staticTexts["你的生日：2月29日"].waitForExistence(timeout: 2),
            "the birthday hint is still there after turning it off"
        )
        showNextFebruary()
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(format: "label CONTAINS '制作人的生日'")
            ).firstMatch.exists,
            "the birthday event is still there after turning it off"
        )
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let wanted = on ? "1" : "0"
        let knob = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        for _ in 0..<3 where (toggle.value as? String) != wanted {
            knob.tap()
            sleep(1)
        }
        XCTAssertEqual(toggle.value as? String, wanted)
    }

    private func showNextFebruary() {
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
    }

    private static func monthNumber(_ text: String) -> Int {
        text.split(separator: "年").last?
            .split(separator: "月").first
            .flatMap { Int($0) } ?? 0
    }
}
