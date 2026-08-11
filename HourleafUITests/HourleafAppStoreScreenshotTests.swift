import XCTest

@MainActor
final class HourleafAppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureLocalizedIPhoneStoreScreenshots() {
        for locale in StoreLocale.allCases {
            captureQuickEntry(locale)
            captureHistoryCalendar(locale)
            captureMonthlyReport(locale)
        }
    }

    private func captureQuickEntry(_ locale: StoreLocale) {
        let app = launch(locale: locale)
        XCTAssertTrue(app.buttons["saveEntryButton"].waitForExistence(timeout: 5))
        keepScreenshot(named: "\(locale.folder)_01_quick-entry", from: app)
        app.terminate()
    }

    private func captureHistoryCalendar(_ locale: StoreLocale) {
        let app = launch(locale: locale, seeded: true)
        app.tabBars.buttons.element(boundBy: 1).tap()

        let mode = app.segmentedControls["historyViewModePicker"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["historyCalendarMonth"].waitForExistence(timeout: 5))
        app.buttons["historyCalendarPreviousMonthButton"].tap()
        XCTAssertTrue(app.buttons["historyCalendarDay_2026-09-15"].waitForExistence(timeout: 5))

        keepScreenshot(named: "\(locale.folder)_02_history-calendar", from: app)
        app.terminate()
    }

    private func captureMonthlyReport(_ locale: StoreLocale) {
        let app = launch(locale: locale, seeded: true)
        app.tabBars.buttons.element(boundBy: 2).tap()
        XCTAssertTrue(app.staticTexts["reportPreview"].waitForExistence(timeout: 5))

        keepScreenshot(named: "\(locale.folder)_03_monthly-report", from: app)
        app.terminate()
    }

    private func launch(locale: StoreLocale, seeded: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-AppleLanguages",
            "(\(locale.language))",
            "-AppleLocale",
            locale.appleLocale,
            "-AppleInterfaceStyle",
            "Dark",
            "-hourleafTestNow",
            "2026-10-02T12:00:00Z"
        ]
        if seeded {
            app.launchArguments.append("-seedUITestData")
        }
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func keepScreenshot(named name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum StoreLocale: CaseIterable {
    case english
    case russian
    case ukrainian

    var language: String {
        switch self {
        case .english: "en"
        case .russian: "ru"
        case .ukrainian: "uk"
        }
    }

    var appleLocale: String {
        switch self {
        case .english: "en_US"
        case .russian: "ru_RU"
        case .ukrainian: "uk_UA"
        }
    }

    var folder: String {
        switch self {
        case .english: "en-US"
        case .russian: "ru"
        case .ukrainian: "uk"
        }
    }
}
