@preconcurrency import CoreData
import Foundation

protocol LedgerRepository: Sendable {
    func ledgerSnapshot() async throws -> LedgerSnapshot
    func fetchEntries() async throws -> [TimeEntry]
    func fetchAllEntries() async throws -> [LedgerEntryRecord]
    func apply(_ command: EntryMutationCommand) async throws -> EntryMutationReceipt
    func latestUndoCandidate(asOf: Date) async throws -> EntryUndoCandidate?
    func loadSettings() async throws -> AppSettings
    func saveSettings(_ settings: AppSettings) async throws
    func fetchPolicies() async throws -> [ReportingPolicy]
    func savePolicy(_ policy: ReportingPolicy) async throws
    func fetchReminders() async throws -> [ReminderSchedule]
    func saveReminder(_ reminder: ReminderSchedule) async throws
    func deleteReminder(id: UUID) async throws
    func fetchReceipts() async throws -> [ReportReceipt]
    func saveReceipt(_ receipt: ReportReceipt, details: ReportSnapshotDetails?) async throws
}

actor CoreDataLedgerRepository: LedgerRepository, PortableBackupSource {
    private static let settingsID = UUID(uuidString: "4E777EA2-6E2E-4C02-AC50-734F6F8B91E1")!
    private static let dataRevision = 2
    private static let appSource = "appQuickEntry"
    private static let migrationSource = "migration"
    private static let undoWindow: TimeInterval = 10 * 60
    private static let normalizationLock = NSLock()

    private let persistence: PersistenceController
    private let clock: @Sendable () -> Date
    private var normalizationComplete = false
    private var normalizationFailure: LedgerRepositoryError?
    private var maintenanceLease: LedgerMaintenanceLease?

    init(
        persistence: PersistenceController,
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        self.persistence = persistence
        self.clock = clock
    }

    func ledgerSnapshot() async throws -> LedgerSnapshot {
        try requireAvailable()
        try ensureNormalized()
        return try perform { context in
            try Self.snapshot(in: context)
        }
    }

    /// Backup must begin with the normal domain validation, then read the raw
    /// attributes from that exact actor-owned context. `LedgerSnapshot` is not
    /// the backup payload because it applies domain fallbacks and projections.
    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        try requireAvailable()
        try ensureNormalized()
        return try perform { context in
            try Self.pinBackupReadGeneration(in: context)
            _ = try Self.snapshot(in: context)
            return try HourleafBackupRecordsV1.rawRecords(in: context)
        }
    }

    func fetchEntries() async throws -> [TimeEntry] {
        try requireAvailable()
        return try await ledgerSnapshot().activeEntries
    }

    func fetchAllEntries() async throws -> [LedgerEntryRecord] {
        try requireAvailable()
        return try await ledgerSnapshot().entries
    }

    func apply(_ command: EntryMutationCommand) async throws -> EntryMutationReceipt {
        try requireAvailable()
        try ensureNormalized()
        let authorizationTime = clock()
        do {
            return try applyOnce(command, authorizationTime: authorizationTime)
        } catch EntryMutationRetry.required {
            // The write may have committed before a verification read failed. Retrying
            // this exact command in a fresh context resolves that case as a replay;
            // when it did not commit, the same mutation ID can still apply only once.
            do {
                return try applyOnce(command, authorizationTime: authorizationTime)
            } catch EntryMutationRetry.required {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf could not verify the time entry after saving it."
                )
            }
        }
    }

    private func applyOnce(
        _ command: EntryMutationCommand,
        authorizationTime: Date
    ) throws -> EntryMutationReceipt {
        return try performMutation { context in
            try Self.validate(command)
            if let existing = try Self.revision(in: context, mutationID: command.mutationID) {
                return try Self.replayReceipt(for: existing, command: command)
            }
            guard command.occurredAt <= authorizationTime else {
                throw EntryMutationError.invalidCommand
            }

            let written = try Self.applyNew(
                command,
                in: context,
                authorizationTime: authorizationTime
            )
            let record: LedgerEntryRecord
            do {
                try Self.saveIfNeeded(context)
                context.refreshAllObjects()

                guard
                    let saved = try Self.entry(in: context, id: command.entryID),
                    let verifiedRecord = Self.entryRecord(from: saved),
                    verifiedRecord.revision == written.appliedRevision,
                    verifiedRecord.lastMutationID == command.mutationID,
                    let savedRevision = try Self.revision(in: context, mutationID: command.mutationID),
                    savedRevision.entryID == command.entryID,
                    savedRevision.revision == written.appliedRevision
                else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "Hourleaf could not verify the time entry it just changed."
                    )
                }
                record = verifiedRecord
            } catch {
                throw EntryMutationRetry.required
            }

            return EntryMutationReceipt(
                mutationID: command.mutationID,
                entry: record,
                operation: written.operation,
                appliedRevision: written.appliedRevision,
                occurredAt: command.occurredAt,
                undoExpiresAt: written.operation.isUndoable
                    ? command.occurredAt.addingTimeInterval(Self.undoWindow)
                    : nil,
                wasReplay: false
            )
        }
    }

    func latestUndoCandidate(asOf: Date = .now) async throws -> EntryUndoCandidate? {
        try requireAvailable()
        try ensureNormalized()
        return try perform { context in
            try Self.latestUndoCandidate(in: context, asOf: asOf)
        }
    }

    func loadSettings() async throws -> AppSettings {
        try requireAvailable()
        return try await ledgerSnapshot().settings
    }

    func saveSettings(_ settings: AppSettings) async throws {
        try requireAvailable()
        try ensureNormalized()
        try perform { context in
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let objects = try context.fetch(request)
            let object = Self.preferredSettingsObject(in: objects) ?? context.insert(SettingsEntity.self)
            if object.id == nil { object.id = Self.settingsID }
            Self.write(settings, to: object)
            objects.filter { $0 !== object }.forEach(context.delete)
            try Self.saveIfNeeded(context)

            let reread = try context.fetch(request)
            guard reread.count == 1, Self.domainSettings(from: object) == settings else {
                throw LedgerRepositoryError.invalidManagedObject("Hourleaf could not verify saved settings.")
            }
        }
    }

    func fetchPolicies() async throws -> [ReportingPolicy] {
        try requireAvailable()
        return try await ledgerSnapshot().policies
    }

    func savePolicy(_ policy: ReportingPolicy) async throws {
        try requireAvailable()
        try ensureNormalized()
        try perform { context in
            let request: NSFetchRequest<PolicyRevisionEntity> = PolicyRevisionEntity.request()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", policy.id as CVarArg)
            let object = try context.fetch(request).first ?? context.insert(PolicyRevisionEntity.self)
            object.id = policy.id
            object.effectiveMonth = policy.effectiveMonth.key
            object.mode = policy.mode.rawValue
            object.carryAcrossServiceYear = false
            object.createdAt = policy.createdAt
            try Self.saveIfNeeded(context)
        }
    }

    func fetchReminders() async throws -> [ReminderSchedule] {
        try requireAvailable()
        return try await ledgerSnapshot().reminderSchedules
    }

    func saveReminder(_ reminder: ReminderSchedule) async throws {
        try requireAvailable()
        try ensureNormalized()
        try perform { context in
            let request: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", reminder.id as CVarArg)
            let object = try context.fetch(request).first ?? context.insert(ReminderEntity.self)
            let now = Date()
            object.id = reminder.id
            object.weekday = Int16(reminder.weekday)
            object.hour = Int16(reminder.hour)
            object.minute = Int16(reminder.minute)
            object.isEnabled = reminder.isEnabled
            object.createdAt = object.createdAt ?? now
            object.updatedAt = now
            try Self.saveIfNeeded(context)
        }
    }

    func deleteReminder(id: UUID) async throws {
        try requireAvailable()
        try ensureNormalized()
        try perform { context in
            let request: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
            request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
            try context.fetch(request).forEach(context.delete)
            try Self.saveIfNeeded(context)
        }
    }

    func fetchReceipts() async throws -> [ReportReceipt] {
        try requireAvailable()
        return try await ledgerSnapshot().receipts
    }

    func saveReceipt(_ receipt: ReportReceipt, details: ReportSnapshotDetails?) async throws {
        try requireAvailable()
        try ensureNormalized()
        try perform { context in
            let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", receipt.id as CVarArg)
            let existing = try context.fetch(request).first
            if let existing {
                guard details == nil else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A prepared report snapshot cannot be recalculated in place."
                    )
                }
                guard
                    existing.id == receipt.id,
                    existing.monthKey == receipt.month.key,
                    existing.reportText == receipt.text,
                    existing.serviceHours == Int32(receipt.serviceHours),
                    existing.creditHours == Int32(receipt.creditHours),
                    existing.serviceCarryOut == Int32(receipt.serviceCarryOut),
                    existing.creditCarryOut == Int32(receipt.creditCarryOut),
                    existing.preparedAt == receipt.preparedAt,
                    existing.confirmedSentAt == nil || receipt.confirmedSentAt != nil
                else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A prepared report snapshot cannot be changed in place."
                    )
                }
                if existing.confirmedSentAt == nil {
                    existing.confirmedSentAt = receipt.confirmedSentAt
                }
            } else {
                guard let details else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A new report snapshot requires its original calculation details."
                    )
                }
                let report = details.report
                let expectedPresentationFingerprint = ReportFingerprint.presentation(
                    calculationFingerprint: details.calculationFingerprint,
                    language: details.reportLanguage,
                    creditLabel: details.creditLabel,
                    templateID: details.templateID,
                    text: receipt.text
                )
                guard
                    report.month == receipt.month,
                    report.serviceHours == receipt.serviceHours,
                    report.creditHours == receipt.creditHours,
                    report.serviceCarryOut == receipt.serviceCarryOut,
                    report.creditCarryOut == receipt.creditCarryOut,
                    ReportCalculator.isConsistent(report, mode: details.reportingMode),
                    report.rawServiceMinutes >= 0,
                    report.rawCreditMinutes >= 0,
                    (0...59).contains(report.serviceCarryIn),
                    (0...59).contains(report.creditCarryIn),
                    receipt.serviceHours >= 0,
                    receipt.creditHours >= 0,
                    (0...59).contains(receipt.serviceCarryOut),
                    (0...59).contains(receipt.creditCarryOut),
                    !receipt.text.isEmpty,
                    !details.templateID.isEmpty,
                    !details.calculationFingerprint.isEmpty,
                    details.presentationFingerprint == expectedPresentationFingerprint
                else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "The report snapshot does not match its calculation details."
                    )
                }

                let version = try Self.nextReceiptVersion(in: context, monthKey: receipt.month.key)
                let object = context.insert(ReportReceiptEntity.self)
                object.id = receipt.id
                object.monthKey = receipt.month.key
                object.reportText = receipt.text
                object.serviceHours = Int32(receipt.serviceHours)
                object.creditHours = Int32(receipt.creditHours)
                object.serviceCarryOut = Int32(receipt.serviceCarryOut)
                object.creditCarryOut = Int32(receipt.creditCarryOut)
                object.preparedAt = receipt.preparedAt
                object.confirmedSentAt = receipt.confirmedSentAt
                object.schemaVersion = 1
                object.version = version
                object.rawServiceMinutes = Int64(report.rawServiceMinutes)
                object.rawCreditMinutes = Int64(report.rawCreditMinutes)
                object.serviceCarryIn = Int32(report.serviceCarryIn)
                object.creditCarryIn = Int32(report.creditCarryIn)
                object.reportingMode = details.reportingMode.rawValue
                object.reportLanguage = details.reportLanguage.rawValue
                object.creditLabel = details.creditLabel
                object.templateID = details.templateID
                object.calculationFingerprint = details.calculationFingerprint
                object.presentationFingerprint = details.presentationFingerprint
                object.createdBySource = Self.appSource
                object.legacyCalculationUnavailable = false
            }

            context.processPendingChanges()
            guard let newest = try Self.newestReceipt(in: context, monthKey: receipt.month.key) else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf could not read the current report snapshot."
                )
            }
            let state = try Self.reportState(in: context, monthKey: receipt.month.key)
            if state == nil {
                let newState = context.insert(ReportStateEntity.self)
                newState.id = UUID()
                newState.monthKey = receipt.month.key
                newState.state = newest.confirmedSentAt == nil ? "prepared" : "sent"
                newState.currentSnapshotID = newest.id
                newState.updatedAt = Date()
            } else if let state {
                state.currentSnapshotID = newest.id
                state.state = newest.confirmedSentAt == nil ? "prepared" : "sent"
                state.updatedAt = Date()
            }
            try Self.saveIfNeeded(context)
        }
    }

    /// The lease is installed in this exact actor turn before normalization or
    /// a Core Data context can be opened for the caller's restore operation.
    /// Every later ordinary repository message observes the gate first.
    func acquireMaintenanceLease() throws -> LedgerMaintenanceLease {
        guard maintenanceLease == nil else {
            throw LedgerMaintenanceError.alreadyInProgress
        }
        let lease = LedgerMaintenanceLease(token: UUID())
        maintenanceLease = lease
        return lease
    }

    func maintenanceCapture(for lease: LedgerMaintenanceLease) throws -> LedgerMaintenanceCapture {
        try require(lease)
        try ensureNormalized()
        let records = try perform { context in
            try Self.pinBackupReadGeneration(in: context)
            _ = try Self.snapshot(in: context)
            return try HourleafBackupRecordsV1.rawRecords(in: context)
        }
        return LedgerMaintenanceCapture(
            records: records,
            recordsDigest: try HourleafBackupCodec.storeDigest(records),
            recordCounts: records.counts
        )
    }

    /// Detects a write from any unexpected second repository/context before a
    /// closed-store operation. The transaction must not call this a success
    /// merely because its earlier actor snapshot was coherent.
    func currentStoreMatchesCapture(
        _ capture: LedgerMaintenanceCapture,
        for lease: LedgerMaintenanceLease
    ) throws {
        try require(lease)
        try ensureNormalized()
        let current = try perform { context in
            try Self.pinBackupReadGeneration(in: context)
            _ = try Self.snapshot(in: context)
            return try HourleafBackupRecordsV1.rawRecords(in: context)
        }
        guard
            try HourleafBackupCodec.storeDigest(current) == capture.recordsDigest,
            current.counts == capture.recordCounts
        else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Hourleaf detected a concurrent local-data change before restore."
            )
        }
    }

    /// Performs the last exact-A digest comparison and closes the live store
    /// under the same Core Data coordinator critical section. A second context
    /// therefore either commits before this final raw read (and is detected) or
    /// cannot commit until the persistent store has been removed.
    func validateCaptureAndCloseStore(
        _ capture: LedgerMaintenanceCapture,
        for lease: LedgerMaintenanceLease
    ) throws -> ClosedPersistentStoreDescriptor {
        try require(lease)
        try ensureNormalized()
        return try persistence.closePersistentStoreForTransition { context in
            try Self.pinBackupReadGeneration(in: context)
            _ = try Self.snapshot(in: context)
            let records = try HourleafBackupRecordsV1.rawRecords(in: context)
            guard
                try HourleafBackupCodec.storeDigest(records) == capture.recordsDigest,
                records.counts == capture.recordCounts
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf detected a concurrent local-data change at the restore boundary."
                )
            }
        }
    }

    /// A new container has no valid normalization cache. Clear both the
    /// success and failure memoization before the first readback so an old
    /// startup failure can never be reported as a successful replacement.
    func resetAfterPersistentStoreTransition(for lease: LedgerMaintenanceLease) throws {
        try require(lease)
        normalizationComplete = false
        normalizationFailure = nil
    }

    func validatedReadback(for lease: LedgerMaintenanceLease) throws -> ValidatedReadback {
        try require(lease)
        let rawBefore = try perform { context in
            try Self.pinBackupReadGeneration(in: context)
            return try HourleafBackupRecordsV1.rawRecords(in: context)
        }
        let rawBeforeDigest = try HourleafBackupCodec.storeDigest(rawBefore)
        try ensureNormalized()
        let final = try perform { context in
            try Self.pinBackupReadGeneration(in: context)
            let snapshot = try Self.snapshot(in: context)
            return (
                records: try HourleafBackupRecordsV1.rawRecords(in: context),
                reminderSchedules: snapshot.reminderSchedules
            )
        }
        let rawAfterDigest = try HourleafBackupCodec.storeDigest(final.records)
        guard rawBeforeDigest == rawAfterDigest else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Hourleaf refused a data-store transition because normalization changed raw records."
            )
        }
        return ValidatedReadback(
            rawBeforeNormalizationDigest: rawBeforeDigest,
            rawAfterNormalizationDigest: rawAfterDigest,
            recordsDigest: rawAfterDigest,
            recordCounts: final.records.counts,
            reminderSchedules: final.reminderSchedules
        )
    }

    /// A synchronous Core Data coordinator close must perform its final
    /// validation while it holds the coordinator barrier. This deliberately
    /// shares the repository's raw/domain/raw definition without manufacturing
    /// a second persistence abstraction around a bare SQLite URL.
    nonisolated static func validateExactRawDomainRaw(
        in context: NSManagedObjectContext,
        expectedRecordsDigest: String,
        expectedRecordCounts: HourleafBackupRecordCountsV1
    ) throws {
        try pinBackupReadGeneration(in: context)
        let rawBefore = try HourleafBackupRecordsV1.rawRecords(in: context)
        guard
            try HourleafBackupCodec.storeDigest(rawBefore) == expectedRecordsDigest,
            rawBefore.counts == expectedRecordCounts
        else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Hourleaf refused a transition because the raw store did not match its expected proof."
            )
        }

        _ = try snapshot(in: context)

        try pinBackupReadGeneration(in: context)
        let rawAfter = try HourleafBackupRecordsV1.rawRecords(in: context)
        guard
            try HourleafBackupCodec.storeDigest(rawAfter) == expectedRecordsDigest,
            rawAfter.counts == expectedRecordCounts
        else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Hourleaf refused a transition because domain validation changed its raw proof."
            )
        }
    }

    func releaseMaintenanceLease(_ lease: LedgerMaintenanceLease) throws {
        try require(lease)
        maintenanceLease = nil
    }

    func maintenanceIsInProgress() -> Bool {
        maintenanceLease != nil
    }

    private func ensureNormalized() throws {
        if let normalizationFailure { throw normalizationFailure }
        guard !normalizationComplete else { return }
        if let startupError = persistence.startupError {
            let error = LedgerRepositoryError.persistenceUnavailable(startupError.localizedDescription)
            normalizationFailure = error
            throw error
        }

        do {
            Self.normalizationLock.lock()
            defer { Self.normalizationLock.unlock() }
            try perform { context in
                if try Self.requiresNormalization(in: context) {
                    try Self.normalize(in: context)
                }
            }
            normalizationComplete = true
        } catch let error as LedgerRepositoryError {
            normalizationFailure = error
            throw error
        } catch {
            let wrapped = LedgerRepositoryError.normalizationFailed(error.localizedDescription)
            normalizationFailure = wrapped
            throw wrapped
        }
    }

    private func requireAvailable() throws {
        guard maintenanceLease == nil else {
            throw LedgerRepositoryError.maintenanceInProgress
        }
    }

    private func require(_ lease: LedgerMaintenanceLease) throws {
        guard maintenanceLease == lease else {
            throw LedgerMaintenanceError.invalidLease
        }
    }

    private func perform<T: Sendable>(
        _ work: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyObjectTrumpMergePolicyType)
        context.undoManager = nil
        return try context.performAndWait {
            try work(context)
        }
    }

    private func performMutation<T: Sendable>(
        _ work: @escaping @Sendable (NSManagedObjectContext) throws -> T
    ) throws -> T {
        let context = persistence.container.newBackgroundContext()
        context.mergePolicy = NSMergePolicy(merge: .errorMergePolicyType)
        context.undoManager = nil
        return try context.performAndWait {
            try work(context)
        }
    }
}

