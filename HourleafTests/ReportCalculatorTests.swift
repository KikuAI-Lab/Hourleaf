import Foundation
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

    func testAugustRemaindersNeverCrossIntoNewServiceYear() {
        let august = MonthKey(year: 2026, month: 8)
        let september = MonthKey(year: 2026, month: 9)
        let entries = [
            entry(.service, month: august, minutes: 40),
            entry(.credit, month: august, minutes: 20)
        ]

        let reports = ReportCalculator.timeline(
            entries: entries,
            from: august,
            through: september,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: august, mode: .carry)]
        )

        XCTAssertEqual(reports[0].serviceCarryOut, 0)
        XCTAssertEqual(reports[0].creditCarryOut, 0)
        XCTAssertEqual(reports[1].serviceCarryIn, 0)
        XCTAssertEqual(reports[1].creditCarryIn, 0)
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

    func testVersionedContractFixturesMatchCurrentReportCalculator() throws {
        let fixture = try loadContractFixture()

        XCTAssertEqual(fixture.contract, "hourleaf-report-service-year")
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.monthlyReportCases.map(\.id),
            [
                "carry-independent-ledgers",
                "august-to-september-reset",
                "round-nearest-boundary",
                "discard-remainder",
                "over-fifty-hours-is-not-capped"
            ]
        )

        for fixtureCase in fixture.monthlyReportCases {
            let reports = ReportCalculator.timeline(
                entries: try fixtureCase.entries.map { entry in
                    TimeEntry(
                        kind: try XCTUnwrap(EntryKind(rawValue: entry.kind)),
                        day: try XCTUnwrap(LocalDay(key: entry.day)),
                        minutes: entry.minutes
                    )
                },
                from: try XCTUnwrap(MonthKey(key: fixtureCase.from)),
                through: try XCTUnwrap(MonthKey(key: fixtureCase.through)),
                openingServiceCarry: fixtureCase.openingServiceCarry,
                openingCreditCarry: fixtureCase.openingCreditCarry,
                policies: try fixtureCase.policies.enumerated().map { index, policy in
                    ReportingPolicy(
                        effectiveMonth: try XCTUnwrap(MonthKey(key: policy.effectiveMonth)),
                        mode: try XCTUnwrap(RemainderMode(rawValue: policy.mode)),
                        createdAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                }
            )

            XCTAssertEqual(reports.count, fixtureCase.expected.count, fixtureCase.id)
            for (report, expected) in zip(reports, fixtureCase.expected) {
                XCTAssertEqual(report.month.key, expected.month, fixtureCase.id)
                XCTAssertEqual(report.rawServiceMinutes, expected.rawServiceMinutes, fixtureCase.id)
                XCTAssertEqual(report.rawCreditMinutes, expected.rawCreditMinutes, fixtureCase.id)
                XCTAssertEqual(report.serviceCarryIn, expected.serviceCarryIn, fixtureCase.id)
                XCTAssertEqual(report.creditCarryIn, expected.creditCarryIn, fixtureCase.id)
                XCTAssertEqual(report.serviceHours, expected.serviceHours, fixtureCase.id)
                XCTAssertEqual(report.creditHours, expected.creditHours, fixtureCase.id)
                XCTAssertEqual(report.serviceCarryOut, expected.serviceCarryOut, fixtureCase.id)
                XCTAssertEqual(report.creditCarryOut, expected.creditCarryOut, fixtureCase.id)
            }
        }
    }

    private func entry(_ kind: EntryKind, month: MonthKey, minutes: Int) -> TimeEntry {
        TimeEntry(kind: kind, day: LocalDay(year: month.year, month: month.month, day: 10), minutes: minutes)
    }

    private func loadContractFixture() throws -> ReportContractFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Contracts/report-service-year-fixtures-v1.json"
            )
        )
        return try JSONDecoder().decode(ReportContractFixture.self, from: data)
    }

    private struct ReportContractFixture: Decodable {
        let contract: String
        let schemaVersion: Int
        let monthlyReportCases: [MonthlyReportCase]
        let serviceYearCases: [IgnoredContractCase]
        let formatterCases: [IgnoredContractCase]
    }

    private struct IgnoredContractCase: Decodable {}

    private struct MonthlyReportCase: Decodable {
        let id: String
        let from: String
        let through: String
        let openingServiceCarry: Int
        let openingCreditCarry: Int
        let policies: [Policy]
        let entries: [Entry]
        let expected: [Expected]

        struct Policy: Decodable {
            let effectiveMonth: String
            let mode: String
        }

        struct Entry: Decodable {
            let kind: String
            let day: String
            let minutes: Int
        }

        struct Expected: Decodable {
            let month: String
            let rawServiceMinutes: Int
            let rawCreditMinutes: Int
            let serviceCarryIn: Int
            let creditCarryIn: Int
            let serviceHours: Int
            let creditHours: Int
            let serviceCarryOut: Int
            let creditCarryOut: Int
        }
    }
}
