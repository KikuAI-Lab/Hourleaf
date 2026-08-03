@preconcurrency import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class HourleafBackupPersistenceTests: XCTestCase {
    func testPortableSourceMapsRepresentativeRawValuesAcrossAllTenV2Entities() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let expected = RawBackupFixture.records
        try RawBackupFixture.seed(expected, into: persistence.container.viewContext)

        let repository = CoreDataLedgerRepository(persistence: persistence)
        let actual = try await repository.portableBackupRecords()

        // Fetch ordering is intentionally not part of the storage contract.
        // Encoding both fixtures exercises the mapper while comparing their
        // canonical raw payloads field-for-field.
        let expectedBackup = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 99, records: expected)
        )
        let actualBackup = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 99, records: actual)
        )
        XCTAssertEqual(actualBackup.content.records, expectedBackup.content.records)
        XCTAssertEqual(
            try HourleafBackupCodec.decodeAndVerify(actualBackup.data).content.records,
            expectedBackup.content.records
        )

        let entry = try XCTUnwrap(actual.entries.first)
        XCTAssertEqual(entry.deletedAt, 12)
        XCTAssertEqual(entry.note, RawBackupFixture.whitespaceUnicodeNote)
        XCTAssertEqual(actual.revisions.count, 2)
        XCTAssertNil(actual.reminders.first?.createdAt)
        XCTAssertTrue(actual.presets.contains(where: { $0.deletedAt == 16 }))
        XCTAssertTrue(actual.receipts.contains(where: \.legacyCalculationUnavailable))
        XCTAssertTrue(actual.receipts.contains(where: { $0.legacyCalculationUnavailable == false }))
        XCTAssertNil(actual.receipts.first(where: \.legacyCalculationUnavailable)?.reportLanguage)
        XCTAssertEqual(actual.settings.dataRevision, 3)
    }

    func testSubsecondRawDatesSurviveCoreDataMappingAndCanonicalRoundTripExactly() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        var expected = RawBackupFixture.records
        let createdAt = 10.125_678_901_234
        let deletedAt = 12.987_654_321_098
        expected.entries[0].createdAt = createdAt
        expected.entries[0].updatedAt = deletedAt
        expected.entries[0].deletedAt = deletedAt
        expected.revisions[0].entryCreatedAt = createdAt
        expected.revisions[0].entryUpdatedAt = createdAt
        expected.revisions[0].occurredAt = createdAt
        expected.revisions[1].entryCreatedAt = createdAt
        expected.revisions[1].entryUpdatedAt = deletedAt
        expected.revisions[1].entryDeletedAt = deletedAt
        expected.revisions[1].occurredAt = deletedAt
        try RawBackupFixture.seed(expected, into: persistence.container.viewContext)

        let repository = CoreDataLedgerRepository(persistence: persistence)
        let actual = try await repository.portableBackupRecords()
        XCTAssertEqual(actual.entries[0].createdAt, createdAt)
        XCTAssertEqual(actual.entries[0].updatedAt, deletedAt)
        XCTAssertEqual(actual.entries[0].deletedAt, deletedAt)
        XCTAssertEqual(
            try XCTUnwrap(actual.revisions.first(where: { $0.revision == 1 })).occurredAt,
            createdAt
        )
        XCTAssertEqual(
            try XCTUnwrap(actual.revisions.first(where: { $0.revision == 2 })).occurredAt,
            deletedAt
        )

        let expectedBackup = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 99.246_810_121_416, records: expected)
        )
        let actualBackup = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 99.246_810_121_416, records: actual)
        )
        XCTAssertEqual(actualBackup.content.records, expectedBackup.content.records)
        XCTAssertEqual(actualBackup.recordsDigest, expectedBackup.recordsDigest)
        XCTAssertEqual(
            try HourleafBackupCodec.decodeAndVerify(actualBackup.data).content.records,
            expectedBackup.content.records
        )
    }

    func testOneTapCreateRoundTripsFrozenBackupV1() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        var expected = RawBackupFixture.records
        expected.entries = [
            HourleafEntryV1(
                createdAt: 30,
                deletedAt: nil,
                id: RawBackupFixture.idString(301),
                kind: EntryKind.service.rawValue,
                lastMutationID: RawBackupFixture.idString(401),
                localDay: "2026-08-03",
                minutes: 61,
                note: nil,
                revision: 1,
                source: EntryMutationSource.appOneTap.rawValue,
                updatedAt: 30
            )
        ]
        expected.revisions = [
            HourleafEntryRevisionV1(
                entryCreatedAt: 30,
                entryDeletedAt: nil,
                entryID: RawBackupFixture.idString(301),
                entryUpdatedAt: 30,
                id: RawBackupFixture.idString(302),
                kind: EntryKind.service.rawValue,
                localDay: "2026-08-03",
                minutes: 61,
                mutationID: RawBackupFixture.idString(401),
                note: nil,
                occurredAt: 30,
                operation: EntryMutationOperation.create.rawValue,
                parentMutationID: nil,
                revertedMutationID: nil,
                revision: 1,
                source: EntryMutationSource.appOneTap.rawValue
            )
        ]
        try RawBackupFixture.seed(expected, into: persistence.container.viewContext)

        let repository = CoreDataLedgerRepository(persistence: persistence)
        let exported = try await repository.portableBackupRecords()
        let backup = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 321, records: exported)
        )
        let decoded = try HourleafBackupCodec.decodeAndVerify(backup.data).content.records

        let decodedEntry = try XCTUnwrap(decoded.entries.first(where: { $0.id == RawBackupFixture.idString(301) }))
        XCTAssertEqual(decodedEntry.source, EntryMutationSource.appOneTap.rawValue)
        XCTAssertNil(decodedEntry.note)
        XCTAssertEqual(decodedEntry.minutes, 61)

        let decodedRevision = try XCTUnwrap(
            decoded.revisions.first(where: {
                $0.entryID == RawBackupFixture.idString(301) &&
                $0.mutationID == RawBackupFixture.idString(401)
            })
        )
        XCTAssertEqual(decodedRevision.operation, EntryMutationOperation.create.rawValue)
        XCTAssertEqual(decodedRevision.source, EntryMutationSource.appOneTap.rawValue)
        XCTAssertNil(decodedRevision.note)
        XCTAssertEqual(decodedRevision.minutes, 61)
        XCTAssertNil(decodedRevision.parentMutationID)
        XCTAssertNil(decodedRevision.revertedMutationID)

        let restoredPersistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        try RawBackupFixture.seed(decoded, into: restoredPersistence.container.viewContext)
        let restoredRepository = CoreDataLedgerRepository(persistence: restoredPersistence)
        let restored = try await restoredRepository.portableBackupRecords()

        let restoredEntry = try XCTUnwrap(restored.entries.first(where: { $0.id == RawBackupFixture.idString(301) }))
        XCTAssertEqual(restoredEntry.source, EntryMutationSource.appOneTap.rawValue)
        XCTAssertNil(restoredEntry.note)
        XCTAssertEqual(restoredEntry.minutes, 61)

        let restoredRevision = try XCTUnwrap(
            restored.revisions.first(where: {
                $0.entryID == RawBackupFixture.idString(301) &&
                $0.mutationID == RawBackupFixture.idString(401)
            })
        )
        XCTAssertEqual(restoredRevision.operation, EntryMutationOperation.create.rawValue)
        XCTAssertEqual(restoredRevision.source, EntryMutationSource.appOneTap.rawValue)
        XCTAssertNil(restoredRevision.note)
        XCTAssertEqual(restoredRevision.minutes, 61)
    }
}

