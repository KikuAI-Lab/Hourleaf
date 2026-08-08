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
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Hours: 52"))
        XCTAssertTrue(preview.label.contains("Credit hours: 7"))
        XCTAssertEqual(app.staticTexts["selectedReportMonth"].label, "September 2026")
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Ready to review")
        XCTAssertTrue(app.buttons["reportReviewButton"].isEnabled)
        XCTAssertFalse(app.buttons["sharePreparedReportButton"].exists)
        XCTAssertFalse(app.buttons["markReportSentButton"].exists)
    }

    func testProgressDoesNotNavigateBeforeLedgerStart() {
        let app = launchApp(
            additionalArguments: [
                "-ledgerStartsCurrentMonthUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        let month = app.staticTexts["selectedReportMonth"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        XCTAssertEqual(month.label, "October 2026")
        XCTAssertFalse(app.buttons["previousReportMonthButton"].isEnabled)
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Month in progress")
        XCTAssertFalse(app.buttons["reportReviewButton"].exists)
        XCTAssertFalse(app.buttons["sharePreparedReportButton"].exists)
    }

    func testPaceIsHiddenByDefaultAndToggleShowsServiceOnlyGuide() {
        let app = launchApp(
            additionalArguments: [
                "-seedPaceUITest",
                "-hourleafTestNow",
                "2026-04-01T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        XCTAssertTrue(app.staticTexts["360 hr"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["serviceYearPaceText"].exists)

        app.tabBars.buttons["Settings"].tap()
        let planningToggle = app.switches["planningVisibilityToggle"]
        XCTAssertTrue(scrollUntilVisible(planningToggle, in: app))
        planningToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()

        app.tabBars.buttons["Progress"].tap()
        let pace = app.staticTexts["serviceYearPaceText"]
        XCTAssertTrue(pace.waitForExistence(timeout: 5))
        XCTAssertEqual(
            pace.label,
            "For reference: about 10 hr 59 min a week until August 31."
        )
        XCTAssertTrue(app.buttons["serviceYearPaceDetails"].exists)
    }

    func testPaceAboveSixHundredShowsUncappedTotal() {
        let app = launchApp(
            additionalArguments: [
                "-seedPaceAboveGoalUITest",
                "-enablePlanningUITest",
                "-hourleafTestNow",
                "2026-08-01T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        XCTAssertTrue(app.staticTexts["601 hr 15 min"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["serviceYearPaceText"].waitForExistence(timeout: 5))
        XCTAssertEqual(
            app.staticTexts["serviceYearPaceText"].label,
            "600-hour guide reached. Total: 601 hr 15 min."
        )
    }

    func testPreviousMonthZeroEntryBannerOpensExactMonth() {
        let app = launchApp(
            additionalArguments: [
                "-pastDateUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )

        let banner = app.buttons["previousReportBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(banner.label.contains("September 2026"))
        banner.tap()

        let month = app.staticTexts["selectedReportMonth"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        XCTAssertEqual(month.label, "September 2026")
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Ready to review")
        XCTAssertTrue(app.staticTexts["reportPreview"].label.contains("Hours: 0"))
    }

    func testClosingShareMenuStillRequiresExplicitMarkAsSent() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()
        app.buttons["reportReviewButton"].tap()
        XCTAssertTrue(app.buttons["finishReportReviewButton"].waitForExistence(timeout: 5))
        app.buttons["finishReportReviewButton"].tap()

        let prepare = app.buttons["prepareReportButton"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()

        let state = app.staticTexts["reportLifecycleState"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Prepared to share")
        XCTAssertTrue(app.buttons["sharePreparedReportButton"].exists)
        XCTAssertTrue(app.buttons["markReportSentButton"].exists)
        XCTAssertFalse(app.alerts["Was the report sent?"].exists)

        app.buttons["markReportSentButton"].tap()
        expectation(
            for: NSPredicate(format: "label == %@", "Marked as sent"),
            evaluatedWith: state
        )
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.buttons["markReportSentButton"].exists)
        XCTAssertTrue(app.buttons["sharePreparedReportButton"].exists)
    }

    func testClosingReadyServiceYearArchivesRecordedServiceWithoutCredit() {
        let app = launchApp(
            additionalArguments: [
                "-seedServiceYearUITest",
                "-hourleafTestNow",
                "2026-09-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        let month = app.staticTexts["selectedReportMonth"]
        XCTAssertTrue(month.waitForExistence(timeout: 5))
        if month.label != "August 2026" {
            app.buttons["previousReportMonthButton"].tap()
        }
        XCTAssertEqual(month.label, "August 2026")
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Ready to review")

        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Hours: 1"))
        XCTAssertTrue(preview.label.contains("Credit hours: 7"))

        let serviceYearState = app.staticTexts["serviceYearArchiveState"].firstMatch
        XCTAssertTrue(serviceYearState.waitForExistence(timeout: 5))
        XCTAssertTrue(serviceYearState.label.contains("Ready to close"))

        let reviewButton = app.buttons["reviewServiceYearButton"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 5))
        reviewButton.tap()

        XCTAssertTrue(app.navigationBars["Review service year"].waitForExistence(timeout: 5))
        XCTAssertTrue(serviceYearState.label.contains("Ready to close"))
        XCTAssertTrue(app.staticTexts["Service recorded in Hourleaf: 1 hr"].exists)
        XCTAssertTrue(app.staticTexts["Credit is kept separately and is not included."].exists)

        let closeButton = app.buttons["closeServiceYearButton"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5))
        closeButton.tap()

        expectation(
            for: NSPredicate(format: "label CONTAINS %@", "Archived"),
            evaluatedWith: serviceYearState
        )
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["Original archive"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["serviceYearArchiveState"].firstMatch.label.contains("Archived"))
    }

    func testReportReviewShowsIncomingRemaindersAndSeparateCredit() {
        let app = launchApp(
            additionalArguments: [
                "-seedReportCarryUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()
        app.buttons["reportReviewButton"].tap()

        XCTAssertTrue(reportBreakdownLine("Service in entries: 2 hr 10 min", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(reportBreakdownLine("Incoming remainder: 20 min", in: app).exists)
        XCTAssertTrue(reportBreakdownLine("In the report: 2 hr", in: app).exists)
        XCTAssertTrue(reportBreakdownLine("Remainder forward: 30 min", in: app).exists)
        XCTAssertTrue(reportBreakdownLine("Credit in entries: 20 min", in: app).exists)
        XCTAssertTrue(reportBreakdownLine("Incoming remainder: 15 min", in: app).exists)
        XCTAssertTrue(reportBreakdownLine("Credit hours: 0 hr", in: app).exists)
        XCTAssertTrue(reportBreakdownLine("Remainder forward: 35 min", in: app).exists)
    }

    func testZeroCreditCalculationIsHiddenFromReportReview() {
        let app = launchApp(
            additionalArguments: [
                "-pastDateUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.buttons["previousReportBanner"].tap()
        app.buttons["reportReviewButton"].tap()

        XCTAssertTrue(reportBreakdownLine("Service in entries: 0 min", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(reportBreakdownLines("Credit in entries: 0 min", in: app).count, 0)
    }

    func testChangedReportKeepsSentOriginalAndPreparesCorrection() {
        let app = launchApp(
            additionalArguments: [
                "-seedChangedReportUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Changed — review again")
        XCTAssertTrue(app.staticTexts["Original"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Marked as sent"].exists)
        app.buttons["reportReviewButton"].tap()
        app.buttons["finishReportReviewButton"].tap()

        let prepare = app.buttons["prepareReportButton"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertEqual(prepare.label, "Prepare corrected report")
        prepare.tap()
        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        close.tap()

        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Prepared to share")
        XCTAssertTrue(app.staticTexts["Correction 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Original"].exists)
        XCTAssertTrue(app.buttons["markReportSentButton"].exists)
    }

    func testReportReviewReflowsAtAccessibilityXXXL() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z",
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        app.tabBars.buttons["Progress"].tap()
        app.buttons["reportReviewButton"].tap()

        XCTAssertTrue(app.navigationBars["Review report"].waitForExistence(timeout: 5))
        let finish = app.buttons["finishReportReviewButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        XCTAssertTrue(finish.isHittable)
        XCTAssertGreaterThanOrEqual(finish.frame.height, 44)
        let breakdown = reportBreakdownLine("Entries: 2", in: app)
        XCTAssertTrue(scrollUntilVisible(breakdown, in: app))
        let entryList = app.descendants(matching: .any)
            .matching(identifier: "reportReviewEntryList")
            .firstMatch
        XCTAssertTrue(scrollUntilVisible(entryList, in: app))
        XCTAssertTrue(finish.isHittable)
    }

    func testReportReadinessCopyIsRussian() {
        let app = launchLocalizedReportApp(language: "ru")
        app.tabBars.buttons["Прогресс"].tap()

        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Готов к проверке")
        XCTAssertTrue(app.staticTexts["Месяц закончился. Проверьте записи и итог перед отправкой."].exists)
        let review = app.buttons["reportReviewButton"]
        XCTAssertEqual(review.label, "Проверить отчёт")
        review.tap()
        XCTAssertTrue(app.navigationBars["Проверить отчёт"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["finishReportReviewButton"].label, "Готово, всё проверено")
    }

    func testReportReadinessCopyIsUkrainian() {
        let app = launchLocalizedReportApp(language: "uk")
        app.tabBars.buttons["Прогрес"].tap()

        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Готово до перевірки")
        XCTAssertTrue(app.staticTexts["Місяць завершився. Перевірте записи й підсумок перед надсиланням."].exists)
        let review = app.buttons["reportReviewButton"]
        XCTAssertEqual(review.label, "Перевірити звіт")
        review.tap()
        XCTAssertTrue(app.navigationBars["Перевірити звіт"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["finishReportReviewButton"].label, "Готово, усе перевірено")
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
        app.buttons["dismissEntryKeyboardButton"].tap()
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

    func testRepeatLastEntryKeepsManualDraftAndShowsUndo() {
        let app = launchApp()
        let repeatButton = app.buttons["repeatLastEntryButton"]
        XCTAssertFalse(repeatButton.exists)

        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "1")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "15")
        let noteField = app.textFields["entryNoteField"]
        noteField.tap()
        noteField.typeText("Source note")
        app.buttons["dismissEntryKeyboardButton"].tap()
        app.buttons["saveEntryButton"].tap()

        XCTAssertTrue(repeatButton.waitForExistence(timeout: 5))
        XCTAssertEqual(repeatButton.value as? String, "Service · 1 hr 15 min")
        expectation(
            for: NSPredicate(format: "value == %@", "Short note (optional)"),
            evaluatedWith: noteField
        )
        waitForExpectations(timeout: 3)

        app.segmentedControls["entryKindPicker"].buttons["Credit"].tap()
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "2")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "30")
        noteField.tap()
        noteField.typeText("Unsaved draft")
        app.buttons["dismissEntryKeyboardButton"].tap()
        XCTAssertTrue(repeatButton.isHittable)
        repeatButton.tap()

        XCTAssertTrue(app.staticTexts["2 hr 30 min"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Credit"].isSelected)
        XCTAssertEqual(noteField.value as? String, "Unsaved draft")
        XCTAssertTrue(app.buttons["saveEntryButton"].isEnabled)
        XCTAssertTrue(app.buttons["undoMutationButton"].waitForExistence(timeout: 5))

        app.tabBars.buttons["History"].tap()
        let historyEntries = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyEntry_'")
        )
        XCTAssertTrue(historyEntries.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(historyEntries.count, 2)
        XCTAssertEqual(
            app.staticTexts.matching(NSPredicate(format: "label == %@", "Source note")).count,
            1
        )
    }

    func testRepeatLastEntryRemainsHittableAtAccessibilityXXXL() {
        let app = launchApp(
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        addEntry(in: app, hours: "1", minutes: "15")

        let repeatButton = app.buttons["repeatLastEntryButton"]
        XCTAssertTrue(repeatButton.waitForExistence(timeout: 5))
        XCTAssertTrue(repeatButton.isHittable)
        XCTAssertGreaterThanOrEqual(repeatButton.frame.height, 44)
        XCTAssertEqual(repeatButton.value as? String, "Service · 1 hr 15 min")
    }

    func testQuickSurfaceTimerIsOffUntilEnabledAndLeavesManualEntryUnchanged() {
        let app = launchQuickSurfaceApp()

        XCTAssertFalse(quickSurfaceTimerRow(in: app).exists)
        XCTAssertFalse(app.buttons["startQuickSurfaceTimerButton"].exists)
        XCTAssertTrue(app.pickerWheels.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Service"].isSelected)
        XCTAssertFalse(app.buttons["saveEntryButton"].isEnabled)
        XCTAssertEqual(app.textFields["entryNoteField"].value as? String, "Short note (optional)")

        enableQuickSurfaceTimer(in: app)

        let row = quickSurfaceTimerRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startQuickSurfaceTimerButton"].exists)
        XCTAssertFalse(app.buttons["stopQuickSurfaceTimerButton"].exists)
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Service"].isSelected)
        XCTAssertFalse(app.buttons["saveEntryButton"].isEnabled)
        XCTAssertEqual(app.textFields["entryNoteField"].value as? String, "Short note (optional)")
    }

    func testQuickSurfaceRunningTimerPersistsAcrossTerminationAndRelaunch() {
        let testID = UUID()
        let app = launchQuickSurfaceApp(testID: testID)
        enableQuickSurfaceTimer(in: app)

        app.buttons["startQuickSurfaceTimerButton"].tap()
        XCTAssertTrue(app.buttons["stopQuickSurfaceTimerButton"].waitForExistence(timeout: 5))

        app.terminate()
        app.launchArguments = quickSurfaceLaunchArguments(
            testID: testID,
            reset: false,
            makeTimerVisible: true
        )
        app.launch()

        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        let row = quickSurfaceTimerRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stopQuickSurfaceTimerButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["startQuickSurfaceTimerButton"].exists)
    }

    func testQuickSurfaceStopPresentsReviewWithoutNoteField() {
        let app = launchQuickSurfaceApp()
        enableQuickSurfaceTimer(in: app)
        startAndStopQuickSurfaceTimer(in: app)

        let reviewNavigationBar = app.navigationBars["Review timer"]
        XCTAssertTrue(reviewNavigationBar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Review timer"].exists)
        XCTAssertTrue(app.segmentedControls["timerReviewKindPicker"].buttons["Service"].isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["timerReviewDurationPicker"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(app.textFields["entryNoteField"].isHittable)
        XCTAssertTrue(app.buttons["saveTimerReviewButton"].exists)
        XCTAssertTrue(app.buttons["discardTimerReviewButton"].exists)
    }

    func testQuickSurfaceReviewPendingDoesNotOverwriteManualDraftOrCoverIt() {
        let app = launchQuickSurfaceApp()
        enableQuickSurfaceTimer(in: app)

        let wheels = app.pickerWheels
        app.segmentedControls["entryKindPicker"].buttons["Credit"].tap()
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "2")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "30")
        let noteField = app.textFields["entryNoteField"]
        noteField.tap()
        noteField.typeText("Unsaved timer draft")
        app.buttons["dismissEntryKeyboardButton"].tap()

        startAndStopQuickSurfaceTimer(in: app)

        XCTAssertTrue(app.buttons["reviewQuickSurfaceTimerButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Review timer"].exists)
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Credit"].isSelected)
        XCTAssertEqual(wheels.element(boundBy: 0).value as? String, "2")
        XCTAssertEqual(wheels.element(boundBy: 1).value as? String, "30")
        XCTAssertEqual(noteField.value as? String, "Unsaved timer draft")
        XCTAssertTrue(app.buttons["saveEntryButton"].isEnabled)
    }

    func testQuickSurfaceReviewSaveCreatesOneHistoryEntryAndUndo() {
        let app = launchQuickSurfaceApp()
        enableQuickSurfaceTimer(in: app)
        startAndStopQuickSurfaceTimer(in: app)

        XCTAssertTrue(app.navigationBars["Review timer"].waitForExistence(timeout: 5))
        setTimerReviewDuration(minutes: "5", in: app)
        let save = app.buttons["saveTimerReviewButton"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let banner = app.descendants(matching: .any)["mutationBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["undoMutationButton"].waitForExistence(timeout: 5))

        app.tabBars.buttons["History"].tap()
        let entries = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyEntry_'")
        )
        XCTAssertTrue(entries.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(app.staticTexts["Service"].exists)
        XCTAssertTrue(app.staticTexts["5 min"].exists)
    }

    func testQuickSurfaceConfirmedDiscardCreatesNoHistoryEntry() {
        let app = launchQuickSurfaceApp()
        enableQuickSurfaceTimer(in: app)
        startAndStopQuickSurfaceTimer(in: app)

        XCTAssertTrue(app.navigationBars["Review timer"].waitForExistence(timeout: 5))
        app.buttons["discardTimerReviewButton"].tap()
        let confirmDiscard = app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND identifier != %@",
                "Discard",
                "discardTimerReviewButton"
            )
        ).firstMatch
        XCTAssertTrue(confirmDiscard.waitForExistence(timeout: 5))
        confirmDiscard.tap()

        XCTAssertTrue(app.buttons["startQuickSurfaceTimerButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 5))
        let entries = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyEntry_'")
        )
        XCTAssertEqual(entries.count, 0)
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

    func testNotificationDeniedLeavesNewReminderAndQuietGapOff() {
        let app = launchApp(additionalArguments: ["-notificationDeniedUITest"])
        app.tabBars.buttons["Settings"].tap()

        app.buttons["addReminderButton"].tap()
        XCTAssertTrue(app.navigationBars["New reminder"].waitForExistence(timeout: 5))
        app.buttons["confirmAddReminderButton"].tap()

        let notificationStatus = app.staticTexts["notificationAuthorizationStatus"]
        XCTAssertTrue(notificationStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(notificationStatus.label, "Notifications are off for Hourleaf.")
        let openSettingsButton = app.buttons["openNotificationSettingsButton"]
        XCTAssertTrue(scrollUntilVisible(openSettingsButton, in: app))

        let reminderRows = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'reminderRow_'")
        )
        XCTAssertEqual(reminderRows.count, 0)

        let quietGapToggle = app.switches["quietGapCheckToggle"]
        XCTAssertTrue(scrollUntilVisible(quietGapToggle, in: app))
        XCTAssertEqual(quietGapToggle.value as? String, "0")
        quietGapToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(quietGapToggle.value as? String, "0")
    }

    func testNotificationNothingToRecordAddsNoHistoryOrReportTime() {
        let app = launchApp(additionalArguments: ["-notificationNothingUITest"])
        app.tabBars.buttons["History"].tap()

        XCTAssertTrue(app.staticTexts["No entries yet"].waitForExistence(timeout: 5))
    }

    func testQuietGapCopyExplainsLocalSevenDayCheckAndCanBeDisabled() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()

        let quietGapToggle = app.switches["quietGapCheckToggle"]
        XCTAssertTrue(scrollUntilVisible(quietGapToggle, in: app))
        XCTAssertEqual(quietGapToggle.value as? String, "0")
        XCTAssertTrue(
            app.staticTexts[
                "If there is no saved service time, Hourleaf may ask you to check once every seven days. It uses only records in Hourleaf."
            ].exists
        )
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
        XCTAssertTrue(scrollUntilVisible(shortcutsLink, in: app))
        XCTAssertTrue(app.staticTexts["shortcutsFooter"].exists)
    }

    func testSettingsOpensDataManagement() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilVisible(dataManagement, in: app))
        dataManagement.tap()

        XCTAssertTrue(app.buttons["createBackupButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chooseRestoreBackupButton"].waitForExistence(timeout: 5))

        let importIntro = app.staticTexts["Choose an Hourleaf CSV. It adds entries only; it does not change settings or report history."]
        XCTAssertTrue(scrollUntilVisible(importIntro, in: app))
        XCTAssertTrue(app.staticTexts["CSV can add entries back to Hourleaf, but it is not a full backup and does not include settings or report history."].exists)
        let chooseImport = app.buttons["chooseCSVImportButton"]
        XCTAssertTrue(chooseImport.exists)
        chooseImport.tap()

        let pickerCancel = app.buttons["Cancel"]
        XCTAssertTrue(pickerCancel.waitForExistence(timeout: 5))
        pickerCancel.tap()
        XCTAssertTrue(chooseImport.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Error"].exists)
    }

    func testRussianDataManagementImportCopy() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(ru)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Настройки"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Настройки"].tap()
        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilVisible(dataManagement, in: app))
        dataManagement.tap()

        let intro = app.staticTexts["Выберите CSV-файл Hourleaf. Он добавит только записи и не изменит настройки или историю отчётов."]
        XCTAssertTrue(scrollUntilVisible(intro, in: app))
        XCTAssertTrue(app.staticTexts["Импорт записей"].exists)
        XCTAssertTrue(app.buttons["chooseCSVImportButton"].label == "Выбрать CSV-файл")
        XCTAssertTrue(app.staticTexts["Из CSV можно снова добавить записи в Hourleaf, но это не полная резервная копия: в нём нет настроек и истории отчётов."].exists)
    }

    func testUkrainianDataManagementImportCopy() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(uk)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Налаштування"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Налаштування"].tap()
        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilVisible(dataManagement, in: app))
        dataManagement.tap()

        let intro = app.staticTexts["Виберіть CSV-файл Hourleaf. Він додасть лише записи й не змінить налаштування чи історію звітів."]
        XCTAssertTrue(scrollUntilVisible(intro, in: app))
        XCTAssertTrue(app.staticTexts["Імпорт записів"].exists)
        XCTAssertTrue(app.buttons["chooseCSVImportButton"].label == "Вибрати CSV-файл")
        XCTAssertTrue(app.staticTexts["З CSV можна знову додати записи до Hourleaf, але це не повна резервна копія: у ньому немає налаштувань та історії звітів."].exists)
    }

    func testRussianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(ru)"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Добавить время"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
        addEntry(in: app, hours: "1", minutes: "15")
        let repeatButton = app.buttons["repeatLastEntryButton"]
        XCTAssertTrue(repeatButton.waitForExistence(timeout: 5))
        XCTAssertEqual(repeatButton.label, "Повторить последнюю запись")
        XCTAssertEqual(repeatButton.value as? String, "Служение · 1 ч 15 мин")
        app.tabBars.buttons["Настройки"].tap()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["Быстрые команды"], in: app))
        XCTAssertTrue(app.staticTexts["shortcutsFooter"].exists)
    }

    func testUkrainianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(uk)"]
        app.launch()

        XCTAssertTrue(app.navigationBars["Додати час"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveEntryButton"].exists)
        addEntry(in: app, hours: "1", minutes: "15")
        let repeatButton = app.buttons["repeatLastEntryButton"]
        XCTAssertTrue(repeatButton.waitForExistence(timeout: 5))
        XCTAssertEqual(repeatButton.label, "Повторити останній запис")
        XCTAssertEqual(repeatButton.value as? String, "Служіння · 1 год 15 хв")
        app.tabBars.buttons["Налаштування"].tap()
        XCTAssertTrue(scrollUntilVisible(app.staticTexts["Швидкі команди"], in: app))
        XCTAssertTrue(app.staticTexts["shortcutsFooter"].exists)
    }

    func testOnboardingExplainsOpeningBalances() {
        let app = XCUIApplication()
        app.launchArguments = ["-onboardingUITest", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Add time you already have, if any. Then record new time as you go."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["finishOnboardingButton"].exists)
        XCTAssertTrue(app.staticTexts["Already served this service year?"].exists)

        XCTAssertTrue(app.textFields["baselineHoursField"].exists)
    }

    func testOnboardingInputsAndFinalActionRemainReachableAtAccessibilityXXXL() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboardingUITest",
            "-AppleLanguages",
            "(en)",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let baselineHours = app.textFields["baselineHoursField"]
        XCTAssertTrue(baselineHours.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(baselineHours, in: app))

        let minutesWheel = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(minutesWheel.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(minutesWheel, in: app))

        let finish = app.buttons["finishOnboardingButton"]
        XCTAssertTrue(scrollUntilHittable(finish, in: app))
        XCTAssertTrue(finish.isEnabled)
        finish.tap()

        XCTAssertTrue(app.navigationBars["Add time"].waitForExistence(timeout: 5))
    }

    func testDataManagementActionsRemainReachableAtAccessibilityXXXL() {
        let app = launchApp(
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        app.tabBars.buttons["Settings"].tap()

        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilHittable(dataManagement, in: app))
        dataManagement.tap()

        for identifier in [
            "createBackupButton",
            "chooseRestoreBackupButton",
            "exportCSVButton",
            "chooseCSVImportButton"
        ] {
            let action = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(scrollUntilHittable(action, in: app), "Not hittable: \(identifier)")
        }
    }

    func testDarkAppearanceKeepsCriticalSurfacesUsable() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z",
                "-AppleInterfaceStyle",
                "Dark"
            ]
        )
        XCTAssertTrue(app.navigationBars["Add time"].exists)

        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "1")
        let save = app.buttons["saveEntryButton"]
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "15")
        XCTAssertTrue(save.isEnabled)
        XCTAssertTrue(save.isHittable)
        save.tap()

        app.tabBars.buttons["History"].tap()
        let historyEntry = firstHistoryEntry(in: app)
        XCTAssertTrue(historyEntry.waitForExistence(timeout: 5))
        XCTAssertTrue(historyEntry.isHittable)

        app.tabBars.buttons["Progress"].tap()
        let review = app.buttons["reportReviewButton"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(review, in: app))

        app.tabBars.buttons["Settings"].tap()
        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilHittable(dataManagement, in: app))
        XCTAssertTrue(dataManagement.isHittable)
        dataManagement.tap()

        let createBackup = app.buttons["createBackupButton"]
        XCTAssertTrue(createBackup.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(createBackup, in: app))
        XCTAssertTrue(createBackup.isHittable)
    }

    func testCriticalControlsExposeLocalizedAccessibilityLabels() {
        for language in ["en", "ru", "uk"] {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTesting", "-AppleLanguages", "(\(language))"]
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))

            for identifier in ["entryKindPicker", "entryDatePicker", "saveEntryButton"] {
                assertNonEmptyAccessibilityLabel(identifier, in: app)
            }

            app.tabBars.buttons.element(boundBy: 2).tap()
            for identifier in ["previousReportMonthButton", "nextReportMonthButton"] {
                assertNonEmptyAccessibilityLabel(identifier, in: app)
            }

            app.tabBars.buttons.element(boundBy: 3).tap()
            let dataManagement = app.buttons["dataManagementButton"]
            XCTAssertTrue(scrollUntilHittable(dataManagement, in: app))
            assertNonEmptyAccessibilityLabel("dataManagementButton", in: app)
            dataManagement.tap()

            for identifier in [
                "createBackupButton",
                "chooseRestoreBackupButton",
                "exportCSVButton",
                "chooseCSVImportButton"
            ] {
                let action = app.descendants(matching: .any)[identifier]
                XCTAssertTrue(scrollUntilHittable(action, in: app), "Missing \(identifier) in \(language)")
                assertNonEmptyAccessibilityLabel(identifier, in: app)
            }

            app.terminate()
        }
    }

    func testReduceMotionKeepsManualEntryAndTimerReviewUsable() {
        let app = launchQuickSurfaceApp(
            additionalArguments: ["-UIAccessibilityReduceMotionEnabled", "YES"]
        )

        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        let kindPicker = app.segmentedControls["entryKindPicker"]
        let noteField = app.textFields["entryNoteField"]
        let save = app.buttons["saveEntryButton"]
        XCTAssertTrue(kindPicker.buttons["Service"].isSelected)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(noteField.value as? String, "Short note (optional)")

        enableQuickSurfaceTimer(in: app)
        XCTAssertTrue(kindPicker.buttons["Service"].isSelected)
        XCTAssertFalse(save.isEnabled)
        XCTAssertEqual(noteField.value as? String, "Short note (optional)")

        let start = app.buttons["startQuickSurfaceTimerButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable)
        assertNonEmptyAccessibilityLabel("startQuickSurfaceTimerButton", in: app)
        start.tap()

        let stop = app.buttons["stopQuickSurfaceTimerButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isHittable)
        assertNonEmptyAccessibilityLabel("stopQuickSurfaceTimerButton", in: app)
        stop.tap()

        XCTAssertTrue(app.navigationBars["Review timer"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["saveTimerReviewButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["discardTimerReviewButton"].exists)
    }

#if !HOURLEAF_LOCAL_DEVICE
    func testStandardBuildOmitsLocalMigrationGuidance() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()

        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilHittable(dataManagement, in: app))
        dataManagement.tap()
        XCTAssertTrue(app.buttons["createBackupButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["localBuildMigrationGuidance"].exists)
    }
#endif

#if HOURLEAF_LOCAL_DEVICE
    func testLocalBuildShowsMigrationGuidanceAndKeepsBackupReachable() {
        let app = launchApp(
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        app.tabBars.buttons["Settings"].tap()

        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilHittable(dataManagement, in: app))
        dataManagement.tap()

        let guidance = app.descendants(matching: .any)["localBuildMigrationGuidance"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilVisible(guidance, in: app))
        XCTAssertFalse(guidance.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let createBackup = app.buttons["createBackupButton"]
        XCTAssertTrue(scrollUntilHittable(createBackup, in: app))
        XCTAssertTrue(createBackup.isHittable)
    }
#endif

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
        XCTAssertTrue(app.navigationBars["Time before Hourleaf"].waitForExistence(timeout: 5))
        let balancesIntro = app.staticTexts.matching(
            NSPredicate(
                format: "label == %@",
                "This does not create entries for past days. Enter service already counted this year and any minutes carried from an earlier report."
            )
        ).firstMatch
        XCTAssertTrue(balancesIntro.exists)

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

    private func launchLocalizedReportApp(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uiTesting",
            "-AppleLanguages",
            "(\(language))",
            "-seedUITestData",
            "-hourleafTestNow",
            "2026-10-02T12:00:00Z"
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func launchQuickSurfaceApp(
        testID: UUID = UUID(),
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = quickSurfaceLaunchArguments(testID: testID, reset: true) + additionalArguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func quickSurfaceLaunchArguments(
        testID: UUID,
        reset: Bool,
        makeTimerVisible: Bool = false
    ) -> [String] {
        var arguments = [
            "-uiTesting",
            "-AppleLanguages",
            "(en)",
            "-quickSurfacesUITest",
            "-quickSurfacesTestID",
            testID.uuidString,
            "-hourleafTestNow",
            "2026-10-02T12:00:00Z"
        ]
        if reset {
            arguments.append("-resetQuickSurfacesUITest")
        }
        if makeTimerVisible {
            arguments.append("-quickSurfacesUITestTimerVisible")
        }
        return arguments
    }

    private func enableQuickSurfaceTimer(in app: XCUIApplication) {
        app.tabBars.buttons["Settings"].tap()
        let toggle = app.switches["quickSurfaceTimerToggle"]
        XCTAssertTrue(scrollQuickSurfaceSettingsUntilVisible(toggle, in: app))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)

        app.tabBars.buttons["Add"].tap()
        XCTAssertTrue(app.buttons["startQuickSurfaceTimerButton"].waitForExistence(timeout: 5))
    }

    private func startAndStopQuickSurfaceTimer(in app: XCUIApplication) {
        let start = app.buttons["startQuickSurfaceTimerButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "isEnabled == true AND isHittable == true"),
            evaluatedWith: start
        )
        waitForExpectations(timeout: 5)
        start.tap()
        let stop = app.buttons["stopQuickSurfaceTimerButton"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
    }

    private func setTimerReviewDuration(minutes: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["timerReviewDurationPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        let wheels = picker.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "0")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: minutes)
    }

    private func quickSurfaceTimerRow(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["quickSurfaceTimerRow"]
    }

    private func scrollQuickSurfaceSettingsUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        for _ in 0..<8 {
            if element.exists,
               app.frame.intersects(element.frame),
               element.frame.height > 0 {
                return true
            }
            let form = app.collectionViews.firstMatch
            if form.exists {
                form.swipeUp()
            } else {
                app.swipeUp()
            }
        }
        return element.exists && app.frame.intersects(element.frame) && element.frame.height > 0
    }

    private func addEntry(in app: XCUIApplication, hours: String, minutes: String) {
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: hours)
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: minutes)
        app.buttons["saveEntryButton"].tap()
    }

    private func scrollUntilVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<5 {
            if element.exists, app.frame.intersects(element.frame), element.frame.height > 0 {
                return true
            }
            app.swipeUp()
        }
        return element.exists && app.frame.intersects(element.frame) && element.frame.height > 0
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<12 {
            if element.exists, element.isHittable {
                return true
            }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    private func assertNonEmptyAccessibilityLabel(
        _ identifier: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Missing \(identifier)", file: file, line: line)
        let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(label.isEmpty, "Empty accessibility label for \(identifier)", file: file, line: line)
        XCTAssertNotEqual(label, identifier, "Raw identifier exposed as label for \(identifier)", file: file, line: line)
    }

    private func reportBreakdownLine(_ label: String, in app: XCUIApplication) -> XCUIElement {
        reportBreakdownLines(label, in: app).firstMatch
    }

    private func reportBreakdownLines(_ label: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ AND label == %@",
                "reportCalculationBreakdown",
                label
            )
        )
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
