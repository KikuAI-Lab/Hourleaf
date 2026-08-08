@preconcurrency import CoreData
import CryptoKit
import Foundation

enum CSVImportRepositoryError: LocalizedError, Equatable, Sendable {
    case unavailable
    case identityCollision
    case validationFailed
    case transactionFailed
    case verificationFailed
    case undoUnavailable
    case undoExpired

    var errorDescription: String? {
        switch self {
        case .undoUnavailable, .undoExpired:
            String(localized: "error.undo_unavailable")
        case .unavailable,
             .identityCollision,
             .validationFailed,
             .transactionFailed,
             .verificationFailed:
            "The CSV file could not be imported."
        }
    }
}

/// Test-only failure points for proving CSV import's atomic save/readback
/// boundary. The default repository initializer installs a no-op injector, so
/// production behavior is unchanged.
enum CSVImportFaultPoint: Hashable, Sendable {
    case importBeforeSave
    case importAfterSaveBeforeReadback
    case undoBeforeSave
    case undoAfterSaveBeforeReadback
}

typealias CSVImportFaultInjector = @Sendable (CSVImportFaultPoint) throws -> Void

protocol LedgerRepository: Sendable {
    func ledgerSnapshot() async throws -> LedgerSnapshot
    func fetchEntries() async throws -> [TimeEntry]
    func fetchAllEntries() async throws -> [LedgerEntryRecord]
    func apply(_ command: EntryMutationCommand) async throws -> EntryMutationReceipt
    func latestUndoCandidate(asOf: Date) async throws -> EntryUndoCandidate?
    func loadSettings() async throws -> AppSettings
    func saveSettings(_ settings: AppSettings) async throws
    func saveQuickSurfacePreferences(_ value: QuickSurfacePreferences) async throws
    func savePlanningPreferences(_ value: PlanningPreferences) async throws
    func acknowledgeNothingToRecord(
        on day: LocalDay,
        source: DayAcknowledgementSource,
        at: Date
    ) async throws -> DayAcknowledgementRecord
    func fetchPolicies() async throws -> [ReportingPolicy]
    func savePolicy(_ policy: ReportingPolicy) async throws
    func fetchReminders() async throws -> [ReminderSchedule]
    func saveReminder(_ reminder: ReminderSchedule) async throws
    func deleteReminder(id: UUID) async throws
    func fetchReceipts() async throws -> [ReportReceipt]
    func reconcileReportLifecycle(asOf now: Date) async throws -> LedgerSnapshot
    func reviewReport(_ request: ReviewReportRequest) async throws -> LedgerSnapshot
    func prepareReport(_ request: PrepareReportRequest) async throws -> PreparedReportResult
    func markReportSent(_ request: MarkReportSentRequest) async throws -> LedgerSnapshot
    func closeServiceYear(_ request: CloseServiceYearRequest) async throws -> ServiceYearArchiveResult
    func previewCSVImport(
        _ document: CSVImportDocument,
        candidateID: UUID
    ) async throws -> CSVImportPreview
    func applyCSVImport(
        _ document: CSVImportDocument,
        policy: CSVImportDuplicatePolicy
    ) async throws -> CSVImportResult
    func undoCSVImport(_ token: CSVImportUndoToken) async throws -> CSVImportUndoResult
}

extension LedgerRepository {
    func previewCSVImport(
        document: CSVImportDocument,
        candidateID: UUID = UUID()
    ) async throws -> CSVImportPreview {
        try await previewCSVImport(document, candidateID: candidateID)
    }

    func applyCSVImport(
        document: CSVImportDocument,
        policy: CSVImportDuplicatePolicy
    ) async throws -> CSVImportResult {
        try await applyCSVImport(document, policy: policy)
    }

    func undoCSVImport(token: CSVImportUndoToken) async throws -> CSVImportUndoResult {
        try await undoCSVImport(token)
    }

    func previewCSVImport(
        _ document: CSVImportDocument,
        candidateID: UUID
    ) async throws -> CSVImportPreview {
        throw CSVImportRepositoryError.unavailable
    }

    func applyCSVImport(
        _ document: CSVImportDocument,
        policy: CSVImportDuplicatePolicy
    ) async throws -> CSVImportResult {
        throw CSVImportRepositoryError.unavailable
    }

    func undoCSVImport(_ token: CSVImportUndoToken) async throws -> CSVImportUndoResult {
        throw CSVImportRepositoryError.unavailable
    }

    func saveQuickSurfacePreferences(_ value: QuickSurfacePreferences) async throws {
        throw LedgerRepositoryError.invalidManagedObject(
            "This repository does not support quick surface preferences."
        )
    }

    func savePlanningPreferences(_ value: PlanningPreferences) async throws {
        throw LedgerRepositoryError.invalidManagedObject(
            "This repository does not support planning preferences."
        )
    }

    func acknowledgeNothingToRecord(
        on day: LocalDay,
        source: DayAcknowledgementSource,
        at: Date
    ) async throws -> DayAcknowledgementRecord {
        throw LedgerRepositoryError.invalidManagedObject(
            "This repository does not support day acknowledgements."
        )
    }
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
    private let csvImportFaultInjector: CSVImportFaultInjector
    private var normalizationComplete = false
    private var normalizationFailure: LedgerRepositoryError?
    private var maintenanceLease: LedgerMaintenanceLease?

    init(
        persistence: PersistenceController,
        clock: @escaping @Sendable () -> Date = { .now },
        csvImportFaultInjector: @escaping CSVImportFaultInjector = { _ in }
    ) {
        self.persistence = persistence
        self.clock = clock
        self.csvImportFaultInjector = csvImportFaultInjector
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

    func previewCSVImport(
        _ document: CSVImportDocument,
        candidateID: UUID
    ) async throws -> CSVImportPreview {
        try requireAvailable()
        try ensureNormalized()
        let authorizationTime = clock()
        do {
            return try perform { context in
                let snapshot = try Self.snapshot(in: context)
                let classification = try Self.classifyCSVImport(
                    document,
                    in: snapshot
                )
                for row in classification.newRows + classification.possibleMatches {
                    do {
                        guard try Self.validatedValues(
                            row.values,
                            in: context,
                            authorizationTime: authorizationTime
                        ) != nil else {
                            throw CSVImportRepositoryError.validationFailed
                        }
                    } catch let error as CSVImportRepositoryError {
                        throw error
                    } catch {
                        throw CSVImportRepositoryError.validationFailed
                    }
                }
                return CSVImportPreview(
                    candidateID: candidateID,
                    totalRows: document.rows.count,
                    noteCount: document.noteCount,
                    dateRange: document.dateRange,
                    previouslyImportedCount: classification.previouslyImported.count,
                    possibleMatchCount: classification.possibleMatches.count,
                    importableWhenSkippingMatches: classification.newRows.count,
                    importableWhenIncludingMatches: classification.newRows.count
                        + classification.possibleMatches.count
                )
            }
        } catch let error as CSVImportRepositoryError {
            throw error
        } catch {
            throw Self.sanitizedCSVImportError(error)
        }
    }

    func applyCSVImport(
        _ document: CSVImportDocument,
        policy: CSVImportDuplicatePolicy
    ) async throws -> CSVImportResult {
        try requireAvailable()
        try ensureNormalized()
        let authorizationTime = clock()
        do {
            return try applyCSVImportOnce(
                document,
                policy: policy,
                authorizationTime: authorizationTime
            )
        } catch let retry as CSVImportRetry {
            guard case let .import(plan) = retry else {
                throw CSVImportRepositoryError.verificationFailed
            }
            do {
                return try replayOrRetryCSVImport(
                    plan,
                    document: document,
                    policy: policy,
                    authorizationTime: authorizationTime
                )
            } catch let retry as CSVImportRetry {
                _ = retry
                throw CSVImportRepositoryError.verificationFailed
            } catch let error as CSVImportRepositoryError {
                throw error
            } catch {
                throw Self.sanitizedCSVImportError(error)
            }
        } catch let error as CSVImportRepositoryError {
            throw error
        } catch {
            throw Self.sanitizedCSVImportError(error)
        }
    }

    func undoCSVImport(_ token: CSVImportUndoToken) async throws -> CSVImportUndoResult {
        try requireAvailable()
        try ensureNormalized()
        let authorizationTime = clock()
        do {
            return try undoCSVImportOnce(
                token,
                authorizationTime: authorizationTime
            )
        } catch let retry as CSVImportRetry {
            guard case let .undo(plan) = retry else {
                throw CSVImportRepositoryError.verificationFailed
            }
            do {
                return try replayOrRetryCSVImportUndo(
                    plan,
                    authorizationTime: authorizationTime
                )
            } catch let retry as CSVImportRetry {
                _ = retry
                throw CSVImportRepositoryError.verificationFailed
            } catch let error as CSVImportRepositoryError {
                throw error
            } catch {
                throw Self.sanitizedCSVImportError(error)
            }
        } catch let error as CSVImportRepositoryError {
            throw error
        } catch {
            throw Self.sanitizedCSVImportError(error)
        }
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

            let before = try Self.snapshot(in: context)
            let written = try Self.applyNew(
                command,
                in: context,
                authorizationTime: authorizationTime
            )
            let record: LedgerEntryRecord
            do {
                try Self.reconcileReportLifecycleAfterChange(
                    in: context,
                    before: before,
                    asOf: authorizationTime
                )
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
        let now = clock()
        try performMutation { context in
            let before = try Self.snapshot(in: context)
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let objects = try context.fetch(request)
            let object = Self.preferredSettingsObject(in: objects) ?? context.insert(SettingsEntity.self)
            if object.id == nil { object.id = Self.settingsID }
            Self.write(settings, to: object)
            object.updatedAt = now
            objects.filter { $0 !== object }.forEach(context.delete)
            try Self.reconcileReportLifecycleAfterChange(
                in: context,
                before: before,
                asOf: now
            )
            try Self.saveIfNeeded(context)
            context.refreshAllObjects()

            let reread = try context.fetch(request)
            guard
                reread.count == 1,
                let persisted = Self.preferredSettingsObject(in: reread),
                Self.domainSettings(from: persisted) == settings
            else {
                throw LedgerRepositoryError.invalidManagedObject("Hourleaf could not verify saved settings.")
            }
        }
    }

    func savePlanningPreferences(_ value: PlanningPreferences) async throws {
        try requireAvailable()
        try ensureNormalized()
        guard (1...365).contains(value.quietGapDays) else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Quiet Gap interval must be between 1 and 365 days."
            )
        }

        let updatedAt = clock()
        try performMutation { context in
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let objects = try context.fetch(request)
            guard
                objects.count == 1,
                let object = Self.preferredSettingsObject(in: objects)
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf settings are unavailable."
                )
            }

