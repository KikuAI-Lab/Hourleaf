import XCTest
@testable import Hourleaf

final class ServiceYearPaceCalculatorTests: XCTestCase {
    func testNonLeapServiceYearStartsAtElevenHoursThirtyOneMinutesPerWeek() throws {
        let pace = try calculate(asOf: day(2025, 9, 1))

        XCTAssertEqual(pace.start, day(2025, 9, 1))
        XCTAssertEqual(pace.endInclusive, day(2026, 8, 31))
        XCTAssertEqual(pace.remainingDays, 365)
        XCTAssertEqual(pace.remainingMinutes, 36_000)
        XCTAssertEqual(pace.presentation, .weekly(minutes: 691))
    }

    func testLeapServiceYearUsesCivilDayCount() throws {
        let pace = try calculate(asOf: day(2023, 9, 1))

        XCTAssertEqual(pace.endInclusive, day(2024, 8, 31))
        XCTAssertEqual(pace.remainingDays, 366)
        XCTAssertEqual(pace.presentation, .weekly(minutes: 689))
    }

    func testLateStartAddsOpeningBalanceOnceAndExcludesCredit() throws {
        var settings = makeSettings(ledgerStart: MonthKey(year: 2026, month: 4))
        settings.baselineServiceYearMinutes = 300 * 60
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)
        let records = [
            record(.service, day: day(2026, 4, 1), minutes: 60 * 60),
            record(.credit, day: day(2026, 4, 1), minutes: 100 * 60)
        ]

        let pace = try ServiceYearPaceCalculator.calculate(
            records: records,
            settings: settings,
            asOf: day(2026, 4, 1),
            calendar: utcCalendar
        )