private struct EntryMutationWrite: Sendable {
    let operation: EntryMutationOperation
    let appliedRevision: Int64
}

private enum EntryMutationRetry: Error {
    case required
}

private extension CoreDataLedgerRepository {
    /// Snapshot and raw DTO fetches must observe one Core Data generation even
    /// when a CloudKit/import context saves outside this repository actor.
    /// Query generations are unavailable for the in-memory store used by unit
    /// tests, where there is no external-store merge to pin against.
    static func pinBackupReadGeneration(in context: NSManagedObjectContext) throws {
        let stores = context.persistentStoreCoordinator?.persistentStores ?? []
        guard !stores.isEmpty, !stores.allSatisfy({ $0.type == NSInMemoryStoreType }) else {
            return
        }
        try context.setQueryGenerationFrom(.current)
    }

    static func applyNew(
        _ command: EntryMutationCommand,
        in context: NSManagedObjectContext,
        authorizationTime: Date
    ) throws -> EntryMutationWrite {
        try validate(command)
        let existing = try entry(in: context, id: command.entryID)

        switch command.operation {
        case .create:
            guard existing == nil, let values = try validatedValues(
                command.values,
                in: context,
                authorizationTime: authorizationTime
            ) else {
                throw EntryMutationError.entryStateChanged
            }
            let object = context.insert(EntryEntity.self)
            object.id = command.entryID
            write(values, to: object)
            object.createdAt = command.occurredAt
            object.updatedAt = command.occurredAt
            object.deletedAt = nil
            object.source = command.source.rawValue
            object.revision = 1
            object.lastMutationID = command.mutationID
            appendRevision(
                for: object,
                in: context,
                mutationID: command.mutationID,
                parentMutationID: nil,
                operation: command.operation.rawValue,
                source: command.source.rawValue,
                occurredAt: command.occurredAt
            )
            return EntryMutationWrite(operation: .create, appliedRevision: object.revision)

        case .update:
            guard let object = existing else { throw EntryMutationError.entryNotFound }
            try requireExpectedRevision(command.expectedRevision, for: object)
            guard object.deletedAt == nil else { throw EntryMutationError.entryStateChanged }
            guard let values = try validatedValues(
                command.values,
                in: context,
                authorizationTime: authorizationTime
            ) else {
                throw EntryMutationError.invalidCommand
            }
            let parentMutationID = object.lastMutationID
            let nextRevision = try nextRevision(after: object.revision)
            write(values, to: object)
            object.updatedAt = command.occurredAt
            object.source = command.source.rawValue
            object.revision = nextRevision
            object.lastMutationID = command.mutationID
            appendRevision(
                for: object,
                in: context,
                mutationID: command.mutationID,
                parentMutationID: parentMutationID,
                operation: command.operation.rawValue,
                source: command.source.rawValue,
                occurredAt: command.occurredAt
            )
            return EntryMutationWrite(operation: .update, appliedRevision: object.revision)

        case .delete:
            guard let object = existing else { throw EntryMutationError.entryNotFound }
            try requireExpectedRevision(command.expectedRevision, for: object)
            guard object.deletedAt == nil else { throw EntryMutationError.entryStateChanged }
            let parentMutationID = object.lastMutationID
            let nextRevision = try nextRevision(after: object.revision)
            object.deletedAt = command.occurredAt
            object.updatedAt = command.occurredAt
            object.source = command.source.rawValue
            object.revision = nextRevision
            object.lastMutationID = command.mutationID
            appendRevision(
                for: object,
                in: context,
                mutationID: command.mutationID,
                parentMutationID: parentMutationID,
                operation: command.operation.rawValue,
                source: command.source.rawValue,
                occurredAt: command.occurredAt
            )
            return EntryMutationWrite(operation: .delete, appliedRevision: object.revision)

        case .restore:
            guard let object = existing else { throw EntryMutationError.entryNotFound }
            try requireExpectedRevision(command.expectedRevision, for: object)
            guard object.deletedAt != nil else { throw EntryMutationError.entryStateChanged }
            let parentMutationID = object.lastMutationID
            let nextRevision = try nextRevision(after: object.revision)
            object.deletedAt = nil
            object.updatedAt = command.occurredAt
            object.source = command.source.rawValue
            object.revision = nextRevision
            object.lastMutationID = command.mutationID
            appendRevision(
                for: object,
                in: context,
                mutationID: command.mutationID,
                parentMutationID: parentMutationID,
                operation: command.operation.rawValue,
                source: command.source.rawValue,
                occurredAt: command.occurredAt
            )
            return EntryMutationWrite(operation: .restore, appliedRevision: object.revision)

        case .undo:
            guard let object = existing else { throw EntryMutationError.entryNotFound }
            return try applyUndo(
                command,
                to: object,
                in: context,
                authorizationTime: authorizationTime
            )
        }
    }

