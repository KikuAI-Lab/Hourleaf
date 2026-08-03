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
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Progress"].tap()

        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Hours: 52"))
        XCTAssertTrue(preview.label.contains("Credit hours: 7"))
        XCTAssertTrue(app.buttons["shareReportButton"].isEnabled)
    }

    func testProgressDoesNotNavigateBeforeLedgerStart() {
        let app = launchApp()
        app.tabBars.buttons["Progress"].tap()

        let month = app.staticTexts["selectedReportMonth"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        XCTAssertEqual(month.label, Self.monthFormatter.string(from: Date()))
        XCTAssertFalse(app.buttons["previousReportMonthButton"].isEnabled)
        XCTAssertTrue(app.buttons["shareReportButton"].isEnabled)
    }

    func testShareCancellationStillAsksForManualSentConfirmation() {
        let app = launchApp(additionalArguments: ["-seedUITestData"])
        app.tabBars.buttons["Progress"].tap()
        app.buttons["shareReportButton"].tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()

        let confirmation = app.alerts["Was the report sent?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        confirmation.buttons["Not sent"].tap()
    }

    func testPastDateCanBeRecorded() {
        let app = launchApp(additionalArguments: ["-pastDateUITest"])
        let pastDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())!

        app.datePickers["entryDatePicker"].tap()
        let day = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", Self.dayButtonFormatter.string(from: pastDate))
        ).firstMatch
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        app.navigationBars["Add time"].tap()

        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "20")
        app.textFields["entryNoteField"].tap()
        app.textFields["entryNoteField"].typeText("Past date")
        app.buttons["saveEntryButton"].tap()
        app.tabBars.buttons["History"].tap()

        XCTAssertTrue(app.staticTexts["Past date"].waitForExistence(timeout: 5))
        let components = Calendar.current.dateComponents([.year, .month, .day], from: pastDate)
        let dateIdentifier = "historyEntryDate_\(components.year!)_\(components.month!)_\(components.day!)"
        XCTAssertTrue(app.staticTexts[dateIdentifier].exists)
    }

    func testEntryCanBeEdited() {
        let app = launchApp()
        addEntry(in: app, hours: "1", minutes: "15")
        app.tabBars.buttons["History"].tap()

        let entry = firstHistoryEntry(in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Entry"].waitForExistence(timeout: 5))
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "30")
        app.buttons["saveEditedEntryButton"].tap()

        XCTAssertTrue(app.staticTexts["1 hr 30 min"].waitForExistence(timeout: 5))
    }

    func testEntryCanBeDeleted() {
        let app = launchApp()
        addEntry(in: app, hours: "1", minutes: "15")
        app.tabBars.buttons["History"].tap()

        let entry = firstHistoryEntry(in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.swipeLeft()
        app.buttons["Delete"].tap()
        let alert = app.alerts["Delete this entry?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()

        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 5))
    }

    func testUndoBannerRevertsTheLatestQuickEntry() {
        let app = launchApp()
        addEntry(in: app, hours: "1", minutes: "15")

        let banner = app.descendants(matching: .any)["mutationBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            banner.frame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "The Undo banner must remain above the tab bar."
        )
        let undo = app.buttons["undoMutationButton"]
        XCTAssertTrue(undo.waitForExistence(timeout: 2))
        undo.tap()

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 5))
    }

    func testUndoBannerRemainsUsableAtAccessibilityTextSize() {
        let app = launchApp(
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        addEntry(in: app, hours: "1", minutes: "15")

        let banner = app.descendants(matching: .any)["mutationBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            banner.frame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "The expanded Undo banner must remain above the tab bar."
        )
        XCTAssertTrue(app.buttons["undoMutationButton"].isHittable)
        XCTAssertTrue(app.buttons["dismissUndoBannerButton"].isHittable)
    }

    func testRecentlyDeletedCanRestoreAnEntry() {
        let app = launchApp()
        addEntry(in: app, hours: "1", minutes: "15")
        app.tabBars.buttons["History"].tap()

        let entry = firstHistoryEntry(in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.swipeLeft()
        app.buttons["Delete"].tap()
        let alert = app.alerts["Delete this entry?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()

        app.buttons["recentlyDeletedButton"].tap()
        XCTAssertTrue(app.navigationBars["Recently Deleted"].waitForExistence(timeout: 5))
        let restore = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'restoreEntry_'")
        ).firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        restore.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        XCTAssertTrue(app.staticTexts["Service"].waitForExistence(timeout: 5))
    }

    func testZeroDurationEditOffersDeletion() {
        let app = launchApp()
        addEntry(in: app, hours: "1", minutes: "15")
        app.tabBars.buttons["History"].tap()

        let entry = firstHistoryEntry(in: app)
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        XCTAssertTrue(app.navigationBars["Entry"].waitForExistence(timeout: 5))
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "0")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "0")
        app.buttons["saveEditedEntryButton"].tap()

        let alert = app.alerts["Delete this entry?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 5))
    }

    func testReminderCanBeScheduledWithoutCreatingTime() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        app.buttons["addReminderButton"].tap()
        XCTAssertTrue(app.navigationBars["New reminder"].waitForExistence(timeout: 5))
        app.buttons["confirmAddReminderButton"].tap()

        XCTAssertTrue(app.staticTexts["Monday"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 5))
    }

    func testColdQuickEntryRouteLaunchesOnAddTime() {
        let app = launchApp(additionalArguments: ["-coldQuickEntryRouteUITest"])

        XCTAssertTrue(app.navigationBars["Add time"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].isHittable)
    }

    func testQuickEntryRouteResetsAnExistingDraftOnForeground() {
        let app = launchApp(
            additionalArguments: [
                "-pastDateUITest",
                "-quickEntryRouteOnForegroundUITest"
            ]
        )
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let draftNote = "Draft note"

        app.segmentedControls["entryKindPicker"].buttons["Credit"].tap()
        app.datePickers["entryDatePicker"].tap()
        let yesterdayButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] %@", Self.dayButtonFormatter.string(from: yesterday))
        ).firstMatch
        XCTAssertTrue(yesterdayButton.waitForExistence(timeout: 5))
        yesterdayButton.tap()
        app.navigationBars["Add time"].tap()
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "2")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "30")
        let noteField = app.textFields["entryNoteField"]
        noteField.tap()
        noteField.typeText(draftNote)
        XCTAssertEqual(noteField.value as? String, draftNote)

        app.tabBars.buttons["History"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.navigationBars["Add time"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Service"].isSelected)
        XCTAssertFalse(app.buttons["saveEntryButton"].isEnabled)
        XCTAssertEqual(noteField.value as? String, "Short note (optional)")

        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "1")
        app.buttons["saveEntryButton"].tap()
        app.tabBars.buttons["History"].tap()

        XCTAssertTrue(app.staticTexts["Service"].waitForExistence(timeout: 5))
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let todayIdentifier = "historyEntryDate_\(today.year!)_\(today.month!)_\(today.day!)"
        XCTAssertTrue(app.staticTexts[todayIdentifier].exists)
    }

    func testSettingsOffersShortcutsLink() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()

        let shortcutsLink = app.descendants(matching: .any)["shortcutsLink"]
        XCTAssertTrue(shortcutsLink.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["shortcutsFooter"].exists)
    }

    func testRussianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(ru)"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Добавить время"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
        app.tabBars.buttons["Настройки"].tap()
        XCTAssertTrue(app.staticTexts["Быстрые команды"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["shortcutsFooter"].exists)
    }

    func testUkrainianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(uk)"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Додати час"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
        app.tabBars.buttons["Налаштування"].tap()
        XCTAssertTrue(app.staticTexts["Швидкі команди"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["shortcutsFooter"].exists)
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
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["creditLabelField"].exists)
        XCTAssertTrue(app.staticTexts["minutePolicyExample"].exists)
        XCTAssertEqual(
            app.staticTexts["minutePolicyExample"].label,
            "Example: 3 hr 20 min in July becomes 3 hr in the report; 20 min is added to August. After August, the remainder resets to zero."
        )
        XCTAssertFalse(app.switches["Carry August remainder into September"].exists)
        XCTAssertFalse(app.staticTexts["App Store name"].exists)

        let settings = app.collectionViews.firstMatch
        settings.swipeUp()
        let existingTime = app.buttons["existingTimeButton"]
        XCTAssertTrue(existingTime.waitForExistence(timeout: 5))
        existingTime.tap()
        XCTAssertTrue(app.navigationBars["Time already recorded"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["You only need this screen when moving an existing record into Hourleaf. It does not create entries for past days."].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        settings.swipeUp()
        settings.swipeUp()
        XCTAssertFalse(app.staticTexts["storageStatus"].exists)
        XCTAssertTrue(app.buttons["developerWebsiteLink"].exists)
        XCTAssertTrue(app.buttons["developerTelegramLink"].exists)
        XCTAssertTrue(app.buttons["developerGitHubLink"].exists)
    }

    private func launchApp(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func addEntry(in app: XCUIApplication, hours: String, minutes: String) {
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: hours)
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: minutes)
        app.buttons["saveEntryButton"].tap()
    }

    private func firstHistoryEntry(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'historyEntry_'")).firstMatch
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let dayButtonFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

}
