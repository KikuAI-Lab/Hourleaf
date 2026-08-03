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

    func testEntryMutationProducesRecordsChanged() async throws {
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

    @MainActor
    func testDataManagementActionsCreateBackupWritesEvidenceAndRefreshesStatus() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
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
        defer { try? FileManager.default.removeItem(at: journalRoot) }
        let restoreCoordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            journalStore: RestoreJournalStoreV1(rootDirectory: journalRoot),
            reminderScheduler: scheduler
        )
        let evidenceRoot = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: evidenceRoot) }

        let actions = DataManagementActions.live(
            repository: repository,
            restoreCoordinator: restoreCoordinator,
            appModel: appModel,
            backupEvidenceStore: VerifiedExportEvidenceStore(applicationSupportDirectory: { evidenceRoot })
        )

        let payload = try await actions.createBackup()
        payload.cleanup()
        actions.backupStatus.requestRefresh()
        let matched = await waitForMatchingStatus(actions.backupStatus)

        guard matched else {
            return XCTFail("Expected backup status to match after live backup creation, got \(String(describing: actions.backupStatus.state)).")
        }
    }

    @MainActor
    private func waitForMatchingStatus(_ model: BackupConfidenceStatusModel) async -> Bool {
        for _ in 0..<100 {
            if case .matches = model.state {
                return true
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
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

@MainActor
private final class LocalTestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
