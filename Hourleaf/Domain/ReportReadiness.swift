import Foundation

struct ReviewReportRequest: Equatable, Sendable {
    let month: MonthKey
    let expectedCalculationFingerprint: String
    let expectedPresentationFingerprint: String
    let reviewedAt: Date
}

struct PrepareReportRequest: Equatable, Sendable {
    let month: MonthKey
    let expectedCalculationFingerprint: String
    let expectedPresentationFingerprint: String
    let snapshotID: UUID
    let preparedAt: Date
}

struct MarkReportSentRequest: Equatable, Sendable {
    let snapshotID: UUID
    let confirmedAt: Date
}

struct PreparedReportResult: Equatable, Sendable {
    let snapshot: ReportSnapshotMetadata
    let ledger: LedgerSnapshot
    let wasReplay: Bool
}

struct CloseServiceYearRequest: Equatable, Sendable {
    let startMonth: MonthKey
    let expectedCalculationFingerprint: String
    let archiveID: UUID
    let createdAt: Date
}

struct ServiceYearArchiveResult: Equatable, Sendable {
    let archive: ServiceYearArchiveRecord
    let ledger: LedgerSnapshot
    let wasReplay: Bool
}

enum ReportLifecycleError: LocalizedError, Equatable, Sendable {
    case beforeLedgerStart
    case monthStillOpen
    case reportChanged
    case reviewRequired
    case snapshotNotFound
    case invalidSnapshotHistory
    case receiptVersionExhausted
    case serviceYearStillOpen
    case archiveChanged
    case archiveVersionExhausted

    var errorDescription: String? {
        switch self {
        case .beforeLedgerStart:
            "This period is before Hourleaf started tracking your time."
        case .monthStillOpen:
            "This month is still in progress."
        case .reportChanged:
            "This report changed. Review it again before sharing."
        case .reviewRequired:
            "Review this report before preparing it."
        case .snapshotNotFound:
            "The prepared report snapshot could not be found."
        case .invalidSnapshotHistory:
            "Hourleaf found an invalid saved report history."
        case .receiptVersionExhausted:
            "Hourleaf cannot create another saved report version for this month."
        case .serviceYearStillOpen:
            "This service year has not finished yet."
        case .archiveChanged:
            "This service-year archive changed. Review it again before saving."
        case .archiveVersionExhausted:
            "Hourleaf cannot create another saved archive version for this service year."
        }
    }
}

struct ReportDraft: Equatable, Sendable {
    let month: MonthKey
    let report: MonthlyReport
    let entries: [TimeEntry]
    let reportingMode: RemainderMode
    let reportLanguage: ReportLanguage
    let creditLabel: String
    let templateID: String
    let text: String
    let calculationFingerprint: String
    let presentationFingerprint: String
}

struct ServiceYearDraft: Equatable, Sendable {
    let startMonth: MonthKey
    let endMonth: MonthKey
    let actualServiceMinutes: Int
    let baselineServiceMinutes: Int
    let targetMinutes: Int
    let calculationFingerprint: String
}

enum ReportReadiness {
    static let standardTemplateID = "standard"
    static let reportSnapshotSource = "reportReadinessV1"

    static func currentMonth(asOf now: Date) -> MonthKey {
        MonthKey(now, calendar: .hourleaf)
    }

    static func isClosedMonth(_ month: MonthKey, asOf now: Date) -> Bool {
        month < currentMonth(asOf: now)
    }

