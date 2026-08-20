import XCTest

@MainActor
final class HourleafAppStoreScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureLocalizedIPhoneStoreScreenshots() {
        for locale in StoreLocale.allCases {
            captureQuickEntry(locale)
            captureBibleStudies(locale)
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

    private func captureBibleStudies(_ locale: StoreLocale) {
        let app = launch(locale: locale, bibleStudies: true)
        let label = app.staticTexts["bibleStudyLabel"]
        let decrease = app.buttons["decreaseBibleStudyCountButton"]
        let count = app.staticTexts["bibleStudyCount"]
        let increase = app.buttons["increaseBibleStudyCountButton"]
        XCTAssertTrue(
            scrollUntilFullyVisible([label, decrease, count, increase], in: app),
            "The complete Bible-study counter must be visible in the Store capture."
        )
        XCTAssertEqual(count.value as? String, "1")
        XCTAssertFalse(app.staticTexts[locale.removedBibleStudyHint].exists)

        keepScreenshot(named: "\(locale.folder)_02_bible-studies", from: app)
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

        keepScreenshot(named: "\(locale.folder)_03_history-calendar", from: app)
        app.terminate()
    }

    private func captureMonthlyReport(_ locale: StoreLocale) {
        let app = launch(locale: locale, seeded: true, bibleStudies: true)
        app.tabBars.buttons.element(boundBy: 2).tap()
        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains(locale.bibleStudyReportLine))
        XCTAssertTrue(
            scrollUntilFullyVisible([app.staticTexts["reportLifecycleState"], preview], in: app),
            "The report state and complete preview must be visible in the Store capture."
        )

        keepScreenshot(named: "\(locale.folder)_04_monthly-report", from: app)
        app.terminate()
    }

    private func launch(
        locale: StoreLocale,
        seeded: Bool = false,
        bibleStudies: Bool = false
    ) -> XCUIApplication {
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
        if bibleStudies {
            app.launchArguments.append("-seedBibleStudyUITest")
        }
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func scrollUntilFullyVisible(
        _ elements: [XCUIElement],
        in app: XCUIApplication
    ) -> Bool {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.waitForExistence(timeout: 5) else { return false }

        for _ in 0..<10 {
            let visibleTop = app.windows.firstMatch.frame.minY + 24
            let visibleBottom = tabBar.frame.minY - 24
            if elements.allSatisfy({ element in
                element.exists
                    && element.isHittable
                    && element.frame.minY >= visibleTop
                    && element.frame.maxY <= visibleBottom
            }) {
                return true
            }
            app.swipeUp(velocity: .slow)
        }

        let visibleTop = app.windows.firstMatch.frame.minY + 24
        let visibleBottom = tabBar.frame.minY - 24
        return elements.allSatisfy { element in
            element.exists
                && element.isHittable
                && element.frame.minY >= visibleTop
                && element.frame.maxY <= visibleBottom
        }
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

    var bibleStudyReportLine: String {
        switch self {
        case .english: "Bible studies: 1"
        case .russian: "Изучения Библии: 1"
        case .ukrainian: "Вивчення Біблії: 1"
        }
    }

    var removedBibleStudyHint: String {
        switch self {
        case .english: "Different studies this month"
        case .russian: "Разные изучения за месяц"
        case .ukrainian: "Різні вивчення за місяць"
        }
    }
}
