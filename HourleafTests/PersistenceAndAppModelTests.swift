import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class PersistenceAndAppModelTests: XCTestCase {
    func testDefaultPersistentStoreIsLocalOnly() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafLocalDefault-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Hourleaf.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var persistence: PersistenceController?
        defer {
            if let persistence {
                try? closePersistentStores(in: persistence)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let opened = PersistenceController(storeURL: storeURL)
        persistence = opened

        XCTAssertNil(opened.startupError)
        XCTAssertNil(opened.container.persistentStoreDescriptions.first?.cloudKitContainerOptions)
        XCTAssertEqual(
            opened.container.persistentStoreCoordinator.persistentStores.first?.url?.standardizedFileURL,
            storeURL.standardizedFileURL
        )
    }

    func testRepositoryRoundTripsEntrySettingsPolicyReminderAndReceipt() async throws {
        let repository = makeRepository()
        var initialSettings = try await repository.loadSettings()
        initialSettings.ledgerStartMonth = MonthKey(year: 2026, month: 7)
        try await repository.saveSettings(initialSettings)
        let timestamp = Date(timeIntervalSince1970: 1_780_000_000)
        let entry = TimeEntry(
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "Morning",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        _ = try await repository.apply(createCommand(for: entry))
        let savedEntries = try await repository.fetchEntries()
        XCTAssertEqual(savedEntries, [entry])

        var settings = try await repository.loadSettings()
        settings.onboardingComplete = true
        settings.reportLanguage = .ukrainian
        try await repository.saveSettings(settings)
        let savedSettings = try await repository.loadSettings()
        XCTAssertEqual(savedSettings.reportLanguage, .ukrainian)

        let policy = ReportingPolicy(effectiveMonth: MonthKey(year: 2026, month: 7), mode: .discard)
        try await repository.savePolicy(policy)
        let savedPolicies = try await repository.fetchPolicies()
        XCTAssertEqual(savedPolicies.first?.mode, .discard)

        let reminder = ReminderSchedule(weekday: 2, hour: 13, minute: 30)
        try await repository.saveReminder(reminder)
        let savedReminders = try await repository.fetchReminders()
        XCTAssertEqual(savedReminders, [reminder])

        let receipt = ReportReceipt(
            id: UUID(),
            month: MonthKey(year: 2026, month: 7),
            text: "July 2026\nHours: 1",
            serviceHours: 1,
            creditHours: 0,
            serviceCarryOut: 15,
            creditCarryOut: 0,
            preparedAt: .now,
            confirmedSentAt: .now
        )
        let report = MonthlyReport(
            month: receipt.month,
            rawServiceMinutes: 75,
            rawCreditMinutes: 0,
            serviceCarryIn: 0,
            creditCarryIn: 0,
            serviceHours: receipt.serviceHours,
            creditHours: receipt.creditHours,
            serviceCarryOut: receipt.serviceCarryOut,
            creditCarryOut: receipt.creditCarryOut
        )
        let calculationFingerprint = "calculation-test"
        let details = ReportSnapshotDetails(
            report: report,
            reportingMode: .carry,
            reportLanguage: .english,
            creditLabel: "Credit hours",
            templateID: "standard",
            calculationFingerprint: calculationFingerprint,
            presentationFingerprint: ReportFingerprint.presentation(
                calculationFingerprint: calculationFingerprint,
                language: .english,
                creditLabel: "Credit hours",
                templateID: "standard",
                text: receipt.text
            )
        )
        try await repository.saveReceipt(receipt, details: details)
        let savedReceipts = try await repository.fetchReceipts()
        XCTAssertEqual(savedReceipts.first?.id, receipt.id)
        let storedSnapshot = try await repository.ledgerSnapshot()
        let snapshotMetadata = try XCTUnwrap(storedSnapshot.reportSnapshots.first)
        XCTAssertEqual(snapshotMetadata.rawServiceMinutes, 75)
        XCTAssertEqual(snapshotMetadata.serviceCarryIn, 0)
        XCTAssertEqual(snapshotMetadata.reportingMode, RemainderMode.carry.rawValue)
        XCTAssertEqual(snapshotMetadata.reportLanguage, ReportLanguage.english.rawValue)
        XCTAssertEqual(snapshotMetadata.calculationFingerprint, calculationFingerprint)
        XCTAssertFalse(snapshotMetadata.legacyCalculationUnavailable)

        let allRecords = try await repository.fetchAllEntries()
        let entryRecord = try XCTUnwrap(allRecords.first)
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: entryRecord.revision,
                operation: .delete,
                occurredAt: timestamp.addingTimeInterval(1),
                source: .appHistory
            )
        )
        let activeEntriesAfterDelete = try await repository.fetchEntries()
        XCTAssertTrue(activeEntriesAfterDelete.isEmpty)
        let allEntriesAfterDelete = try await repository.fetchAllEntries()
        let deletedEntry = try XCTUnwrap(allEntriesAfterDelete.first)
        XCTAssertEqual(deletedEntry.id, entry.id)
        XCTAssertNotNil(deletedEntry.deletedAt)
    }

    func testPastEditMarksConfirmedReceiptStale() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        XCTAssertEqual(model.startupState, .ready)
        let month = MonthKey(Date(), calendar: .hourleaf)
        let date = Date()
        let added = await model.addEntry(kind: .service, date: date, hours: 1, minutes: 15, note: nil)
        XCTAssertTrue(added)

        let report = model.report(for: month)
        let text = ReportFormatter.format(report, settings: model.settings)
        let createdReceipt = await model.createReceipt(for: report, text: text)
        let receipt = try XCTUnwrap(createdReceipt)
        await model.markReceiptSent(receipt)
        let entry = try XCTUnwrap(model.entryRecords.first)

        let updated = await model.updateEntry(entry, kind: .service, date: date, hours: 2, minutes: 0, note: nil)
        XCTAssertTrue(updated)
        let storedReceipt = try XCTUnwrap(model.receipts.first)
        XCTAssertTrue(model.isStale(storedReceipt))
        XCTAssertTrue(model.changeAffectsConfirmedReport(from: month))
    }

    func testFingerprintsExposeDiscardedMinuteChangesAndPresentationChanges() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let month = MonthKey(Date(), calendar: .hourleaf)
        await model.updateReportingPolicy(mode: .discard)

        let added = await model.addEntry(kind: .service, date: Date(), hours: 1, minutes: 5, note: nil)
        XCTAssertTrue(added)
        let originalReport = model.report(for: month)
        let originalText = ReportFormatter.format(originalReport, settings: model.settings)
        let createdReceipt = await model.createReceipt(for: originalReport, text: originalText)
        let receipt = try XCTUnwrap(createdReceipt)
        XCTAssertEqual(model.reportSnapshots.first(where: { $0.id == receipt.id })?.calculationFingerprint?.isEmpty, false)

        let record = try XCTUnwrap(model.entryRecords.first)
        let updated = await model.updateEntry(
            record,
            kind: .service,
            date: Date(),
            hours: 1,
            minutes: 15,
            note: nil
        )
        XCTAssertTrue(updated)
        let changedReport = model.report(for: month)
        XCTAssertEqual(changedReport.serviceHours, originalReport.serviceHours)
        XCTAssertEqual(changedReport.serviceCarryOut, originalReport.serviceCarryOut)
        XCTAssertEqual(ReportFormatter.format(changedReport, settings: model.settings), receipt.text)
        XCTAssertTrue(model.isStale(receipt))

        await model.undoLatestMutation()
        XCTAssertFalse(model.isStale(receipt))

        await model.updateReportLanguage(.ukrainian)
        XCTAssertTrue(model.isStale(receipt))
    }

    func testFingerprintsTrackDeleteRestoreAndUndo() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let month = MonthKey(Date(), calendar: .hourleaf)
        await model.updateReportingPolicy(mode: .discard)
        let added = await model.addEntry(kind: .service, date: Date(), hours: 1, minutes: 5, note: nil)
        XCTAssertTrue(added)

        let report = model.report(for: month)
        let createdReceipt = await model.createReceipt(
            for: report,
            text: ReportFormatter.format(report, settings: model.settings)
        )
        let receipt = try XCTUnwrap(createdReceipt)
        let record = try XCTUnwrap(model.entryRecords.first)
        let deletedSuccessfully = await model.deleteEntry(record)
        XCTAssertTrue(deletedSuccessfully)
        XCTAssertTrue(model.isStale(receipt))

        let deleted = try XCTUnwrap(model.deletedEntryRecords.first)
        let restoredSuccessfully = await model.restoreEntry(deleted)
        XCTAssertTrue(restoredSuccessfully)
        XCTAssertFalse(model.isStale(receipt))

        await model.undoLatestMutation()
        XCTAssertTrue(model.isStale(receipt))
    }

    func testReportPreparationRejectsMixedStaleInputs() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let month = MonthKey(Date(), calendar: .hourleaf)
        let date = Date()
        let firstAdded = await model.addEntry(kind: .service, date: date, hours: 1, minutes: 15, note: nil)
        XCTAssertTrue(firstAdded)
        let capturedReport = model.report(for: month)
        let capturedText = ReportFormatter.format(capturedReport, settings: model.settings)

        let secondAdded = await model.addEntry(kind: .service, date: date, hours: 0, minutes: 15, note: nil)
        XCTAssertTrue(secondAdded)
        let receipt = await model.createReceipt(for: capturedReport, text: capturedText)

        XCTAssertNil(receipt)
        XCTAssertEqual(model.errorMessage, String(localized: "error.report_changed"))
        let receipts = try await repository.fetchReceipts()
        XCTAssertTrue(receipts.isEmpty)
    }

    func testConcurrentReportPreparationCreatesOnlyOneSnapshot() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let month = MonthKey(Date(), calendar: .hourleaf)
        let report = model.report(for: month)
        let text = ReportFormatter.format(report, settings: model.settings)

        async let first = model.createReceipt(for: report, text: text)
        async let second = model.createReceipt(for: report, text: text)
        let (firstResult, secondResult) = await (first, second)
        let results = [firstResult, secondResult]

        XCTAssertEqual(results.compactMap { $0 }.count, 1)
        let receipts = try await repository.fetchReceipts()
        XCTAssertEqual(receipts.count, 1)
    }

    func testAddCommandRejectsZeroDuration() async throws {
        let repository = makeRepository()
        do {
            _ = try await AddTimeEntryCommand(repository: repository)
                .execute(kind: .service, date: .now, hours: 0, minutes: 0, note: nil)
            XCTFail("The command must reject zero duration.")
        } catch {
            XCTAssertEqual(error as? EntryValidationError, .emptyDuration)
        }
    }

    func testOneTapSelectsLatestActiveByCreatedAtThenGreatestUUID() throws {
        let day = LocalDay(year: 2026, month: 8, day: 3)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [
            makeOneTapRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
                day: day,
                minutes: 15,
                createdAt: createdAt.addingTimeInterval(-1)
            ),
            makeOneTapRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                kind: .credit,
                day: day,
                minutes: 30,
                createdAt: createdAt
            ),
            makeOneTapRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                day: day,
                minutes: 75,
                createdAt: createdAt
            )
        ]

        let proposal = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: records))
        XCTAssertEqual(
            proposal.sourceEntryID,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        XCTAssertEqual(proposal.sourceCreatedAt, createdAt)
        XCTAssertEqual(proposal.minutes, 75)
    }

    func testOneTapIgnoresDeletedNewerRecord() throws {
        let day = LocalDay(year: 2026, month: 8, day: 3)
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let activeID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let records = [
            makeOneTapRecord(
                id: activeID,
                day: day,
                minutes: 45,
                createdAt: createdAt
            ),
            makeOneTapRecord(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                kind: .credit,
                day: day,
                minutes: 90,
                createdAt: createdAt.addingTimeInterval(1),
                deletedAt: createdAt.addingTimeInterval(2)
            )
        ]

        let proposal = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: records))
        XCTAssertEqual(proposal.sourceEntryID, activeID)
        XCTAssertEqual(proposal.kind, .service)
        XCTAssertEqual(proposal.minutes, 45)
    }

    func testOneTapIgnoresUpdatedAtAndOriginalEntryDay() throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let olderEditedRecently = makeOneTapRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            kind: .credit,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 20,
            createdAt: createdAt,
            updatedAt: createdAt.addingTimeInterval(100)
        )
        let newer = makeOneTapRecord(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 2),
            minutes: 75,
            createdAt: createdAt.addingTimeInterval(1),
            updatedAt: createdAt.addingTimeInterval(2)
        )

        let proposal = try XCTUnwrap(
            RepeatLastEntryCommand.proposal(from: [olderEditedRecently, newer])
        )
        XCTAssertEqual(proposal.sourceEntryID, newer.id)
        XCTAssertEqual(proposal.sourceCreatedAt, newer.entry.createdAt)
        XCTAssertEqual(proposal.kind, .service)
        XCTAssertEqual(proposal.minutes, 75)
    }

    func testOneTapIsUnavailableWhenNoActiveEntries() {
        let deleted = makeOneTapRecord(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            day: LocalDay(year: 2026, month: 8, day: 3),
            minutes: 30,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            deletedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        XCTAssertNil(RepeatLastEntryCommand.proposal(from: [deleted]))
    }

    func testOneTapCopiesOnlyKindAndMinutesForToday() async throws {
        let tappedAt = Date().addingTimeInterval(-2)
        let sourceDay = oneTapDay(tappedAt, offsetBy: -1)
        let sourceCreatedAt = tappedAt.addingTimeInterval(-1)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let source = TimeEntry(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            kind: .service,
            day: sourceDay,
            minutes: 75,
            note: "Private source note",
            createdAt: sourceCreatedAt,
            updatedAt: sourceCreatedAt
        )
        _ = try await repository.apply(createCommand(for: source))
        let initialSnapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: initialSnapshot.entries))
        let repeatedID = UUID(uuidString: "70000000-0000-0000-0000-000000000007")!
        let receipt = try await RepeatLastEntryCommand(repository: repository).execute(
            expected: expected,
            at: tappedAt,
            mutationID: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
            entryID: repeatedID
        )

        let snapshot = try await repository.ledgerSnapshot()
        let repeated = try XCTUnwrap(snapshot.entries.first { $0.id == repeatedID })
        XCTAssertFalse(receipt.wasReplay)
        XCTAssertEqual(repeated.entry.kind, .service)
        XCTAssertEqual(repeated.entry.minutes, 75)
        XCTAssertEqual(repeated.entry.day, LocalDay(tappedAt, calendar: .hourleaf))
        XCTAssertEqual(repeated.entry.createdAt, tappedAt)
        XCTAssertEqual(repeated.entry.updatedAt, tappedAt)
        XCTAssertNil(repeated.entry.note)
        XCTAssertEqual(repeated.source, EntryMutationSource.appOneTap.rawValue)
    }

    func testOneTapNeverCopiesTheSourceNote() async throws {
        let tappedAt = Date().addingTimeInterval(-2)
        let sourceDay = oneTapDay(tappedAt, offsetBy: -1)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let source = TimeEntry(
            id: UUID(uuidString: "90000000-0000-0000-0000-000000000009")!,
            kind: .service,
            day: sourceDay,
            minutes: 30,
            note: "Never copy this",
            createdAt: tappedAt.addingTimeInterval(-1),
            updatedAt: tappedAt.addingTimeInterval(-1)
        )
        _ = try await repository.apply(createCommand(for: source))
        let snapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: snapshot.entries))

        let receipt = try await RepeatLastEntryCommand(repository: repository).execute(
            expected: expected,
            at: tappedAt
        )

        XCTAssertNil(receipt.entry.entry.note)
        let afterSnapshot = try await repository.ledgerSnapshot()
        let sourceAfter = try XCTUnwrap(afterSnapshot.entries.first { $0.id == source.id })
        XCTAssertEqual(sourceAfter.entry.note, "Never copy this")
    }

    func testOneTapPreservesCreditAsCredit() async throws {
        let tappedAt = Date().addingTimeInterval(-2)
        let sourceDay = oneTapDay(tappedAt, offsetBy: -1)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let source = TimeEntry(
            id: UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!,
            kind: .credit,
            day: sourceDay,
            minutes: 45,
            createdAt: tappedAt.addingTimeInterval(-1),
            updatedAt: tappedAt.addingTimeInterval(-1)
        )
        _ = try await repository.apply(createCommand(for: source))
        let initialSnapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: initialSnapshot.entries))
        let receipt = try await RepeatLastEntryCommand(repository: repository).execute(
            expected: expected,
            at: tappedAt
        )

        XCTAssertEqual(receipt.entry.entry.kind, .credit)
        XCTAssertEqual(receipt.entry.entry.minutes, 45)
        XCTAssertEqual(
            ServiceYearCalculator.progressMinutes(
                entries: [receipt.entry.entry],
                containing: LocalDay(tappedAt, calendar: .hourleaf),
                baselineMinutes: 0
            ),
            0
        )
    }

    func testOneTapAllowsServiceProgressAboveSixHundredHours() async throws {
        let tappedAt = Date().addingTimeInterval(-2)
        let sourceDay = oneTapDay(tappedAt, offsetBy: -1)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let source = TimeEntry(
            id: UUID(uuidString: "B0000000-0000-0000-0000-00000000000B")!,
            kind: .service,
            day: sourceDay,
            minutes: 60,
            createdAt: tappedAt.addingTimeInterval(-1),
            updatedAt: tappedAt.addingTimeInterval(-1)
        )
        _ = try await repository.apply(createCommand(for: source))
        let initialSnapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: initialSnapshot.entries))
        _ = try await RepeatLastEntryCommand(repository: repository).execute(
            expected: expected,
            at: tappedAt
        )

        let snapshot = try await repository.ledgerSnapshot()
        let progress = ServiceYearCalculator.progressMinutes(
            entries: snapshot.activeEntries,
            containing: LocalDay(tappedAt, calendar: .hourleaf),
            baselineMinutes: GoalPolicy.regularPioneer.targetMinutes
        )
        XCTAssertGreaterThan(progress, GoalPolicy.regularPioneer.targetMinutes)
    }

    func testOneTapRejectsChangedProposalWithoutWriting() async throws {
        let tappedAt = Date().addingTimeInterval(-3)
        let sourceDay = oneTapDay(tappedAt, offsetBy: -1)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let firstCreatedAt = tappedAt.addingTimeInterval(-2)
        let first = TimeEntry(
            id: UUID(uuidString: "C0000000-0000-0000-0000-00000000000C")!,
            kind: .service,
            day: sourceDay,
            minutes: 30,
            createdAt: firstCreatedAt,
            updatedAt: firstCreatedAt
        )
        _ = try await repository.apply(createCommand(for: first))
        let initialSnapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: initialSnapshot.entries))

        let secondCreatedAt = tappedAt.addingTimeInterval(-1)
        let second = TimeEntry(
            id: UUID(uuidString: "D0000000-0000-0000-0000-00000000000D")!,
            kind: .credit,
            day: sourceDay,
            minutes: 45,
            createdAt: secondCreatedAt,
            updatedAt: secondCreatedAt
        )
        _ = try await repository.apply(createCommand(for: second))

        do {
            _ = try await RepeatLastEntryCommand(repository: repository).execute(
                expected: expected,
                at: tappedAt,
                mutationID: UUID(uuidString: "E0000000-0000-0000-0000-00000000000E")!,
                entryID: UUID(uuidString: "F0000000-0000-0000-0000-00000000000F")!
            )
            XCTFail("A changed proposal must not write a repeated entry.")
        } catch let error as OneTapEntryError {
            XCTAssertEqual(error, .proposalChanged)
        }

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entryRevisions.count, 2)
        XCTAssertTrue(snapshot.entries.allSatisfy { $0.source != EntryMutationSource.appOneTap.rawValue })
    }

    func testOneTapRejectsDeletedProposalWithoutWriting() async throws {
        let tappedAt = Date().addingTimeInterval(-3)
        let sourceDay = oneTapDay(tappedAt, offsetBy: -1)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let sourceCreatedAt = tappedAt.addingTimeInterval(-2)
        let source = TimeEntry(
            id: UUID(uuidString: "11000000-0000-0000-0000-000000000011")!,
            kind: .service,
            day: sourceDay,
            minutes: 30,
            createdAt: sourceCreatedAt,
            updatedAt: sourceCreatedAt
        )
        _ = try await repository.apply(createCommand(for: source))
        let initialSnapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: initialSnapshot.entries))
        let sourceRecord = try XCTUnwrap(initialSnapshot.entries.first { $0.id == source.id })
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: source.id,
                expectedRevision: sourceRecord.revision,
                operation: .delete,
                occurredAt: tappedAt.addingTimeInterval(-1),
                source: .appHistory
            )
        )

        do {
            _ = try await RepeatLastEntryCommand(repository: repository).execute(
                expected: expected,
                at: tappedAt,
                mutationID: UUID(uuidString: "12000000-0000-0000-0000-000000000012")!,
                entryID: UUID(uuidString: "13000000-0000-0000-0000-000000000013")!
            )
            XCTFail("A deleted proposal must not write a repeated entry.")
        } catch let error as OneTapEntryError {
            XCTAssertEqual(error, .unavailable)
        }

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertTrue(snapshot.entries[0].isDeleted)
        XCTAssertEqual(snapshot.entryRevisions.map(\.operation), ["create", "delete"])
    }

    func testOneTapExactReplayCreatesOneEntryAndOneCreateRevision() async throws {
        let tappedAt = Date().addingTimeInterval(-5)
        let sourceDay = oneTapDay(tappedAt)
        let repository = makeRepository()
        try await configureOneTapLedgerStart(repository, for: sourceDay)

        let source = TimeEntry(
            id: UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!,
            kind: .service,
            day: sourceDay,
            minutes: 60,
            note: "Source note",
            createdAt: tappedAt,
            updatedAt: tappedAt
        )
        _ = try await repository.apply(createCommand(for: source))
        let initialSnapshot = try await repository.ledgerSnapshot()
        let expected = try XCTUnwrap(RepeatLastEntryCommand.proposal(from: initialSnapshot.entries))
        let mutationID = UUID(uuidString: "14000000-0000-0000-0000-000000000014")!
        let entryID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
        let command = RepeatLastEntryCommand(repository: repository)

        let first = try await command.execute(
            expected: expected,
            at: tappedAt,
            mutationID: mutationID,
            entryID: entryID
        )
        let replay = try await command.execute(
            expected: expected,
            at: tappedAt,
            mutationID: mutationID,
            entryID: entryID
        )

        XCTAssertFalse(first.wasReplay)
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.entry, first.entry)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 2)
        let repeatedRevisions = snapshot.entryRevisions.filter { $0.entryID == entryID }
        XCTAssertEqual(repeatedRevisions.count, 1)
        XCTAssertEqual(repeatedRevisions.first?.operation, EntryMutationOperation.create.rawValue)
        XCTAssertEqual(repeatedRevisions.first?.revision, 1)
        XCTAssertEqual(snapshot.entries.filter { $0.id == entryID }.count, 1)
    }

    func testAppModelPreventsConcurrentOneTapRequests() async throws {
        let baseRepository = makeRepository()
        let source = TimeEntry(
            kind: .service,
            day: LocalDay(Date(), calendar: .hourleaf),
            minutes: 45,
            note: "Source note",
            createdAt: Date().addingTimeInterval(-120),
            updatedAt: Date().addingTimeInterval(-120)
        )
        _ = try await baseRepository.apply(createCommand(for: source))
        let repository = GatedLedgerRepository(base: baseRepository)
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let proposal = try XCTUnwrap(model.oneTapProposal)

        await repository.gateNextSnapshot()
        let firstRequest = Task { await model.repeatLastEntry(expected: proposal) }
        await repository.waitUntilSnapshotIsBlocked()

        XCTAssertTrue(model.isRepeatingLastEntry)
        let secondResult = await model.repeatLastEntry(expected: proposal)
        XCTAssertFalse(secondResult)

        await repository.releaseSnapshot()
        let firstResult = await firstRequest.value
        XCTAssertTrue(firstResult)
        XCTAssertFalse(model.isRepeatingLastEntry)

        let snapshot = try await baseRepository.ledgerSnapshot()
        XCTAssertEqual(
            snapshot.entries.filter { $0.source == EntryMutationSource.appOneTap.rawValue }.count,
            1
        )
    }

    func testOneTapSuccessRefreshesEntriesAndShowsMatchingUndo() async throws {
        let repository = makeRepository()
        let source = TimeEntry(
            kind: .service,
            day: LocalDay(Date(), calendar: .hourleaf),
            minutes: 75,
            note: "Source note",
            createdAt: Date().addingTimeInterval(-120),
            updatedAt: Date().addingTimeInterval(-120)
        )
        _ = try await repository.apply(createCommand(for: source))
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let proposal = try XCTUnwrap(model.oneTapProposal)
        let draftGeneration = model.quickEntryResetGeneration

        let repeatedSuccessfully = await model.repeatLastEntry(expected: proposal)
        XCTAssertTrue(repeatedSuccessfully)

        let repeated = try XCTUnwrap(
            model.entryRecords.first { $0.source == EntryMutationSource.appOneTap.rawValue }
        )
        XCTAssertEqual(model.entryRecords.count, 2)
        XCTAssertEqual(repeated.entry.kind, .service)
        XCTAssertEqual(repeated.entry.minutes, 75)
        XCTAssertEqual(
            repeated.entry.day,
            LocalDay(repeated.entry.createdAt, calendar: .hourleaf)
        )
        XCTAssertNil(repeated.entry.note)
        XCTAssertEqual(model.undoCandidate?.entryID, repeated.id)
        XCTAssertEqual(model.visibleUndoCandidate?.entryID, repeated.id)
        XCTAssertEqual(model.quickEntryResetGeneration, draftGeneration)
        XCTAssertFalse(model.isRepeatingLastEntry)
    }

    func testOneTapUndoSoftDeletesOnlyTheRepeatedEntry() async throws {
        let repository = makeRepository()
        let source = TimeEntry(
            kind: .credit,
            day: LocalDay(Date(), calendar: .hourleaf),
            minutes: 30,
            note: "Keep source",
            createdAt: Date().addingTimeInterval(-120),
            updatedAt: Date().addingTimeInterval(-120)
        )
        _ = try await repository.apply(createCommand(for: source))
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let proposal = try XCTUnwrap(model.oneTapProposal)
        let repeatedSuccessfully = await model.repeatLastEntry(expected: proposal)
        XCTAssertTrue(repeatedSuccessfully)
        let repeatedID = try XCTUnwrap(
            model.entryRecords.first { $0.source == EntryMutationSource.appOneTap.rawValue }?.id
        )

        await model.undoLatestMutation()

        XCTAssertEqual(model.entryRecords.map(\.id), [source.id])
        XCTAssertEqual(model.deletedEntryRecords.map(\.id), [repeatedID])
        XCTAssertEqual(model.entryRecords.first?.entry.note, "Keep source")
    }

    func testSupersedingMutationPreventsMisleadingOneTapUndoBanner() async throws {
        let repository = makeRepository()
        let source = TimeEntry(
            kind: .service,
            day: LocalDay(Date(), calendar: .hourleaf),
            minutes: 60,
            createdAt: Date().addingTimeInterval(-120),
            updatedAt: Date().addingTimeInterval(-120)
        )
        _ = try await repository.apply(createCommand(for: source))
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let proposal = try XCTUnwrap(model.oneTapProposal)
        let repeatedSuccessfully = await model.repeatLastEntry(expected: proposal)
        XCTAssertTrue(repeatedSuccessfully)
        let repeatedID = try XCTUnwrap(model.visibleUndoCandidate?.entryID)

        let addedSupersedingEntry = await model.addEntry(
            kind: .credit,
            date: Date(),
            hours: 0,
            minutes: 5,
            note: nil
        )
        XCTAssertTrue(addedSupersedingEntry)

        let visibleUndo = try XCTUnwrap(model.visibleUndoCandidate)
        XCTAssertNotEqual(visibleUndo.entryID, repeatedID)
        XCTAssertEqual(visibleUndo.entry.entry.kind, .credit)
        XCTAssertEqual(visibleUndo.entry.entry.minutes, 5)
        XCTAssertEqual(visibleUndo.entry.source, EntryMutationSource.appQuickEntry.rawValue)
    }

    func testOneTapFailureLeavesManualDraftAndLedgerUnchanged() async throws {
        let repository = makeRepository()
        let now = Date()
        let source = TimeEntry(
            kind: .service,
            day: LocalDay(now, calendar: .hourleaf),
            minutes: 30,
            note: "Original",
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now.addingTimeInterval(-120)
        )
        _ = try await repository.apply(createCommand(for: source))
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let staleProposal = try XCTUnwrap(model.oneTapProposal)
        let draftGeneration = model.quickEntryResetGeneration

        let newer = TimeEntry(
            kind: .credit,
            day: LocalDay(now, calendar: .hourleaf),
            minutes: 45,
            note: "Newer",
            createdAt: now.addingTimeInterval(-60),
            updatedAt: now.addingTimeInterval(-60)
        )
        _ = try await repository.apply(createCommand(for: newer))

        let repeatedSuccessfully = await model.repeatLastEntry(expected: staleProposal)
        XCTAssertFalse(repeatedSuccessfully)

        XCTAssertEqual(Set(model.entryRecords.map(\.id)), Set([source.id, newer.id]))
        XCTAssertEqual(model.oneTapProposal?.sourceEntryID, newer.id)
        XCTAssertEqual(model.quickEntryResetGeneration, draftGeneration)
        XCTAssertEqual(model.errorMessage, String(localized: "error.one_tap_changed"))
        XCTAssertFalse(model.isRepeatingLastEntry)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertFalse(snapshot.entries.contains { $0.source == EntryMutationSource.appOneTap.rawValue })
        XCTAssertEqual(snapshot.entryRevisions.count, 2)
    }

    func testOpeningBalanceOnlyAppliesToItsServiceYear() async {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        XCTAssertEqual(model.startupState, .ready)
        let currentDay = LocalDay(Date(), calendar: .hourleaf)
        let currentStart = ServiceYearCalculator.serviceYearStart(containing: currentDay)
        var settings = model.settings
        settings.baselineServiceYearMinutes = 120
        settings.baselineServiceYearStart = currentStart.monthKey
        await model.saveSettings(settings)

        XCTAssertEqual(model.serviceYearProgress(containing: currentDay), 120)
        XCTAssertEqual(
            model.serviceYearProgress(containing: LocalDay(year: currentStart.year + 1, month: 9, day: 1)),
            0
        )
    }

    func testSettingsImportPrefersConfiguredRecordAndRemovesDuplicate() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let context = persistence.container.viewContext
        let localDefault: SettingsEntity = context.insert(SettingsEntity.self)
        populate(
            localDefault,
            id: UUID(),
            settings: AppSettings(reportLanguage: .english, onboardingComplete: false),
            updatedAt: .now
        )
        let imported: SettingsEntity = context.insert(SettingsEntity.self)
        populate(
            imported,
            id: UUID(),
            settings: AppSettings(reportLanguage: .russian, onboardingComplete: true),
            updatedAt: .distantPast
        )
        try context.save()

        let repository = CoreDataLedgerRepository(persistence: persistence)
        let loaded = try await repository.loadSettings()
        XCTAssertTrue(loaded.onboardingComplete)
        XCTAssertEqual(loaded.reportLanguage, .russian)

        context.reset()
        let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        XCTAssertEqual(try context.count(for: request), 1)
    }

    func testV1OnDiskStoreMigratesAndNormalizationIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafMigration-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("Hourleaf.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var migrationPersistence: PersistenceController?
        defer {
            if let migrationPersistence {
                try? closePersistentStores(in: migrationPersistence)
            }
            try? FileManager.default.removeItem(at: directory)
        }

        let fixture = try createV1Fixture(at: storeURL)
        let persistence = PersistenceController(inMemory: false, cloudSyncEnabled: false, storeURL: storeURL)
        migrationPersistence = persistence
        XCTAssertNil(persistence.startupError)

        let repository = CoreDataLedgerRepository(persistence: persistence)
        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(snapshot.activeEntries, [fixture.entry])
        let migratedEntry = try XCTUnwrap(snapshot.entries.first)
        XCTAssertNil(migratedEntry.deletedAt)
        XCTAssertEqual(migratedEntry.revision, 1)
        XCTAssertEqual(migratedEntry.source, "migration")
        XCTAssertNotNil(migratedEntry.lastMutationID)
        XCTAssertEqual(snapshot.entryRevisions.count, 1)
        let revision = try XCTUnwrap(snapshot.entryRevisions.first)
        XCTAssertEqual(revision.entryID, fixture.entry.id)
        XCTAssertEqual(revision.revision, 1)
        XCTAssertEqual(revision.operation, "create")
        XCTAssertEqual(revision.kind, fixture.entry.kind.rawValue)
        XCTAssertEqual(revision.localDay, fixture.entry.day.key)
        XCTAssertEqual(revision.minutes, fixture.entry.minutes)
        XCTAssertEqual(revision.note, fixture.entry.note)
        XCTAssertEqual(revision.entryCreatedAt, fixture.entry.createdAt)
        XCTAssertEqual(revision.entryUpdatedAt, fixture.entry.updatedAt)
        XCTAssertEqual(revision.source, "migration")

        XCTAssertEqual(snapshot.settings, fixture.settings)
        XCTAssertEqual(snapshot.settingsMetadata.id, fixture.settingsID)
        XCTAssertEqual(snapshot.settingsMetadata.dataRevision, 2)
        XCTAssertEqual(snapshot.policies, [fixture.policy])
        XCTAssertEqual(snapshot.reminderSchedules, [fixture.reminder])
        XCTAssertNotNil(snapshot.reminders.first?.createdAt)
        XCTAssertNotNil(snapshot.reminders.first?.updatedAt)

        let receipt = try XCTUnwrap(snapshot.receipts.first)
        XCTAssertEqual(receipt, fixture.receipt)
        let receiptMetadata = try XCTUnwrap(snapshot.reportSnapshots.first)
        XCTAssertEqual(receiptMetadata.version, 1)
        XCTAssertEqual(receiptMetadata.rawServiceMinutes, 0)
        XCTAssertEqual(receiptMetadata.rawCreditMinutes, 0)
        XCTAssertTrue(receiptMetadata.legacyCalculationUnavailable)
        XCTAssertEqual(receiptMetadata.createdBySource, "migration")
        let state = try XCTUnwrap(snapshot.reportStates.first)
        XCTAssertEqual(state.month, fixture.receipt.month)
        XCTAssertEqual(state.state, .sent)
        XCTAssertEqual(state.currentSnapshotID, fixture.receipt.id)

        let secondRepository = CoreDataLedgerRepository(persistence: persistence)
        let rerun = try await secondRepository.ledgerSnapshot()
        XCTAssertEqual(rerun.entries.map(\.id), snapshot.entries.map(\.id))
        XCTAssertEqual(rerun.entryRevisions.map(\.id), snapshot.entryRevisions.map(\.id))
        XCTAssertEqual(rerun.reportStates.map(\.id), snapshot.reportStates.map(\.id))
        XCTAssertEqual(rerun.reportSnapshots.map(\.id), snapshot.reportSnapshots.map(\.id))
        XCTAssertEqual(rerun.settingsMetadata.dataRevision, 2)
    }

    func testNormalizationRejectsMalformedEntryBeforeAdvancingDataRevision() async throws {
        try await assertNormalizationRejects { context in
            let object: EntryEntity = context.insert(EntryEntity.self)
            object.kind = EntryKind.service.rawValue
            object.localDay = "2026-07-12"
            object.minutes = 15
            object.createdAt = .now
            object.updatedAt = .now
        }
    }

    func testNormalizationRejectsMalformedPolicyBeforeAdvancingDataRevision() async throws {
        try await assertNormalizationRejects { context in
            let object: PolicyRevisionEntity = context.insert(PolicyRevisionEntity.self)
            object.id = UUID()
            object.effectiveMonth = "2026-07"
            object.mode = "invalid-mode"
            object.createdAt = .now
        }
    }

    func testNormalizationRejectsMalformedReceiptBeforeAdvancingDataRevision() async throws {
        try await assertNormalizationRejects { context in
            let object: ReportReceiptEntity = context.insert(ReportReceiptEntity.self)
            object.id = UUID()
            object.monthKey = "2026-13"
            object.reportText = "Invalid month"
            object.preparedAt = .now
        }
    }

    func testNewestPreparedReceiptDefinesCurrentReportState() async throws {
        let repository = makeRepository()
        let month = MonthKey(year: 2026, month: 7)
        let older = ReportReceipt(
            id: UUID(),
            month: month,
            text: "Older",
            serviceHours: 1,
            creditHours: 0,
            serviceCarryOut: 15,
            creditCarryOut: 0,
            preparedAt: Date(timeIntervalSince1970: 1_700_000_000),
            confirmedSentAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let newer = ReportReceipt(
            id: UUID(),
            month: month,
            text: "Newer",
            serviceHours: 2,
            creditHours: 0,
            serviceCarryOut: 5,
            creditCarryOut: 0,
            preparedAt: Date(timeIntervalSince1970: 1_700_001_000),
            confirmedSentAt: nil
        )

        try await repository.saveReceipt(older, details: reportDetails(for: older, rawServiceMinutes: 75))
        try await repository.saveReceipt(newer, details: reportDetails(for: newer, rawServiceMinutes: 125))
        try await repository.saveReceipt(older, details: nil)

        let snapshot = try await repository.ledgerSnapshot()
        let state = try XCTUnwrap(snapshot.reportStates.first { $0.month == month })
        XCTAssertEqual(state.state, .prepared)
        XCTAssertEqual(state.currentSnapshotID, newer.id)
    }

    func testReportSnapshotRejectsContradictoryCalculationDetails() async throws {
        let repository = makeRepository()
        let receipt = ReportReceipt(
            id: UUID(),
            month: MonthKey(year: 2026, month: 7),
            text: "July 2026\nHours: 1",
            serviceHours: 1,
            creditHours: 0,
            serviceCarryOut: 15,
            creditCarryOut: 0,
            preparedAt: .now,
            confirmedSentAt: nil
        )
        let contradictory = reportDetails(for: receipt, rawServiceMinutes: 135)
        let mismatchedReport = MonthlyReport(
            month: receipt.month,
            rawServiceMinutes: contradictory.report.rawServiceMinutes,
            rawCreditMinutes: 0,
            serviceCarryIn: 0,
            creditCarryIn: 0,
            serviceHours: 2,
            creditHours: 0,
            serviceCarryOut: 15,
            creditCarryOut: 0
        )
        let details = ReportSnapshotDetails(
            report: mismatchedReport,
            reportingMode: contradictory.reportingMode,
            reportLanguage: contradictory.reportLanguage,
            creditLabel: contradictory.creditLabel,
            templateID: contradictory.templateID,
            calculationFingerprint: contradictory.calculationFingerprint,
            presentationFingerprint: contradictory.presentationFingerprint
        )

        do {
            try await repository.saveReceipt(receipt, details: details)
            XCTFail("Contradictory report totals must not be stored.")
        } catch let error as LedgerRepositoryError {
            guard case .invalidManagedObject = error else {
                return XCTFail("Expected invalidManagedObject, got \(error).")
            }
        }
        let receipts = try await repository.fetchReceipts()
        XCTAssertTrue(receipts.isEmpty)
    }

    func testPreparedReportSnapshotCannotBeMutatedInPlace() async throws {
        let repository = makeRepository()
        let receipt = ReportReceipt(
            id: UUID(),
            month: MonthKey(year: 2026, month: 7),
            text: "July 2026\nHours: 1",
            serviceHours: 1,
            creditHours: 0,
            serviceCarryOut: 15,
            creditCarryOut: 0,
            preparedAt: .now,
            confirmedSentAt: nil
        )
        try await repository.saveReceipt(receipt, details: reportDetails(for: receipt, rawServiceMinutes: 75))
        let changed = ReportReceipt(
            id: receipt.id,
            month: receipt.month,
            text: "Changed text",
            serviceHours: 2,
            creditHours: 0,
            serviceCarryOut: 0,
            creditCarryOut: 0,
            preparedAt: receipt.preparedAt,
            confirmedSentAt: .now
        )

        do {
            try await repository.saveReceipt(changed, details: nil)
            XCTFail("A prepared snapshot must be immutable apart from sent confirmation.")
        } catch let error as LedgerRepositoryError {
            guard case .invalidManagedObject = error else {
                return XCTFail("Expected invalidManagedObject, got \(error).")
            }
        }

        let receipts = try await repository.fetchReceipts()
        let stored = try XCTUnwrap(receipts.first)
        XCTAssertEqual(stored.text, receipt.text)
        XCTAssertEqual(stored.serviceHours, receipt.serviceHours)
        XCTAssertNil(stored.confirmedSentAt)
    }

    func testAccountingKeysRejectMalformedSeparatorsAndComponents() {
        XCTAssertNil(LocalDay(key: "2026-x-07-12"))
        XCTAssertNil(LocalDay(key: "2026--07-12"))
        XCTAssertNil(LocalDay(key: "2026-7-12"))
        XCTAssertNil(LocalDay(key: "2026-02-31"))
        XCTAssertNil(MonthKey(key: "2026-x-07"))
        XCTAssertNil(MonthKey(key: "2026--07"))
        XCTAssertNil(MonthKey(key: "2026-7"))
    }

    func testNormalizationUsesNewestLegacyReceiptForCurrentState() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let context = persistence.container.viewContext
        let settings: SettingsEntity = context.insert(SettingsEntity.self)
        populate(settings, id: UUID(), settings: AppSettings(), updatedAt: .now)
        settings.dataRevision = 1

        let month = MonthKey(year: 2026, month: 7)
        let olderID = UUID()
        let newerID = UUID()
        let older: ReportReceiptEntity = context.insert(ReportReceiptEntity.self)
        older.id = olderID
        older.monthKey = month.key
        older.reportText = "Older sent report"
        older.serviceHours = 1
        older.preparedAt = Date(timeIntervalSince1970: 1_700_000_000)
        older.confirmedSentAt = Date(timeIntervalSince1970: 1_700_000_100)

        let newer: ReportReceiptEntity = context.insert(ReportReceiptEntity.self)
        newer.id = newerID
        newer.monthKey = month.key
        newer.reportText = "Newer prepared report"
        newer.serviceHours = 2
        newer.preparedAt = Date(timeIntervalSince1970: 1_700_001_000)

        let olderState: ReportStateEntity = context.insert(ReportStateEntity.self)
        olderState.id = UUID()
        olderState.monthKey = month.key
        olderState.state = "sent"
        olderState.currentSnapshotID = olderID
        olderState.updatedAt = Date(timeIntervalSince1970: 1_700_000_200)
        let newerState: ReportStateEntity = context.insert(ReportStateEntity.self)
        newerState.id = UUID()
        newerState.monthKey = month.key
        newerState.state = "sent"
        newerState.currentSnapshotID = olderID
        newerState.updatedAt = Date(timeIntervalSince1970: 1_700_000_300)
        try context.save()

        let repository = CoreDataLedgerRepository(persistence: persistence)
        let snapshot = try await repository.ledgerSnapshot()
        let state = try XCTUnwrap(snapshot.reportStates.first)
        XCTAssertEqual(state.state, .prepared)
        XCTAssertEqual(state.currentSnapshotID, newerID)
        XCTAssertEqual(snapshot.reportStates.count, 1)
        XCTAssertTrue(snapshot.reportSnapshots.allSatisfy(\.legacyCalculationUnavailable))
    }

    func testIndependentSettingsUpdatesDoNotOverwriteEachOther() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()

        async let language: Void = model.updateReportLanguage(.russian)
        async let label: Void = model.updateCreditLabel("Field credit", for: .english)
        _ = await (language, label)

        let settings = try await repository.loadSettings()
        XCTAssertEqual(settings.reportLanguage, .russian)
        XCTAssertEqual(settings.creditLabelEnglish, "Field credit")
    }

    func testReloadWaitsForQueuedSettingsSave() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()

        model.queueReportLanguageChange(
            .ukrainian,
            savingCreditLabel: "Field credit",
            for: .english
        )
        await model.reload()

        XCTAssertEqual(model.settings.reportLanguage, .ukrainian)
        XCTAssertEqual(model.settings.creditLabelEnglish, "Field credit")
        let persisted = try await repository.loadSettings()
        XCTAssertEqual(persisted, model.settings)
    }

    func testDeferredInitialLoadDoesNotExposeReadyUIBeforeSeeding() async {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())

        await model.loadInitialSnapshot(markReady: false)
        XCTAssertEqual(model.startupState, .loading)

        var settings = model.settings
        settings.onboardingComplete = true
        await model.saveSettings(settings)
        model.finishInitialLoad()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertTrue(model.settings.onboardingComplete)
    }

    func testActorSerializesConcurrentEntryWritesAndReadback() async throws {
        let repository = makeRepository()
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 7)
        try await repository.saveSettings(settings)
        let first = TimeEntry(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 30,
            note: "First",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let second = TimeEntry(
            id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            kind: .credit,
            day: LocalDay(year: 2026, month: 7, day: 13),
            minutes: 45,
            note: "Second",
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        let firstCommand = createCommand(for: first)
        let secondCommand = createCommand(for: second)
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await repository.apply(firstCommand) }
            group.addTask { _ = try await repository.apply(secondCommand) }
            try await group.waitForAll()
        }

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(Set(snapshot.activeEntries.map(\.id)), Set([first.id, second.id]))
        let revisions = snapshot.entryRevisions.filter { $0.entryID == first.id || $0.entryID == second.id }
        XCTAssertEqual(revisions.count, 2)
        XCTAssertEqual(Set(revisions.map(\.revision)), Set([1]))
        XCTAssertEqual(Set(revisions.map(\.operation)), Set(["create"]))
    }

    func testStoreLoadFailureIsExposedThroughRepository() async throws {
        let corruptStore = try makeCorruptStoreURL()
        defer { try? FileManager.default.removeItem(at: corruptStore.directory) }
        let persistence = PersistenceController(inMemory: false, cloudSyncEnabled: false, storeURL: corruptStore.url)
        let repository = CoreDataLedgerRepository(persistence: persistence)

        do {
            _ = try await repository.ledgerSnapshot()
            XCTFail("A failed local-store load must be observable.")
        } catch let error as LedgerRepositoryError {
            guard case .persistenceUnavailable = error else {
                return XCTFail("Expected an unavailable persistence error, got \(error).")
            }
        }
    }

    func testInitialLoadFailureStaysOnNonInteractiveFailureSurface() async throws {
        let corruptStore = try makeCorruptStoreURL()
        defer { try? FileManager.default.removeItem(at: corruptStore.directory) }
        let persistence = PersistenceController(inMemory: false, cloudSyncEnabled: false, storeURL: corruptStore.url)
        let model = AppModel(
            repository: CoreDataLedgerRepository(persistence: persistence),
            reminderScheduler: TestReminderScheduler()
        )

        XCTAssertEqual(model.startupState, .loading)
        await model.loadInitialSnapshot()

        guard case .failed = model.startupState else {
            return XCTFail("A failed first snapshot must keep the app off its interactive ledger surface.")
        }
        XCTAssertFalse(model.startupDiagnostic?.isEmpty ?? true)
    }

    private func makeRepository() -> CoreDataLedgerRepository {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        return CoreDataLedgerRepository(persistence: persistence)
    }

    private func configureOneTapLedgerStart(
        _ repository: CoreDataLedgerRepository,
        for day: LocalDay
    ) async throws {
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = day.monthKey
        try await repository.saveSettings(settings)
    }

    private func oneTapDay(_ date: Date, offsetBy days: Int = 0) -> LocalDay {
        let shifted = Calendar.hourleaf.date(byAdding: .day, value: days, to: date) ?? date
        return LocalDay(shifted, calendar: .hourleaf)
    }

    private func makeOneTapRecord(
        id: UUID,
        kind: EntryKind = .service,
        day: LocalDay,
        minutes: Int,
        note: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        revision: Int64 = 1
    ) -> LedgerEntryRecord {
        LedgerEntryRecord(
            entry: TimeEntry(
                id: id,
                kind: kind,
                day: day,
                minutes: minutes,
                note: note,
                createdAt: createdAt,
                updatedAt: updatedAt ?? createdAt
            ),
            deletedAt: deletedAt,
            source: EntryMutationSource.appQuickEntry.rawValue,
            revision: revision,
            lastMutationID: nil
        )
    }

    private func createCommand(
        for entry: TimeEntry,
        mutationID: UUID = UUID(),
        source: EntryMutationSource = .appQuickEntry
    ) -> EntryMutationCommand {
        EntryMutationCommand(
            mutationID: mutationID,
            entryID: entry.id,
            expectedRevision: nil,
            operation: .create,
            values: EntryMutationValues(
                kind: entry.kind,
                day: entry.day,
                minutes: entry.minutes,
                note: entry.note
            ),
            occurredAt: entry.updatedAt,
            source: source
        )
    }

    private func reportDetails(
        for receipt: ReportReceipt,
        rawServiceMinutes: Int
    ) -> ReportSnapshotDetails {
        let calculationFingerprint = "calculation-\(receipt.id.uuidString)"
        return ReportSnapshotDetails(
            report: MonthlyReport(
                month: receipt.month,
                rawServiceMinutes: rawServiceMinutes,
                rawCreditMinutes: 0,
                serviceCarryIn: 0,
                creditCarryIn: 0,
                serviceHours: receipt.serviceHours,
                creditHours: receipt.creditHours,
                serviceCarryOut: receipt.serviceCarryOut,
                creditCarryOut: receipt.creditCarryOut
            ),
            reportingMode: .carry,
            reportLanguage: .english,
            creditLabel: "Credit hours",
            templateID: "standard",
            calculationFingerprint: calculationFingerprint,
            presentationFingerprint: ReportFingerprint.presentation(
                calculationFingerprint: calculationFingerprint,
                language: .english,
                creditLabel: "Credit hours",
                templateID: "standard",
                text: receipt.text
            )
        )
    }

    private func assertNormalizationRejects(
        _ insertMalformedObject: (NSManagedObjectContext) -> Void
    ) async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let context = persistence.container.viewContext
        insertMalformedObject(context)
        try context.save()

        let repository = CoreDataLedgerRepository(persistence: persistence)
        do {
            _ = try await repository.ledgerSnapshot()
            XCTFail("Normalization must not accept an invalid managed object.")
        } catch let error as LedgerRepositoryError {
            guard case .invalidManagedObject = error else {
                return XCTFail("Expected invalidManagedObject, got \(error).")
            }
        }

        context.reset()
        let settingsRequest: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        let revisionRequest: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        XCTAssertEqual(try context.count(for: settingsRequest), 0)
        XCTAssertEqual(try context.count(for: revisionRequest), 0)
    }

    private func populate(
        _ object: SettingsEntity,
        id: UUID,
        settings: AppSettings,
        updatedAt: Date
    ) {
        object.id = id
        object.reportLanguage = settings.reportLanguage.rawValue
        object.creditLabelEnglish = settings.creditLabelEnglish
        object.creditLabelRussian = settings.creditLabelRussian
        object.creditLabelUkrainian = settings.creditLabelUkrainian
        object.ledgerStartMonth = settings.ledgerStartMonth.key
        object.baselineServiceYearMinutes = Int64(settings.baselineServiceYearMinutes)
        object.baselineServiceYearStart = settings.baselineServiceYearStart.key
        object.openingServiceCarryMinutes = Int32(settings.openingServiceCarryMinutes)
        object.openingCreditCarryMinutes = Int32(settings.openingCreditCarryMinutes)
        object.onboardingComplete = settings.onboardingComplete
        object.updatedAt = updatedAt
    }

    private func makeCorruptStoreURL() throws -> (directory: URL, url: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafCorruptStore-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("Hourleaf.sqlite")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a SQLite database".utf8).write(to: url, options: .atomic)
        return (directory, url)
    }

    private func createV1Fixture(at storeURL: URL) throws -> V1Fixture {
        let model = try v1Model()
        let container = NSPersistentContainer(name: "HourleafModel", managedObjectModel: model)
        let description = NSPersistentStoreDescription(url: storeURL)
        description.type = NSSQLiteStoreType
        description.shouldAddStoreAsynchronously = false
        container.persistentStoreDescriptions = [description]

        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }

        let context = container.viewContext
        let entryID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let policyID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let reminderID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let receiptID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let settingsID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let updatedAt = Date(timeIntervalSince1970: 1_700_003_600)
        let preparedAt = Date(timeIntervalSince1970: 1_700_010_000)
        let sentAt = Date(timeIntervalSince1970: 1_700_020_000)
        let entry = TimeEntry(
            id: entryID,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "Stable V1 note",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let settings = AppSettings(
            reportLanguage: .russian,
            creditLabelEnglish: "Credit hours",
            creditLabelRussian: "Кредит часов",
            creditLabelUkrainian: "Кредит годин",
            ledgerStartMonth: MonthKey(year: 2026, month: 1),
            baselineServiceYearMinutes: 123,
            baselineServiceYearStart: MonthKey(year: 2025, month: 9),
            openingServiceCarryMinutes: 17,
            openingCreditCarryMinutes: 23,
            onboardingComplete: true
        )
        let policy = ReportingPolicy(
            id: policyID,
            effectiveMonth: MonthKey(year: 2026, month: 7),
            mode: .roundNearest,
            createdAt: createdAt
        )
        let reminder = ReminderSchedule(id: reminderID, weekday: 3, hour: 18, minute: 45, isEnabled: true)
        let receipt = ReportReceipt(
            id: receiptID,
            month: MonthKey(year: 2026, month: 7),
            text: "Июль 2026\nЧасы: 1\nКредит часов: 2",
            serviceHours: 1,
            creditHours: 2,
            serviceCarryOut: 15,
            creditCarryOut: 20,
            preparedAt: preparedAt,
            confirmedSentAt: sentAt
        )

        let entryObject = NSEntityDescription.insertNewObject(forEntityName: "EntryEntity", into: context)
        entryObject.setValue(entry.id, forKey: "id")
        entryObject.setValue(entry.kind.rawValue, forKey: "kind")
        entryObject.setValue(entry.day.key, forKey: "localDay")
        entryObject.setValue(Int32(entry.minutes), forKey: "minutes")
        entryObject.setValue(entry.note, forKey: "note")
        entryObject.setValue(entry.createdAt, forKey: "createdAt")
        entryObject.setValue(entry.updatedAt, forKey: "updatedAt")

        let policyObject = NSEntityDescription.insertNewObject(forEntityName: "PolicyRevisionEntity", into: context)
        policyObject.setValue(policy.id, forKey: "id")
        policyObject.setValue(policy.effectiveMonth.key, forKey: "effectiveMonth")
        policyObject.setValue(policy.mode.rawValue, forKey: "mode")
        policyObject.setValue(true, forKey: "carryAcrossServiceYear")
        policyObject.setValue(policy.createdAt, forKey: "createdAt")

        let reminderObject = NSEntityDescription.insertNewObject(forEntityName: "ReminderEntity", into: context)
        reminderObject.setValue(reminder.id, forKey: "id")
        reminderObject.setValue(Int16(reminder.weekday), forKey: "weekday")
        reminderObject.setValue(Int16(reminder.hour), forKey: "hour")
        reminderObject.setValue(Int16(reminder.minute), forKey: "minute")
        reminderObject.setValue(reminder.isEnabled, forKey: "isEnabled")

        let receiptObject = NSEntityDescription.insertNewObject(forEntityName: "ReportReceiptEntity", into: context)
        receiptObject.setValue(receipt.id, forKey: "id")
        receiptObject.setValue(receipt.month.key, forKey: "monthKey")
        receiptObject.setValue(receipt.text, forKey: "reportText")
        receiptObject.setValue(Int32(receipt.serviceHours), forKey: "serviceHours")
        receiptObject.setValue(Int32(receipt.creditHours), forKey: "creditHours")
        receiptObject.setValue(Int32(receipt.serviceCarryOut), forKey: "serviceCarryOut")
        receiptObject.setValue(Int32(receipt.creditCarryOut), forKey: "creditCarryOut")
        receiptObject.setValue(receipt.preparedAt, forKey: "preparedAt")
        receiptObject.setValue(receipt.confirmedSentAt, forKey: "confirmedSentAt")

        let settingsObject = NSEntityDescription.insertNewObject(forEntityName: "SettingsEntity", into: context)
        settingsObject.setValue(settingsID, forKey: "id")
        settingsObject.setValue(settings.reportLanguage.rawValue, forKey: "reportLanguage")
        settingsObject.setValue(settings.creditLabelEnglish, forKey: "creditLabelEnglish")
        settingsObject.setValue(settings.creditLabelRussian, forKey: "creditLabelRussian")
        settingsObject.setValue(settings.creditLabelUkrainian, forKey: "creditLabelUkrainian")
        settingsObject.setValue(settings.ledgerStartMonth.key, forKey: "ledgerStartMonth")
        settingsObject.setValue(Int64(settings.baselineServiceYearMinutes), forKey: "baselineServiceYearMinutes")
        settingsObject.setValue(settings.baselineServiceYearStart.key, forKey: "baselineServiceYearStart")
        settingsObject.setValue(Int32(settings.openingServiceCarryMinutes), forKey: "openingServiceCarryMinutes")
        settingsObject.setValue(Int32(settings.openingCreditCarryMinutes), forKey: "openingCreditCarryMinutes")
        settingsObject.setValue(settings.onboardingComplete, forKey: "onboardingComplete")
        settingsObject.setValue(updatedAt, forKey: "updatedAt")

        try context.save()
        if let store = container.persistentStoreCoordinator.persistentStores.first {
            try container.persistentStoreCoordinator.remove(store)
        }
        return V1Fixture(
            entry: entry,
            settingsID: settingsID,
            settings: settings,
            policy: policy,
            reminder: reminder,
            receipt: receipt
        )
    }

    private func v1Model() throws -> NSManagedObjectModel {
        let testBundle = Bundle(for: PersistenceAndAppModelTests.self)
        let bundles = [Bundle.main, testBundle]
        for bundle in bundles {
            guard let packageURL = bundle.url(forResource: "HourleafModel", withExtension: "momd") else { continue }
            let modelURL = packageURL.appendingPathComponent("HourleafModelV1.mom")
            if let model = NSManagedObjectModel(contentsOf: modelURL) { return model }
        }
        throw LedgerRepositoryError.persistenceUnavailable("The bundled Hourleaf V1 model is unavailable to migration tests.")
    }

    private func closePersistentStores(in persistence: PersistenceController) throws {
        let viewContext = persistence.container.viewContext
        viewContext.performAndWait { viewContext.reset() }
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }
}

