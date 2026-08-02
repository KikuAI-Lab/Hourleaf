import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class PersistenceAndAppModelTests: XCTestCase {
    func testRepositoryRoundTripsEntrySettingsPolicyReminderAndReceipt() async throws {
        let repository = makeRepository()
        let entry = TimeEntry(
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "Morning"
        )
        try await repository.saveEntry(entry)
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

        try await repository.deleteEntry(id: entry.id)
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
        let date = LocalDay(year: month.year, month: month.month, day: 10).date(calendar: .hourleaf)
        let added = await model.addEntry(kind: .service, date: date, hours: 1, minutes: 15, note: nil)
        XCTAssertTrue(added)

        let report = model.report(for: month)
        let text = ReportFormatter.format(report, settings: model.settings)
        let createdReceipt = await model.createReceipt(for: report, text: text)
        let receipt = try XCTUnwrap(createdReceipt)
        await model.markReceiptSent(receipt)
        let entry = try XCTUnwrap(model.entries.first)

        let updated = await model.updateEntry(entry, kind: .service, date: date, hours: 2, minutes: 0, note: nil)
        XCTAssertTrue(updated)
        let storedReceipt = try XCTUnwrap(model.receipts.first)
        XCTAssertTrue(model.isStale(storedReceipt))
        XCTAssertTrue(model.changeAffectsConfirmedReport(from: month))
    }

    func testReportPreparationRejectsMixedStaleInputs() async throws {
        let repository = makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: TestReminderScheduler())
        await model.loadInitialSnapshot()
        let month = MonthKey(Date(), calendar: .hourleaf)
        let date = LocalDay(year: month.year, month: month.month, day: 10).date(calendar: .hourleaf)
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
        XCTAssertEqual(state.state, "sent")
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
        XCTAssertEqual(state.state, "prepared")
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
        XCTAssertEqual(state.state, "prepared")
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

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await repository.saveEntry(first) }
            group.addTask { try await repository.saveEntry(second) }
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

@MainActor
private final class TestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
