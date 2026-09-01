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
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Ready to send")
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

    func testProgressOmitsWeeklyPaceProse() {
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
    }

    func testProgressAboveSixHundredShowsUncappedTotalWithoutWeeklyPace() {
        let app = launchApp(
            additionalArguments: [
                "-seedPaceAboveGoalUITest",
                "-hourleafTestNow",
                "2026-08-01T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        XCTAssertTrue(app.staticTexts["601 hr 15 min"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["serviceYearPaceText"].exists)
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
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Ready to send")
        XCTAssertTrue(app.staticTexts["reportPreview"].label.contains("Hours: 0"))
    }

    func testClosingShareMenuStillRequiresExplicitMarkAsSent() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-seedBibleStudyUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        app.tabBars.buttons["Progress"].tap()

        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Bible studies: 1"))
        app.buttons["reportReviewButton"].tap()
        XCTAssertTrue(app.buttons["finishReportReviewButton"].waitForExistence(timeout: 5))
        app.buttons["finishReportReviewButton"].tap()

        let prepare = app.buttons["prepareReportButton"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        prepare.tap()

        let close = app.buttons["header.closeButton"]
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
        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Ready to send")

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

        let close = app.buttons["header.closeButton"]
        if close.waitForExistence(timeout: 4) {
            close.tap()
        }

        let state = app.staticTexts["reportLifecycleState"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Prepared to share")
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

        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Готов к отправке")
        XCTAssertTrue(app.staticTexts["Отправьте сразу или сначала проверьте записи и итог."].exists)
        let review = app.buttons["reportReviewButton"]
        XCTAssertEqual(review.label, "Проверить отчёт")
        review.tap()
        XCTAssertTrue(app.navigationBars["Проверить отчёт"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["finishReportReviewButton"].label, "Готово, всё проверено")
    }

    func testReportReadinessCopyIsUkrainian() {
        let app = launchLocalizedReportApp(language: "uk")
        app.tabBars.buttons["Прогрес"].tap()

        XCTAssertEqual(app.staticTexts["reportLifecycleState"].label, "Готово до надсилання")
        XCTAssertTrue(app.staticTexts["Надішліть одразу або спершу перевірте записи й підсумок."].exists)
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
        let day = calendarDayButton(for: pastDate, in: app)
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        day.tap()
        app.navigationBars.firstMatch.tap()
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

    func testHistoryListCalendarDayFilterAndCreatedAtLabels() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )
        addEntry(in: app, hours: "0", minutes: "5")
        app.tabBars.buttons["History"].tap()

        let modePicker = app.segmentedControls["historyViewModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        XCTAssertTrue(modePicker.buttons["List"].isSelected)

        let entries = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyEntry_'")
        )
        XCTAssertTrue(entries.element(boundBy: 2).waitForExistence(timeout: 5))
        XCTAssertEqual(entries.count, 3)

        let createdAtLabels = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH 'historyEntryCreatedAt_'")
        )
        XCTAssertTrue(createdAtLabels.element(boundBy: 2).waitForExistence(timeout: 5))
        XCTAssertEqual(createdAtLabels.count, 3)
        for label in createdAtLabels.allElementsBoundByIndex {
            XCTAssertFalse(label.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        modePicker.buttons["Calendar"].tap()
        XCTAssertTrue(app.buttons["historyCalendarPreviousMonthButton"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["historyCalendarMonth"].label, "October 2026")
        app.buttons["historyCalendarPreviousMonthButton"].tap()
        XCTAssertEqual(app.staticTexts["historyCalendarMonth"].label, "September 2026")

        let seededDay = app.buttons["historyCalendarDay_2026-09-15"]
        XCTAssertTrue(scrollUntilHittable(seededDay, in: app))
        seededDay.tap()

        XCTAssertTrue(entries.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(createdAtLabels.element(boundBy: 1).waitForExistence(timeout: 5))
        XCTAssertEqual(createdAtLabels.count, 2)
        for label in createdAtLabels.allElementsBoundByIndex {
            XCTAssertFalse(label.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
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

    func testSavedToastDisappearsAndHistoryKeepsTheEntry() {
        let app = launchApp()
        addEntry(in: app, hours: "1", minutes: "15")

        let toast = app.descendants(matching: .any)["mutationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            toast.frame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "The saved toast must remain above the tab bar."
        )
        XCTAssertLessThan(toast.frame.midX, app.frame.midX)
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        XCTAssertFalse(app.buttons["undoMutationButton"].exists)
        XCTAssertFalse(app.buttons["dismissUndoBannerButton"].exists)
        XCTAssertTrue(toast.waitForNonExistence(timeout: 5))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(firstHistoryEntry(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["1 hr 15 min"].exists)
    }

    func testSavedToastRemainsReadableAtAccessibilityTextSize() {
        let app = launchApp(
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityXXXL"
            ]
        )
        addEntry(in: app, hours: "1", minutes: "15")

        let toast = app.descendants(matching: .any)["mutationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(
            toast.frame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "The expanded saved toast must remain above the tab bar."
        )
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        XCTAssertFalse(app.buttons["undoMutationButton"].exists)
        XCTAssertFalse(app.buttons["dismissUndoBannerButton"].exists)
    }

    func testQuickEntryHasNoVisibleTitleOrRepeatAndShareOpensReportMonthChooser() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )

        XCTAssertFalse(app.navigationBars["Add time"].exists)
        XCTAssertFalse(app.buttons["repeatLastEntryButton"].exists)

        app.tabBars.buttons["Progress"].tap()
        let selectedMonth = app.staticTexts["selectedReportMonth"]
        XCTAssertTrue(selectedMonth.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedMonth.label, "September 2026")
        app.buttons["nextReportMonthButton"].tap()
        XCTAssertEqual(selectedMonth.label, "October 2026")
        app.tabBars.buttons["Add"].tap()

        let share = app.buttons["shareReportButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        share.tap()

        XCTAssertTrue(app.tabBars.buttons["Progress"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Progress"].isSelected)
        XCTAssertTrue(selectedMonth.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedMonth.label, "September 2026")
        XCTAssertTrue(app.buttons["previousReportMonthButton"].exists)
        XCTAssertTrue(app.buttons["nextReportMonthButton"].exists)
    }

    func testQuickEntryBibleStudyCounterUpdatesCurrentMonthReport() {
        let app = launchApp(
            additionalArguments: [
                "-pastDateUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )

        let count = app.staticTexts["bibleStudyCount"]
        let increase = app.buttons["increaseBibleStudyCountButton"]
        XCTAssertTrue(scrollUntilHittable(increase, in: app))
        XCTAssertEqual(count.value as? String, "0")
        increase.tap()
        expectation(
            for: NSPredicate(format: "value == %@", "1"),
            evaluatedWith: count
        )
        waitForExpectations(timeout: 5)

        app.tabBars.buttons["Progress"].tap()
        let selectedMonth = app.staticTexts["selectedReportMonth"]
        XCTAssertTrue(selectedMonth.waitForExistence(timeout: 5))
        XCTAssertEqual(selectedMonth.label, "September 2026")
        app.buttons["nextReportMonthButton"].tap()
        XCTAssertEqual(selectedMonth.label, "October 2026")

        let preview = app.staticTexts["reportPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Bible studies: 1"))
    }

    func testQuickEntryShowsBibleStudiesWithoutInitialScrollAtDefaultTextSize() {
        let app = launchApp(
            additionalArguments: [
                "-pastDateUITest",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )

        let tabBar = app.tabBars.firstMatch
        let elements = [
            app.staticTexts["bibleStudyLabel"],
            app.buttons["decreaseBibleStudyCountButton"],
            app.staticTexts["bibleStudyCount"],
            app.buttons["increaseBibleStudyCountButton"]
        ]

        XCTAssertTrue(tabBar.waitForExistence(timeout: 5))
        XCTAssertTrue(elements[0].waitForExistence(timeout: 5))
        for element in elements {
            XCTAssertTrue(element.exists)
            XCTAssertGreaterThanOrEqual(element.frame.minY, app.windows.firstMatch.frame.minY)
            XCTAssertLessThanOrEqual(element.frame.maxY, tabBar.frame.minY)
        }
    }

    func testQuickSurfaceTimerIsOffUntilEnabledAndLeavesManualEntryUnchanged() {
        let app = launchQuickSurfaceApp()

        XCTAssertFalse(quickSurfaceTimerRow(in: app).exists)
        XCTAssertFalse(app.buttons["startQuickSurfaceTimerButton"].exists)
        XCTAssertTrue(app.pickerWheels.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Service"].isSelected)
        XCTAssertFalse(app.buttons["saveEntryButton"].isEnabled)
        assertEmptyNoteField(app.textFields["entryNoteField"])

        enableQuickSurfaceTimer(in: app)

        let row = quickSurfaceTimerRow(in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startQuickSurfaceTimerButton"].exists)
        XCTAssertFalse(app.buttons["stopQuickSurfaceTimerButton"].exists)
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Service"].isSelected)
        XCTAssertFalse(app.buttons["saveEntryButton"].isEnabled)
        assertEmptyNoteField(app.textFields["entryNoteField"])
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

    func testQuickSurfaceReviewSaveCreatesOneHistoryEntryAndShowsSavedToast() {
        let app = launchQuickSurfaceApp()
        enableQuickSurfaceTimer(in: app)
        startAndStopQuickSurfaceTimer(in: app)

        XCTAssertTrue(app.navigationBars["Review timer"].waitForExistence(timeout: 5))
        setTimerReviewDuration(minutes: "5", in: app)
        let save = app.buttons["saveTimerReviewButton"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let toast = app.descendants(matching: .any)["mutationToast"]
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Saved"].exists)
        XCTAssertFalse(app.buttons["undoMutationButton"].exists)

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

        let notificationStatus = app.staticTexts["monthlyReportReminderStatus"]
        XCTAssertTrue(notificationStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(notificationStatus.label, "Notifications are off in iPhone Settings.")
        let openSettingsButton = app.buttons["openMonthlyReminderSettingsButton"]
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
                "After a week without a service entry, Hourleaf can ask you to check."
            ].exists
        )
    }

    func testColdQuickEntryRouteLaunchesOnBlankEntry() {
        let app = launchApp(additionalArguments: ["-coldQuickEntryRouteUITest"])

        XCTAssertFalse(app.navigationBars["Add time"].exists)
        let save = app.buttons["saveEntryButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(app.buttons["shareReportButton"].waitForExistence(timeout: 5))
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
        let yesterdayButton = calendarDayButton(for: yesterday, in: app)
        XCTAssertTrue(yesterdayButton.waitForExistence(timeout: 5))
        yesterdayButton.tap()
        app.navigationBars.firstMatch.tap()
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "2")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "30")
        let noteField = app.textFields["entryNoteField"]
        noteField.tap()
        noteField.typeText(draftNote)
        XCTAssertEqual(noteField.value as? String, draftNote)

        app.tabBars.buttons["History"].tap()
        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertFalse(app.navigationBars["Add time"].exists)
        XCTAssertTrue(app.buttons["saveEntryButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["entryKindPicker"].buttons["Service"].isSelected)
        XCTAssertFalse(app.buttons["saveEntryButton"].isEnabled)
        assertEmptyNoteField(noteField)

        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "1")
        app.buttons["saveEntryButton"].tap()
        app.tabBars.buttons["History"].tap()

        XCTAssertTrue(app.staticTexts["Service"].waitForExistence(timeout: 5))
        let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let todayIdentifier = "historyEntryDate_\(today.year!)_\(today.month!)_\(today.day!)"
        XCTAssertTrue(app.staticTexts[todayIdentifier].exists)
    }

    func testSettingsOffersPlainLanguageWatchAndVoiceGuides() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()

        let watchGuide = app.descendants(matching: .any)["watchGuideLink"]
        XCTAssertTrue(scrollUntilVisible(watchGuide, in: app))
        XCTAssertTrue(app.staticTexts["Apple Watch and voice"].exists)
        let voiceGuide = app.descendants(matching: .any)["voiceGuideLink"]
        XCTAssertTrue(scrollUntilVisible(voiceGuide, in: app))
        XCTAssertTrue(app.staticTexts["settingsGuidesFooter"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["serviceSiriTip"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["shortcutsLink"].exists)
    }

    func testSettingsOpensDataManagement() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()
        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilVisible(dataManagement, in: app))
        dataManagement.tap()

        XCTAssertTrue(app.buttons["createBackupButton"].waitForExistence(timeout: 5))
        let chooseRestore = app.buttons["chooseRestoreBackupButton"]
        XCTAssertTrue(chooseRestore.waitForExistence(timeout: 5))
        chooseRestore.tap()

        let restorePickerClose = app.buttons["Close"]
        let restorePickerCancel = app.buttons["Cancel"]
        if restorePickerClose.waitForExistence(timeout: 5) {
            restorePickerClose.tap()
        } else {
            XCTAssertTrue(restorePickerCancel.waitForExistence(timeout: 5))
            restorePickerCancel.tap()
        }
        XCTAssertTrue(chooseRestore.waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Error"].exists)

        let importIntro = app.staticTexts["Choose an Hourleaf CSV. It adds entries only; it does not change settings or report history."]
        XCTAssertTrue(scrollUntilVisible(importIntro, in: app))
        XCTAssertTrue(app.staticTexts["CSV can add entries back to Hourleaf, but it is not a full backup and does not include settings or report history."].exists)
        let chooseImport = app.buttons["chooseCSVImportButton"]
        XCTAssertTrue(chooseImport.exists)
        chooseImport.tap()

        let pickerClose = app.buttons["Close"]
        let pickerCancel = app.buttons["Cancel"]
        if pickerClose.waitForExistence(timeout: 5) {
            pickerClose.tap()
        } else {
            XCTAssertTrue(pickerCancel.waitForExistence(timeout: 5))
            pickerCancel.tap()
        }
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

        XCTAssertFalse(app.navigationBars["Добавить время"].exists)
        XCTAssertTrue(app.buttons["saveEntryButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["repeatLastEntryButton"].exists)
        XCTAssertTrue(app.buttons["shareReportButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Настройки"].tap()
        let watchGuide = app.descendants(matching: .any)["watchGuideLink"]
        XCTAssertTrue(scrollUntilVisible(watchGuide, in: app))
        XCTAssertTrue(app.staticTexts["Apple Watch и голос"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["voiceGuideLink"].exists)
        XCTAssertFalse(app.staticTexts["Быстрые команды"].exists)
    }

    func testUkrainianInterfaceLaunches() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(uk)"]
        app.launch()

        XCTAssertFalse(app.navigationBars["Додати час"].exists)
        XCTAssertTrue(app.buttons["saveEntryButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["repeatLastEntryButton"].exists)
        XCTAssertTrue(app.buttons["shareReportButton"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Налаштування"].tap()
        let watchGuide = app.descendants(matching: .any)["watchGuideLink"]
        XCTAssertTrue(scrollUntilVisible(watchGuide, in: app))
        XCTAssertTrue(app.staticTexts["Apple Watch і голос"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["voiceGuideLink"].exists)
        XCTAssertFalse(app.staticTexts["Швидкі команди"].exists)
    }

    func testFreshInstallOpensQuickEntryWithoutOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = ["-freshInstallUITest", "-AppleLanguages", "(en)"]
        app.launch()

        XCTAssertTrue(app.buttons["saveEntryButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["shareReportButton"].exists)
        XCTAssertFalse(app.buttons["finishOnboardingButton"].exists)
        XCTAssertFalse(app.staticTexts["Already served this service year?"].exists)
    }

    func testFreshInstallQuickEntryRemainsReachableAtAccessibilityXXXL() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-freshInstallUITest",
            "-AppleLanguages",
            "(en)",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL"
        ]
        app.launch()

        let save = app.buttons["saveEntryButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(save, in: app))
        XCTAssertFalse(app.buttons["finishOnboardingButton"].exists)
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
        XCTAssertFalse(app.navigationBars["Add time"].exists)

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

    func testLightAppearanceChoicePersistsAndKeepsCriticalSurfacesUsable() {
        let app = launchApp(
            additionalArguments: [
                "-seedUITestData",
                "-hourleafTestNow",
                "2026-10-02T12:00:00Z"
            ]
        )

        app.tabBars.buttons["Settings"].tap()
        selectAppearance("Match iPhone", in: app)
        selectAppearance("Light", in: app)
        assertAppearancePickerValue("Light", in: app)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        assertAppearancePickerValue("Light", in: app)

        app.tabBars.buttons["Add"].tap()
        let wheels = app.pickerWheels
        XCTAssertTrue(wheels.element(boundBy: 0).waitForExistence(timeout: 5))
        wheels.element(boundBy: 0).adjust(toPickerWheelValue: "1")
        wheels.element(boundBy: 1).adjust(toPickerWheelValue: "15")
        app.buttons["saveEntryButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["mutationToast"].waitForExistence(timeout: 5))

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(firstHistoryEntry(in: app).waitForExistence(timeout: 5))

        app.tabBars.buttons["Progress"].tap()
        let review = app.buttons["reportReviewButton"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(scrollUntilHittable(review, in: app))
        review.tap()
        XCTAssertTrue(app.buttons["finishReportReviewButton"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Settings"].tap()
        let dataManagement = app.buttons["dataManagementButton"]
        XCTAssertTrue(scrollUntilHittable(dataManagement, in: app))
        dataManagement.tap()
        XCTAssertTrue(app.buttons["createBackupButton"].waitForExistence(timeout: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        selectAppearance("Match iPhone", in: app)
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
            let storeActions: [(String, String)] = switch language {
            case "ru":
                [
                    ("shareHourleafButton", "Поделиться Hourleaf"),
                    ("rateHourleafButton", "Оценить Hourleaf")
                ]
            case "uk":
                [
                    ("shareHourleafButton", "Поділитися Hourleaf"),
                    ("rateHourleafButton", "Оцінити Hourleaf")
                ]
            default:
                [
                    ("shareHourleafButton", "Share Hourleaf"),
                    ("rateHourleafButton", "Rate Hourleaf")
                ]
            }
            for (identifier, expectedLabel) in storeActions {
                let action = app.descendants(matching: .any)[identifier]
                XCTAssertTrue(scrollUntilHittable(action, in: app), "Missing \(identifier) in \(language)")
                XCTAssertEqual(action.label, expectedLabel, "Unexpected \(identifier) label in \(language)")
                assertNonEmptyAccessibilityLabel(identifier, in: app)
            }

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
        assertEmptyNoteField(noteField)

        enableQuickSurfaceTimer(in: app)
        XCTAssertTrue(kindPicker.buttons["Service"].isSelected)
        XCTAssertFalse(save.isEnabled)
        assertEmptyNoteField(noteField)

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

    func testSimplifiedSettingsShowsMonthlyReminderAndGuidesWithoutRemovedControls() {
        let app = launchApp()
        app.tabBars.buttons["Settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let monthlyReminder = app.switches["monthlyReportReminderToggle"]
        XCTAssertTrue(monthlyReminder.waitForExistence(timeout: 5))
        XCTAssertEqual(monthlyReminder.value as? String, "1")
        XCTAssertTrue(app.staticTexts["minutePolicyExample"].exists)
        XCTAssertFalse(app.textFields["creditLabelField"].exists)
        XCTAssertFalse(app.staticTexts["Credit wording"].exists)
        XCTAssertFalse(app.switches["planningVisibilityToggle"].exists)
        XCTAssertFalse(app.staticTexts["Show weekly guide to 600 hours"].exists)
        XCTAssertFalse(app.buttons["existingTimeButton"].exists)
        XCTAssertFalse(app.staticTexts["Time before Hourleaf"].exists)

        let watchGuide = app.descendants(matching: .any)["watchGuideLink"]
        XCTAssertTrue(scrollUntilVisible(watchGuide, in: app))
        XCTAssertTrue(app.staticTexts["Hourleaf on Apple Watch"].exists)
        let voiceGuide = app.descendants(matching: .any)["voiceGuideLink"]
        XCTAssertTrue(scrollUntilVisible(voiceGuide, in: app))
        XCTAssertTrue(app.staticTexts["Add time with Siri"].exists)
        XCTAssertFalse(app.staticTexts["Shortcuts"].exists)
    }

    func testTimeSelectionFeedbackTogglePersistsAcrossRelaunch() {
        let resetArgument = "-resetTimeSelectionFeedbackUITest"
        let app = launchApp(additionalArguments: [resetArgument])
        app.tabBars.buttons["Settings"].tap()

        let toggle = app.switches["timeSelectionFeedbackToggle"]
        XCTAssertTrue(scrollUntilHittable(toggle, in: app))
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.5)).tap()
        app.tabBars.buttons["Add"].tap()
        app.tabBars.buttons["Settings"].tap()
        let disabledToggle = app.switches["timeSelectionFeedbackToggle"]
        XCTAssertTrue(scrollUntilHittable(disabledToggle, in: app))
        XCTAssertEqual(disabledToggle.value as? String, "0")

        app.terminate()
        let relaunchedApp = launchApp()
        relaunchedApp.tabBars.buttons["Settings"].tap()

        let persistedToggle = relaunchedApp.switches["timeSelectionFeedbackToggle"]
        XCTAssertTrue(scrollUntilHittable(persistedToggle, in: relaunchedApp))
        XCTAssertEqual(persistedToggle.value as? String, "0")

        // Restore the default so this persisted presentation preference cannot
        // influence another UI test in the same installed app container.
        persistedToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        relaunchedApp.tabBars.buttons["Add"].tap()
        relaunchedApp.tabBars.buttons["Settings"].tap()
        let enabledToggle = relaunchedApp.switches["timeSelectionFeedbackToggle"]
        XCTAssertTrue(scrollUntilHittable(enabledToggle, in: relaunchedApp))
        XCTAssertEqual(enabledToggle.value as? String, "1")
        relaunchedApp.terminate()
        let restoredApp = launchApp()
        restoredApp.tabBars.buttons["Settings"].tap()
        let restoredToggle = restoredApp.switches["timeSelectionFeedbackToggle"]
        XCTAssertTrue(scrollUntilHittable(restoredToggle, in: restoredApp))
        XCTAssertEqual(restoredToggle.value as? String, "1")
    }

    private func launchApp(additionalArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-AppleLanguages", "(en)"] + additionalArguments
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 5))
        return app
    }

    private func selectAppearance(_ option: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["appearancePicker"]
        XCTAssertTrue(scrollAppearancePickerIntoView(picker, in: app))
        picker.tap()

        let button = app.buttons[option]
        if button.waitForExistence(timeout: 2) {
            button.tap()
            return
        }

        let text = app.staticTexts[option]
        XCTAssertTrue(text.waitForExistence(timeout: 2))
        text.tap()
    }

    private func assertAppearancePickerValue(_ expected: String, in app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["appearancePicker"]
        XCTAssertTrue(scrollAppearancePickerIntoView(picker, in: app))
        picker.tap()
        let option = app.buttons[expected]
        XCTAssertTrue(option.waitForExistence(timeout: 2))
        XCTAssertTrue(option.isSelected, "Appearance option was not selected: \(expected)")
        option.tap()
    }

    private func scrollAppearancePickerIntoView(
        _ picker: XCUIElement,
        in app: XCUIApplication
    ) -> Bool {
        for _ in 0..<8 {
            if picker.exists, picker.isHittable {
                return true
            }
            let form = app.collectionViews.firstMatch
            if form.exists {
                form.swipeDown()
            } else {
                app.swipeDown()
            }
        }
        return picker.exists && picker.isHittable
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
        toggle.tap()

        let directTap = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"),
            object: toggle
        )
        if XCTWaiter.wait(for: [directTap], timeout: 1) != .completed {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }

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

    private func assertEmptyNoteField(
        _ field: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Missing note field", file: file, line: line)
        XCTAssertEqual(field.label, "Note", "Unexpected note field label", file: file, line: line)

        let value = field.value as? String
        XCTAssertTrue(
            value == nil || value == "" || value == "Note",
            "Expected an empty note field, got \(value ?? "<nil>")",
            file: file,
            line: line
        )
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

    private func calendarDayButton(for date: Date, in app: XCUIApplication) -> XCUIElement {
        let day = Self.dayFormatter.string(from: date)
        let dayMonth = Self.dayMonthFormatter.string(from: date)
        let monthDay = Self.monthDayFormatter.string(from: date)
        return app.buttons.matching(
            NSPredicate(
                format: "label == %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
                day,
                dayMonth,
                monthDay
            )
        ).firstMatch
    }

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d"
        return formatter
    }()

    private static let dayMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "d MMMM"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d"
        return formatter
    }()

}
