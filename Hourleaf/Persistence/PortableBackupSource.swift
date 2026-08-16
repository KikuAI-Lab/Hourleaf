@preconcurrency import CoreData
import Foundation

/// A deliberately narrow read seam for portable backups. It is separate from
/// `LedgerRepository` because ordinary app features do not need raw storage
/// values or the backup trust boundary.
protocol PortableBackupSource: Sendable {
    func portableBackupRecords() async throws -> HourleafBackupRecordsV1
}

extension HourleafBackupRecordsV1 {
    static func rawRecords(in context: NSManagedObjectContext) throws -> Self {
        let settings = try backupFetch(SettingsEntity.self, in: context)
        guard settings.count == 1, let setting = settings.first else {
            throw LedgerRepositoryError.invalidManagedObject(
                "Hourleaf settings must contain exactly one record before backup."
            )
        }
        let states = try backupFetch(ReportStateEntity.self, in: context)

        return Self(
            acknowledgements: try backupFetch(DayAcknowledgementEntity.self, in: context).map(HourleafDayAcknowledgementV1.init),
            archives: try backupFetch(ServiceYearArchiveEntity.self, in: context).map(HourleafServiceYearArchiveV1.init),
            bibleStudyCounts: states.compactMap(HourleafBibleStudyCountV2.init),
            entries: try backupFetch(EntryEntity.self, in: context).map(HourleafEntryV1.init),
            policies: try backupFetch(PolicyRevisionEntity.self, in: context).map(HourleafPolicyRevisionV1.init),
            presets: try backupFetch(PresetEntity.self, in: context).map(HourleafPresetV1.init),
            receipts: try backupFetch(ReportReceiptEntity.self, in: context).map(HourleafReportReceiptV1.init),
            reminders: try backupFetch(ReminderEntity.self, in: context).map(HourleafReminderV1.init),
            revisions: try backupFetch(EntryRevisionEntity.self, in: context).map(HourleafEntryRevisionV1.init),
            settings: HourleafSettingsV1(setting),
            states: states.map(HourleafReportStateV1.init)
        )
    }
}

private func backupFetch<T: NSManagedObject>(
    _ type: T.Type,
    in context: NSManagedObjectContext
) throws -> [T] {
    let request: NSFetchRequest<T> = T.request()
    return try context.fetch(request)
}

private func backupUUID(_ value: UUID?) -> String? {
    value?.uuidString.lowercased()
}

private func backupDate(_ value: Date?) -> Double? {
    value?.timeIntervalSinceReferenceDate
}

private extension HourleafDayAcknowledgementV1 {
    init(_ object: DayAcknowledgementEntity) {
        self.init(
            createdAt: backupDate(object.createdAt),
            id: backupUUID(object.id),
            localDay: object.localDay,
            source: object.source,
            status: object.status,
            updatedAt: backupDate(object.updatedAt)
        )
    }
}

private extension HourleafEntryV1 {
    init(_ object: EntryEntity) {
        self.init(
            createdAt: backupDate(object.createdAt),
            deletedAt: backupDate(object.deletedAt),
            id: backupUUID(object.id),
            kind: object.kind,
            lastMutationID: backupUUID(object.lastMutationID),
            localDay: object.localDay,
            minutes: object.minutes,
            note: object.note,
            revision: object.revision,
            source: object.source,
            updatedAt: backupDate(object.updatedAt)
        )
    }
}

private extension HourleafEntryRevisionV1 {
    init(_ object: EntryRevisionEntity) {
        self.init(
            entryCreatedAt: backupDate(object.entryCreatedAt),
            entryDeletedAt: backupDate(object.entryDeletedAt),
            entryID: backupUUID(object.entryID),
            entryUpdatedAt: backupDate(object.entryUpdatedAt),
            id: backupUUID(object.id),
            kind: object.kind,
            localDay: object.localDay,
            minutes: object.minutes,
            mutationID: backupUUID(object.mutationID),
            note: object.note,
            occurredAt: backupDate(object.occurredAt),
            operation: object.operation,
            parentMutationID: backupUUID(object.parentMutationID),
            revertedMutationID: backupUUID(object.revertedMutationID),
            revision: object.revision,
            source: object.source
        )
    }
}

private extension HourleafPolicyRevisionV1 {
    init(_ object: PolicyRevisionEntity) {
        self.init(
            carryAcrossServiceYear: object.carryAcrossServiceYear,
            createdAt: backupDate(object.createdAt),
            effectiveMonth: object.effectiveMonth,
            id: backupUUID(object.id),
            mode: object.mode
        )
    }
}