    static func draft(for month: MonthKey, in snapshot: LedgerSnapshot) -> ReportDraft? {
        guard month >= snapshot.settings.ledgerStartMonth else { return nil }

        let activeEntries = snapshot.activeEntries
        guard let report = ReportCalculator.timeline(
            entries: activeEntries,
            from: snapshot.settings.ledgerStartMonth,
            through: month,
            openingServiceCarry: snapshot.settings.openingServiceCarryMinutes,
            openingCreditCarry: snapshot.settings.openingCreditCarryMinutes,
            policies: snapshot.policies
        ).last else { return nil }

        let entries = activeEntries
            .filter { $0.day.monthKey == month }
            .sorted(by: reportEntryOrder)
        let reportingMode = ReportCalculator.policy(for: month, revisions: snapshot.policies).mode
        let reportLanguage = snapshot.settings.reportLanguage
        let creditLabel = snapshot.settings.creditLabel(for: reportLanguage)
        let text = ReportFormatter.format(report, settings: snapshot.settings)
        let calculationFingerprint = ReportFingerprint.calculationV2(
            report: report,
            entries: entries,
            mode: reportingMode
        )
        let presentationFingerprint = ReportFingerprint.presentationV2(
            calculationFingerprint: calculationFingerprint,
            templateID: standardTemplateID,
            text: text
        )

        return ReportDraft(
            month: month,
            report: report,
            entries: entries,
            reportingMode: reportingMode,
            reportLanguage: reportLanguage,
            creditLabel: creditLabel,
            templateID: standardTemplateID,
            text: text,
            calculationFingerprint: calculationFingerprint,
            presentationFingerprint: presentationFingerprint
        )
    }

    static func serviceYearDraft(
        starting startMonth: MonthKey,
        in snapshot: LedgerSnapshot,
        goalPolicy: GoalPolicy = .regularPioneer
    ) -> ServiceYearDraft? {
        guard startMonth.month == goalPolicy.startMonth else { return nil }

        let endMonth = startMonth.advanced(by: 11, calendar: .hourleaf)
        guard endMonth >= snapshot.settings.ledgerStartMonth else { return nil }

        let endExclusiveMonth = endMonth.advanced(by: 1, calendar: .hourleaf)
        let serviceEntries = snapshot.activeEntries.filter {
            $0.kind == .service
                && $0.day.monthKey >= startMonth
                && $0.day.monthKey < endExclusiveMonth
        }
        let actualServiceMinutes = serviceEntries.reduce(0) { $0 + $1.minutes }
        let baselineServiceMinutes = snapshot.settings.baselineServiceYearStart == startMonth
            ? max(0, snapshot.settings.baselineServiceYearMinutes)
            : 0
        let targetMinutes = goalPolicy.targetMinutes
        let calculationFingerprint = ServiceYearFingerprint.calculation(
            startMonth: startMonth,
            endMonth: endMonth,
            actualServiceMinutes: actualServiceMinutes,
            baselineServiceMinutes: baselineServiceMinutes,
            targetMinutes: targetMinutes,
            entries: serviceEntries
        )

        return ServiceYearDraft(
            startMonth: startMonth,
            endMonth: endMonth,
            actualServiceMinutes: actualServiceMinutes,
            baselineServiceMinutes: baselineServiceMinutes,
            targetMinutes: targetMinutes,
            calculationFingerprint: calculationFingerprint
        )
    }

    static func snapshotMatchesDraft(
        _ snapshot: ReportSnapshotMetadata,
        month: MonthKey,
        in ledger: LedgerSnapshot
    ) -> Bool {
        guard let draft = draft(for: month, in: ledger) else { return false }
        return snapshotMatchesDraft(snapshot, draft: draft, ledger: ledger)
    }

    static func snapshotMatchesDraft(
        _ snapshot: ReportSnapshotMetadata,
        draft: ReportDraft,
        ledger: LedgerSnapshot
    ) -> Bool {
        guard snapshot.receipt.month == draft.month else { return false }

        if let storedCalculation = snapshot.calculationFingerprint,
           storedCalculation.hasPrefix("v2:") {
            return snapshotMatchesImmutableFields(
                snapshot,
                report: draft.report,
                reportingMode: draft.reportingMode.rawValue,
                reportLanguage: draft.reportLanguage.rawValue,
                creditLabel: draft.creditLabel,
                templateID: draft.templateID,
                calculationFingerprint: draft.calculationFingerprint,
                presentationFingerprint: draft.presentationFingerprint,
                text: draft.text
            )
        }

        if snapshot.legacyCalculationUnavailable {
            return snapshotMatchesScalarFields(snapshot, report: draft.report, text: draft.text)
        }

        let calculationFingerprint = ReportFingerprint.calculation(
                report: draft.report,
                entries: ledger.activeEntries,
                settings: ledger.settings,
                policies: ledger.policies
        )
        let presentationFingerprint = ReportFingerprint.presentation(
            calculationFingerprint: calculationFingerprint,
            language: draft.reportLanguage,
            creditLabel: draft.creditLabel,
            templateID: draft.templateID,
            text: draft.text
        )
        return snapshotMatchesV1Fields(
            snapshot,
            report: draft.report,
            reportingMode: draft.reportingMode.rawValue,
            reportLanguage: draft.reportLanguage.rawValue,
            creditLabel: draft.creditLabel,
            templateID: draft.templateID,
            calculationFingerprint: calculationFingerprint,
            presentationFingerprint: presentationFingerprint,
            text: draft.text
        )
    }

