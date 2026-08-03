import Foundation

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

    private static func reportEntryOrder(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}
