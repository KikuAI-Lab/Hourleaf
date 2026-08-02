import XCTest

@MainActor
final class HourleafUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testQuickEntryAppearsInHistory() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertFalse(app.staticTexts["A calm record of your ministry"].exists)
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "1")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "15")
        app.buttons["saveEntryButton"].tap()
        app.tabBars.buttons["History"].tap()

        XCTAssertTrue(app.staticTexts["Service"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["1 hr 15 min"].exists)
    }

    func testSeededPreviousMonthReportIsVisible() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-seedUITestData", "-AppleLanguages", "(en)"]
        app.launch()
        app.tabBars.buttons["Progress"].tap()

        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Hours: 52"))
        XCTAssertTrue(preview.label.contains("Credit hours: 7"))
        XCTAssertTrue(app.buttons["shareReportButton"].isEnabled)
    }

    func testRussianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(ru)"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Добавить время"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
    }

    func testUkrainianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(uk)"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Додати час"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
    }

    func testOnboardingExplainsOpeningBalances() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingUITest", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Welcome to Hourleaf"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["finishOnboardingButton"].exists)
        XCTAssertTrue(app.staticTexts["Already served this service year?"].exists)

        XCTAssertTrue(app.textFields["baselineHoursField"].exists)
    }

    func testSettingsDoesNotOfferServiceYearCarry() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["Carry August remainder into September"].exists)
    }
}