            object.planningVisible = value.isPaceVisible
            object.quietGapCheckEnabled = value.isQuietGapEnabled
            object.quietGapDays = Int16(value.quietGapDays)
            object.updatedAt = updatedAt
            try Self.saveIfNeeded(context)
            context.refreshAllObjects()

            let reread = try context.fetch(request)
            guard
                reread.count == 1,
                let persisted = reread.first,
                persisted.planningVisible == value.isPaceVisible,
                persisted.quietGapCheckEnabled == value.isQuietGapEnabled,
                Int(persisted.quietGapDays) == value.quietGapDays
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf could not verify saved planning preferences."
                )
            }
        }
    }

    func saveQuickSurfacePreferences(_ value: QuickSurfacePreferences) async throws {
        try requireAvailable()
        try ensureNormalized()
        let updatedAt = clock()

        try performMutation { context in
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let objects = try context.fetch(request)
            guard
                objects.count == 1,
                let object = Self.preferredSettingsObject(in: objects)
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf settings are unavailable."
                )
            }

            object.timerVisible = value.timerVisible
            object.widgetPrivacyMode = value.privacyMode.rawValue
            object.updatedAt = updatedAt
            try Self.saveIfNeeded(context)
            context.refreshAllObjects()

            let reread = try context.fetch(request)
            guard
                reread.count == 1,
                let persisted = Self.preferredSettingsObject(in: reread),
                persisted.timerVisible == value.timerVisible,
                persisted.widgetPrivacyMode == value.privacyMode.rawValue
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf could not verify saved quick surface preferences."
                )
            }
        }
    }

    func acknowledgeNothingToRecord(
        on day: LocalDay,
        source: DayAcknowledgementSource,
        at: Date
    ) async throws -> DayAcknowledgementRecord {
        try requireAvailable()
        try ensureNormalized()
        guard let canonicalDay = LocalDay(key: day.key), canonicalDay == day else {
            throw LedgerRepositoryError.invalidManagedObject(
                "The acknowledgement day is invalid."
            )
        }
        guard day <= LocalDay(at, calendar: .hourleaf) else {
            throw LedgerRepositoryError.invalidManagedObject(
                "A future day cannot be acknowledged."
            )
        }

        return try performMutation { context in
            let settingsRequest: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            guard
                let settingsObject = Self.preferredSettingsObject(
                    in: try context.fetch(settingsRequest)
                ),
                let settings = Self.domainSettings(from: settingsObject)
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf settings are unavailable."
                )
            }
            guard day.monthKey >= settings.ledgerStartMonth else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "The acknowledgement day is before Hourleaf records begin."
                )
            }

            let request: NSFetchRequest<DayAcknowledgementEntity> = DayAcknowledgementEntity.request()
            request.predicate = NSPredicate(format: "localDay == %@", day.key)
            let matching = try context.fetch(request)
            guard matching.count <= 1 else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf found duplicate day acknowledgements."
                )
            }

            let object = matching.first ?? context.insert(DayAcknowledgementEntity.self)
            if let existing = matching.first {
                guard
                    existing.status == DayAcknowledgementStatus.nothingToday.rawValue,
                    Self.dayAcknowledgementRecord(from: existing) != nil
                else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "Hourleaf found an unsupported day acknowledgement."
                    )
                }
            } else {
                object.id = UUID()
                object.localDay = day.key
                object.status = DayAcknowledgementStatus.nothingToday.rawValue
                object.createdAt = at
            }
            object.source = source.rawValue
            object.updatedAt = at

            try Self.saveIfNeeded(context)
            context.refreshAllObjects()

            let reread = try context.fetch(request)
            guard
                reread.count == 1,
                let record = reread.first.flatMap(Self.dayAcknowledgementRecord),
                record.day == day,
                record.status == DayAcknowledgementStatus.nothingToday.rawValue,
                record.source == source.rawValue
            else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf could not verify the day acknowledgement."
                )
            }
            return record
        }
    }

    func fetchPolicies() async throws -> [ReportingPolicy] {
        try requireAvailable()
        return try await ledgerSnapshot().policies
    }

    func savePolicy(_ policy: ReportingPolicy) async throws {
        try requireAvailable()
        try ensureNormalized()
        let now = clock()
        try performMutation { context in
            let before = try Self.snapshot(in: context)
            let request: NSFetchRequest<PolicyRevisionEntity> = PolicyRevisionEntity.request()
            request.fetchLimit = 1
            request.predicate = NSPredicate(format: "id == %@", policy.id as CVarArg)
            let object = try context.fetch(request).first ?? context.insert(PolicyRevisionEntity.self)
            object.id = policy.id
            object.effectiveMonth = policy.effectiveMonth.key
            object.mode = policy.mode.rawValue
            object.carryAcrossServiceYear = false
            object.createdAt = policy.createdAt
            try Self.reconcileReportLifecycleAfterChange(
                in: context,
                before: before,
                asOf: now
            )
            try Self.saveIfNeeded(context)
            context.refreshAllObjects()

            let reread = try context.fetch(request)
            guard reread.count == 1, let persisted = reread.first, Self.domainPolicy(from: persisted) == policy else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Hourleaf could not verify the saved reporting policy."
                )
            }
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

    #if DEBUG
    private func saveReceiptFixture(
        _ receipt: ReportReceipt,
        details: ReportSnapshotDetails?
    ) async throws {
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
    #endif

    func reconcileReportLifecycle(asOf now: Date) async throws -> LedgerSnapshot {
        try requireAvailable()
        try ensureNormalized()
        return try performMutation { context in
            let snapshot = try Self.snapshot(in: context)
            try Self.reconcileLifecycleStateEntities(in: context, snapshot: snapshot, asOf: now)
            try Self.saveIfNeeded(context)
            context.refreshAllObjects()
            return try Self.snapshot(in: context)
        }
    }

    func reviewReport(_ request: ReviewReportRequest) async throws -> LedgerSnapshot {
        try requireAvailable()
        try ensureNormalized()
        return try performMutation { context in
            let snapshot = try Self.snapshot(in: context)
            let currentMonth = ReportReadiness.currentMonth(asOf: request.reviewedAt)
            guard request.month >= snapshot.settings.ledgerStartMonth else {
                throw ReportLifecycleError.beforeLedgerStart
            }
            guard request.month < currentMonth else {
                throw ReportLifecycleError.monthStillOpen
            }
            let draft = try Self.requireReportDraft(for: request.month, in: snapshot)
            guard
                draft.calculationFingerprint == request.expectedCalculationFingerprint,
                draft.presentationFingerprint == request.expectedPresentationFingerprint
            else {
                throw ReportLifecycleError.reportChanged
            }

            let existingRecord = Self.stateRecord(for: request.month, in: snapshot)
            if existingRecord?.state == .reviewed,
               existingRecord?.reviewedCalculationFingerprint == draft.calculationFingerprint,
               existingRecord?.reviewedPresentationFingerprint == draft.presentationFingerprint {
                return snapshot
            }

            let allowedStates: Set<ReportLifecycleState> = [.ready, .changed]
            let effectiveState = Self.effectiveLifecycleState(
                for: request.month,
                snapshot: snapshot,
                asOf: request.reviewedAt
            )
            guard allowedStates.contains(effectiveState) else {
                throw ReportLifecycleError.reportChanged
            }

            let state = try Self.reportState(in: context, monthKey: request.month.key)
                ?? Self.insertState(month: request.month, in: context, at: request.reviewedAt)
            state.state = ReportLifecycleState.reviewed.rawValue
            state.lastStableState = nil
            state.changedAt = nil
            state.reviewedCalculationFingerprint = draft.calculationFingerprint
            state.reviewedPresentationFingerprint = draft.presentationFingerprint
            state.updatedAt = request.reviewedAt

            try Self.saveIfNeeded(context)
            context.refreshAllObjects()
            return try Self.snapshot(in: context)
        }
    }

    func prepareReport(_ request: PrepareReportRequest) async throws -> PreparedReportResult {
        try requireAvailable()
        try ensureNormalized()
        return try performMutation { context in
            if let existing = try Self.reportSnapshotEntity(in: context, id: request.snapshotID) {
                let series = try Self.reportSnapshotSeries(in: context, month: request.month)
                let priorSeries = series.filter { $0.version < existing.version }
                let expectedPreparedAt = Self.clampedTimestamp(
                    requested: request.preparedAt,
                    existing: priorSeries.compactMap(\.preparedAt)
                )
                let expectedVersion = try Self.nextVersion(
                    in: priorSeries.map(\.version),
                    exhaustedError: .receiptVersionExhausted
                )
                guard
                    existing.schemaVersion == 2,
                    existing.monthKey == request.month.key,
                    existing.version == expectedVersion,
                    existing.supersedesID == Self.nextSupersedesID(for: priorSeries),
                    existing.preparedAt == expectedPreparedAt,
                    existing.calculationFingerprint == request.expectedCalculationFingerprint,
                    existing.presentationFingerprint == request.expectedPresentationFingerprint,
                    existing.createdBySource == ReportReadiness.reportSnapshotSource
                else {
                    throw ReportLifecycleError.invalidSnapshotHistory
                }
                let refreshed = try Self.snapshot(in: context)
                guard let replay = refreshed.reportSnapshots.first(where: { $0.id == request.snapshotID }) else {
                    throw LedgerRepositoryError.invalidManagedObject("Hourleaf could not verify the saved report snapshot.")
                }
                return PreparedReportResult(snapshot: replay, ledger: refreshed, wasReplay: true)
            }

            let snapshot = try Self.snapshot(in: context)
            let currentMonth = ReportReadiness.currentMonth(asOf: request.preparedAt)
            guard request.month >= snapshot.settings.ledgerStartMonth else {
                throw ReportLifecycleError.beforeLedgerStart
            }
            guard request.month < currentMonth else {
                throw ReportLifecycleError.monthStillOpen
            }

            let draft = try Self.requireReportDraft(for: request.month, in: snapshot)
            guard
                draft.calculationFingerprint == request.expectedCalculationFingerprint,
                draft.presentationFingerprint == request.expectedPresentationFingerprint
            else {
                throw ReportLifecycleError.reportChanged
            }

            let state = try Self.reportState(in: context, monthKey: request.month.key)
            guard
                let state,
                ReportLifecycleState(rawValue: state.state ?? "") == .reviewed,
                state.reviewedCalculationFingerprint == request.expectedCalculationFingerprint,
                state.reviewedPresentationFingerprint == request.expectedPresentationFingerprint
            else {
                throw ReportLifecycleError.reviewRequired
            }

            let series = try Self.reportSnapshotSeries(in: context, month: request.month)
            let version = try Self.nextVersion(
                in: series.map(\.version),
                exhaustedError: .receiptVersionExhausted
            )
            let effectivePreparedAt = Self.clampedTimestamp(
                requested: request.preparedAt,
                existing: series.compactMap(\.preparedAt)
            )
            let object = context.insert(ReportReceiptEntity.self)
            object.id = request.snapshotID
            object.monthKey = request.month.key
            object.reportText = draft.text
            object.serviceHours = Int32(draft.report.serviceHours)
            object.creditHours = Int32(draft.report.creditHours)
            object.serviceCarryOut = Int32(draft.report.serviceCarryOut)
            object.creditCarryOut = Int32(draft.report.creditCarryOut)
            object.preparedAt = effectivePreparedAt
            object.confirmedSentAt = nil
            object.schemaVersion = 2
            object.version = version
            object.supersedesID = Self.nextSupersedesID(for: series)
            object.rawServiceMinutes = Int64(draft.report.rawServiceMinutes)
            object.rawCreditMinutes = Int64(draft.report.rawCreditMinutes)
            object.serviceCarryIn = Int32(draft.report.serviceCarryIn)
            object.creditCarryIn = Int32(draft.report.creditCarryIn)
            object.reportingMode = draft.reportingMode.rawValue
            object.reportLanguage = draft.reportLanguage.rawValue
            object.creditLabel = draft.creditLabel
            object.templateID = draft.templateID
            object.calculationFingerprint = draft.calculationFingerprint
            object.presentationFingerprint = draft.presentationFingerprint
            object.createdBySource = ReportReadiness.reportSnapshotSource
            object.legacyCalculationUnavailable = false

            state.currentSnapshotID = request.snapshotID
            state.state = ReportLifecycleState.prepared.rawValue
            state.lastStableState = nil
            state.changedAt = nil
            state.reviewedCalculationFingerprint = nil
            state.reviewedPresentationFingerprint = nil
            state.updatedAt = effectivePreparedAt

            try Self.saveIfNeeded(context)
            context.refreshAllObjects()
            let refreshed = try Self.snapshot(in: context)
            guard let prepared = refreshed.reportSnapshots.first(where: { $0.id == request.snapshotID }) else {
                throw LedgerRepositoryError.invalidManagedObject("Hourleaf could not verify the saved report snapshot.")
            }
            return PreparedReportResult(snapshot: prepared, ledger: refreshed, wasReplay: false)
        }
    }

    func markReportSent(_ request: MarkReportSentRequest) async throws -> LedgerSnapshot {
        try requireAvailable()
        try ensureNormalized()
        return try performMutation { context in
            let target = try Self.reportSnapshotEntity(in: context, id: request.snapshotID)
            guard let target, let monthKey = target.monthKey, let month = MonthKey(key: monthKey) else {
                throw ReportLifecycleError.snapshotNotFound
            }
            if target.confirmedSentAt != nil {
                return try Self.snapshot(in: context)
            }
            let preSaveSnapshot = try Self.snapshot(in: context)
            target.confirmedSentAt = request.confirmedAt
            if let state = try Self.reportState(in: context, monthKey: month.key),
               state.currentSnapshotID == request.snapshotID {
                if let current = preSaveSnapshot.reportSnapshots.first(where: { $0.id == request.snapshotID }),
                   Self.snapshotReferenceMatchesCurrentDraft(current, month: month, in: preSaveSnapshot) {
                    state.state = ReportLifecycleState.sent.rawValue
                    state.lastStableState = nil
                    state.changedAt = nil
                    state.updatedAt = request.confirmedAt
                } else if ReportLifecycleState(rawValue: state.state ?? "") == .changed {
                    if state.lastStableState == ReportLifecycleState.prepared.rawValue {
                        state.lastStableState = ReportLifecycleState.sent.rawValue
                    }
                    state.updatedAt = request.confirmedAt
                }
            }

            try Self.saveIfNeeded(context)
            context.refreshAllObjects()
            return try Self.snapshot(in: context)
        }
    }

    func closeServiceYear(_ request: CloseServiceYearRequest) async throws -> ServiceYearArchiveResult {
        try requireAvailable()
        try ensureNormalized()
        return try performMutation { context in
            if let existing = try Self.serviceYearArchiveEntity(in: context, id: request.archiveID) {
                guard
                    let existingStart = existing.startMonthKey.flatMap(MonthKey.init(key:)),
                    let existingEnd = existing.endMonthKey.flatMap(MonthKey.init(key:))
                else {
                    throw ReportLifecycleError.invalidSnapshotHistory
                }
                let series = try Self.serviceYearArchiveSeries(
                    in: context,
                    startMonth: existingStart,
                    endMonth: existingEnd
                )
                let priorSeries = series.filter { $0.version < existing.version }
                let expectedCreatedAt = Self.clampedTimestamp(
                    requested: request.createdAt,
                    existing: priorSeries.compactMap(\.createdAt)
                )
                let expectedVersion = try Self.nextVersion(
                    in: priorSeries.map(\.version),
                    exhaustedError: .archiveVersionExhausted
                )
                guard
                    existing.startMonthKey == request.startMonth.key,
                    existing.endMonthKey == request.startMonth.advanced(by: 11, calendar: .hourleaf).key,
                    existing.version == expectedVersion,
                    existing.supersedesID == Self.nextSupersedesID(for: priorSeries),
                    existing.createdAt == expectedCreatedAt,
                    existing.calculationFingerprint == request.expectedCalculationFingerprint
                else {
                    throw ReportLifecycleError.invalidSnapshotHistory
                }
                let refreshed = try Self.snapshot(in: context)
                guard let replay = refreshed.serviceYearArchives.first(where: { $0.id == request.archiveID }) else {
                    throw LedgerRepositoryError.invalidManagedObject("Hourleaf could not verify the saved archive snapshot.")
                }
                return ServiceYearArchiveResult(archive: replay, ledger: refreshed, wasReplay: true)
            }

            let snapshot = try Self.snapshot(in: context)
            guard let draft = ReportReadiness.serviceYearDraft(starting: request.startMonth, in: snapshot) else {
                throw ReportLifecycleError.beforeLedgerStart
            }
            let currentMonth = ReportReadiness.currentMonth(asOf: request.createdAt)
            guard draft.endMonth < currentMonth else {
                throw ReportLifecycleError.serviceYearStillOpen
            }
            guard draft.calculationFingerprint == request.expectedCalculationFingerprint else {
                throw ReportLifecycleError.archiveChanged
            }

            let series = try Self.serviceYearArchiveSeries(in: context, startMonth: draft.startMonth, endMonth: draft.endMonth)
            let version = try Self.nextVersion(
                in: series.map(\.version),
                exhaustedError: .archiveVersionExhausted
            )
            let effectiveCreatedAt = Self.clampedTimestamp(
                requested: request.createdAt,
                existing: series.compactMap(\.createdAt)
            )
            let object = context.insert(ServiceYearArchiveEntity.self)
            object.id = request.archiveID
            object.startMonthKey = draft.startMonth.key
            object.endMonthKey = draft.endMonth.key
            object.actualServiceMinutes = Int64(draft.actualServiceMinutes)
            object.baselineServiceMinutes = Int64(draft.baselineServiceMinutes)
            object.targetMinutes = Int64(draft.targetMinutes)
            object.calculationFingerprint = draft.calculationFingerprint
            object.version = version
            object.supersedesID = Self.nextSupersedesID(for: series)
            object.createdAt = effectiveCreatedAt

            try Self.saveIfNeeded(context)
            context.refreshAllObjects()
            let refreshed = try Self.snapshot(in: context)
            guard let archive = refreshed.serviceYearArchives.first(where: { $0.id == request.archiveID }) else {
                throw LedgerRepositoryError.invalidManagedObject("Hourleaf could not verify the saved archive snapshot.")
            }
            return ServiceYearArchiveResult(archive: archive, ledger: refreshed, wasReplay: false)
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

private struct CSVImportClassification: Sendable {
    let previouslyImported: [CSVImportRow]
    let possibleMatches: [CSVImportRow]
    let newRows: [CSVImportRow]
}

private struct CSVImportRetryPlan: Sendable {
    let selectedRows: [CSVImportRow]
    let previouslyImportedCount: Int
    let skippedPossibleMatchCount: Int
    let authorizationTime: Date
}

private struct CSVImportUndoRetryPlan: Sendable {
    let token: CSVImportUndoToken
    let authorizationTime: Date
}

private enum CSVImportRetry: Error {
    case `import`(CSVImportRetryPlan)
    case undo(CSVImportUndoRetryPlan)
}

private enum CSVImportReplayStatus: Equatable, Sendable {
    case exact
    case absent
    case mismatch
}

private enum CSVImportUndoMemberState: Equatable, Sendable {
    case active
    case alreadyUndone
    case mismatch
}

private enum EntryMutationRetry: Error {
    case required
}

private struct DraftIdentity: Equatable, Sendable {
    let calculationFingerprint: String
    let presentationFingerprint: String
}

private enum StableReportReference: Sendable {
    case reviewed(calculationFingerprint: String?, presentationFingerprint: String?)
    case snapshot(ReportSnapshotMetadata)

    var allowsAutoRestore: Bool {
        switch self {
        case .reviewed:
            true
        case let .snapshot(snapshot):
            !snapshot.legacyCalculationUnavailable
        }
    }

    var requiresExplicitMutationInvalidation: Bool {
        switch self {
        case .reviewed:
            false
        case let .snapshot(snapshot):
            snapshot.legacyCalculationUnavailable
        }
    }

    func matches(
        month: MonthKey,
        in snapshot: LedgerSnapshot
    ) -> Bool {
        switch self {
        case let .reviewed(calculationFingerprint, presentationFingerprint):
            guard let draft = ReportReadiness.draft(for: month, in: snapshot) else { return false }
            return draft.calculationFingerprint == calculationFingerprint
                && draft.presentationFingerprint == presentationFingerprint
        case let .snapshot(metadata):
            return CoreDataLedgerRepository.snapshotReferenceMatchesCurrentDraft(
                metadata,
                month: month,
                in: snapshot
            )
        }
    }
}

private extension CoreDataLedgerRepository {
    static func sanitizedCSVImportError(_ error: Error) -> CSVImportRepositoryError {
        if let error = error as? CSVImportRepositoryError { return error }
        if error is EntryMutationError || error is EntryValidationError {
            return .validationFailed
        }
        return .transactionFailed
    }

    static func classifyCSVImport(
        _ document: CSVImportDocument,
        in snapshot: LedgerSnapshot
    ) throws -> CSVImportClassification {
        let entriesByID = Dictionary(
            uniqueKeysWithValues: snapshot.entries.map { ($0.id, $0) }
        )
        let revisionsByMutationID = Dictionary(
            uniqueKeysWithValues: snapshot.entryRevisions.map { ($0.mutationID, $0) }
        )
        let importedRevisionByEntryID = Dictionary(
            snapshot.entryRevisions.compactMap { revision -> (UUID, EntryRevisionRecord)? in
                guard
                    revision.operation == EntryMutationOperation.create.rawValue,
                    revision.source == EntryMutationSource.csvImport.rawValue,
                    revision.revision == 1
                else { return nil }
                return (revision.entryID, revision)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let importedEntryIDs = Set(importedRevisionByEntryID.keys)
        let activeManualEntries = snapshot.entries.filter {
            !$0.isDeleted && !importedEntryIDs.contains($0.id)
        }

        var consumedManualIDs = Set<UUID>()
        var previouslyImported = [CSVImportRow]()
        var possibleMatches = [CSVImportRow]()
        var newRows = [CSVImportRow]()
        previouslyImported.reserveCapacity(document.rows.count)
        possibleMatches.reserveCapacity(document.rows.count)
        newRows.reserveCapacity(document.rows.count)

        for row in document.rows {
            if let entry = entriesByID[row.entryID] {
                guard
                    let importedRevision = importedRevisionByEntryID[row.entryID],
                    importedRevision.mutationID == row.mutationID,
                    importedRevision.kind == row.values.kind.rawValue,
                    importedRevision.localDay == row.values.day.key,
                    importedRevision.minutes == row.values.minutes,
                    importedRevision.note == row.values.note
                else {
                    throw CSVImportRepositoryError.identityCollision
                }
                _ = entry
                previouslyImported.append(row)
                continue
            }

            if let existingRevision = revisionsByMutationID[row.mutationID] {
                guard
                    existingRevision.entryID == row.entryID,
                    existingRevision.operation == EntryMutationOperation.create.rawValue,
                    existingRevision.source == EntryMutationSource.csvImport.rawValue,
                    existingRevision.revision == 1,
                    existingRevision.kind == row.values.kind.rawValue,
                    existingRevision.localDay == row.values.day.key,
                    existingRevision.minutes == row.values.minutes,
                    existingRevision.note == row.values.note
                else {
                    throw CSVImportRepositoryError.identityCollision
                }
                throw CSVImportRepositoryError.transactionFailed
            }

            if let matching = activeManualEntries.first(where: {
                !consumedManualIDs.contains($0.id)
                    && $0.entry.kind == row.values.kind
                    && $0.entry.day == row.values.day
                    && $0.entry.minutes == row.values.minutes
                    && $0.entry.note == row.values.note
            }) {
                consumedManualIDs.insert(matching.id)
                possibleMatches.append(row)
            } else {
                newRows.append(row)
            }
        }

        return CSVImportClassification(
            previouslyImported: previouslyImported,
            possibleMatches: possibleMatches,
            newRows: newRows
        )
    }

    static func csvImportResult(
        plan: CSVImportRetryPlan,
        importedCount: Int? = nil
    ) -> CSVImportResult {
        let imported = importedCount ?? plan.selectedRows.count
        guard imported > 0 else {
            return CSVImportResult(
                importedCount: 0,
                previouslyImportedCount: plan.previouslyImportedCount,
                skippedPossibleMatchCount: plan.skippedPossibleMatchCount,
                undoToken: nil
            )
        }
        let members = plan.selectedRows.map {
            CSVImportUndoMember(
                entryID: $0.entryID,
                importMutationID: $0.mutationID,
                expectedRevision: 1,
                undoMutationID: csvImportUndoMutationID(
                    entryID: $0.entryID,
                    importMutationID: $0.mutationID
                )
            )
        }
        let token = CSVImportUndoToken(
            id: csvImportUndoTokenID(members: members),
            members: members,
            importedAt: plan.authorizationTime,
            expiresAt: plan.authorizationTime.addingTimeInterval(Self.undoWindow)
        )
        return CSVImportResult(
            importedCount: imported,
            previouslyImportedCount: plan.previouslyImportedCount,
            skippedPossibleMatchCount: plan.skippedPossibleMatchCount,
            undoToken: token
        )
    }

    func applyCSVImportOnce(
        _ document: CSVImportDocument,
        policy: CSVImportDuplicatePolicy,
        authorizationTime: Date
    ) throws -> CSVImportResult {
        try performMutation { context in
            let before = try Self.snapshot(in: context)
            let classification = try Self.classifyCSVImport(document, in: before)
            let selectedRows: [CSVImportRow]
            let skippedPossibleMatchCount: Int
            switch policy {
            case .skipPossibleMatches:
                selectedRows = classification.newRows
                skippedPossibleMatchCount = classification.possibleMatches.count
            case .includePossibleMatches:
                selectedRows = classification.newRows + classification.possibleMatches
                skippedPossibleMatchCount = 0
            }

            let plan = CSVImportRetryPlan(
                selectedRows: selectedRows,
                previouslyImportedCount: classification.previouslyImported.count,
                skippedPossibleMatchCount: skippedPossibleMatchCount,
                authorizationTime: authorizationTime
            )
            guard !selectedRows.isEmpty else {
                return Self.csvImportResult(plan: plan, importedCount: 0)
            }

            for row in selectedRows {
                guard
                    try Self.entry(in: context, id: row.entryID) == nil,
                    try Self.revision(in: context, mutationID: row.mutationID) == nil
                else {
                    throw CSVImportRepositoryError.identityCollision
                }
                let values: EntryMutationValues
                do {
                    guard let validated = try Self.validatedValues(
                        row.values,
                        in: context,
                        authorizationTime: authorizationTime
                    ) else {
                        throw CSVImportRepositoryError.validationFailed
                    }
                    values = validated
                } catch let error as CSVImportRepositoryError {
                    throw error
                } catch {
                    throw CSVImportRepositoryError.validationFailed
                }

                let object = context.insert(EntryEntity.self)
                object.id = row.entryID
                Self.write(values, to: object)
                object.createdAt = authorizationTime
                object.updatedAt = authorizationTime
                object.deletedAt = nil
                object.source = EntryMutationSource.csvImport.rawValue
                object.revision = 1
                object.lastMutationID = row.mutationID
                Self.appendRevision(
                    for: object,
                    in: context,
                    mutationID: row.mutationID,
                    parentMutationID: nil,
                    operation: EntryMutationOperation.create.rawValue,
                    source: EntryMutationSource.csvImport.rawValue,
                    occurredAt: authorizationTime
                )
            }

            do {
                try Self.reconcileReportLifecycleAfterChange(
                    in: context,
                    before: before,
                    asOf: authorizationTime
                )
            } catch {
                throw CSVImportRepositoryError.transactionFailed
            }

            do {
                try self.csvImportFaultInjector(.importBeforeSave)
                try Self.saveIfNeeded(context)
            } catch {
                throw CSVImportRepositoryError.transactionFailed
            }

            do {
                try self.csvImportFaultInjector(.importAfterSaveBeforeReadback)
                context.refreshAllObjects()
                let after = try Self.snapshot(in: context)
                guard selectedRows.allSatisfy({ Self.csvImportRowIsExact($0, in: after) }) else {
                    throw CSVImportRepositoryError.verificationFailed
                }
                let finalClassification = try Self.classifyCSVImport(document, in: after)
                guard
                    finalClassification.previouslyImported.count
                        == classification.previouslyImported.count + selectedRows.count,
                    finalClassification.possibleMatches.count == skippedPossibleMatchCount,
                    finalClassification.newRows.isEmpty
                else {
                    throw CSVImportRepositoryError.verificationFailed
                }
            } catch {
                throw CSVImportRetry.import(plan)
            }
            return Self.csvImportResult(plan: plan)
        }
    }

    func replayOrRetryCSVImport(
        _ plan: CSVImportRetryPlan,
        document: CSVImportDocument,
        policy: CSVImportDuplicatePolicy,
        authorizationTime: Date
    ) throws -> CSVImportResult {
        let statuses = try perform { context in
            let snapshot = try Self.snapshot(in: context)
            return plan.selectedRows.map { Self.csvImportReplayStatus($0, in: snapshot) }
        }
        if statuses.allSatisfy({ $0 == .exact }) {
            return Self.csvImportResult(plan: plan)
        }
        guard statuses.allSatisfy({ $0 == .absent }) else {
            throw CSVImportRepositoryError.verificationFailed
        }
        return try applyCSVImportOnce(
            document,
            policy: policy,
            authorizationTime: authorizationTime
        )
    }

    static func csvImportReplayStatus(
        _ row: CSVImportRow,
        in snapshot: LedgerSnapshot
    ) -> CSVImportReplayStatus {
        if Self.csvImportRowIsExact(row, in: snapshot) { return .exact }
        if snapshot.entries.contains(where: { $0.id == row.entryID })
            || snapshot.entryRevisions.contains(where: { $0.mutationID == row.mutationID }) {
            return .mismatch
        }
        return .absent
    }

    static func csvImportRowIsExact(
        _ row: CSVImportRow,
        in snapshot: LedgerSnapshot
    ) -> Bool {
        guard let entry = snapshot.entries.first(where: { $0.id == row.entryID }) else {
            return false
        }
        guard
            !entry.isDeleted,
            entry.revision == 1,
            entry.lastMutationID == row.mutationID,
            entry.source == EntryMutationSource.csvImport.rawValue,
            entry.entry.kind == row.values.kind,
            entry.entry.day == row.values.day,
            entry.entry.minutes == row.values.minutes,
            entry.entry.note == row.values.note,
            let revision = snapshot.entryRevisions.first(where: {
                $0.mutationID == row.mutationID
            })
        else { return false }
        return revision.entryID == row.entryID
            && revision.revision == 1
            && revision.operation == EntryMutationOperation.create.rawValue
            && revision.source == EntryMutationSource.csvImport.rawValue
            && revision.kind == row.values.kind.rawValue
            && revision.localDay == row.values.day.key
            && revision.minutes == row.values.minutes
            && revision.note == row.values.note
    }

    static func validateCSVImportUndoToken(
        _ token: CSVImportUndoToken,
        asOf now: Date
    ) throws {
        guard
            token.expiresAt == token.importedAt.addingTimeInterval(Self.undoWindow),
            now >= token.importedAt,
            now < token.expiresAt
        else { throw CSVImportRepositoryError.undoExpired }
        guard
            !token.members.isEmpty
        else { throw CSVImportRepositoryError.undoUnavailable }
        let entryIDs = token.members.map(\.entryID)
        let mutationIDs = token.members.map(\.importMutationID)
        let undoIDs = token.members.map(\.undoMutationID)
        guard
            Set(entryIDs).count == entryIDs.count,
            Set(mutationIDs).count == mutationIDs.count,
            Set(undoIDs).count == undoIDs.count,
            token.members.allSatisfy({
                $0.expectedRevision == 1
                    && $0.undoMutationID == Self.csvImportUndoMutationID(
                        entryID: $0.entryID,
                        importMutationID: $0.importMutationID
                    )
            })
        else { throw CSVImportRepositoryError.undoUnavailable }
    }

    static func csvImportUndoMemberState(
        _ member: CSVImportUndoMember,
        in snapshot: LedgerSnapshot
    ) -> CSVImportUndoMemberState {
        guard let entry = snapshot.entries.first(where: { $0.id == member.entryID }) else {
            return .mismatch
        }
        guard let importedRevision = snapshot.entryRevisions.first(where: {
            $0.mutationID == member.importMutationID
        }) else { return .mismatch }
        guard
            importedRevision.entryID == member.entryID,
            importedRevision.revision == member.expectedRevision,
            importedRevision.operation == EntryMutationOperation.create.rawValue,
            importedRevision.source == EntryMutationSource.csvImport.rawValue
        else { return .mismatch }

        if entry.revision == member.expectedRevision,
           !entry.isDeleted,
           entry.lastMutationID == member.importMutationID {
            guard !snapshot.entryRevisions.contains(where: {
                $0.mutationID == member.undoMutationID
            }) else { return .mismatch }
            return .active
        }

        guard
            entry.isDeleted,
            entry.revision == member.expectedRevision + 1,
            entry.lastMutationID == member.undoMutationID,
            let undoRevision = snapshot.entryRevisions.first(where: {
                $0.mutationID == member.undoMutationID
            }),
            undoRevision.entryID == member.entryID,
            undoRevision.revision == member.expectedRevision + 1,
            undoRevision.operation == EntryMutationOperation.undo.rawValue,
            undoRevision.source == EntryMutationSource.undo.rawValue,
            undoRevision.revertedMutationID == member.importMutationID
        else { return .mismatch }
        return .alreadyUndone
    }

    func undoCSVImportOnce(
        _ token: CSVImportUndoToken,
        authorizationTime: Date
    ) throws -> CSVImportUndoResult {
        try performMutation { context in
            try Self.validateCSVImportUndoToken(token, asOf: authorizationTime)
            let before = try Self.snapshot(in: context)
            let states = token.members.map {
                Self.csvImportUndoMemberState($0, in: before)
            }
            if states.allSatisfy({ $0 == .alreadyUndone }) {
                return CSVImportUndoResult(deletedCount: token.members.count)
            }
            guard states.allSatisfy({ $0 == .active }) else {
                throw CSVImportRepositoryError.undoUnavailable
            }

            for member in token.members {
                guard let object = try Self.entry(in: context, id: member.entryID) else {
                    throw CSVImportRepositoryError.undoUnavailable
                }
                guard
                    object.revision == member.expectedRevision,
                    object.deletedAt == nil,
                    object.lastMutationID == member.importMutationID
                else { throw CSVImportRepositoryError.undoUnavailable }
                let nextRevision = try Self.nextRevision(after: object.revision)
                let parentMutationID = object.lastMutationID
                object.deletedAt = authorizationTime
                object.updatedAt = authorizationTime
                object.source = EntryMutationSource.undo.rawValue
                object.revision = nextRevision
                object.lastMutationID = member.undoMutationID
                Self.appendRevision(
                    for: object,
                    in: context,
                    mutationID: member.undoMutationID,
                    parentMutationID: parentMutationID,
                    revertedMutationID: member.importMutationID,
                    operation: EntryMutationOperation.undo.rawValue,
                    source: EntryMutationSource.undo.rawValue,
                    occurredAt: authorizationTime
                )
            }

            do {
                try Self.reconcileReportLifecycleAfterChange(
                    in: context,
                    before: before,
                    asOf: authorizationTime
                )
                try self.csvImportFaultInjector(.undoBeforeSave)
                try Self.saveIfNeeded(context)
            } catch {
                throw CSVImportRepositoryError.transactionFailed
            }

            do {
                try self.csvImportFaultInjector(.undoAfterSaveBeforeReadback)
                context.refreshAllObjects()
                let after = try Self.snapshot(in: context)
                guard token.members.allSatisfy({
                    Self.csvImportUndoMemberState($0, in: after) == .alreadyUndone
                }) else {
                    throw CSVImportRepositoryError.verificationFailed
                }
            } catch {
                throw CSVImportRetry.undo(
                    CSVImportUndoRetryPlan(
                        token: token,
                        authorizationTime: authorizationTime
                    )
                )
            }
            return CSVImportUndoResult(deletedCount: token.members.count)
        }
    }

    func replayOrRetryCSVImportUndo(
        _ plan: CSVImportUndoRetryPlan,
        authorizationTime: Date
    ) throws -> CSVImportUndoResult {
        try Self.validateCSVImportUndoToken(plan.token, asOf: authorizationTime)
        let states = try perform { context in
            let snapshot = try Self.snapshot(in: context)
            return plan.token.members.map {
                Self.csvImportUndoMemberState($0, in: snapshot)
            }
        }
        if states.allSatisfy({ $0 == .alreadyUndone }) {
            return CSVImportUndoResult(deletedCount: plan.token.members.count)
        }
        guard states.allSatisfy({ $0 == .active }) else {
            throw CSVImportRepositoryError.undoUnavailable
        }
        return try undoCSVImportOnce(
            plan.token,
            authorizationTime: authorizationTime
        )
    }

    static func csvImportUndoMutationID(
        entryID: UUID,
        importMutationID: UUID
    ) -> UUID {
        deterministicCSVImportUUID(fields: [
            CSVImportIdentity.namespace,
            "undo",
            entryID.uuidString,
            importMutationID.uuidString
        ])
    }

    static func csvImportUndoTokenID(
        members: [CSVImportUndoMember]
    ) -> UUID {
        var fields = [CSVImportIdentity.namespace, "batch-undo"]
        for member in members.sorted(by: { $0.entryID.uuidString < $1.entryID.uuidString }) {
            fields.append(member.entryID.uuidString)
            fields.append(member.importMutationID.uuidString)
            fields.append(member.undoMutationID.uuidString)
        }
        return deterministicCSVImportUUID(fields: fields)
    }

    static func deterministicCSVImportUUID(fields: [String]) -> UUID {
        let digest = SHA256.hash(data: CSVImportIdentity.frame(fields: fields))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

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
                    .timer,
                    .csvImport
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
        request.predicate = NSPredicate(
            format: "source != %@ AND source != %@",
            EntryMutationSource.migration.rawValue,
            EntryMutationSource.csvImport.rawValue
        )
        request.sortDescriptors = [
            NSSortDescriptor(key: "occurredAt", ascending: false),
            NSSortDescriptor(key: "mutationID", ascending: false)
        ]
        request.fetchBatchSize = 100
        for object in try context.fetch(request) {
            guard let revision = entryRevisionRecord(from: object) else {
                throw LedgerRepositoryError.invalidManagedObject("A saved entry revision is incomplete or invalid.")
            }
            guard
                let entry = try entry(in: context, id: revision.entryID),
                let record = entryRecord(from: entry),
                record.lastMutationID == revision.mutationID,
                record.revision == revision.revision
            else {
                // Older revisions can sort before the current head when two
                // commands share an exact timestamp. Keep looking instead of
                // hiding a valid Undo action behind a random UUID tie-break.
                continue
            }
            guard let operation = EntryMutationOperation(rawValue: revision.operation), operation.isUndoable else {
                return nil
            }
            let age = asOf.timeIntervalSince(revision.occurredAt)
            guard age >= 0, age < undoWindow else { return nil }
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
        return nil
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
        try validateServiceYearArchiveGraph(archives: archives)

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
            let state = object.state.flatMap(ReportLifecycleState.init(rawValue:)),
            let updatedAt = object.updatedAt
        else { return nil }
        let lastStableState: ReportLifecycleState?
        if let rawLastStableState = object.lastStableState {
            guard let parsed = ReportLifecycleState(rawValue: rawLastStableState) else { return nil }
            lastStableState = parsed
        } else {
            lastStableState = nil
        }
        return ReportStateRecord(
            id: id,
            month: month,
            state: state,
            lastStableState: lastStableState,
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
        var snapshotsByMonth: [MonthKey: [ReportSnapshotMetadata]] = [:]
        for snapshot in snapshots {
            guard snapshotsByID.updateValue(snapshot, forKey: snapshot.id) == nil else {
                throw LedgerRepositoryError.invalidManagedObject("Saved reports contain a duplicate identifier.")
            }
            snapshotsByMonth[snapshot.receipt.month, default: []].append(snapshot)
        }

        var newestSnapshotIDByMonth: [MonthKey: UUID] = [:]
        for (month, monthSnapshots) in snapshotsByMonth {
            try validateVersionSeries(
                monthSnapshots.sorted { ($0.version, $0.id.uuidString) < ($1.version, $1.id.uuidString) },
                seriesDescription: "Saved reports for \(month.key)",
                id: \.id,
                version: \.version,
                supersedesID: \.supersedesID
            )
            guard let newest = monthSnapshots.max(by: reportSnapshotOrder) else {
                throw LedgerRepositoryError.invalidManagedObject("Saved reports are missing a newest version.")
            }
            newestSnapshotIDByMonth[month] = newest.id
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
                if state.state == .sent, current.receipt.confirmedSentAt == nil {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A sent report state points to a report that was not confirmed sent."
                    )
                }
                if state.state == .prepared, current.receipt.confirmedSentAt != nil {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "A prepared report state points to a sent report snapshot."
                    )
                }
                if newestSnapshotIDByMonth[state.month] != currentSnapshotID {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "Saved report state does not point to the newest report snapshot."
                    )
                }
            } else if state.state == .prepared || state.state == .sent {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Prepared and sent report states require a current report snapshot."
                )
            }
        }
        for (month, newestSnapshotID) in newestSnapshotIDByMonth {
            guard states.contains(where: { $0.month == month && $0.currentSnapshotID == newestSnapshotID }) else {
                throw LedgerRepositoryError.invalidManagedObject(
                    "Saved report state does not point to the newest report snapshot."
                )
            }
        }
    }

    static func validateServiceYearArchiveGraph(
        archives: [ServiceYearArchiveRecord]
    ) throws {
        var archiveIDs = Set<UUID>()
        let grouped = Dictionary(grouping: archives) { "\($0.startMonth.key)|\($0.endMonth.key)" }
        for archive in archives {
            guard archiveIDs.insert(archive.id).inserted else {
                throw LedgerRepositoryError.invalidManagedObject("Saved service-year archives contain a duplicate identifier.")
            }
            if archive.calculationFingerprint.hasPrefix("service-year-v1:") {
                guard archive.startMonth.month == GoalPolicy.regularPioneer.startMonth else {
                    throw LedgerRepositoryError.invalidManagedObject("A saved service-year archive has an invalid start month.")
                }
                guard archive.endMonth == archive.startMonth.advanced(by: 11, calendar: .hourleaf) else {
                    throw LedgerRepositoryError.invalidManagedObject("A saved service-year archive has an invalid end month.")
                }
            }
        }
        for (series, members) in grouped {
            try validateVersionSeries(
                members.sorted { ($0.version, $0.id.uuidString) < ($1.version, $1.id.uuidString) },
                seriesDescription: "Saved archive series \(series)",
                id: \.id,
                version: \.version,
                supersedesID: \.supersedesID
            )
        }
    }

    static func validateVersionSeries<Record>(
        _ ordered: [Record],
        seriesDescription: String,
        id: (Record) -> UUID,
        version: (Record) -> Int,
        supersedesID: (Record) -> UUID?
    ) throws {
        let hasSupersedesEdges = ordered.contains { supersedesID($0) != nil }
        var priorID: UUID?
        for (offset, record) in ordered.enumerated() {
            let expected = offset + 1
            guard version(record) == expected else {
                throw LedgerRepositoryError.invalidManagedObject("\(seriesDescription) do not have contiguous versions.")
            }
            if hasSupersedesEdges {
                guard supersedesID(record) == priorID else {
                    throw LedgerRepositoryError.invalidManagedObject(
                        "\(seriesDescription) do not supersede the immediate prior version."
                    )
                }
            }
            priorID = id(record)
        }
    }

    static func stateRecord(
        for month: MonthKey,
        in snapshot: LedgerSnapshot
    ) -> ReportStateRecord? {
        snapshot.reportStates.first { $0.month == month }
    }

    static func reconcileReportLifecycleAfterChange(
        in context: NSManagedObjectContext,
        before: LedgerSnapshot,
        asOf now: Date
    ) throws {
        let afterChange = try snapshot(in: context)
        try reconcileLifecycleStateEntities(in: context, snapshot: afterChange, asOf: now)
        let reconciled = try snapshot(in: context)
        let months = Set(before.reportStates.map(\.month)).union(reconciled.reportStates.map(\.month))
        let changedDraftMonths = reportDraftChangedMonths(months: months, before: before, after: reconciled)

        for month in months where month >= reconciled.settings.ledgerStartMonth {
            guard let record = stateRecord(for: month, in: reconciled) else { continue }
            guard let state = try reportState(in: context, monthKey: month.key) else { continue }
            applyLifecycleReferenceIfNeeded(
                to: state,
                record: record,
                month: month,
                in: reconciled,
                changedDraftMonths: changedDraftMonths,
                asOf: now
            )
        }
    }

    static func reportDraftChangedMonths(
        months: Set<MonthKey>,
        before: LedgerSnapshot,
        after: LedgerSnapshot
    ) -> Set<MonthKey> {
        Set(months.filter { month in
            reportDraftIdentity(for: month, in: before) != reportDraftIdentity(for: month, in: after)
        })
    }

    static func reportDraftIdentity(
        for month: MonthKey,
        in snapshot: LedgerSnapshot
    ) -> DraftIdentity? {
        guard let draft = ReportReadiness.draft(for: month, in: snapshot) else { return nil }
        return DraftIdentity(
            calculationFingerprint: draft.calculationFingerprint,
            presentationFingerprint: draft.presentationFingerprint
        )
    }

    static func applyLifecycleReferenceIfNeeded(
        to state: ReportStateEntity,
        record: ReportStateRecord,
        month: MonthKey,
        in snapshot: LedgerSnapshot,
        changedDraftMonths: Set<MonthKey>,
        asOf now: Date
    ) {
        guard month < ReportReadiness.currentMonth(asOf: now) else { return }

        let reference: StableReportReference?
        switch record.state {
        case .draft, .ready:
            return
        case .reviewed:
            reference = .reviewed(
                calculationFingerprint: record.reviewedCalculationFingerprint,
                presentationFingerprint: record.reviewedPresentationFingerprint
            )
        case .prepared, .sent:
            reference = stableSnapshotReference(for: record, in: snapshot)
        case .changed:
            switch record.lastStableState {
            case .reviewed?:
                reference = .reviewed(
                    calculationFingerprint: record.reviewedCalculationFingerprint,
                    presentationFingerprint: record.reviewedPresentationFingerprint
                )
            case .prepared?, .sent?:
                reference = stableSnapshotReference(for: record, in: snapshot)
            case .draft?, .ready?, .changed?, nil:
                reference = nil
            }
        }

        guard let reference else { return }
        let matchesCurrentDraft = reference.matches(month: month, in: snapshot)
        let explicitLegacyChange = reference.requiresExplicitMutationInvalidation
            && changedDraftMonths.contains(month)

        if record.state == .changed {
            guard matchesCurrentDraft, reference.allowsAutoRestore else { return }
            restoreLifecycleState(state, from: record, at: now)
            return
        }

        guard !matchesCurrentDraft || explicitLegacyChange else { return }
        transitionLifecycleStateToChanged(state, from: record, at: now)
    }

    static func stableSnapshotReference(
        for record: ReportStateRecord,
        in snapshot: LedgerSnapshot
    ) -> StableReportReference? {
        guard let snapshotID = record.currentSnapshotID,
              let metadata = snapshot.reportSnapshots.first(where: { $0.id == snapshotID }) else {
            return nil
        }
        return .snapshot(metadata)
    }

    static func snapshotReferenceMatchesCurrentDraft(
        _ metadata: ReportSnapshotMetadata,
        month: MonthKey,
        in ledger: LedgerSnapshot
    ) -> Bool {
        guard let draft = ReportReadiness.draft(for: month, in: ledger) else { return false }
        guard metadata.receipt.month == draft.month else { return false }

        if let storedCalculation = metadata.calculationFingerprint,
           storedCalculation.hasPrefix("v2:") {
            return metadata.schemaVersion == 2
                && metadata.createdBySource == ReportReadiness.reportSnapshotSource
                && !metadata.legacyCalculationUnavailable
                && metadata.calculationFingerprint == draft.calculationFingerprint
                && metadata.presentationFingerprint == draft.presentationFingerprint
        }

        return ReportReadiness.snapshotMatchesDraft(metadata, draft: draft, ledger: ledger)
    }

    static func restoreLifecycleState(
        _ state: ReportStateEntity,
        from record: ReportStateRecord,
        at timestamp: Date
    ) {
        guard let restored = record.lastStableState else { return }
        state.state = restored.rawValue
        state.lastStableState = nil
        state.changedAt = nil
        state.updatedAt = timestamp
    }

    static func transitionLifecycleStateToChanged(
        _ state: ReportStateEntity,
        from record: ReportStateRecord,
        at timestamp: Date
    ) {
        guard record.state != .changed else { return }
        state.state = ReportLifecycleState.changed.rawValue
        state.lastStableState = record.state.rawValue
        state.changedAt = timestamp
        state.updatedAt = timestamp
    }

    static func effectiveLifecycleState(
        for month: MonthKey,
        snapshot: LedgerSnapshot,
        asOf now: Date
    ) -> ReportLifecycleState {
        if !ReportReadiness.isClosedMonth(month, asOf: now) {
            return .draft
        }
        if let state = stateRecord(for: month, in: snapshot) {
            if state.state == .draft {
                return .ready
            }
            return state.state
        }
        if let head = newestSnapshot(for: month, in: snapshot) {
            return head.receipt.confirmedSentAt == nil ? .prepared : .sent
        }
        return .ready
    }

    static func newestSnapshot(
        for month: MonthKey,
        in snapshot: LedgerSnapshot
    ) -> ReportSnapshotMetadata? {
        snapshot.reportSnapshots
            .filter { $0.receipt.month == month }
            .max(by: reportSnapshotOrder)
    }

    static func reconcileLifecycleStateEntities(
        in context: NSManagedObjectContext,
        snapshot: LedgerSnapshot,
        asOf now: Date
    ) throws {
        let currentMonth = ReportReadiness.currentMonth(asOf: now)
        let previousMonth = currentMonth.advanced(by: -1, calendar: .hourleaf)

        for record in snapshot.reportStates {
            guard let state = try reportState(in: context, monthKey: record.month.key) else { continue }
            if record.month >= currentMonth {
                state.state = ReportLifecycleState.draft.rawValue
                state.updatedAt = now
                continue
            }
            if record.state == .draft {
                state.state = ReportLifecycleState.ready.rawValue
                state.updatedAt = now
            }
        }

        guard previousMonth >= snapshot.settings.ledgerStartMonth else { return }
        if try reportState(in: context, monthKey: previousMonth.key) == nil {
            let state = insertState(month: previousMonth, in: context, at: now)
            if let newest = newestSnapshot(for: previousMonth, in: snapshot) {
                state.currentSnapshotID = newest.id
                state.state = newest.receipt.confirmedSentAt == nil
                    ? ReportLifecycleState.prepared.rawValue
                    : ReportLifecycleState.sent.rawValue
            } else {
                state.state = ReportLifecycleState.ready.rawValue
            }
        }
    }

    static func insertState(
        month: MonthKey,
        in context: NSManagedObjectContext,
        at timestamp: Date
    ) -> ReportStateEntity {
        let state = context.insert(ReportStateEntity.self)
        state.id = UUID()
        state.monthKey = month.key
        state.updatedAt = timestamp
        return state
    }

    static func requireReportDraft(
        for month: MonthKey,
        in snapshot: LedgerSnapshot
    ) throws -> ReportDraft {
        guard let draft = ReportReadiness.draft(for: month, in: snapshot) else {
            throw ReportLifecycleError.beforeLedgerStart
        }
        return draft
    }

    static func reportSnapshotEntity(
        in context: NSManagedObjectContext,
        id: UUID
    ) throws -> ReportReceiptEntity? {
        let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let objects = try context.fetch(request)
        _ = try decodeRequired(objects, entity: "ReportReceiptEntity", using: reportSnapshotMetadata)
        return objects.first
    }

    static func reportSnapshotSeries(
        in context: NSManagedObjectContext,
        month: MonthKey
    ) throws -> [ReportReceiptEntity] {
        let request: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        request.predicate = NSPredicate(format: "monthKey == %@", month.key)
        let objects = try context.fetch(request)
        _ = try decodeRequired(objects, entity: "ReportReceiptEntity", using: reportSnapshotMetadata)
        return objects.sorted { ($0.version, $0.id?.uuidString ?? "") < ($1.version, $1.id?.uuidString ?? "") }
    }

    static func serviceYearArchiveEntity(
        in context: NSManagedObjectContext,
        id: UUID
    ) throws -> ServiceYearArchiveEntity? {
        let request: NSFetchRequest<ServiceYearArchiveEntity> = ServiceYearArchiveEntity.request()
        request.fetchLimit = 1
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        let objects = try context.fetch(request)
        _ = try decodeRequired(objects, entity: "ServiceYearArchiveEntity", using: serviceYearArchiveRecord)
        return objects.first
    }

    static func serviceYearArchiveSeries(
        in context: NSManagedObjectContext,
        startMonth: MonthKey,
        endMonth: MonthKey
    ) throws -> [ServiceYearArchiveEntity] {
        let request: NSFetchRequest<ServiceYearArchiveEntity> = ServiceYearArchiveEntity.request()
        request.predicate = NSPredicate(
            format: "startMonthKey == %@ AND endMonthKey == %@",
            startMonth.key,
            endMonth.key
        )
        let objects = try context.fetch(request)
        _ = try decodeRequired(objects, entity: "ServiceYearArchiveEntity", using: serviceYearArchiveRecord)
        return objects.sorted { ($0.version, $0.id?.uuidString ?? "") < ($1.version, $1.id?.uuidString ?? "") }
    }

    static func serviceYearArchiveEntityMatchesDraft(
        _ object: ServiceYearArchiveEntity,
        draft: ServiceYearDraft
    ) -> Bool {
        guard let record = serviceYearArchiveRecord(from: object) else { return false }
        return ReportReadiness.archiveMatchesDraft(record, draft: draft)
    }

    static func nextVersion(
        in versions: [Int32],
        exhaustedError: ReportLifecycleError
    ) throws -> Int32 {
        let current = versions.max() ?? 0
        guard current < Int32.max else { throw exhaustedError }
        return current + 1
    }

    static func nextSupersedesID<Record>(
        for orderedSeries: [Record]
    ) -> UUID? where Record: NSManagedObject {
        guard !orderedSeries.isEmpty else { return nil }
        let idsAndSupersedes: [(UUID, UUID?)] = orderedSeries.compactMap { record in
            switch record {
            case let receipt as ReportReceiptEntity:
                guard let id = receipt.id else { return nil }
                return (id, receipt.supersedesID)
            case let archive as ServiceYearArchiveEntity:
                guard let id = archive.id else { return nil }
                return (id, archive.supersedesID)
            default:
                return nil
            }
        }
        guard idsAndSupersedes.count == orderedSeries.count else { return nil }
        let allNil = idsAndSupersedes.count > 1 && idsAndSupersedes.allSatisfy { $0.1 == nil }
        if allNil { return nil }
        return idsAndSupersedes.last?.0
    }

    static func clampedTimestamp(
        requested: Date,
        existing: [Date]
    ) -> Date {
        guard let maximum = existing.max() else { return requested }
        let minimumNext = maximum.addingTimeInterval(0.001)
        return requested > maximum ? requested : minimumNext
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

    static func reportSnapshotOrder(_ lhs: ReportSnapshotMetadata, _ rhs: ReportSnapshotMetadata) -> Bool {
        let lhsKey = (lhs.receipt.preparedAt, lhs.id.uuidString)
        let rhsKey = (rhs.receipt.preparedAt, rhs.id.uuidString)
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

#if DEBUG
extension CoreDataLedgerRepository {
    func testOnlySaveReceiptFixture(
        _ receipt: ReportReceipt,
        details: ReportSnapshotDetails?
    ) async throws {
        try await saveReceiptFixture(receipt, details: details)
    }
}
#endif

private extension EntryMutationOperation {
    var isUndoable: Bool {
        switch self {
        case .create, .update, .delete, .restore: true
        case .undo: false
        }
    }
}