private extension HourleafPresetV1 {
    init(_ object: PresetEntity) {
        self.init(
            createdAt: backupDate(object.createdAt),
            deletedAt: backupDate(object.deletedAt),
            id: backupUUID(object.id),
            kind: object.kind,
            minutes: object.minutes,
            position: object.position,
            updatedAt: backupDate(object.updatedAt)
        )
    }
}

private extension HourleafReminderV1 {
    init(_ object: ReminderEntity) {
        self.init(
            createdAt: backupDate(object.createdAt),
            hour: object.hour,
            id: backupUUID(object.id),
            isEnabled: object.isEnabled,
            minute: object.minute,
            updatedAt: backupDate(object.updatedAt),
            weekday: object.weekday
        )
    }
}

private extension HourleafReportReceiptV1 {
    init(_ object: ReportReceiptEntity) {
        self.init(
            calculationFingerprint: object.calculationFingerprint,
            confirmedSentAt: backupDate(object.confirmedSentAt),
            createdBySource: object.createdBySource,
            creditCarryIn: object.creditCarryIn,
            creditCarryOut: object.creditCarryOut,
            creditHours: object.creditHours,
            creditLabel: object.creditLabel,
            id: backupUUID(object.id),
            legacyCalculationUnavailable: object.legacyCalculationUnavailable,
            monthKey: object.monthKey,
            presentationFingerprint: object.presentationFingerprint,
            preparedAt: backupDate(object.preparedAt),
            rawCreditMinutes: object.rawCreditMinutes,
            rawServiceMinutes: object.rawServiceMinutes,
            reportLanguage: object.reportLanguage,
            reportText: object.reportText,
            reportingMode: object.reportingMode,
            schemaVersion: object.schemaVersion,
            serviceCarryIn: object.serviceCarryIn,
            serviceCarryOut: object.serviceCarryOut,
            serviceHours: object.serviceHours,
            supersedesID: backupUUID(object.supersedesID),
            templateID: object.templateID,
            version: object.version
        )
    }
}

private extension HourleafReportStateV1 {
    init(_ object: ReportStateEntity) {
        self.init(
            changedAt: backupDate(object.changedAt),
            currentSnapshotID: backupUUID(object.currentSnapshotID),
            id: backupUUID(object.id),
            lastStableState: object.lastStableState,
            monthKey: object.monthKey,
            reviewedCalculationFingerprint: object.reviewedCalculationFingerprint,
            reviewedPresentationFingerprint: object.reviewedPresentationFingerprint,
            state: object.state,
            updatedAt: backupDate(object.updatedAt)
        )
    }
}

private extension HourleafBibleStudyCountV2 {
    init?(_ object: ReportStateEntity) {
        guard object.bibleStudyCount > 0 else { return nil }
        self.init(count: object.bibleStudyCount, monthKey: object.monthKey)
    }
}

private extension HourleafServiceYearArchiveV1 {
    init(_ object: ServiceYearArchiveEntity) {
        self.init(
            actualServiceMinutes: object.actualServiceMinutes,
            baselineServiceMinutes: object.baselineServiceMinutes,
            calculationFingerprint: object.calculationFingerprint,
            createdAt: backupDate(object.createdAt),
            endMonthKey: object.endMonthKey,
            id: backupUUID(object.id),
            startMonthKey: object.startMonthKey,
            supersedesID: backupUUID(object.supersedesID),
            targetMinutes: object.targetMinutes,
            version: object.version
        )
    }
}

private extension HourleafSettingsV1 {
    init(_ object: SettingsEntity) {
        self.init(
            baselineServiceYearMinutes: object.baselineServiceYearMinutes,
            baselineServiceYearStart: object.baselineServiceYearStart,
            creditLabelEnglish: object.creditLabelEnglish,
            creditLabelRussian: object.creditLabelRussian,
            creditLabelUkrainian: object.creditLabelUkrainian,
            dataRevision: object.dataRevision,
            id: backupUUID(object.id),
            lastPurgeAt: backupDate(object.lastPurgeAt),
            ledgerStartMonth: object.ledgerStartMonth,
            onboardingComplete: object.onboardingComplete,
            openingCreditCarryMinutes: object.openingCreditCarryMinutes,
            openingServiceCarryMinutes: object.openingServiceCarryMinutes,
            planningVisible: object.planningVisible,
            quietGapCheckEnabled: object.quietGapCheckEnabled,
            quietGapDays: object.quietGapDays,
            reportLanguage: object.reportLanguage,
            syncMode: object.syncMode,
            timerVisible: object.timerVisible,
            updatedAt: backupDate(object.updatedAt),
            widgetPrivacyMode: object.widgetPrivacyMode
        )
    }
}
