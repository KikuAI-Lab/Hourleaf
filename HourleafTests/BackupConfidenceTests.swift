import Foundation
import XCTest
@testable import Hourleaf

final class BackupConfidenceTests: XCTestCase {
    func testNoReceiptProducesNoVerifiedExport() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let records = Self.makeRecords()

        let state = await BackupConfidenceEvaluator(
            evidenceStore: VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox }),
            snapshot: { records }
        ).evaluate()

        XCTAssertEqual(state, .noVerifiedExport)
    }

    func testVerifiedExporterSuccessThenDigestMatchProducesMatches() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let records = Self.makeRecords()
        let evidenceStore = VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox })
        let artifact = try Self.makeArtifact(records: records)

        try await evidenceStore.recordVerifiedExport(for: artifact, verifiedAt: Date(timeIntervalSinceReferenceDate: 500))

        let state = await BackupConfidenceEvaluator(
            evidenceStore: evidenceStore,
            snapshot: { records }
        ).evaluate()

        XCTAssertEqual(state, .matches(verifiedAt: Date(timeIntervalSinceReferenceDate: 500)))
    }

    func testMalformedReceiptProducesUnavailable() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let directory = sandbox
            .appendingPathComponent("Hourleaf", isDirectory: true)
            .appendingPathComponent("BackupEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("broken".utf8).write(
            to: directory.appendingPathComponent("last-verified-export-v1.json"),
            options: .withoutOverwriting
        )

        let state = await BackupConfidenceEvaluator(
            evidenceStore: VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox }),
            snapshot: { Self.makeRecords() }
        ).evaluate()

        XCTAssertEqual(state, .unavailable)
    }

    func testUnsupportedReceiptSchemaProducesUnavailable() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let directory = sandbox
            .appendingPathComponent("Hourleaf", isDirectory: true)
            .appendingPathComponent("BackupEvidence", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unsupported = """
        {
          "artifactChecksum" : "\(String(repeating: "a", count: 64))",
          "byteCount" : 1024,
          "exportedAt" : "2001-01-01T00:01:40.000Z",
          "recordsDigest" : "\(String(repeating: "b", count: 64))",
          "schemaVersion" : 2,
          "totalRecordCount" : 42,
          "verifiedAt" : "2001-01-01T00:03:20.000Z"
        }
        """
        try Data(unsupported.utf8).write(
            to: directory.appendingPathComponent("last-verified-export-v1.json"),
            options: .withoutOverwriting
        )

        let state = await BackupConfidenceEvaluator(
            evidenceStore: VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox }),
            snapshot: { Self.makeRecords() }
        ).evaluate()

        XCTAssertEqual(state, .unavailable)
    }

    func testSettingsMutationProducesRecordsChanged() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let records = Self.makeRecords()
        let evidenceStore = VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox })
        let verifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        try await evidenceStore.recordVerifiedExport(
            for: Self.makeArtifact(records: records),
            verifiedAt: verifiedAt
        )

        let changedRecords: HourleafBackupRecordsV1 = {
            var changed = records
            changed.settings.creditLabelEnglish = "Different credit label"
            return changed
        }()

        let state = await BackupConfidenceEvaluator(
            evidenceStore: evidenceStore,
            snapshot: { changedRecords }
        ).evaluate()

        XCTAssertEqual(state, .recordsChanged(verifiedAt: verifiedAt))
    }

    func testDeletedEntryMutationProducesRecordsChanged() async throws {
        try await assertRecordsChanged { records in
            var changed = records
            changed.entries[0].deletedAt = 11
            changed.entries[0].updatedAt = 11
            changed.entries[0].revision = 2
            changed.entries[0].lastMutationID = "00000000-0000-0000-0000-000000000102"
            changed.entries[0].source = EntryMutationSource.appHistory.rawValue
            changed.revisions.append(HourleafEntryRevisionV1(
                entryCreatedAt: 10,
                entryDeletedAt: 11,
                entryID: "00000000-0000-0000-0000-000000000001",
                entryUpdatedAt: 11,
                id: "00000000-0000-0000-0000-000000000202",
                kind: EntryKind.service.rawValue,
                localDay: "2026-07-12",
                minutes: 75,
                mutationID: "00000000-0000-0000-0000-000000000102",
                note: "note",
                occurredAt: 11,
                operation: EntryMutationOperation.delete.rawValue,
                parentMutationID: "00000000-0000-0000-0000-000000000101",
                revertedMutationID: nil,
                revision: 2,
                source: EntryMutationSource.appHistory.rawValue
            ))
            return changed
        }
    }

    func testRevisionMutationProducesRecordsChanged() async throws {
        try await assertRecordsChanged { records in
            var changed = records
            changed.entries[0].note = "revised note"
            changed.entries[0].updatedAt = 11
            changed.entries[0].revision = 2
            changed.entries[0].lastMutationID = "00000000-0000-0000-0000-000000000102"
            changed.entries[0].source = EntryMutationSource.appHistory.rawValue
            changed.revisions.append(HourleafEntryRevisionV1(
                entryCreatedAt: 10,
                entryDeletedAt: nil,
                entryID: "00000000-0000-0000-0000-000000000001",
                entryUpdatedAt: 11,
                id: "00000000-0000-0000-0000-000000000202",
                kind: EntryKind.service.rawValue,
                localDay: "2026-07-12",
                minutes: 75,
                mutationID: "00000000-0000-0000-0000-000000000102",
                note: "revised note",
                occurredAt: 11,
                operation: EntryMutationOperation.update.rawValue,
                parentMutationID: "00000000-0000-0000-0000-000000000101",
                revertedMutationID: nil,
                revision: 2,
                source: EntryMutationSource.appHistory.rawValue
            ))
            return changed
        }
    }

    func testReminderMutationProducesRecordsChanged() async throws {
        try await assertRecordsChanged { records in
            var changed = records
            changed.reminders = [
                HourleafReminderV1(
                    createdAt: 12,
                    hour: 18,
                    id: "00000000-0000-0000-0000-000000000401",
                    isEnabled: true,
                    minute: 30,
                    updatedAt: 12,
                    weekday: 2
                )
            ]
            return changed
        }
    }

    func testReportStateMutationProducesRecordsChanged() async throws {
        try await assertRecordsChanged { records in
            var changed = records
            changed.states = [
                HourleafReportStateV1(
                    changedAt: nil,
                    currentSnapshotID: nil,
                    id: "00000000-0000-0000-0000-000000000501",
                    lastStableState: nil,
                    monthKey: "2026-07",
                    reviewedCalculationFingerprint: nil,
                    reviewedPresentationFingerprint: nil,
                    state: ReportLifecycleState.draft.rawValue,
                    updatedAt: 15
                )
            ]
            return changed
        }
    }

    func testAcknowledgementMutationProducesRecordsChanged() async throws {
        try await assertRecordsChanged { records in
            var changed = records
            changed.acknowledgements = [
                HourleafDayAcknowledgementV1(
                    createdAt: 13,
                    id: "00000000-0000-0000-0000-000000000601",
                    localDay: "2026-07-12",
                    source: DayAcknowledgementSource.scheduledReminder.rawValue,
                    status: DayAcknowledgementStatus.nothingToday.rawValue,
                    updatedAt: 13
                )
            ]
            return changed
        }
    }

    func testRestartWithRetainedReceiptAndSameDigestRemainsMatches() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let records = Self.makeRecords()
        let firstStore = VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox })
        let verifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        try await firstStore.recordVerifiedExport(
            for: Self.makeArtifact(records: records),
            verifiedAt: verifiedAt
        )

        let restartedState = await BackupConfidenceEvaluator(
            evidenceStore: VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox }),
            snapshot: { records }
        ).evaluate()

        XCTAssertEqual(restartedState, .matches(verifiedAt: verifiedAt))
    }

    func testFailedVerifiedExportDoesNotReplacePriorGoodEvidence() async throws {
        let sandbox = try makeSandbox()
        let directory = try makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: directory)
        }

        let records = Self.makeRecords()
        let store = VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox })
        let firstArtifact = try Self.makeArtifact(records: records)
        let firstVerifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        try await store.recordVerifiedExport(for: firstArtifact, verifiedAt: firstVerifiedAt)

        let exporter = HourleafBackupExporter(
            source: BackupConfidenceFixtureSource(records: records),
            readBack: { url in
                let data = try Data(contentsOf: url)
                return Data(data.dropLast())
            }
        )

        await assertBackupConfidenceThrowsErrorAsync(
            try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 700)
            )
        ) { error in
            XCTAssertEqual(error as? HourleafBackupExportError, .verificationFailed)
        }

        let preserved = try await store.read()
        XCTAssertEqual(preserved?.verifiedAt, firstVerifiedAt)
        XCTAssertEqual(preserved?.recordsDigest, firstArtifact.recordsDigest)
    }

    @MainActor
    func testCSVExportCleanupDoesNotUpdateEvidence() async throws {
        let environment = try await makeLiveEnvironment()
        defer {
            environment.cleanup()
        }

        let verifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        let original = try await Self.seedEvidence(
            store: environment.evidenceStore,
            repository: environment.repository,
            verifiedAt: verifiedAt
        )

        let payload = try await environment.actions.exportCSV(false)
        payload.cleanup()
        environment.actions.backupStatus.requestRefresh()
        let matched = await waitForState(environment.actions.backupStatus) { state in
            state == .matches(verifiedAt: verifiedAt)
        }

        XCTAssertTrue(matched)
        let retainedEvidence = try await environment.evidenceStore.read()
        XCTAssertEqual(retainedEvidence, original)
    }

    @MainActor
    func testRestorePreviewAndDiscardDoNotUpdateEvidence() async throws {
        let environment = try await makeLiveEnvironment(fileBacked: true)
        defer {
            environment.cleanup()
        }

        let verifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        let original = try await Self.seedEvidence(
            store: environment.evidenceStore,
            repository: environment.repository,
            verifiedAt: verifiedAt
        )
        let backupDirectory = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let artifact = try await HourleafBackupExporter(source: environment.repository)
            .createVerifiedBackup(in: backupDirectory)

        let preview = try await environment.actions.previewRestore(artifact.url)
        await environment.actions.discardRestorePreview(preview)
        environment.actions.backupStatus.requestRefresh()
        let matched = await waitForState(environment.actions.backupStatus) { state in
            state == .matches(verifiedAt: verifiedAt)
        }

        XCTAssertTrue(matched)
        let retainedEvidence = try await environment.evidenceStore.read()
        XCTAssertEqual(retainedEvidence, original)
    }

    @MainActor
    func testSuccessfulRestoreRecomputesAgainstRetainedReceipt() async throws {
        let environment = try await makeLiveEnvironment(fileBacked: true)
        defer {
            environment.cleanup()
        }

        let backupDirectory = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: backupDirectory) }
        let artifact = try await HourleafBackupExporter(source: environment.repository)
            .createVerifiedBackup(in: backupDirectory)
        try await environment.evidenceStore.recordVerifiedExport(for: artifact)
        environment.actions.backupStatus.requestRefresh()
        let initiallyMatched = await waitForState(environment.actions.backupStatus) { state in
            if case .matches = state { return true }
            return false
        }
        guard initiallyMatched,
              case let .matches(originalVerifiedAt)? = environment.actions.backupStatus.state else {
            return XCTFail("Expected initial backup status to match immediately after verified export.")
        }

        _ = try await environment.repository.apply(
            EntryMutationCommand(
                entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
                expectedRevision: 1,
                operation: .update,
                values: EntryMutationValues(
                    kind: .service,
                    day: LocalDay(year: 2026, month: 7, day: 12),
                    minutes: 30,
                    note: "changed after export"
                ),
                occurredAt: environment.authorizedAt,
                source: .appHistory
            )
        )
        environment.actions.backupStatus.requestRefresh()
        let changed = await waitForState(environment.actions.backupStatus) { state in
            state == .recordsChanged(verifiedAt: originalVerifiedAt)
        }
        XCTAssertTrue(changed)

        let preview = try await environment.actions.previewRestore(artifact.url)
        try await environment.actions.restore(preview)
        let restored = await waitForState(environment.actions.backupStatus) { state in
            state == .matches(verifiedAt: originalVerifiedAt)
        }

        XCTAssertTrue(restored)
    }

    @MainActor
    func testDataManagementActionsCreateBackupWritesEvidenceAndRefreshesStatus() async throws {
        let environment = try await makeLiveEnvironment()
        defer {
            environment.cleanup()
        }

        let payload = try await environment.actions.createBackup()
        payload.cleanup()
        environment.actions.backupStatus.requestRefresh()
        let matched = await waitForState(environment.actions.backupStatus) { state in
            if case .matches = state {
                return true
            }
            return false
        }

        guard matched else {
            return XCTFail("Expected backup status to match after live backup creation, got \(String(describing: environment.actions.backupStatus.state)).")
        }
    }

    @MainActor
    private func waitForState(
        _ model: BackupConfidenceStatusModel,
        predicate: @escaping (BackupConfidenceState?) -> Bool
    ) async -> Bool {
        for _ in 0..<100 {
            if predicate(model.state) {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private func assertRecordsChanged(
        file: StaticString = #filePath,
        line: UInt = #line,
        mutate: @escaping @Sendable (HourleafBackupRecordsV1) -> HourleafBackupRecordsV1
    ) async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let records = Self.makeRecords()
        let evidenceStore = VerifiedExportEvidenceStore(applicationSupportDirectory: { sandbox })
        let verifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        try await evidenceStore.recordVerifiedExport(
            for: Self.makeArtifact(records: records),
            verifiedAt: verifiedAt
        )

        let state = await BackupConfidenceEvaluator(
            evidenceStore: evidenceStore,
            snapshot: { mutate(records) }
        ).evaluate()

        XCTAssertEqual(state, .recordsChanged(verifiedAt: verifiedAt), file: file, line: line)
    }

    @MainActor
    private func makeLiveEnvironment(fileBacked: Bool = false) async throws -> LiveEnvironment {
        let storeRoot: URL?
        let persistence: PersistenceController
        if fileBacked {
            let root = try makeSandbox()
            storeRoot = root
            persistence = PersistenceController(
                inMemory: false,
                cloudSyncEnabled: false,
                storeURL: root.appendingPathComponent("live.sqlite")
            )
        } else {
            storeRoot = nil
            persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        }
        let authorizedAt = Calendar.hourleaf.date(
            from: DateComponents(year: 2026, month: 7, day: 12, hour: 12, minute: 0, second: 0)
        )!
        let repository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { authorizedAt }
        )
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 7)
        try await repository.saveSettings(settings)
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: .service,
                    day: LocalDay(year: 2026, month: 7, day: 12),
                    minutes: 75,
                    note: "evidence"
                ),
                occurredAt: authorizedAt.addingTimeInterval(-60),
                source: .appQuickEntry
            )
        )

        let scheduler = LocalTestReminderScheduler()
        let appModel = AppModel(repository: repository, reminderScheduler: scheduler, now: { authorizedAt })
        let journalRoot = try makeSandbox()
        let restoreCoordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            journalStore: RestoreJournalStoreV1(rootDirectory: journalRoot),
            reminderScheduler: scheduler
        )
        let evidenceRoot = try makeSandbox()
        let evidenceStore = VerifiedExportEvidenceStore(applicationSupportDirectory: { evidenceRoot })

        return LiveEnvironment(
            actions: DataManagementActions.live(
                repository: repository,
                restoreCoordinator: restoreCoordinator,
                appModel: appModel,
                backupEvidenceStore: evidenceStore
            ),
            authorizedAt: authorizedAt,
            evidenceRoot: evidenceRoot,
            evidenceStore: evidenceStore,
            journalRoot: journalRoot,
            persistence: persistence,
            storeRoot: storeRoot,
            repository: repository
        )
    }

    private static func seedEvidence(
        store: VerifiedExportEvidenceStore,
        repository: CoreDataLedgerRepository,
        verifiedAt: Date
    ) async throws -> VerifiedExportEvidenceV1 {
        let records = try await repository.portableBackupRecords()
        let artifact = try Self.makeArtifact(records: records)
        try await store.recordVerifiedExport(for: artifact, verifiedAt: verifiedAt)
        let evidence = try await store.read()
        return try XCTUnwrap(evidence)
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupConfidenceTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func makeArtifact(records: HourleafBackupRecordsV1) throws -> HourleafBackupArtifactV1 {
        let exportedAt = recordsExportDate()
        let backup = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(
                exportedAt: exportedAt.timeIntervalSinceReferenceDate,
                records: records
            )
        )
        return HourleafBackupArtifactV1(
            url: URL(fileURLWithPath: "/tmp/verified.hourleafbackup"),
            exportedAt: exportedAt,
            byteCount: backup.byteCount,
            checksum: backup.checksum,
            recordCounts: backup.recordCounts,
            recordsDigest: backup.recordsDigest
        )
    }

    private static func makeRecords() -> HourleafBackupRecordsV1 {
        HourleafBackupRecordsV1(
            acknowledgements: [],
            archives: [],
            entries: [
                HourleafEntryV1(
                    createdAt: 10,
                    deletedAt: nil,
                    id: "00000000-0000-0000-0000-000000000001",
                    kind: EntryKind.service.rawValue,
                    lastMutationID: "00000000-0000-0000-0000-000000000101",
                    localDay: "2026-07-12",
                minutes: 75,
                note: "note",
                revision: 1,
                source: EntryMutationSource.appQuickEntry.rawValue,
                updatedAt: 10
            )
            ],
            policies: [],
            presets: [],
            receipts: [],
            reminders: [],
            revisions: [
                HourleafEntryRevisionV1(
                    entryCreatedAt: 10,
                    entryDeletedAt: nil,
                    entryID: "00000000-0000-0000-0000-000000000001",
                    entryUpdatedAt: 10,
                    id: "00000000-0000-0000-0000-000000000201",
                    kind: EntryKind.service.rawValue,
                    localDay: "2026-07-12",
                    minutes: 75,
                    mutationID: "00000000-0000-0000-0000-000000000101",
                    note: "note",
                    occurredAt: 10,
                    operation: EntryMutationOperation.create.rawValue,
                    parentMutationID: nil,
                    revertedMutationID: nil,
                    revision: 1,
                    source: EntryMutationSource.appQuickEntry.rawValue
                )
            ],
            settings: HourleafSettingsV1(
                baselineServiceYearMinutes: 0,
                baselineServiceYearStart: "2025-09",
                creditLabelEnglish: "Credit hours",
                creditLabelRussian: "Credit",
                creditLabelUkrainian: "Credit",
                dataRevision: 2,
                id: "00000000-0000-0000-0000-000000000301",
                lastPurgeAt: nil,
                ledgerStartMonth: "2026-07",
                onboardingComplete: true,
                openingCreditCarryMinutes: 0,
                openingServiceCarryMinutes: 0,
                planningVisible: false,
                quietGapCheckEnabled: false,
                quietGapDays: 7,
                reportLanguage: ReportLanguage.english.rawValue,
                syncMode: nil,
                timerVisible: false,
                updatedAt: 10,
                widgetPrivacyMode: nil
            ),
            states: []
        )
    }

    private static func recordsExportDate() -> Date {
        Date(timeIntervalSinceReferenceDate: 500)
    }
}

private struct LiveEnvironment {
    let actions: DataManagementActions
    let authorizedAt: Date
    let evidenceRoot: URL
    let evidenceStore: VerifiedExportEvidenceStore
    let journalRoot: URL
    let persistence: PersistenceController
    let storeRoot: URL?
    let repository: CoreDataLedgerRepository

    func cleanup() {
        _ = try? persistence.closePersistentStoreForTransition()
        try? FileManager.default.removeItem(at: evidenceRoot)
        try? FileManager.default.removeItem(at: journalRoot)
        if let storeRoot {
            try? FileManager.default.removeItem(at: storeRoot)
        }
    }
}

private actor BackupConfidenceFixtureSource: PortableBackupSource {
    let records: HourleafBackupRecordsV1

    init(records: HourleafBackupRecordsV1) {
        self.records = records
    }

    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        records
    }
}

private func assertBackupConfidenceThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

@MainActor
private final class LocalTestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