private struct V1Fixture {
    let entry: TimeEntry
    let settingsID: UUID
    let settings: AppSettings
    let policy: ReportingPolicy
    let reminder: ReminderSchedule
    let receipt: ReportReceipt
}

private actor GatedLedgerRepository: LedgerRepository {
    private let base: CoreDataLedgerRepository
    private var shouldGateNextSnapshot = false
    private var isSnapshotBlocked = false
    private var snapshotStartedContinuation: CheckedContinuation<Void, Never>?
    private var snapshotReleaseContinuation: CheckedContinuation<Void, Never>?

    init(base: CoreDataLedgerRepository) {
        self.base = base
    }

    func gateNextSnapshot() {
        shouldGateNextSnapshot = true
    }

    func waitUntilSnapshotIsBlocked() async {
        guard !isSnapshotBlocked else { return }
        await withCheckedContinuation { continuation in
            snapshotStartedContinuation = continuation
        }
    }

    func releaseSnapshot() {
        snapshotReleaseContinuation?.resume()
        snapshotReleaseContinuation = nil
    }

    func ledgerSnapshot() async throws -> LedgerSnapshot {
        if shouldGateNextSnapshot {
            shouldGateNextSnapshot = false
            isSnapshotBlocked = true
            snapshotStartedContinuation?.resume()
            snapshotStartedContinuation = nil
            await withCheckedContinuation { continuation in
                snapshotReleaseContinuation = continuation
            }
            isSnapshotBlocked = false
        }
        return try await base.ledgerSnapshot()
    }

    func fetchEntries() async throws -> [TimeEntry] {
        try await base.fetchEntries()
    }

    func fetchAllEntries() async throws -> [LedgerEntryRecord] {
        try await base.fetchAllEntries()
    }

    func apply(_ command: EntryMutationCommand) async throws -> EntryMutationReceipt {
        try await base.apply(command)
    }

    func latestUndoCandidate(asOf: Date) async throws -> EntryUndoCandidate? {
        try await base.latestUndoCandidate(asOf: asOf)
    }

    func loadSettings() async throws -> AppSettings {
        try await base.loadSettings()
    }

    func saveSettings(_ settings: AppSettings) async throws {
        try await base.saveSettings(settings)
    }

    func fetchPolicies() async throws -> [ReportingPolicy] {
        try await base.fetchPolicies()
    }

    func savePolicy(_ policy: ReportingPolicy) async throws {
        try await base.savePolicy(policy)
    }

    func fetchReminders() async throws -> [ReminderSchedule] {
        try await base.fetchReminders()
    }

    func saveReminder(_ reminder: ReminderSchedule) async throws {
        try await base.saveReminder(reminder)
    }

    func deleteReminder(id: UUID) async throws {
        try await base.deleteReminder(id: id)
    }

    func fetchReceipts() async throws -> [ReportReceipt] {
        try await base.fetchReceipts()
    }

    func saveReceipt(_ receipt: ReportReceipt, details: ReportSnapshotDetails?) async throws {
        try await base.saveReceipt(receipt, details: details)
    }

    func reconcileReportLifecycle(asOf now: Date) async throws -> LedgerSnapshot {
        try await base.reconcileReportLifecycle(asOf: now)
    }

    func reviewReport(_ request: ReviewReportRequest) async throws -> LedgerSnapshot {
        try await base.reviewReport(request)
    }

    func prepareReport(_ request: PrepareReportRequest) async throws -> PreparedReportResult {
        try await base.prepareReport(request)
    }

    func markReportSent(_ request: MarkReportSentRequest) async throws -> LedgerSnapshot {
        try await base.markReportSent(request)
    }

    func closeServiceYear(_ request: CloseServiceYearRequest) async throws -> ServiceYearArchiveResult {
        try await base.closeServiceYear(request)
    }
}

@MainActor
private final class TestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
