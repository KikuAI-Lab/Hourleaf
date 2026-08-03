@preconcurrency import CoreData
import Foundation
@testable import Hourleaf

enum RestoreFixture {
    static let unicodeMultilineNote = "  Русский / Українська / English 🙂 \"quoted\"\nsecond line  "
    static let deletedMultilineNote = "deleted\nзаметка"

    static func backupData(
        exportedAt: Date = Date(timeIntervalSinceReferenceDate: 99),
        acknowledgementCount: Int = 1
    ) throws -> Data {
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(
                exportedAt: exportedAt.timeIntervalSinceReferenceDate,
                records: records(acknowledgementCount: acknowledgementCount)
            )
        ).data
    }

    static func records(acknowledgementCount: Int = 1) -> HourleafBackupRecordsV1 {
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
        let acknowledgements = (0..<acknowledgementCount).map { index in
            HourleafDayAcknowledgementV1(
                createdAt: 16 + Double(index),
                id: idString(10_000 + index),
                localDay: "2026-07-13",
                source: "quietDayPromptV2",
                status: "nothingToday",
                updatedAt: 17 + Double(index)
            )
        }

        return HourleafBackupRecordsV1(
            acknowledgements: acknowledgements,
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
                    deletedAt: nil,
                    id: idString(1),
                    kind: EntryKind.service.rawValue,
                    lastMutationID: idString(103),
                    localDay: "2026-07-12",
                    minutes: 75,
                    note: unicodeMultilineNote,
                    revision: 3,
                    source: EntryMutationSource.undo.rawValue,
                    updatedAt: 13
                ),
                HourleafEntryV1(
                    createdAt: 30,
                    deletedAt: 31,
                    id: idString(201),
                    kind: EntryKind.credit.rawValue,
                    lastMutationID: idString(205),
                    localDay: "2026-07-13",
                    minutes: 30,
                    note: deletedMultilineNote,
                    revision: 2,
                    source: EntryMutationSource.appHistory.rawValue,
                    updatedAt: 31
                ),
                HourleafEntryV1(
                    createdAt: 40,
                    deletedAt: nil,
                    id: idString(301),
                    kind: EntryKind.credit.rawValue,
                    lastMutationID: idString(303),
                    localDay: "2026-07-14",
                    minutes: 15,
                    note: nil,
                    revision: 1,
                    source: EntryMutationSource.appQuickEntry.rawValue,
                    updatedAt: 40
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
                    note: unicodeMultilineNote,
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
                    note: unicodeMultilineNote,
                    occurredAt: 12,
                    operation: EntryMutationOperation.delete.rawValue,
                    parentMutationID: idString(101),
                    revertedMutationID: nil,
                    revision: 2,
                    source: EntryMutationSource.appHistory.rawValue
                ),
                HourleafEntryRevisionV1(
                    entryCreatedAt: 10,
                    entryDeletedAt: nil,
                    entryID: idString(1),
                    entryUpdatedAt: 13,
                    id: idString(22),
                    kind: EntryKind.service.rawValue,
                    localDay: "2026-07-12",
                    minutes: 75,
                    mutationID: idString(103),
                    note: unicodeMultilineNote,
                    occurredAt: 13,
                    operation: EntryMutationOperation.undo.rawValue,
                    parentMutationID: idString(102),
                    revertedMutationID: idString(102),
                    revision: 3,
                    source: EntryMutationSource.undo.rawValue
                ),
                HourleafEntryRevisionV1(
                    entryCreatedAt: 30,
                    entryDeletedAt: nil,
                    entryID: idString(201),
                    entryUpdatedAt: 30,
                    id: idString(202),
                    kind: EntryKind.credit.rawValue,
                    localDay: "2026-07-13",
                    minutes: 30,
                    mutationID: idString(204),
                    note: deletedMultilineNote,
                    occurredAt: 30,
                    operation: EntryMutationOperation.create.rawValue,
                    parentMutationID: nil,
                    revertedMutationID: nil,
                    revision: 1,
                    source: EntryMutationSource.appQuickEntry.rawValue
                ),
                HourleafEntryRevisionV1(
                    entryCreatedAt: 30,
                    entryDeletedAt: 31,
                    entryID: idString(201),
                    entryUpdatedAt: 31,
                    id: idString(203),
                    kind: EntryKind.credit.rawValue,
                    localDay: "2026-07-13",
                    minutes: 30,
                    mutationID: idString(205),
                    note: deletedMultilineNote,
                    occurredAt: 31,
                    operation: EntryMutationOperation.delete.rawValue,
                    parentMutationID: idString(204),
                    revertedMutationID: nil,
                    revision: 2,
                    source: EntryMutationSource.appHistory.rawValue
                ),
                HourleafEntryRevisionV1(
                    entryCreatedAt: 40,
                    entryDeletedAt: nil,
                    entryID: idString(301),
                    entryUpdatedAt: 40,
                    id: idString(302),
                    kind: EntryKind.credit.rawValue,
                    localDay: "2026-07-14",
                    minutes: 15,
                    mutationID: idString(303),
                    note: nil,
                    occurredAt: 40,
                    operation: EntryMutationOperation.create.rawValue,
                    parentMutationID: nil,
                    revertedMutationID: nil,
                    revision: 1,
                    source: EntryMutationSource.appQuickEntry.rawValue
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

    static func idString(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }
}

@MainActor
final class RestoreTestRuntime {
    let persistence: PersistenceController
    let repository: CoreDataLedgerRepository
    private var isClosed = false

    init(
        storeURL: URL,
        reopenFailureMessage: @escaping @Sendable () -> String? = { nil }
    ) {
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: storeURL,
            reopenFailureMessage: reopenFailureMessage
        )
        self.persistence = persistence
        repository = CoreDataLedgerRepository(persistence: persistence)
    }

    func seed(_ records: HourleafBackupRecordsV1) throws {
        let context = persistence.container.newBackgroundContext()
        context.undoManager = nil
        defer {
            context.performAndWait { context.reset() }
        }
        try context.performAndWait {
            try RawBackupStore.insert(records, into: context)
        }
    }

    func readyRuntime() -> RestoreReadyRuntime {
        RestoreReadyRuntime(persistence: persistence, repository: repository)
    }

    func close() {
        guard !isClosed else { return }
        // Confirmation may intentionally leave a process-local controller
        // closed after an injected boundary failure. Teardown owns only its
        // sandbox, so a second close is a harmless no-op here.
        _ = try? persistence.closePersistentStoreForTransition()
        isClosed = true
    }
}

