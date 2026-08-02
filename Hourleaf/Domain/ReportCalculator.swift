import Foundation

enum ReportCalculator {
    static func timeline(
        entries: [TimeEntry],
        from start: MonthKey,
        through end: MonthKey,
        openingServiceCarry: Int,
        openingCreditCarry: Int,
        policies: [ReportingPolicy]
    ) -> [MonthlyReport] {
        guard start <= end else { return [] }
        var month = start
        var serviceCarry = max(0, openingServiceCarry) % 60
        var creditCarry = max(0, openingCreditCarry) % 60
        var reports: [MonthlyReport] = []

        while month <= end {
            let policy = policy(for: month, revisions: policies)
            let monthEntries = entries.filter { $0.day.monthKey == month }
            let rawService = monthEntries.filter { $0.kind == .service }.reduce(0) { $0 + $1.minutes }
            let rawCredit = monthEntries.filter { $0.kind == .credit }.reduce(0) { $0 + $1.minutes }
            let serviceResult = report(totalMinutes: rawService + serviceCarry, month: month, policy: policy)
            let creditResult = report(totalMinutes: rawCredit + creditCarry, month: month, policy: policy)

            reports.append(MonthlyReport(
                month: month,
                rawServiceMinutes: rawService,
                rawCreditMinutes: rawCredit,
                serviceCarryIn: serviceCarry,
                creditCarryIn: creditCarry,
                serviceHours: serviceResult.hours,
                creditHours: creditResult.hours,
                serviceCarryOut: serviceResult.carry,
                creditCarryOut: creditResult.carry
            ))
            serviceCarry = serviceResult.carry
            creditCarry = creditResult.carry
            month = month.advanced(by: 1, calendar: .hourleaf)
        }
        return reports
    }

    static func policy(for month: MonthKey, revisions: [ReportingPolicy]) -> ReportingPolicy {
        revisions
            .filter { $0.effectiveMonth <= month }
            .max { lhs, rhs in
                lhs.effectiveMonth == rhs.effectiveMonth
                    ? lhs.createdAt < rhs.createdAt
                    : lhs.effectiveMonth < rhs.effectiveMonth
            }
            ?? ReportingPolicy(effectiveMonth: month)
    }

    private static func report(
        totalMinutes: Int,
        month: MonthKey,
        policy: ReportingPolicy
    ) -> (hours: Int, carry: Int) {
        let safeTotal = max(0, totalMinutes)
        switch policy.mode {
        case .carry:
            return (safeTotal / 60, month.month == 8 ? 0 : safeTotal % 60)
        case .roundNearest:
            return ((safeTotal + 30) / 60, 0)
        case .discard:
            return (safeTotal / 60, 0)
        }
    }
}
enum ServiceYearCalculator {
    static func serviceYearStart(containing day: LocalDay, policy: GoalPolicy = .regularPioneer) -> LocalDay {
        let year = day.month >= policy.startMonth ? day.year : day.year - 1
        return LocalDay(year: year, month: policy.startMonth, day: 1)
    }

    static func progressMinutes(
        entries: [TimeEntry],
        containing day: LocalDay,
        baselineMinutes: Int,
        policy: GoalPolicy = .regularPioneer
    ) -> Int {
        let start = serviceYearStart(containing: day, policy: policy)
        let end = LocalDay(year: start.year + 1, month: policy.startMonth, day: 1)
        let recorded = entries
            .filter { $0.kind == .service && $0.day >= start && $0.day < end }
            .reduce(0) { $0 + $1.minutes }
        return max(0, baselineMinutes) + recorded
    }
}