private enum RawBackupFixture {
    static let whitespaceUnicodeNote = "  Русский / Українська / English 🙂 \"quoted\"\n  "

    static var records: HourleafBackupRecordsV1 {
        let reportText = "Июль 2026\nService / Кредит годин"
        let calculationFingerprint = "calculation-fingerprint-v1"
        let creditLabel = "Кредит годин"
        let templateID = "standard"
        let presentationFingerprint = ReportFingerprint.presentation(
            calculationFingerprint: calculationFingerprint,
            language: .ukrainian,
            creditLabel: creditLabel,
            templateID: templateID,
            text: reportText
        )

        return HourleafBackupRecordsV1(
            acknowledgements: [
                HourleafDayAcknowledgementV1(
                    createdAt: 16,
                    id: idString(3),
                    localDay: "2026-07-13",
                    source: "quietDayPromptV2",
                    status: "nothingToday",
                    updatedAt: 17
                )
            ],
            archives: [
                HourleafServiceYearArchiveV1(
                    actualServiceMinutes: 100,
                    baselineServiceMinutes: 20,
                    calculationFingerprint: "archive-v1",
                    createdAt: 15,
                    endMonthKey: "2026-08",
                    id: idString(9),
                    startMonthKey: "2025-09",
                    supersedesID: nil,
                    targetMinutes: 36_000,
                    version: 1
                ),
                HourleafServiceYearArchiveV1(
                    actualServiceMinutes: 125,
                    baselineServiceMinutes: 20,
                    calculationFingerprint: "archive-v2",
                    createdAt: 21,
                    endMonthKey: "2026-08",
                    id: idString(91),
                    startMonthKey: "2025-09",
                    supersedesID: idString(9),
                    targetMinutes: 36_000,
                    version: 2
                )
            ],
            entries: [
                HourleafEntryV1(
                    createdAt: 10,
                    deletedAt: 12,
                    id: idString(1),
                    kind: EntryKind.service.rawValue,
                    lastMutationID: idString(102),
                    localDay: "2026-07-12",
                    minutes: 75,
                    note: whitespaceUnicodeNote,
                    revision: 2,
                    source: EntryMutationSource.appHistory.rawValue,
                    updatedAt: 12
                )
            ],
            policies: [
                HourleafPolicyRevisionV1(
                    carryAcrossServiceYear: true,
                    createdAt: 11,
                    effectiveMonth: "2026-07",
                    id: idString(4),
                    mode: RemainderMode.carry.rawValue
                )
            ],
            presets: [
                HourleafPresetV1(
                    createdAt: 12,
                    deletedAt: nil,
                    id: idString(5),
                    kind: EntryKind.credit.rawValue,
                    minutes: 30,
                    position: 0,
                    updatedAt: 13
                ),
                HourleafPresetV1(
                    createdAt: 14,
                    deletedAt: 16,
                    id: idString(52),
                    kind: EntryKind.service.rawValue,
                    minutes: 15,
                    position: 1,
                    updatedAt: 15
                )
            ],
            receipts: [
                HourleafReportReceiptV1(
                    calculationFingerprint: calculationFingerprint,
                    confirmedSentAt: nil,
                    createdBySource: "reportComposerV2",
                    creditCarryIn: 0,
                    creditCarryOut: 0,
                    creditHours: 0,
                    creditLabel: creditLabel,
                    id: idString(7),
                    legacyCalculationUnavailable: false,
                    monthKey: "2026-07",
                    presentationFingerprint: presentationFingerprint,
                    preparedAt: 13,
                    rawCreditMinutes: 0,
                    rawServiceMinutes: 75,
                    reportLanguage: ReportLanguage.ukrainian.rawValue,
                    reportText: reportText,
                    reportingMode: RemainderMode.carry.rawValue,
                    schemaVersion: 1,
                    serviceCarryIn: 0,
                    serviceCarryOut: 15,
                    serviceHours: 1,
                    supersedesID: nil,
                    templateID: templateID,
                    version: 1
                ),
                HourleafReportReceiptV1(
                    calculationFingerprint: nil,
                    confirmedSentAt: 19,
                    createdBySource: nil,
                    creditCarryIn: 0,
                    creditCarryOut: 0,
                    creditHours: 0,
                    creditLabel: nil,
                    id: idString(70),
                    legacyCalculationUnavailable: true,
                    monthKey: "2026-06",
                    presentationFingerprint: nil,
                    preparedAt: 18,
                    rawCreditMinutes: 0,
                    rawServiceMinutes: 0,
                    reportLanguage: nil,
                    reportText: " Legacy report ",
                    reportingMode: nil,
                    schemaVersion: 1,
                    serviceCarryIn: 0,
                    serviceCarryOut: 0,
                    serviceHours: 0,
                    supersedesID: nil,
                    templateID: nil,
                    version: 1
                )
            ],
            reminders: [
                HourleafReminderV1(
                    createdAt: nil,
                    hour: 18,
                    id: idString(6),
                    isEnabled: true,
                    minute: 45,
                    updatedAt: 17,
                    weekday: 3
                )
            ],
            revisions: [
                HourleafEntryRevisionV1(
                    entryCreatedAt: 10,
                    entryDeletedAt: nil,
                    entryID: idString(1),
                    entryUpdatedAt: 10,
                    id: idString(2),
                    kind: EntryKind.service.rawValue,
                    localDay: "2026-07-12",
                    minutes: 75,
                    mutationID: idString(101),
                    note: whitespaceUnicodeNote,
                    occurredAt: 10,
                    operation: EntryMutationOperation.create.rawValue,
                    parentMutationID: nil,
                    revertedMutationID: nil,
                    revision: 1,
                    source: EntryMutationSource.appQuickEntry.rawValue
                ),
                HourleafEntryRevisionV1(
                    entryCreatedAt: 10,
                    entryDeletedAt: 12,
                    entryID: idString(1),
                    entryUpdatedAt: 12,
                    id: idString(21),
                    kind: EntryKind.service.rawValue,
                    localDay: "2026-07-12",
                    minutes: 75,
                    mutationID: idString(102),
                    note: whitespaceUnicodeNote,
                    occurredAt: 12,
                    operation: EntryMutationOperation.delete.rawValue,
                    parentMutationID: idString(101),
                    revertedMutationID: nil,
                    revision: 2,
                    source: EntryMutationSource.appHistory.rawValue
                )
            ],
            settings: HourleafSettingsV1(
                baselineServiceYearMinutes: 600,
                baselineServiceYearStart: "2025-09",
                creditLabelEnglish: "Credit hours",
                creditLabelRussian: "Кредит часов",
                creditLabelUkrainian: "Кредит годин",
                dataRevision: 3,
                id: idString(10),
                lastPurgeAt: nil,
                ledgerStartMonth: "2026-01",
                onboardingComplete: true,
                openingCreditCarryMinutes: 10,
                openingServiceCarryMinutes: 20,
                planningVisible: true,
                quietGapCheckEnabled: true,
                quietGapDays: 7,
                reportLanguage: ReportLanguage.ukrainian.rawValue,
                syncMode: "local",
                timerVisible: true,
                updatedAt: 18,
                widgetPrivacyMode: "hideTotals"
            ),
            states: [
                HourleafReportStateV1(
                    changedAt: nil,
                    currentSnapshotID: idString(7),
                    id: idString(8),
                    lastStableState: "reviewed",
                    monthKey: "2026-07",
                    reviewedCalculationFingerprint: calculationFingerprint,
                    reviewedPresentationFingerprint: presentationFingerprint,
                    state: "prepared",
                    updatedAt: 14
                ),
                HourleafReportStateV1(
                    changedAt: 20,
                    currentSnapshotID: idString(70),
                    id: idString(71),
                    lastStableState: nil,
                    monthKey: "2026-06",
                    reviewedCalculationFingerprint: nil,
                    reviewedPresentationFingerprint: nil,
                    state: "sent",
                    updatedAt: 19
                )
            ]
        )
    }

