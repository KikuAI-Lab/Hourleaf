import Foundation

struct ServiceYearPace: Equatable, Sendable {
    enum Presentation: Equatable, Sendable {
        case weekly(minutes: Int)
        case finalDays(remainingMinutes: Int, dayCount: Int)
        case reached
    }

    let start: LocalDay
    let endInclusive: LocalDay
    let asOf: LocalDay
    let targetMinutes: Int
    let openingMinutes: Int
    let recordedMinutes: Int
    let actualMinutes: Int
    let remainingMinutes: Int
    let remainingDays: Int
    let presentation: Presentation
}

enum ServiceYearPaceCalculationError: Error, Equatable, Sendable {
    case nonGregorianCalendar
    case invalidPolicy
    case invalidDay(LocalDay)
    case negativeMinutes
    case arithmeticOverflow
}

enum ServiceYearPaceCalculator {
    static func calculate(
        records: [LedgerEntryRecord],
        settings: AppSettings,
        asOf: LocalDay,
        calendar: Calendar,
        policy: GoalPolicy = .regularPioneer
    ) throws -> ServiceYearPace {
        guard calendar.identifier == .gregorian else {
            throw ServiceYearPaceCalculationError.nonGregorianCalendar
        }
        guard (1...12).contains(policy.startMonth), policy.targetMinutes >= 0 else {
            throw ServiceYearPaceCalculationError.invalidPolicy
        }

        let asOfDate = try validatedDate(for: asOf, calendar: calendar)
        let startYear: Int
        if asOf.month >= policy.startMonth {
            startYear = asOf.year
        } else {
            let result = asOf.year.subtractingReportingOverflow(1)
            guard !result.overflow else {
                throw ServiceYearPaceCalculationError.arithmeticOverflow
            }
            startYear = result.partialValue
        }

        let endYearResult = startYear.addingReportingOverflow(1)
        guard !endYearResult.overflow else {
            throw ServiceYearPaceCalculationError.arithmeticOverflow
        }

        let start = LocalDay(year: startYear, month: policy.startMonth, day: 1)
        let yearEnd = LocalDay(year: endYearResult.partialValue, month: policy.startMonth, day: 1)
        _ = try validatedDate(for: start, calendar: calendar)
        let yearEndDate = try validatedDate(for: yearEnd, calendar: calendar)

        guard asOf >= start, asOf < yearEnd else {
            throw ServiceYearPaceCalculationError.invalidDay(asOf)
        }
        guard
            let endInclusiveDate = calendar.date(byAdding: .day, value: -1, to: yearEndDate),
            let remainingDays = calendar.dateComponents([.day], from: asOfDate, to: yearEndDate).day,
            remainingDays > 0
        else {
            throw ServiceYearPaceCalculationError.invalidDay(asOf)
        }

        let endInclusive = LocalDay(endInclusiveDate, calendar: calendar)
        let ledgerStartDay = LocalDay(
            year: settings.ledgerStartMonth.year,
            month: settings.ledgerStartMonth.month,
            day: 1
        )
        _ = try validatedDate(for: ledgerStartDay, calendar: calendar)

        let openingMinutes = settings.baselineServiceYearStart == start.monthKey
            ? settings.baselineServiceYearMinutes
            : 0
        let totals = try ServiceYearActualMinutesCalculator.totals(
            entries: records.lazy.filter { $0.deletedAt == nil }.map(\.entry),
            yearStart: start,
            yearEnd: yearEnd,
            ledgerStartDay: ledgerStartDay,
            through: asOf,
            openingMinutes: openingMinutes,
            calendar: calendar
        )
        let target = try nonnegativeInt64(policy.targetMinutes)
        let remaining = totals.actual >= target ? 0 : target - totals.actual

        let presentation: ServiceYearPace.Presentation
        if remaining == 0 {
            presentation = .reached
        } else if remainingDays < 7 {
            presentation = .finalDays(
                remainingMinutes: try exactInt(remaining),
                dayCount: remainingDays
            )
        } else {
            let multiplication = remaining.multipliedReportingOverflow(by: 7)
            guard !multiplication.overflow else {
                throw ServiceYearPaceCalculationError.arithmeticOverflow
            }
            let adjustment = Int64(remainingDays - 1)
            let numerator = multiplication.partialValue.addingReportingOverflow(adjustment)
            guard !numerator.overflow else {
                throw ServiceYearPaceCalculationError.arithmeticOverflow
            }
            presentation = .weekly(
                minutes: try exactInt(numerator.partialValue / Int64(remainingDays))
            )
        }

        return ServiceYearPace(
            start: start,
            endInclusive: endInclusive,
            asOf: asOf,
            targetMinutes: policy.targetMinutes,
            openingMinutes: try exactInt(totals.opening),
            recordedMinutes: try exactInt(totals.recorded),
            actualMinutes: try exactInt(totals.actual),
            remainingMinutes: try exactInt(remaining),
            remainingDays: remainingDays,
            presentation: presentation
        )
    }

    static func validatedDate(for day: LocalDay, calendar: Calendar) throws -> Date {
        guard
            (1...9_999).contains(day.year),
            (1...12).contains(day.month),
            (1...31).contains(day.day),
            let date = calendar.date(
                from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)
            )
        else {
            throw ServiceYearPaceCalculationError.invalidDay(day)
        }

        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard
            components.year == day.year,
            components.month == day.month,
            components.day == day.day
        else {
            throw ServiceYearPaceCalculationError.invalidDay(day)
        }
        return date
    }

    static func nonnegativeInt64(_ value: Int) throws -> Int64 {
        guard value >= 0 else {
            throw ServiceYearPaceCalculationError.negativeMinutes
        }
        guard let converted = Int64(exactly: value) else {
            throw ServiceYearPaceCalculationError.arithmeticOverflow
        }
        return converted
    }

    static func exactInt(_ value: Int64) throws -> Int {
        guard let converted = Int(exactly: value) else {
            throw ServiceYearPaceCalculationError.arithmeticOverflow
        }
        return converted
    }
}

struct ServiceYearMinuteTotals: Equatable, Sendable {
    let opening: Int64
    let recorded: Int64
    let actual: Int64
}

enum ServiceYearActualMinutesCalculator {
    static func totals<S: Sequence>(
        entries: S,
        yearStart: LocalDay,
        yearEnd: LocalDay,
        ledgerStartDay: LocalDay,
        through: LocalDay,
        openingMinutes: Int,
        calendar: Calendar
    ) throws -> ServiceYearMinuteTotals where S.Element == TimeEntry {
        let opening = try ServiceYearPaceCalculator.nonnegativeInt64(openingMinutes)
        var recorded: Int64 = 0

        for entry in entries where entry.kind == .service {
            _ = try ServiceYearPaceCalculator.validatedDate(for: entry.day, calendar: calendar)
            guard
                entry.day >= yearStart,
                entry.day >= ledgerStartDay,
                entry.day <= through,
                entry.day < yearEnd
            else { continue }

            let minutes = try ServiceYearPaceCalculator.nonnegativeInt64(entry.minutes)
            let addition = recorded.addingReportingOverflow(minutes)
            guard !addition.overflow else {
                throw ServiceYearPaceCalculationError.arithmeticOverflow
            }
            recorded = addition.partialValue
        }

        let actualAddition = opening.addingReportingOverflow(recorded)
        guard !actualAddition.overflow else {
            throw ServiceYearPaceCalculationError.arithmeticOverflow
        }
        return ServiceYearMinuteTotals(
            opening: opening,
            recorded: recorded,
            actual: actualAddition.partialValue
        )
    }
}