    static func validate(_ command: EntryMutationCommand) throws {
        guard
            command.source != .migration,
            command.operation == .undo || command.source != .undo
        else { throw EntryMutationError.invalidCommand }
        switch command.operation {
        case .create:
            guard
                command.expectedRevision == nil,
                command.values != nil,
                command.revertedMutationID == nil,
                [
                    EntryMutationSource.appQuickEntry,
                    .appOneTap,
                    .shortcut,
                    .widget,
                    .watch,
                    .timer
                ].contains(command.source)
            else { throw EntryMutationError.invalidCommand }
        case .update:
            guard
                command.expectedRevision != nil,
                command.values != nil,
                command.revertedMutationID == nil,
                command.source == .appHistory
            else { throw EntryMutationError.invalidCommand }
        case .delete:
            guard
                command.expectedRevision != nil,
                command.values == nil,
                command.revertedMutationID == nil,
                command.source == .appHistory
            else { throw EntryMutationError.invalidCommand }
        case .restore:
            guard
                command.expectedRevision != nil,
                command.values == nil,
                command.revertedMutationID == nil,
                command.source == .restore
            else { throw EntryMutationError.invalidCommand }
        case .undo:
            guard
                command.expectedRevision != nil,
                command.values == nil,
                command.revertedMutationID != nil,
                command.source == .undo
            else { throw EntryMutationError.invalidCommand }
        }
    }

