@preconcurrency import CoreData
import Foundation

enum RawBackupStoreError: LocalizedError, Equatable, Sendable {
    case malformedIdentifier(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case let .malformedIdentifier(value):
            "Hourleaf could not import a malformed stored identifier: \(value)"
        case let .saveFailed(reason):
            "Hourleaf could not write the staged local data: \(reason)"
        }
    }
}

/// The inverse of Slice 4's raw mapper. It writes storage attributes exactly
/// as verified by the frozen codec; it does not run app-domain projections,
/// merge records, invent defaults, or expose the result outside restore code.
enum RawBackupStore {
    typealias BatchCheckpoint = (_ entityGroup: String, _ batchIndex: Int) throws -> Void

    private static let maximumRecordsPerBatch = 256

    static func insert(
        _ records: HourleafBackupRecordsV1,
        into context: NSManagedObjectContext,
        checkpoint: BatchCheckpoint = { _, _ in }
    ) throws {
        var pendingRecords = 0
        var batchIndex = 0

        for value in records.acknowledgements {
            let object = context.insert(DayAcknowledgementEntity.self)
            object.createdAt = date(value.createdAt)
            object.id = try uuid(value.id)
            object.localDay = value.localDay
            object.source = value.source
            object.status = value.status
            object.updatedAt = date(value.updatedAt)
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.archives {
            let object = context.insert(ServiceYearArchiveEntity.self)
            object.actualServiceMinutes = value.actualServiceMinutes
            object.baselineServiceMinutes = value.baselineServiceMinutes
            object.calculationFingerprint = value.calculationFingerprint
            object.createdAt = date(value.createdAt)
            object.endMonthKey = value.endMonthKey
            object.id = try uuid(value.id)
            object.startMonthKey = value.startMonthKey
            object.supersedesID = try uuid(value.supersedesID)
            object.targetMinutes = value.targetMinutes
            object.version = value.version
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.entries {
            let object = context.insert(EntryEntity.self)
            object.createdAt = date(value.createdAt)
            object.deletedAt = date(value.deletedAt)
            object.id = try uuid(value.id)
            object.kind = value.kind
            object.lastMutationID = try uuid(value.lastMutationID)
            object.localDay = value.localDay
            object.minutes = value.minutes
            object.note = value.note
            object.revision = value.revision
            object.source = value.source
            object.updatedAt = date(value.updatedAt)
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.policies {
            let object = context.insert(PolicyRevisionEntity.self)
            object.carryAcrossServiceYear = value.carryAcrossServiceYear
            object.createdAt = date(value.createdAt)
            object.effectiveMonth = value.effectiveMonth
            object.id = try uuid(value.id)
            object.mode = value.mode
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.presets {
            let object = context.insert(PresetEntity.self)
            object.createdAt = date(value.createdAt)
            object.deletedAt = date(value.deletedAt)
            object.id = try uuid(value.id)
            object.kind = value.kind
            object.minutes = value.minutes
            object.position = value.position
            object.updatedAt = date(value.updatedAt)
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.receipts {
            let object = context.insert(ReportReceiptEntity.self)
            object.calculationFingerprint = value.calculationFingerprint
            object.confirmedSentAt = date(value.confirmedSentAt)
            object.createdBySource = value.createdBySource
            object.creditCarryIn = value.creditCarryIn
            object.creditCarryOut = value.creditCarryOut
            object.creditHours = value.creditHours
            object.creditLabel = value.creditLabel
            object.id = try uuid(value.id)
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
            object.supersedesID = try uuid(value.supersedesID)
            object.templateID = value.templateID
            object.version = value.version
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.reminders {
            let object = context.insert(ReminderEntity.self)
            object.createdAt = date(value.createdAt)
            object.hour = value.hour
            object.id = try uuid(value.id)
            object.isEnabled = value.isEnabled
            object.minute = value.minute
            object.updatedAt = date(value.updatedAt)
            object.weekday = value.weekday
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        for value in records.revisions {
            let object = context.insert(EntryRevisionEntity.self)
            object.entryCreatedAt = date(value.entryCreatedAt)
            object.entryDeletedAt = date(value.entryDeletedAt)
            object.entryID = try uuid(value.entryID)
            object.entryUpdatedAt = date(value.entryUpdatedAt)
            object.id = try uuid(value.id)
            object.kind = value.kind
            object.localDay = value.localDay
            object.minutes = value.minutes
            object.mutationID = try uuid(value.mutationID)
            object.note = value.note
            object.occurredAt = date(value.occurredAt)
            object.operation = value.operation
            object.parentMutationID = try uuid(value.parentMutationID)
            object.revertedMutationID = try uuid(value.revertedMutationID)
            object.revision = value.revision
            object.source = value.source
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        let settings = context.insert(SettingsEntity.self)
        settings.baselineServiceYearMinutes = records.settings.baselineServiceYearMinutes
        settings.baselineServiceYearStart = records.settings.baselineServiceYearStart
        settings.creditLabelEnglish = records.settings.creditLabelEnglish
        settings.creditLabelRussian = records.settings.creditLabelRussian
        settings.creditLabelUkrainian = records.settings.creditLabelUkrainian
        settings.dataRevision = records.settings.dataRevision
        settings.id = try uuid(records.settings.id)
        settings.lastPurgeAt = date(records.settings.lastPurgeAt)
        settings.ledgerStartMonth = records.settings.ledgerStartMonth
        settings.onboardingComplete = records.settings.onboardingComplete
        settings.openingCreditCarryMinutes = records.settings.openingCreditCarryMinutes
        settings.openingServiceCarryMinutes = records.settings.openingServiceCarryMinutes
        settings.planningVisible = records.settings.planningVisible
        settings.quietGapCheckEnabled = records.settings.quietGapCheckEnabled
        settings.quietGapDays = records.settings.quietGapDays
        settings.reportLanguage = records.settings.reportLanguage
        settings.syncMode = records.settings.syncMode
        settings.timerVisible = records.settings.timerVisible
        settings.updatedAt = date(records.settings.updatedAt)
        settings.widgetPrivacyMode = records.settings.widgetPrivacyMode
        try saveBatchIfNeeded(
            context,
            pendingRecords: &pendingRecords,
            batchIndex: &batchIndex,
            checkpoint: checkpoint
        )

        let bibleStudyCountsByMonth = Dictionary(
            uniqueKeysWithValues: records.bibleStudyCounts.compactMap { value in
                value.monthKey.map { ($0, value.count) }
            }
        )
        for value in records.states {
            let object = context.insert(ReportStateEntity.self)
            object.bibleStudyCount = value.monthKey.flatMap { bibleStudyCountsByMonth[$0] } ?? 0
            object.changedAt = date(value.changedAt)
            object.currentSnapshotID = try uuid(value.currentSnapshotID)
            object.id = try uuid(value.id)
            object.lastStableState = value.lastStableState
            object.monthKey = value.monthKey
            object.reviewedCalculationFingerprint = value.reviewedCalculationFingerprint
            object.reviewedPresentationFingerprint = value.reviewedPresentationFingerprint
            object.state = value.state
            object.updatedAt = date(value.updatedAt)
            try saveBatchIfNeeded(
                context,
                pendingRecords: &pendingRecords,
                batchIndex: &batchIndex,
                checkpoint: checkpoint
            )
        }

        try flush(
            context,
            pendingRecords: &pendingRecords,
            batchIndex: &batchIndex,
            checkpoint: checkpoint
        )
    }

    private static func date(_ value: Double?) -> Date? {
        value.map(Date.init(timeIntervalSinceReferenceDate:))
    }

    private static func uuid(_ value: String?) throws -> UUID? {
        guard let value else { return nil }
        guard let identifier = UUID(uuidString: value) else {
            throw RawBackupStoreError.malformedIdentifier(value)
        }
        return identifier
    }

    private static func saveBatchIfNeeded(
        _ context: NSManagedObjectContext,
        pendingRecords: inout Int,
        batchIndex: inout Int,
        checkpoint: BatchCheckpoint
    ) throws {
        pendingRecords += 1
        guard pendingRecords == maximumRecordsPerBatch else { return }
        try flush(
            context,
            pendingRecords: &pendingRecords,
            batchIndex: &batchIndex,
            checkpoint: checkpoint
        )
    }

    private static func flush(
        _ context: NSManagedObjectContext,
        pendingRecords: inout Int,
        batchIndex: inout Int,
        checkpoint: BatchCheckpoint
    ) throws {
        guard pendingRecords > 0 else { return }
        do {
            try context.save()
            context.reset()
            batchIndex += 1
            try checkpoint("rawRecords", batchIndex)
            pendingRecords = 0
        } catch let error as RawBackupStoreError {
            throw error
        } catch {
            throw RawBackupStoreError.saveFailed(error.localizedDescription)
        }
    }
}
