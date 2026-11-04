import XCTest

/// 设置里的统计与用量花费 (spec #96): the two entries, their empty state, the seeded
/// numbers, the price editor and clearing the ledger.
final class StatsUsageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func openUsage() {
        app.tabBars.buttons["设置"].tap()
        let usage = app.buttons["settings.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 10), "no usage entry")
        usage.tap()
        XCTAssertTrue(
            app.navigationBars["用量与花费"].waitForExistence(timeout: 5),
            "usage page did not open"
        )
    }

    func testSettingsOpensStatsAndAnEmptyUsagePage() throws {
        app.launchEnvironment["EIDOLON_CLEAR_USAGE"] = "1"
        app.launch()

        app.tabBars.buttons["设置"].tap()
        let stats = app.buttons["settings.stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10), "no stats entry")
        stats.tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 5), "stats did not open")
        XCTAssertTrue(
            app.segmentedControls["stats.range"].exists || app.buttons["近 30 天"].exists,
            "no range switch"
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let usage = app.buttons["settings.usage"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5), "no usage entry after back")
        usage.tap()
        XCTAssertTrue(app.navigationBars["用量与花费"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["从这次更新开始统计"].waitForExistence(timeout: 5),
            "usage has no empty state"
        )
        XCTAssertTrue(app.buttons["usage.prices"].exists, "no price entry")
    }

    func testSeededStatsShowsThePortraitAndHeatmap() throws {
        app.launchEnvironment["EIDOLON_SEED_STATS"] = "1"
        app.launch()
        app.tabBars.buttons["设置"].tap()
        let stats = app.buttons["settings.stats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        stats.tap()
        XCTAssertTrue(app.navigationBars["统计"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["stats.portrait"].waitForExistence(timeout: 5),
            "no portrait with the seeded contacts"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["stats.heatmap"].exists, "no heatmap"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["stats.rangeNumbers"].exists, "no range numbers"
        )
        let range = app.segmentedControls["stats.range"]
        XCTAssertTrue(range.exists, "no range switch")
        range.buttons["近 30 天"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["stats.portrait"].waitForExistence(timeout: 5),
            "the statistics did not survive a range change"
        )
    }

    func testSeededUsageShowsServicesAndClears() throws {
        app.launchEnvironment["EIDOLON_SEED_USAGE"] = "1"
        app.launch()
        openUsage()

        XCTAssertTrue(
            app.staticTexts["对话模型"].waitForExistence(timeout: 5), "no chat service row"
        )
        XCTAssertTrue(app.staticTexts["语音合成"].exists, "no speech service row")
        XCTAssertTrue(app.staticTexts["语音识别"].exists, "no recognition service row")
        XCTAssertTrue(app.staticTexts["你的估算花费"].exists, "no totals")
        let range = app.segmentedControls["usage.range"]
        XCTAssertTrue(range.exists, "no range switch")
        range.buttons["近一年"].tap()
        XCTAssertTrue(
            app.staticTexts["对话模型"].waitForExistence(timeout: 5),
            "the usage did not survive a range change"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["usage.metric"].exists
                || app.buttons["估算花费"].exists,
            "no daily trend switch"
        )

        let clear = app.buttons["usage.clear"]
        XCTAssertTrue(clear.exists, "no clear button")
        clear.tap()
        XCTAssertTrue(
            app.alerts["清空用量记录？"].waitForExistence(timeout: 5), "no confirmation"
        )
        app.alerts["清空用量记录？"].buttons["取消"].tap()
    }

    func testThePriceEditorOpensARow() throws {
        app.launchEnvironment["EIDOLON_SEED_USAGE"] = "1"
        app.launch()
        openUsage()

        let prices = app.buttons["usage.prices"]
        XCTAssertTrue(prices.waitForExistence(timeout: 5))
        prices.tap()
        XCTAssertTrue(
            app.navigationBars["单价与币种"].waitForExistence(timeout: 5),
            "price editor did not open"
        )
        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'price.row.'")
        )
        XCTAssertGreaterThan(rows.count, 0, "the price editor has no rows")
        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["单价"].waitForExistence(timeout: 5), "no edit sheet")
        XCTAssertTrue(app.buttons["price.save"].exists, "no save button")
    }
}