    static func validatedValues(
        _ values: EntryMutationValues?,
        in context: NSManagedObjectContext,
        authorizationTime: Date
    ) throws -> EntryMutationValues? {
        guard let values else { return nil }
        let normalized = EntryMutationValues(
            kind: values.kind,
            day: values.day,
            minutes: values.minutes,
            note: values.note
        )
        guard let canonicalDay = LocalDay(key: normalized.day.key), canonicalDay == normalized.day else {
            throw EntryMutationError.invalidLocalDay
        }
        guard (1...5_999).contains(normalized.minutes) else {
            throw normalized.minutes == 0 ? EntryValidationError.emptyDuration : EntryValidationError.durationTooLarge
        }
        guard (normalized.note ?? "").count <= 280 else { throw EntryValidationError.noteTooLong }
        guard normalized.day <= LocalDay(authorizationTime, calendar: .hourleaf) else {
            throw EntryMutationError.dateInFuture
        }
        let settingsRequest: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        guard
            let settingsObject = preferredSettingsObject(in: try context.fetch(settingsRequest)),
            let settings = domainSettings(from: settingsObject)
        else {
            throw LedgerRepositoryError.invalidManagedObject("Hourleaf settings are unavailable.")
        }
        guard normalized.day.monthKey >= settings.ledgerStartMonth else {
            throw EntryMutationError.beforeLedgerStart
        }
        return normalized
    }

    static func requireExpectedRevision(_ expectedRevision: Int64?, for object: EntryEntity) throws {
        guard let expectedRevision else { throw EntryMutationError.invalidCommand }
        guard object.revision == expectedRevision else { throw EntryMutationError.staleRevision }
    }

    static func nextRevision(after currentRevision: Int64) throws -> Int64 {
        guard currentRevision < Int64.max else { throw EntryMutationError.revisionExhausted }
        return currentRevision + 1
    }

    static func applyUndo(
        _ command: EntryMutationCommand,
        to object: EntryEntity,
        in context: NSManagedObjectContext,
        authorizationTime: Date
    ) throws -> EntryMutationWrite {
        guard let revertedMutationID = command.revertedMutationID else {
            throw EntryMutationError.invalidCommand
        }
        try requireExpectedRevision(command.expectedRevision, for: object)
        guard object.lastMutationID == revertedMutationID else {
            throw EntryMutationError.undoSuperseded
        }
        guard let target = try revision(in: context, mutationID: revertedMutationID) else {
            throw EntryMutationError.undoUnavailable
        }
        guard
            target.entryID == command.entryID,
            let targetOperation = EntryMutationOperation(rawValue: target.operation),
            targetOperation.isUndoable
        else { throw EntryMutationError.undoUnavailable }

        let now = authorizationTime
        let commandAge = command.occurredAt.timeIntervalSince(target.occurredAt)
        let wallClockAge = now.timeIntervalSince(target.occurredAt)
        guard
            commandAge >= 0,
            commandAge < undoWindow,
            wallClockAge >= 0,
            wallClockAge < undoWindow
        else { throw EntryMutationError.undoExpired }
        guard let latest = try latestUndoCandidate(in: context, asOf: now), latest.mutationID == revertedMutationID else {
            throw EntryMutationError.undoSuperseded
        }

        let nextRevision = try nextRevision(after: object.revision)

        switch targetOperation {
        case .create:
            guard object.deletedAt == nil else { throw EntryMutationError.undoSuperseded }
            object.deletedAt = command.occurredAt
        case .update:
            guard let parentMutationID = target.parentMutationID,
                  let parent = try revision(in: context, mutationID: parentMutationID),
                  parent.entryID == object.id,
                  parent.entryDeletedAt == nil
            else { throw EntryMutationError.undoUnavailable }
            write(parent, to: object)
            object.deletedAt = nil
        case .delete:
            guard object.deletedAt != nil else { throw EntryMutationError.undoSuperseded }
            object.deletedAt = nil
        case .restore:
            guard let parentMutationID = target.parentMutationID,
                  let parent = try revision(in: context, mutationID: parentMutationID),
                  parent.entryID == object.id,
                  let deletedAt = parent.entryDeletedAt,
                  object.deletedAt == nil
            else { throw EntryMutationError.undoUnavailable }
            object.deletedAt = deletedAt
        case .undo:
            throw EntryMutationError.undoUnavailable
        }

        let parentMutationID = object.lastMutationID
        object.updatedAt = command.occurredAt
        object.source = command.source.rawValue
        object.revision = nextRevision
        object.lastMutationID = command.mutationID
        appendRevision(
            for: object,
            in: context,
            mutationID: command.mutationID,
            parentMutationID: parentMutationID,
            revertedMutationID: revertedMutationID,
            operation: EntryMutationOperation.undo.rawValue,
            source: command.source.rawValue,
            occurredAt: command.occurredAt
        )
        return EntryMutationWrite(operation: .undo, appliedRevision: object.revision)
    }

    static func latestUndoCandidate(
        in context: NSManagedObjectContext,
        asOf: Date
    ) throws -> EntryUndoCandidate? {
        let request: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        request.predicate = NSPredicate(format: "source != %@", EntryMutationSource.migration.rawValue)
        request.sortDescriptors = [
            NSSortDescriptor(key: "occurredAt", ascending: false),
            NSSortDescriptor(key: "mutationID", ascending: false)
        ]
        request.fetchLimit = 1
        guard let object = try context.fetch(request).first else { return nil }
        guard let revision = entryRevisionRecord(from: object) else {
            throw LedgerRepositoryError.invalidManagedObject("The newest saved entry revision is incomplete or invalid.")
        }
        guard let operation = EntryMutationOperation(rawValue: revision.operation), operation.isUndoable else {
            return nil
        }
        let age = asOf.timeIntervalSince(revision.occurredAt)
        guard age >= 0, age < undoWindow else { return nil }
        guard
            let entry = try entry(in: context, id: revision.entryID),
            let record = entryRecord(from: entry),
            record.lastMutationID == revision.mutationID,
            record.revision == revision.revision
        else { return nil }
        return EntryUndoCandidate(
            mutationID: revision.mutationID,
            entryID: revision.entryID,
            expectedRevision: revision.revision,
            operation: operation,
            entry: record,
            occurredAt: revision.occurredAt,
            expiresAt: revision.occurredAt.addingTimeInterval(undoWindow)
        )
    }

    static func entry(in context: NSManagedObjectContext, id: UUID) throws -> EntryEntity? {
        let request: NSFetchRequest<EntryEntity> = EntryEntity.request()
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let objects = try context.fetch(request)
        guard objects.count <= 1 else {
            throw LedgerRepositoryError.invalidManagedObject("Saved time entries contain a duplicate identifier.")
        }
        return objects.first
    }

