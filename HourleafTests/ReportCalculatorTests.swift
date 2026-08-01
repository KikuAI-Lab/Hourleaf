import XCTest
@testable import Hourleaf

final class ReportCalculatorTests: XCTestCase {
    private let january = MonthKey(year: 2026, month: 1)

    func testCarryKeepsOnlyMinuteRemainderAndKeepsLedgersIndependent() {
        let entries = [
            entry(.service, month: january, minutes: 52 * 60 + 45),
            entry(.credit, month: january, minutes: 7 * 60 + 20)
        ]
        let policy = ReportingPolicy(effectiveMonth: january, mode: .carry)

        let reports = ReportCalculator.timeline(
            entries: entries,
            from: january,
            through: january.advanced(by: 1, calendar: .hourleaf),
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [policy]
        )

        XCTAssertEqual(reports[0].serviceHours, 52)
        XCTAssertEqual(reports[0].serviceCarryOut, 45)
        XCTAssertEqual(reports[0].creditHours, 7)
        XCTAssertEqual(reports[0].creditCarryOut, 20)
        XCTAssertEqual(reports[1].serviceHours, 0)
        XCTAssertEqual(reports[1].serviceCarryIn, 45)
        XCTAssertEqual(reports[1].creditCarryIn, 20)
    }

    func testCarryCanTurnSixtyCombinedMinutesIntoNextMonthHour() {
        let february = january.advanced(by: 1, calendar: .hourleaf)
        let entries = [
            entry(.service, month: january, minutes: 49 * 60 + 40),
            entry(.service, month: february, minutes: 20)
        ]

        let reports = ReportCalculator.timeline(
            entries: entries,
            from: january,
            through: february,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: january)]
        )

        XCTAssertEqual(reports[0].serviceHours, 49)
        XCTAssertEqual(reports[0].serviceCarryOut, 40)
        XCTAssertEqual(reports[1].serviceHours, 1)
        XCTAssertEqual(reports[1].serviceCarryOut, 0)
    }

    func testRoundNearestUsesThirtyMinuteBoundaryAndDoesNotCarry() {
        let reports = ReportCalculator.timeline(
            entries: [
                entry(.service, month: january, minutes: 12 * 60 + 29),
                entry(.credit, month: january, minutes: 4 * 60 + 30)
            ],
            from: january,
            through: january,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: january, mode: .roundNearest)]
        )

        XCTAssertEqual(reports[0].serviceHours, 12)
        XCTAssertEqual(reports[0].creditHours, 5)
        XCTAssertEqual(reports[0].serviceCarryOut, 0)
        XCTAssertEqual(reports[0].creditCarryOut, 0)
    }

    func testDiscardFloorsAndDropsRemainder() {
        let reports = ReportCalculator.timeline(
            entries: [entry(.service, month: january, minutes: 5 * 60 + 59)],
            from: january,
            through: january,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: january, mode: .discard)]
        )

        XCTAssertEqual(reports[0].serviceHours, 5)
        XCTAssertEqual(reports[0].serviceCarryOut, 0)
    }

    func testAugustBoundaryRespectsConscienceSetting() {
        let august = MonthKey(year: 2026, month: 8)
        let september = MonthKey(year: 2026, month: 9)
        let entries = [entry(.service, month: august, minutes: 40)]

        let noCarry = ReportCalculator.timeline(
            entries: entries,
            from: august,
            through: september,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: august, mode: .carry, carryAcrossServiceYear: false)]
        )
        let carry = ReportCalculator.timeline(
            entries: entries,
            from: august,
            through: september,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: august, mode: .carry, carryAcrossServiceYear: true)]
        )

        XCTAssertEqual(noCarry[1].serviceCarryIn, 0)
        XCTAssertEqual(carry[1].serviceCarryIn, 40)
    }

    func testPolicyRevisionsApplyFromTheirEffectiveMonth() {
        let february = january.advanced(by: 1, calendar: .hourleaf)
        let reports = ReportCalculator.timeline(
            entries: [
                entry(.service, month: january, minutes: 40),
                entry(.service, month: february, minutes: 40)
            ],
            from: january,
            through: february,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [
                ReportingPolicy(effectiveMonth: january, mode: .carry),
                ReportingPolicy(effectiveMonth: february, mode: .discard)
            ]
        )

        XCTAssertEqual(reports[0].serviceCarryOut, 40)
        XCTAssertEqual(reports[1].serviceHours, 1)
        XCTAssertEqual(reports[1].serviceCarryOut, 0)
    }

    private func entry(_ kind: EntryKind, month: MonthKey, minutes: Int) -> TimeEntry {
        TimeEntry(kind: kind, day: LocalDay(year: month.year, month: month.month, day: 10), minutes: minutes)
    }
}