final class RestoreTestProtectionReader: HourleafFileProtectionReading, @unchecked Sendable {
    private let value: String?

    init(value: String? = FileProtectionType.completeUntilFirstUserAuthentication.rawValue) {
        self.value = value
    }

    func protectionClass(at _: URL) throws -> String? {
        value
    }
}

@MainActor
final class RestoreTestReminderScheduler: ReminderScheduling {
    enum Failure: Error {
        case injected
    }

    private(set) var requestsAuthorizationCount = 0
    private(set) var rescheduled: [[ReminderSchedule]] = []
    var failsReschedule = false

    func requestAuthorization() async throws -> Bool {
        requestsAuthorizationCount += 1
        return true
    }

    func reschedule(_ reminders: [ReminderSchedule]) async throws {
        rescheduled.append(reminders)
        if failsReschedule { throw Failure.injected }
    }
}

/// Exercises the public repository writer gate from inside the reminder
/// boundary. A successful restore must keep ordinary writes unavailable until
/// after this callback, cleanup, journal completion, and terminal readback.
@MainActor
final class RestoreLeaseCheckingReminderScheduler: ReminderScheduling {
    private let repository: CoreDataLedgerRepository
    private(set) var observedMaintenanceLease = false
    private(set) var observedOrdinaryWriterBlocked = false
    private(set) var rescheduled: [[ReminderSchedule]] = []

    init(repository: CoreDataLedgerRepository) {
        self.repository = repository
    }

    func requestAuthorization() async throws -> Bool {
        true
    }

    func reschedule(_ reminders: [ReminderSchedule]) async throws {
        rescheduled.append(reminders)
        observedMaintenanceLease = await repository.maintenanceIsInProgress()
        guard let reminder = reminders.first else { return }
        do {
            try await repository.saveReminder(reminder)
        } catch let error as LedgerRepositoryError {
            observedOrdinaryWriterBlocked = error == .maintenanceInProgress
        } catch {
            observedOrdinaryWriterBlocked = false
        }
    }
}

final class RestoreLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.withLock { value += 1 }
    }

    func read() -> Int {
        lock.withLock { value }
    }
}

final class RestoreOneShotReopenFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingMessage: String?

    init(message: String) {
        pendingMessage = message
    }

    func consume() -> String? {
        lock.withLock {
            defer { pendingMessage = nil }
            return pendingMessage
        }
    }
}

enum RestoreTestFault: Error {
    case injected
}

final class RestoreOneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: RestoreFaultPoint
    private var didFire = false

    init(point: RestoreFaultPoint) {
        self.point = point
    }

    func inject(_ observed: RestoreFaultPoint) throws {
        guard observed == point else { return }
        let shouldThrow = lock.withLock {
            guard !didFire else { return false }
            didFire = true
            return true
        }
        if shouldThrow {
            throw RestoreTestFault.injected
        }
    }
}

final class RestoreOneShotAction: @unchecked Sendable {
    private let lock = NSLock()
    private let point: RestoreFaultPoint
    private let action: @Sendable () throws -> Void
    private var didRun = false

    init(
        point: RestoreFaultPoint,
        action: @escaping @Sendable () throws -> Void
    ) {
        self.point = point
        self.action = action
    }

    func inject(_ observed: RestoreFaultPoint) throws {
        guard observed == point else { return }
        let shouldRun = lock.withLock {
            guard !didRun else { return false }
            didRun = true
            return true
        }
        if shouldRun {
            try action()
        }
    }
}