    static func revision(in context: NSManagedObjectContext, mutationID: UUID) throws -> EntryRevisionRecord? {
        let request: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        request.predicate = NSPredicate(format: "mutationID == %@", mutationID as CVarArg)
        let objects = try context.fetch(request)
        guard objects.count <= 1 else {
            throw LedgerRepositoryError.invalidManagedObject("Saved entry revisions contain a duplicate mutation identifier.")
        }
        guard let object = objects.first else { return nil }
        guard let record = entryRevisionRecord(from: object) else {
            throw LedgerRepositoryError.invalidManagedObject("A saved entry revision contains incomplete or invalid data.")
        }
        return record
    }

    static func replayReceipt(
        for revision: EntryRevisionRecord,
        command: EntryMutationCommand
    ) throws -> EntryMutationReceipt {
        guard commandMatches(command, revision: revision),
              let operation = EntryMutationOperation(rawValue: revision.operation),
              let entry = entryRecord(from: revision)
        else { throw EntryMutationError.mutationIDCollision }
        return EntryMutationReceipt(
            mutationID: revision.mutationID,
            entry: entry,
            operation: operation,
            appliedRevision: revision.revision,
            occurredAt: revision.occurredAt,
            undoExpiresAt: operation.isUndoable
                ? revision.occurredAt.addingTimeInterval(undoWindow)
                : nil,
            wasReplay: true
        )
    }

    static func commandMatches(_ command: EntryMutationCommand, revision: EntryRevisionRecord) -> Bool {
        guard
            command.entryID == revision.entryID,
            command.operation.rawValue == revision.operation,
            command.source.rawValue == revision.source,
            command.occurredAt == revision.occurredAt,
            command.revertedMutationID == revision.revertedMutationID
        else { return false }
        let expectedRevision: Int64? = command.operation == .create ? nil : revision.revision - 1
        guard command.expectedRevision == expectedRevision else { return false }
        switch command.operation {
        case .create, .update:
            guard let values = command.values else { return false }
            return values.kind.rawValue == revision.kind
                && values.day.key == revision.localDay
                && values.minutes == revision.minutes
                && values.note == revision.note
        case .delete, .restore:
            return command.values == nil && command.revertedMutationID == nil
        case .undo:
            return command.values == nil && command.revertedMutationID != nil
        }
    }

    static func entryRecord(from revision: EntryRevisionRecord) -> LedgerEntryRecord? {
        guard
            let kind = EntryKind(rawValue: revision.kind),
            let day = LocalDay(key: revision.localDay),
            (1...5_999).contains(revision.minutes)
        else { return nil }
        return LedgerEntryRecord(
            entry: TimeEntry(
                id: revision.entryID,
                kind: kind,
                day: day,
                minutes: revision.minutes,
                note: revision.note,
                createdAt: revision.entryCreatedAt,
                updatedAt: revision.entryUpdatedAt
            ),
            deletedAt: revision.entryDeletedAt,
            source: revision.source,
            revision: revision.revision,
            lastMutationID: revision.mutationID
        )
    }

    static func write(_ values: EntryMutationValues, to object: EntryEntity) {
        object.kind = values.kind.rawValue
        object.localDay = values.day.key
        object.minutes = Int32(values.minutes)
        object.note = values.note
    }

    static func write(_ revision: EntryRevisionRecord, to object: EntryEntity) {
        object.kind = revision.kind
        object.localDay = revision.localDay
        object.minutes = Int32(revision.minutes)
        object.note = revision.note
        object.createdAt = revision.entryCreatedAt
    }

    static func requiresNormalization(in context: NSManagedObjectContext) throws -> Bool {
        let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        let settings = try context.fetch(request)
        guard settings.count == 1, let setting = settings.first else { return true }
        return setting.dataRevision < dataRevision
    }

    static func normalize(in context: NSManagedObjectContext) throws {
        let normalizedAt = Date()

        let entryRequest: NSFetchRequest<EntryEntity> = EntryEntity.request()
        let entries = try context.fetch(entryRequest)
        _ = try decodeRequired(entries, entity: "EntryEntity", using: entryRecord)

        let policyRequest: NSFetchRequest<PolicyRevisionEntity> = PolicyRevisionEntity.request()
        let policies = try context.fetch(policyRequest)
        _ = try decodeRequired(policies, entity: "PolicyRevisionEntity", using: domainPolicy)

        let reminderRequest: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
        let reminders = try context.fetch(reminderRequest)
        _ = try decodeRequired(reminders, entity: "ReminderEntity", using: reminderRecord)

        let receiptRequest: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        let receipts = try context.fetch(receiptRequest)
        _ = try decodeRequired(
            receipts,
            entity: "ReportReceiptEntity",
            using: legacyCompatibleReportSnapshotMetadata
        )

        let revisionRequest: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        let revisions = try context.fetch(revisionRequest)
        _ = try decodeRequired(revisions, entity: "EntryRevisionEntity", using: entryRevisionRecord)

        let stateRequest: NSFetchRequest<ReportStateEntity> = ReportStateEntity.request()
        let existingStates = try context.fetch(stateRequest)
        _ = try decodeRequired(existingStates, entity: "ReportStateEntity", using: reportStateRecord)

        let presetRequest: NSFetchRequest<PresetEntity> = PresetEntity.request()
        let presets = try context.fetch(presetRequest)
        _ = try decodeRequired(presets, entity: "PresetEntity", using: presetRecord)

        let acknowledgementRequest: NSFetchRequest<DayAcknowledgementEntity> = DayAcknowledgementEntity.request()
        let acknowledgements = try context.fetch(acknowledgementRequest)
        _ = try decodeRequired(
            acknowledgements,
            entity: "DayAcknowledgementEntity",
            using: dayAcknowledgementRecord
        )

        let archiveRequest: NSFetchRequest<ServiceYearArchiveEntity> = ServiceYearArchiveEntity.request()
        let archives = try context.fetch(archiveRequest)
        _ = try decodeRequired(archives, entity: "ServiceYearArchiveEntity", using: serviceYearArchiveRecord)

        let settingsRequest: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        let settingsObjects = try context.fetch(settingsRequest)
        _ = try decodeRequired(settingsObjects, entity: "SettingsEntity", using: domainSettings)

        let entryCount = entries.count
        let priorRevisionCount = revisions.count
        let legacyEntries = entries.filter { $0.lastMutationID == nil }

        for entry in legacyEntries {
            let mutationID = UUID()
            entry.revision = max(entry.revision, 1)
            entry.source = migrationSource
            entry.lastMutationID = mutationID
            appendRevision(
                for: entry,
                in: context,
                mutationID: mutationID,
                parentMutationID: nil,
                operation: "create",
                source: migrationSource,
                occurredAt: normalizedAt
            )
        }

        let receiptGroups = Dictionary(grouping: try receipts.map { receipt -> (String, ReportReceiptEntity) in
            guard let monthKey = receipt.monthKey, MonthKey(key: monthKey) != nil else {
                throw LedgerRepositoryError.invalidManagedObject("A saved report has an invalid month.")
            }
            return (monthKey, receipt)
        }, by: \.0)
        let statePairs = try existingStates.map { state -> (String, ReportStateEntity) in
            guard let monthKey = state.monthKey, MonthKey(key: monthKey) != nil else {
                throw LedgerRepositoryError.invalidManagedObject("A report state has an invalid month.")
            }
            return (monthKey, state)
        }
        let stateGroups = Dictionary(grouping: statePairs, by: \.0)
        var currentStates: [String: ReportStateEntity] = [:]
        for (monthKey, pairs) in stateGroups {
            let sorted = pairs.map(\.1).sorted(by: reportStateOrder)
            guard let preferred = sorted.last else { continue }
            currentStates[monthKey] = preferred
            sorted.dropLast().forEach(context.delete)
        }
        let missingStateMonths = Set(receiptGroups.keys).subtracting(currentStates.keys)

        for monthKey in receiptGroups.keys {
            let sortedReceipts = (receiptGroups[monthKey] ?? []).map(\.1).sorted(by: receiptOrder)
            for (index, receipt) in sortedReceipts.enumerated() {
                receipt.schemaVersion = max(receipt.schemaVersion, 1)
                receipt.version = Int32(index + 1)
                if receipt.createdBySource == nil {
                    receipt.rawServiceMinutes = 0
                    receipt.rawCreditMinutes = 0
                    receipt.serviceCarryIn = 0
                    receipt.creditCarryIn = 0
                    receipt.reportingMode = nil
                    receipt.reportLanguage = nil
                    receipt.creditLabel = nil
                    receipt.templateID = nil
                    receipt.calculationFingerprint = nil
                    receipt.presentationFingerprint = nil
                    receipt.createdBySource = migrationSource
                    receipt.legacyCalculationUnavailable = true
                }
            }
            guard let newest = sortedReceipts.last else { continue }
            let state: ReportStateEntity
            if let current = currentStates[monthKey] {
                state = current
            } else {
                state = context.insert(ReportStateEntity.self)
                state.id = UUID()
                state.monthKey = monthKey
                currentStates[monthKey] = state
            }
            state.state = newest.confirmedSentAt == nil ? "prepared" : "sent"
            state.currentSnapshotID = newest.id
            state.updatedAt = normalizedAt
        }

        for reminder in reminders {
            reminder.createdAt = reminder.createdAt ?? normalizedAt
            reminder.updatedAt = reminder.updatedAt ?? normalizedAt
        }

        let settings = preferredSettingsObject(in: settingsObjects) ?? context.insert(SettingsEntity.self)
        if settingsObjects.isEmpty {
            settings.id = settingsID
            write(AppSettings(), to: settings)
        } else if settings.id == nil {
            settings.id = settingsID
        }
        guard domainSettings(from: settings) != nil else {
            throw LedgerRepositoryError.invalidManagedObject("Hourleaf settings contain incomplete saved data.")
        }
        settingsObjects.filter { $0 !== settings }.forEach(context.delete)

        context.processPendingChanges()
        let verified = try snapshot(in: context)
        guard
            verified.entries.count == entryCount,
            verified.entryRevisions.count == priorRevisionCount + legacyEntries.count,
            verified.policies.count == policies.count,
            verified.reminders.count == reminders.count,
            verified.reportSnapshots.count == receipts.count,
            verified.reportStates.count == stateGroups.count + missingStateMonths.count,
            verified.presets.count == presets.count,
            verified.dayAcknowledgements.count == acknowledgements.count,
            verified.serviceYearArchives.count == archives.count,
            verified.settingsMetadata.id == settings.id
        else {
            throw LedgerRepositoryError.normalizationFailed("Hourleaf could not verify the local data upgrade.")
        }

        settings.dataRevision = Int16(dataRevision)
        try saveIfNeeded(context)

        context.refreshAllObjects()
        let persisted = try snapshot(in: context)
        guard persisted.settingsMetadata.dataRevision == dataRevision else {
            throw LedgerRepositoryError.normalizationFailed("Hourleaf could not finish the local data upgrade.")
        }
    }