    static func snapshotMatchesImmutableFields(
        _ snapshot: ReportSnapshotMetadata,
        report: MonthlyReport,
        reportingMode: String,
        reportLanguage: String,
        creditLabel: String,
        templateID: String,
        calculationFingerprint: String,
        presentationFingerprint: String,
        text: String
    ) -> Bool {
        snapshot.schemaVersion == 2
            && snapshot.rawServiceMinutes == report.rawServiceMinutes
            && snapshot.rawCreditMinutes == report.rawCreditMinutes
            && snapshot.serviceCarryIn == report.serviceCarryIn
            && snapshot.creditCarryIn == report.creditCarryIn
            && snapshot.receipt.serviceHours == report.serviceHours
            && snapshot.receipt.creditHours == report.creditHours
            && snapshot.receipt.serviceCarryOut == report.serviceCarryOut
            && snapshot.receipt.creditCarryOut == report.creditCarryOut
            && snapshot.reportingMode == reportingMode
            && snapshot.reportLanguage == reportLanguage
            && snapshot.creditLabel == creditLabel
            && snapshot.templateID == templateID
            && snapshot.calculationFingerprint == calculationFingerprint
            && snapshot.presentationFingerprint == presentationFingerprint
            && snapshot.createdBySource == reportSnapshotSource
            && !snapshot.legacyCalculationUnavailable
            && snapshot.receipt.text == text
    }

    static func snapshotMatchesV1Fields(
        _ snapshot: ReportSnapshotMetadata,
        report: MonthlyReport,
        reportingMode: String,
        reportLanguage: String,
        creditLabel: String,
        templateID: String,
        calculationFingerprint: String,
        presentationFingerprint: String,
        text: String
    ) -> Bool {
        snapshot.schemaVersion == 1
            && snapshotMatchesScalarFields(snapshot, report: report, text: text)
            && snapshot.reportingMode == reportingMode
            && snapshot.reportLanguage == reportLanguage
            && snapshot.creditLabel == creditLabel
            && snapshot.templateID == templateID
            && snapshot.calculationFingerprint == calculationFingerprint
            && snapshot.presentationFingerprint == presentationFingerprint
            && !snapshot.legacyCalculationUnavailable
    }

    static func snapshotMatchesScalarFields(
        _ snapshot: ReportSnapshotMetadata,
        report: MonthlyReport,
        text: String
    ) -> Bool {
        snapshot.rawServiceMinutes == report.rawServiceMinutes
            && snapshot.rawCreditMinutes == report.rawCreditMinutes
            && snapshot.serviceCarryIn == report.serviceCarryIn
            && snapshot.creditCarryIn == report.creditCarryIn
            && snapshot.receipt.serviceHours == report.serviceHours
            && snapshot.receipt.creditHours == report.creditHours
            && snapshot.receipt.serviceCarryOut == report.serviceCarryOut
            && snapshot.receipt.creditCarryOut == report.creditCarryOut
            && snapshot.receipt.text == text
    }

    static func archiveMatchesDraft(
        _ archive: ServiceYearArchiveRecord,
        draft: ServiceYearDraft
    ) -> Bool {
        archive.startMonth == draft.startMonth
            && archive.endMonth == draft.endMonth
            && archive.actualServiceMinutes == draft.actualServiceMinutes
            && archive.baselineServiceMinutes == draft.baselineServiceMinutes
            && archive.targetMinutes == draft.targetMinutes
            && archive.calculationFingerprint == draft.calculationFingerprint
    }

    private static func reportEntryOrder(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