    static func seed(_ records: HourleafBackupRecordsV1, into context: NSManagedObjectContext) throws {
        for value in records.acknowledgements {
            let object: DayAcknowledgementEntity = context.insert(DayAcknowledgementEntity.self)
            object.createdAt = date(value.createdAt)
            object.id = uuid(value.id)
            object.localDay = value.localDay
            object.source = value.source
            object.status = value.status
            object.updatedAt = date(value.updatedAt)
        }
        for value in records.archives {
            let object: ServiceYearArchiveEntity = context.insert(ServiceYearArchiveEntity.self)
            object.actualServiceMinutes = value.actualServiceMinutes
            object.baselineServiceMinutes = value.baselineServiceMinutes
            object.calculationFingerprint = value.calculationFingerprint
            object.createdAt = date(value.createdAt)
            object.endMonthKey = value.endMonthKey
            object.id = uuid(value.id)
            object.startMonthKey = value.startMonthKey
            object.supersedesID = uuid(value.supersedesID)
            object.targetMinutes = value.targetMinutes
            object.version = value.version
        }
        for value in records.entries {
            let object: EntryEntity = context.insert(EntryEntity.self)
            object.createdAt = date(value.createdAt)
            object.deletedAt = date(value.deletedAt)
            object.id = uuid(value.id)
            object.kind = value.kind
            object.lastMutationID = uuid(value.lastMutationID)
            object.localDay = value.localDay
            object.minutes = value.minutes
            object.note = value.note
            object.revision = value.revision
            object.source = value.source
            object.updatedAt = date(value.updatedAt)
        }
        for value in records.policies {
            let object: PolicyRevisionEntity = context.insert(PolicyRevisionEntity.self)
            object.carryAcrossServiceYear = value.carryAcrossServiceYear
            object.createdAt = date(value.createdAt)
            object.effectiveMonth = value.effectiveMonth
            object.id = uuid(value.id)
            object.mode = value.mode
        }
        for value in records.presets {
            let object: PresetEntity = context.insert(PresetEntity.self)
            object.createdAt = date(value.createdAt)
            object.deletedAt = date(value.deletedAt)
            object.id = uuid(value.id)
            object.kind = value.kind
            object.minutes = value.minutes
            object.position = value.position
            object.updatedAt = date(value.updatedAt)
        }
        for value in records.receipts {
            let object: ReportReceiptEntity = context.insert(ReportReceiptEntity.self)
            object.calculationFingerprint = value.calculationFingerprint
            object.confirmedSentAt = date(value.confirmedSentAt)
            object.createdBySource = value.createdBySource
            object.creditCarryIn = value.creditCarryIn
            object.creditCarryOut = value.creditCarryOut
            object.creditHours = value.creditHours
            object.creditLabel = value.creditLabel
            object.id = uuid(value.id)
            object.legacyCalculationUnavailable = value.legacyCalculationUnavailable
            object.monthKey = value.monthKey
            object.presentationFingerprint = value.presentationFingerprint
            object.preparedAt = date(value.preparedAt)
            object.rawCreditMinutes = value.rawCreditMinutes
            object.rawServiceMinutes = value.rawServiceMinutes
            object.reportLanguage = value.reportLanguage
            object.reportText = value.reportText
            object.reportingMode = value.reportingMode
            object.schemaVersion = value.schemaVersion
            object.serviceCarryIn = value.serviceCarryIn
            object.serviceCarryOut = value.serviceCarryOut
            object.serviceHours = value.serviceHours
            object.supersedesID = uuid(value.supersedesID)
            object.templateID = value.templateID
            object.version = value.version
        }
        for value in records.reminders {
            let object: ReminderEntity = context.insert(ReminderEntity.self)
            object.createdAt = date(value.createdAt)
            object.hour = value.hour
            object.id = uuid(value.id)
            object.isEnabled = value.isEnabled
            object.minute = value.minute
            object.updatedAt = date(value.updatedAt)
            object.weekday = value.weekday
        }
        for value in records.revisions {
            let object: EntryRevisionEntity = context.insert(EntryRevisionEntity.self)
            object.entryCreatedAt = date(value.entryCreatedAt)
            object.entryDeletedAt = date(value.entryDeletedAt)
            object.entryID = uuid(value.entryID)
            object.entryUpdatedAt = date(value.entryUpdatedAt)
            object.id = uuid(value.id)
            object.kind = value.kind
            object.localDay = value.localDay
            object.minutes = value.minutes
            object.mutationID = uuid(value.mutationID)
            object.note = value.note
            object.occurredAt = date(value.occurredAt)
            object.operation = value.operation
            object.parentMutationID = uuid(value.parentMutationID)
            object.revertedMutationID = uuid(value.revertedMutationID)
            object.revision = value.revision
            object.source = value.source
        }

        let setting: SettingsEntity = context.insert(SettingsEntity.self)
        setting.baselineServiceYearMinutes = records.settings.baselineServiceYearMinutes
        setting.baselineServiceYearStart = records.settings.baselineServiceYearStart
        setting.creditLabelEnglish = records.settings.creditLabelEnglish
        setting.creditLabelRussian = records.settings.creditLabelRussian
        setting.creditLabelUkrainian = records.settings.creditLabelUkrainian
        setting.dataRevision = records.settings.dataRevision
        setting.id = uuid(records.settings.id)
        setting.lastPurgeAt = date(records.settings.lastPurgeAt)
        setting.ledgerStartMonth = records.settings.ledgerStartMonth
        setting.onboardingComplete = records.settings.onboardingComplete
        setting.openingCreditCarryMinutes = records.settings.openingCreditCarryMinutes
        setting.openingServiceCarryMinutes = records.settings.openingServiceCarryMinutes
        setting.planningVisible = records.settings.planningVisible
        setting.quietGapCheckEnabled = records.settings.quietGapCheckEnabled
        setting.quietGapDays = records.settings.quietGapDays
        setting.reportLanguage = records.settings.reportLanguage
        setting.syncMode = records.settings.syncMode
        setting.timerVisible = records.settings.timerVisible
        setting.updatedAt = date(records.settings.updatedAt)
        setting.widgetPrivacyMode = records.settings.widgetPrivacyMode

        for value in records.states {
            let object: ReportStateEntity = context.insert(ReportStateEntity.self)
            object.changedAt = date(value.changedAt)
            object.currentSnapshotID = uuid(value.currentSnapshotID)
            object.id = uuid(value.id)
            object.lastStableState = value.lastStableState
            object.monthKey = value.monthKey
            object.reviewedCalculationFingerprint = value.reviewedCalculationFingerprint
            object.reviewedPresentationFingerprint = value.reviewedPresentationFingerprint
            object.state = value.state
            object.updatedAt = date(value.updatedAt)
        }

        try context.save()
    }

    static func idString(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }

    private static func uuid(_ value: String?) -> UUID? {
        value.flatMap(UUID.init(uuidString:))
    }

    private static func date(_ value: Double?) -> Date? {
        value.map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