    static func snapshot(in context: NSManagedObjectContext) throws -> LedgerSnapshot {
        let settingsRequest: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
        let settingsObjects = try context.fetch(settingsRequest)
        guard
            let settingsObject = preferredSettingsObject(in: settingsObjects),
            let settingsID = settingsObject.id
        else {
            throw LedgerRepositoryError.invalidManagedObject("Hourleaf settings are unavailable.")
        }

        let entryRequest: NSFetchRequest<EntryEntity> = EntryEntity.request()
        entryRequest.sortDescriptors = [
            NSSortDescriptor(key: "localDay", ascending: false),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        let entries = try decodeRequired(
            context.fetch(entryRequest),
            entity: "EntryEntity",
            using: entryRecord
        )

        let policyRequest: NSFetchRequest<PolicyRevisionEntity> = PolicyRevisionEntity.request()
        let policies = try decodeRequired(
            context.fetch(policyRequest),
            entity: "PolicyRevisionEntity",
            using: domainPolicy
        ).sorted {
            ($0.effectiveMonth, $0.createdAt, $0.id.uuidString) < ($1.effectiveMonth, $1.createdAt, $1.id.uuidString)
        }

        let reminderRequest: NSFetchRequest<ReminderEntity> = ReminderEntity.request()
        let reminders = try decodeRequired(
            context.fetch(reminderRequest),
            entity: "ReminderEntity",
            using: reminderRecord
        ).sorted {
            ($0.reminder.weekday, $0.reminder.hour, $0.reminder.minute, $0.id.uuidString)
                < ($1.reminder.weekday, $1.reminder.hour, $1.reminder.minute, $1.id.uuidString)
        }

        let receiptRequest: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        let reportSnapshots = try decodeRequired(
            context.fetch(receiptRequest),
            entity: "ReportReceiptEntity",
            using: reportSnapshotMetadata
        ).sorted {
            ($0.receipt.preparedAt, $0.id.uuidString) > ($1.receipt.preparedAt, $1.id.uuidString)
        }

        let stateRequest: NSFetchRequest<ReportStateEntity> = ReportStateEntity.request()
        let reportStates = try decodeRequired(
            context.fetch(stateRequest),
            entity: "ReportStateEntity",
            using: reportStateRecord
        ).sorted {
            ($0.month, $0.updatedAt, $0.id.uuidString) < ($1.month, $1.updatedAt, $1.id.uuidString)
        }
        try validateReportGraph(snapshots: reportSnapshots, states: reportStates)

        let revisionRequest: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        let revisions = try decodeRequired(
            context.fetch(revisionRequest),
            entity: "EntryRevisionEntity",
            using: entryRevisionRecord
        ).sorted {
            ($0.entryID.uuidString, $0.revision, $0.mutationID.uuidString)
                < ($1.entryID.uuidString, $1.revision, $1.mutationID.uuidString)
        }

        let presetRequest: NSFetchRequest<PresetEntity> = PresetEntity.request()
        let presets = try decodeRequired(
            context.fetch(presetRequest),
            entity: "PresetEntity",
            using: presetRecord
        ).sorted {
            ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString)
        }

        let acknowledgementRequest: NSFetchRequest<DayAcknowledgementEntity> = DayAcknowledgementEntity.request()
        let acknowledgements = try decodeRequired(
            context.fetch(acknowledgementRequest),
            entity: "DayAcknowledgementEntity",
            using: dayAcknowledgementRecord
        ).sorted {
            ($0.day, $0.id.uuidString) < ($1.day, $1.id.uuidString)
        }

        let archiveRequest: NSFetchRequest<ServiceYearArchiveEntity> = ServiceYearArchiveEntity.request()
        let archives = try decodeRequired(
            context.fetch(archiveRequest),
            entity: "ServiceYearArchiveEntity",
            using: serviceYearArchiveRecord
        ).sorted {
            ($0.startMonth, $0.version, $0.id.uuidString) < ($1.startMonth, $1.version, $1.id.uuidString)
        }

        return LedgerSnapshot(
            entries: entries,
            settings: try requireDomainSettings(from: settingsObject),
            settingsMetadata: LedgerSettingsMetadata(
                id: settingsID,
                dataRevision: Int(settingsObject.dataRevision),
                planningVisible: settingsObject.planningVisible,
                quietGapCheckEnabled: settingsObject.quietGapCheckEnabled,
                quietGapDays: Int(settingsObject.quietGapDays),
                timerVisible: settingsObject.timerVisible,
                syncMode: settingsObject.syncMode ?? "local",
                widgetPrivacyMode: settingsObject.widgetPrivacyMode ?? "hideTotals",
                lastPurgeAt: settingsObject.lastPurgeAt
            ),
            policies: policies,
            reminders: reminders,
            reportSnapshots: reportSnapshots,
            reportStates: reportStates,
            entryRevisions: revisions,
            presets: presets,
            dayAcknowledgements: acknowledgements,
            serviceYearArchives: archives
        )
    }