        XCTAssertEqual(pace.openingMinutes, 18_000)
        XCTAssertEqual(pace.recordedMinutes, 3_600)
        XCTAssertEqual(pace.actualMinutes, 21_600)
        XCTAssertEqual(pace.remainingMinutes, 14_400)
        XCTAssertEqual(pace.remainingDays, 153)
        XCTAssertEqual(pace.presentation, .weekly(minutes: 659))
    }

    func testBaselineAppliesOnlyToItsNamedServiceYear() throws {
        var settings = makeSettings(ledgerStart: MonthKey(year: 2025, month: 9))
        settings.baselineServiceYearMinutes = 12_000
        settings.baselineServiceYearStart = MonthKey(year: 2024, month: 9)

        let ignored = try ServiceYearPaceCalculator.calculate(
            records: [],
            settings: settings,
            asOf: day(2026, 4, 1),
            calendar: utcCalendar
        )
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)
        let applied = try ServiceYearPaceCalculator.calculate(
            records: [],
            settings: settings,
            asOf: day(2026, 4, 1),
            calendar: utcCalendar
        )

        XCTAssertEqual(ignored.openingMinutes, 0)
        XCTAssertEqual(ignored.actualMinutes, 0)
        XCTAssertEqual(applied.openingMinutes, 12_000)
        XCTAssertEqual(applied.actualMinutes, 12_000)
    }

    func testDeletedFutureBeforeLedgerAndCreditEntriesAreExcluded() throws {
        let settings = makeSettings(ledgerStart: MonthKey(year: 2026, month: 1))
        let records = [
            record(.service, day: day(2026, 1, 1), minutes: 60),
            record(.service, day: day(2026, 2, 1), minutes: 120, isDeleted: true),
            record(.service, day: day(2026, 4, 2), minutes: 180),
            record(.service, day: day(2025, 12, 31), minutes: 240),
            record(.credit, day: day(2026, 3, 1), minutes: 300)
        ]

        let pace = try ServiceYearPaceCalculator.calculate(
            records: records,
            settings: settings,
            asOf: day(2026, 4, 1),
            calendar: utcCalendar
        )

        XCTAssertEqual(pace.recordedMinutes, 60)
        XCTAssertEqual(pace.actualMinutes, 60)
    }

    func testMonthlyCarryAndRoundingPolicyCannotChangePace() throws {
        let month = MonthKey(year: 2025, month: 9)
        let entry = TimeEntry(kind: .service, day: day(2025, 9, 1), minutes: 31)
        let discarded = ReportCalculator.timeline(
            entries: [entry],
            from: month,
            through: month,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: month, mode: .discard)]
        )
        let rounded = ReportCalculator.timeline(
            entries: [entry],
            from: month,
            through: month,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: month, mode: .roundNearest)]
        )
        var settings = makeSettings(ledgerStart: month)
        settings.openingServiceCarryMinutes = 59
        settings.openingCreditCarryMinutes = 59

        let pace = try ServiceYearPaceCalculator.calculate(
            records: [record(entry)],
            settings: settings,
            asOf: day(2025, 9, 1),
            calendar: utcCalendar
        )

        XCTAssertEqual(discarded.first?.serviceHours, 0)
        XCTAssertEqual(rounded.first?.serviceHours, 1)
        XCTAssertEqual(pace.actualMinutes, 31)
    }

    func testProgressCanExceedSixHundredWithoutCapping() throws {
        var settings = makeSettings(ledgerStart: MonthKey(year: 2025, month: 9))
        settings.baselineServiceYearMinutes = 36_075
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)

        let pace = try ServiceYearPaceCalculator.calculate(
            records: [],
            settings: settings,
            asOf: day(2026, 8, 1),
            calendar: utcCalendar
        )

        XCTAssertEqual(pace.actualMinutes, 36_075)
        XCTAssertEqual(pace.remainingMinutes, 0)
        XCTAssertEqual(pace.presentation, .reached)
    }

    func testSixFinalDaysShowRawRemainderInsteadOfWeeklyExtrapolation() throws {
        var settings = makeSettings(ledgerStart: MonthKey(year: 2025, month: 9))
        settings.baselineServiceYearMinutes = 35_940
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)

        let pace = try ServiceYearPaceCalculator.calculate(
            records: [],
            settings: settings,
            asOf: day(2026, 8, 26),
            calendar: utcCalendar
        )

        XCTAssertEqual(pace.remainingDays, 6)
        XCTAssertEqual(pace.remainingMinutes, 60)
        XCTAssertEqual(pace.presentation, .finalDays(remainingMinutes: 60, dayCount: 6))
    }

    func testSeptemberFirstExcludesPriorAugustEntriesBaselineAndCarry() throws {
        var settings = makeSettings(ledgerStart: MonthKey(year: 2025, month: 9))
        settings.baselineServiceYearMinutes = 30_000
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9)
        settings.openingServiceCarryMinutes = 59
        settings.openingCreditCarryMinutes = 59
        let records = [
            record(.service, day: day(2026, 8, 31), minutes: 600),
            record(.service, day: day(2026, 9, 1), minutes: 15)
        ]

        let pace = try ServiceYearPaceCalculator.calculate(
            records: records,
            settings: settings,
            asOf: day(2026, 9, 1),
            calendar: utcCalendar
        )

        XCTAssertEqual(pace.start, day(2026, 9, 1))
        XCTAssertEqual(pace.openingMinutes, 0)
        XCTAssertEqual(pace.recordedMinutes, 15)
        XCTAssertEqual(pace.actualMinutes, 15)
    }

    func testDSTTransitionDoesNotChangeCivilRemainingDayCount() throws {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))

        let pace = try calculate(asOf: day(2026, 3, 7), calendar: dstCalendar)

        XCTAssertEqual(pace.remainingDays, 178)
    }

    func testIntegerBoundsFailWithoutOverflow() {
        let settings = makeSettings(ledgerStart: MonthKey(year: 2025, month: 9))
        let records = [
            record(.service, day: day(2025, 9, 1), minutes: Int.max),
            record(.service, day: day(2025, 9, 2), minutes: Int.max)
        ]

        XCTAssertThrowsError(
            try ServiceYearPaceCalculator.calculate(
                records: records,
                settings: settings,
                asOf: day(2025, 9, 2),
                calendar: utcCalendar,
                policy: GoalPolicy(targetMinutes: Int.max, startMonth: 9)
            )
        ) { error in
            XCTAssertEqual(error as? ServiceYearPaceCalculationError, .arithmeticOverflow)
        }
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func calculate(
        asOf: LocalDay,
        calendar: Calendar? = nil
    ) throws -> ServiceYearPace {
        try ServiceYearPaceCalculator.calculate(
            records: [],
            settings: makeSettings(
                ledgerStart: MonthKey(
                    year: asOf.month >= 9 ? asOf.year : asOf.year - 1,
                    month: 9
                )
            ),
            asOf: asOf,
            calendar: calendar ?? utcCalendar
        )
    }

    private func makeSettings(ledgerStart: MonthKey) -> AppSettings {
        var settings = AppSettings()
        settings.ledgerStartMonth = ledgerStart
        settings.baselineServiceYearMinutes = 0
        settings.baselineServiceYearStart = MonthKey(
            year: ledgerStart.month >= 9 ? ledgerStart.year : ledgerStart.year - 1,
            month: 9
        )
        return settings
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> LocalDay {
        LocalDay(year: year, month: month, day: day)
    }

    private func record(
        _ kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        isDeleted: Bool = false
    ) -> LedgerEntryRecord {
        record(TimeEntry(kind: kind, day: day, minutes: minutes), isDeleted: isDeleted)
    }

    private func record(_ entry: TimeEntry, isDeleted: Bool = false) -> LedgerEntryRecord {
        LedgerEntryRecord(
            entry: entry,
            deletedAt: isDeleted ? Date(timeIntervalSince1970: 1) : nil,
            source: nil,
            revision: 1,
            lastMutationID: nil
        )
    }
}
