import XCTest

@MainActor
final class HourleafScrollPerformanceTests: XCTestCase {
    func testHistoryScrollPerformance() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting", "-seedScrollPerformanceUITest",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-hourleafTestNow", "2026-11-17T12:00:00Z"
        ]
        app.launch()
        XCTAssertTrue(app.buttons["saveEntryButton"].waitForExistence(timeout: 60))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Synthetic scroll entry 0"].waitForExistence(timeout: 10))
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists)
        let options = XCTMeasureOptions()
        options.iterationCount = 3
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            list.swipeUp(velocity: .fast)
            list.swipeUp(velocity: .fast)
            list.swipeDown(velocity: .fast)
            list.swipeDown(velocity: .fast)
        }
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.tabBars.buttons["Progress"].tap()
        XCTAssertTrue(app.staticTexts["selectedReportMonth"].waitForExistence(timeout: 5))
        app.scrollViews.firstMatch.swipeUp()
        app.scrollViews.firstMatch.swipeDown()
        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
    }
}