    static func entryRecord(from object: EntryEntity) -> LedgerEntryRecord? {
        guard
            let id = object.id,
            let kind = object.kind.flatMap(EntryKind.init(rawValue:)),
            let day = object.localDay.flatMap(LocalDay.init(key:)),
            let createdAt = object.createdAt,
            let updatedAt = object.updatedAt,
            (1...5_999).contains(Int(object.minutes))
        else { return nil }
        return LedgerEntryRecord(
            entry: TimeEntry(
                id: id,
                kind: kind,
                day: day,
                minutes: Int(object.minutes),
                note: object.note,
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            deletedAt: object.deletedAt,
            source: object.source,
            revision: max(object.revision, 1),
            lastMutationID: object.lastMutationID
        )
    }

    static func entryRevisionRecord(from object: EntryRevisionEntity) -> EntryRevisionRecord? {
        guard
            let id = object.id,
            let entryID = object.entryID,
            let mutationID = object.mutationID,
            let operation = object.operation,
            let kind = object.kind,
            let localDay = object.localDay,
            let entryCreatedAt = object.entryCreatedAt,
            let entryUpdatedAt = object.entryUpdatedAt,
            let source = object.source,
            let occurredAt = object.occurredAt,
            EntryKind(rawValue: kind) != nil,
            LocalDay(key: localDay) != nil,
            (1...5_999).contains(Int(object.minutes)),
            object.revision >= 1
        else { return nil }
        return EntryRevisionRecord(
            id: id,
            entryID: entryID,
            mutationID: mutationID,
            parentMutationID: object.parentMutationID,
            revertedMutationID: object.revertedMutationID,
            revision: max(object.revision, 1),
            operation: operation,
            kind: kind,
            localDay: localDay,
            minutes: Int(object.minutes),
            note: object.note,
            entryCreatedAt: entryCreatedAt,
            entryUpdatedAt: entryUpdatedAt,
            entryDeletedAt: object.entryDeletedAt,
            source: source,
            occurredAt: occurredAt
        )
    }

    static func domainPolicy(from object: PolicyRevisionEntity) -> ReportingPolicy? {
        guard
            let id = object.id,
            let month = object.effectiveMonth.flatMap(MonthKey.init(key:)),
            let mode = object.mode.flatMap(RemainderMode.init(rawValue:)),
            let createdAt = object.createdAt
        else { return nil }
        return ReportingPolicy(
            id: id,
            effectiveMonth: month,
            mode: mode,
            createdAt: createdAt
        )
    }

    static func reminderRecord(from object: ReminderEntity) -> ReminderRecord? {
        guard
            let id = object.id,
            (1...7).contains(Int(object.weekday)),
            (0...23).contains(Int(object.hour)),
            (0...59).contains(Int(object.minute))
        else { return nil }
        return ReminderRecord(
            reminder: ReminderSchedule(
                id: id,
                weekday: Int(object.weekday),
                hour: Int(object.hour),
                minute: Int(object.minute),
                isEnabled: object.isEnabled
            ),
            createdAt: object.createdAt,
            updatedAt: object.updatedAt
        )
    }

    static func reportSnapshotMetadata(from object: ReportReceiptEntity) -> ReportSnapshotMetadata? {
        reportSnapshotMetadata(from: object, allowsUnmarkedLegacy: false)
    }

    static func legacyCompatibleReportSnapshotMetadata(
        from object: ReportReceiptEntity
    ) -> ReportSnapshotMetadata? {
        reportSnapshotMetadata(from: object, allowsUnmarkedLegacy: true)
    }

    static func reportSnapshotMetadata(
        from object: ReportReceiptEntity,
        allowsUnmarkedLegacy: Bool
    ) -> ReportSnapshotMetadata? {
        guard
            let id = object.id,
            let month = object.monthKey.flatMap(MonthKey.init(key:)),
            let text = object.reportText,
            let preparedAt = object.preparedAt,
            object.serviceHours >= 0,
            object.creditHours >= 0,
            (0...59).contains(Int(object.serviceCarryOut)),
            (0...59).contains(Int(object.creditCarryOut)),
            object.rawServiceMinutes >= 0,
            object.rawCreditMinutes >= 0,
            (0...59).contains(Int(object.serviceCarryIn)),
            (0...59).contains(Int(object.creditCarryIn)),
            object.schemaVersion >= 1,
            object.version >= 1
        else { return nil }

        let storedReport = MonthlyReport(
            month: month,
            rawServiceMinutes: Int(object.rawServiceMinutes),
            rawCreditMinutes: Int(object.rawCreditMinutes),
            serviceCarryIn: Int(object.serviceCarryIn),
            creditCarryIn: Int(object.creditCarryIn),
            serviceHours: Int(object.serviceHours),
            creditHours: Int(object.creditHours),
            serviceCarryOut: Int(object.serviceCarryOut),
            creditCarryOut: Int(object.creditCarryOut)
        )

        if !object.legacyCalculationUnavailable && !allowsUnmarkedLegacy {
            guard
                let mode = object.reportingMode.flatMap(RemainderMode.init(rawValue:)),
                let language = object.reportLanguage.flatMap(ReportLanguage.init(rawValue:)),
                let creditLabel = object.creditLabel,
                let templateID = object.templateID,
                let calculationFingerprint = object.calculationFingerprint,
                let presentationFingerprint = object.presentationFingerprint,
                let createdBySource = object.createdBySource,
                !templateID.isEmpty,
                !calculationFingerprint.isEmpty,
                !createdBySource.isEmpty,
                ReportCalculator.isConsistent(storedReport, mode: mode),
                presentationFingerprint == ReportFingerprint.presentation(
                    calculationFingerprint: calculationFingerprint,
                    language: language,
                    creditLabel: creditLabel,
                    templateID: templateID,
                    text: text
                ),
                mode.rawValue == object.reportingMode
            else { return nil }
        }
        let receipt = ReportReceipt(
            id: id,
            month: month,
            text: text,
            serviceHours: Int(object.serviceHours),
            creditHours: Int(object.creditHours),
            serviceCarryOut: Int(object.serviceCarryOut),
            creditCarryOut: Int(object.creditCarryOut),
            preparedAt: preparedAt,
            confirmedSentAt: object.confirmedSentAt
        )
        return ReportSnapshotMetadata(
            receipt: receipt,
            schemaVersion: Int(object.schemaVersion),
            version: Int(object.version),
            supersedesID: object.supersedesID,
            rawServiceMinutes: Int(object.rawServiceMinutes),
            rawCreditMinutes: Int(object.rawCreditMinutes),
            serviceCarryIn: Int(object.serviceCarryIn),
            creditCarryIn: Int(object.creditCarryIn),
            reportingMode: object.reportingMode,
            reportLanguage: object.reportLanguage,
            creditLabel: object.creditLabel,
            templateID: object.templateID,
            calculationFingerprint: object.calculationFingerprint,
            presentationFingerprint: object.presentationFingerprint,
            createdBySource: object.createdBySource,
            legacyCalculationUnavailable: object.legacyCalculationUnavailable
        )
    }

    static func reportStateRecord(from object: ReportStateEntity) -> ReportStateRecord? {
        guard
            let id = object.id,
            let month = object.monthKey.flatMap(MonthKey.init(key:)),
            let state = object.state,
            let updatedAt = object.updatedAt,
            ["draft", "ready", "reviewed", "prepared", "sent", "changed"].contains(state)
        else { return nil }
        return ReportStateRecord(
            id: id,
            month: month,
            state: state,
            lastStableState: object.lastStableState,
            currentSnapshotID: object.currentSnapshotID,
            reviewedCalculationFingerprint: object.reviewedCalculationFingerprint,
            reviewedPresentationFingerprint: object.reviewedPresentationFingerprint,
            updatedAt: updatedAt,
            changedAt: object.changedAt
        )
    }

    static func presetRecord(from object: PresetEntity) -> PresetRecord? {
        guard
            let id = object.id,
            let kind = object.kind.flatMap(EntryKind.init(rawValue:)),
            let createdAt = object.createdAt,
            let updatedAt = object.updatedAt,
            (1...5_999).contains(Int(object.minutes)),
            (0...2).contains(Int(object.position))
        else { return nil }
        return PresetRecord(
            id: id,
            kind: kind,
            minutes: Int(object.minutes),
            position: Int(object.position),
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: object.deletedAt
        )
    }

    static func dayAcknowledgementRecord(from object: DayAcknowledgementEntity) -> DayAcknowledgementRecord? {
        guard
            let id = object.id,
            let day = object.localDay.flatMap(LocalDay.init(key:)),
            let status = object.status,
            let source = object.source,
            let createdAt = object.createdAt,
            let updatedAt = object.updatedAt,
            status == "nothingToday",
            !source.isEmpty
        else { return nil }
        return DayAcknowledgementRecord(
            id: id,
            day: day,
            status: status,
            source: source,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    static func serviceYearArchiveRecord(from object: ServiceYearArchiveEntity) -> ServiceYearArchiveRecord? {
        guard
            let id = object.id,
            let startMonth = object.startMonthKey.flatMap(MonthKey.init(key:)),
            let endMonth = object.endMonthKey.flatMap(MonthKey.init(key:)),
            let calculationFingerprint = object.calculationFingerprint,
            let createdAt = object.createdAt,
            endMonth >= startMonth,
            object.actualServiceMinutes >= 0,
            object.baselineServiceMinutes >= 0,
            object.targetMinutes > 0,
            object.version >= 1,
            !calculationFingerprint.isEmpty
        else { return nil }
        return ServiceYearArchiveRecord(
            id: id,
            startMonth: startMonth,
            endMonth: endMonth,
            actualServiceMinutes: Int(object.actualServiceMinutes),
            baselineServiceMinutes: Int(object.baselineServiceMinutes),
            targetMinutes: Int(object.targetMinutes),
            calculationFingerprint: calculationFingerprint,
            version: Int(object.version),
            supersedesID: object.supersedesID,
            createdAt: createdAt
        )
    }

    static func domainSettings(from object: SettingsEntity) -> AppSettings? {
        guard
            object.id != nil,
            let reportLanguage = object.reportLanguage.flatMap(ReportLanguage.init(rawValue:)),
            let creditLabelEnglish = object.creditLabelEnglish,
            let creditLabelRussian = object.creditLabelRussian,
            let creditLabelUkrainian = object.creditLabelUkrainian,
            let ledgerStartMonth = object.ledgerStartMonth.flatMap(MonthKey.init(key:)),
            let baselineServiceYearStart = object.baselineServiceYearStart.flatMap(MonthKey.init(key:)),
            object.baselineServiceYearMinutes >= 0,
            (0...59).contains(Int(object.openingServiceCarryMinutes)),
            (0...59).contains(Int(object.openingCreditCarryMinutes))
        else { return nil }
        return AppSettings(
            reportLanguage: reportLanguage,
            creditLabelEnglish: creditLabelEnglish,
            creditLabelRussian: creditLabelRussian,
            creditLabelUkrainian: creditLabelUkrainian,
            ledgerStartMonth: ledgerStartMonth,
            baselineServiceYearMinutes: Int(object.baselineServiceYearMinutes),
            baselineServiceYearStart: baselineServiceYearStart,
            openingServiceCarryMinutes: Int(object.openingServiceCarryMinutes),
            openingCreditCarryMinutes: Int(object.openingCreditCarryMinutes),
            onboardingComplete: object.onboardingComplete
        )
    }

    static func requireDomainSettings(from object: SettingsEntity) throws -> AppSettings {
        guard let settings = domainSettings(from: object) else {
            throw LedgerRepositoryError.invalidManagedObject("Hourleaf settings contain incomplete saved data.")
        }
        return settings
    }

    static func decodeRequired<Object, Value>(
        _ objects: [Object],
        entity: String,
        using decode: (Object) -> Value?
    ) throws -> [Value] {
        try objects.map { object in
            guard let value = decode(object) else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "A saved \(entity) record contains incomplete or invalid data."
                )
            }
            return value
        }
    }

    static func validateReportGraph(
        snapshots: [ReportSnapshotMetadata],
        states: [ReportStateRecord]
    ) throws {
        var snapshotsByID: [UUID: ReportSnapshotMetadata] = [:]
        var versionsByMonth: [MonthKey: Set<Int>] = [:]
        for snapshot in snapshots {
            guard snapshotsByID.updateValue(snapshot, forKey: snapshot.id) == nil else {
                throw LedgerRepositoryError.invalidManagedObject("Saved reports contain a duplicate identifier.")
            }
            guard versionsByMonth[snapshot.receipt.month, default: []].insert(snapshot.version).inserted else {
                throw LedgerRepositoryError.invalidManagedObject("Saved reports contain a duplicate month version.")
            }
        }

        var stateMonths = Set<MonthKey>()
        for state in states {
            guard stateMonths.insert(state.month).inserted else {
                throw LedgerRepositoryError.invalidManagedObject("Saved report state is duplicated for a month.")
            }
            if let currentSnapshotID = state.currentSnapshotID {
                guard
                    let current = snapshotsByID[currentSnapshotID],
                    current.receipt.month == state.month
                else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "Saved report state points to a missing report snapshot."
                    )
                }
                if state.state == "sent", current.receipt.confirmedSentAt == nil {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A sent report state points to a report that was not confirmed sent."
                    )
                }
                if state.state == "prepared", current.receipt.confirmedSentAt != nil {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A prepared report state points to a sent report snapshot."
                    )
                }
            } else if state.state == "prepared" || state.state == "sent" {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Prepared and sent report states require a current report snapshot."
                )
            }
        }
    }

    static func write(_ settings: AppSettings, to object: SettingsEntity) {
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
        object.updatedAt = .now
    }

    static func preferredSettingsObject(in objects: [SettingsEntity]) -> SettingsEntity? {
        objects.max { lhs, rhs in
            if lhs.onboardingComplete != rhs.onboardingComplete {
                return !lhs.onboardingComplete && rhs.onboardingComplete
            }
            if lhs.updatedAt != rhs.updatedAt {
                return (lhs.updatedAt ?? .distantPast) < (rhs.updatedAt ?? .distantPast)
            }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
    }

    static func appendRevision(
        for entry: EntryEntity,
        in context: NSManagedObjectContext,
        mutationID: UUID,
        parentMutationID: UUID?,
        revertedMutationID: UUID? = nil,
        operation: String,
        source: String,
        occurredAt: Date
    ) {
        let revision = context.insert(EntryRevisionEntity.self)
        revision.id = UUID()
        revision.entryID = entry.id
        revision.mutationID = mutationID
        revision.parentMutationID = parentMutationID
        revision.revertedMutationID = revertedMutationID
        revision.revision = max(entry.revision, 1)
        revision.operation = operation
        revision.kind = entry.kind
        revision.localDay = entry.localDay
        revision.minutes = entry.minutes
        revision.note = entry.note
        revision.entryCreatedAt = entry.createdAt
        revision.entryUpdatedAt = entry.updatedAt
        revision.entryDeletedAt = entry.deletedAt
        revision.source = source
        revision.occurredAt = occurredAt
    }

    static func reportState(in context: NSManagedObjectContext, monthKey: String) throws -> ReportStateEntity? {
        let request: NSFetchRequest<ReportStateEntity> = ReportStateEntity.request()
        request.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]
        request.predicate = NSPredicate(format: "monthKey == %@", monthKey)
        let states = try context.fetch(request)
        _ = try decodeRequired(states, entity: "ReportStateEntity", using: reportStateRecord)
        let sorted = states.sorted(by: reportStateOrder)
        guard let preferred = sorted.last else { return nil }
        sorted.dropLast().forEach(context.delete)
        return preferred
    }

    static func nextReceiptVersion(in context: NSManagedObjectContext, monthKey: String) throws -> Int32 {
        let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        request.predicate = NSPredicate(format: "monthKey == %@", monthKey)
        let versions = try context.fetch(request).map(\.version)
        let current = max(versions.max() ?? 0, 0)
        guard current < Int32.max else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Saved report versions are exhausted for this month."
            )
        }
        return current + 1
    }

    static func newestReceipt(
        in context: NSManagedObjectContext,
        monthKey: String
    ) throws -> ReportReceiptEntity? {
        let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        request.predicate = NSPredicate(format: "monthKey == %@", monthKey)
        return try context.fetch(request).max(by: receiptOrder)
    }

    static func receiptOrder(_ lhs: ReportReceiptEntity, _ rhs: ReportReceiptEntity) -> Bool {
        let lhsKey = (lhs.preparedAt ?? .distantPast, lhs.id?.uuidString ?? "")
        let rhsKey = (rhs.preparedAt ?? .distantPast, rhs.id?.uuidString ?? "")
        return lhsKey < rhsKey
    }

    static func reportStateOrder(_ lhs: ReportStateEntity, _ rhs: ReportStateEntity) -> Bool {
        let lhsKey = (lhs.updatedAt ?? .distantPast, lhs.id?.uuidString ?? "")
        let rhsKey = (rhs.updatedAt ?? .distantPast, rhs.id?.uuidString ?? "")
        return lhsKey < rhsKey
    }

    static func saveIfNeeded(_ context: NSManagedObjectContext) throws {
        if context.hasChanges { try context.save() }
    }
}

private extension EntryMutationOperation {
    var isUndoable: Bool {
        switch self {
        case .create, .update, .delete, .restore: true
        case .undo: false
        }
    }
}
