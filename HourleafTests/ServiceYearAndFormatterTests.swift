import Foundation
import XCTest
@testable import Hourleaf

final class ServiceYearAndFormatterTests: XCTestCase {
    func testServiceYearCountsDatedServiceAndExcludesCredit() {
        let entries = [
            TimeEntry(kind: .service, day: LocalDay(year: 2025, month: 9, day: 1), minutes: 100),
            TimeEntry(kind: .service, day: LocalDay(year: 2026, month: 8, day: 31), minutes: 200),
            TimeEntry(kind: .credit, day: LocalDay(year: 2026, month: 5, day: 1), minutes: 9_000),
            TimeEntry(kind: .service, day: LocalDay(year: 2026, month: 9, day: 1), minutes: 400)
        ]

        let result = ServiceYearCalculator.progressMinutes(
            entries: entries,
            containing: LocalDay(year: 2026, month: 8, day: 1),
            baselineMinutes: 60
        )

        XCTAssertEqual(result, 360)
    }

    func testServiceYearProgressCanExceedGoal() {
        let baseline = 650 * 60 + 15
        let result = ServiceYearCalculator.progressMinutes(
            entries: [],
            containing: LocalDay(year: 2026, month: 8, day: 1),
            baselineMinutes: baseline
        )

        XCTAssertEqual(result, baseline)
        XCTAssertGreaterThan(result, GoalPolicy.regularPioneer.targetMinutes)
    }

    func testReportFormatterSupportsAllLanguagesAndOmitsZeroCredit() {
        let report = MonthlyReport(
            month: MonthKey(year: 2026, month: 7),
            rawServiceMinutes: 3_120,
            rawCreditMinutes: 0,
            serviceCarryIn: 0,
            creditCarryIn: 0,
            serviceHours: 52,
            creditHours: 0,
            serviceCarryOut: 0,
            creditCarryOut: 0
        )
        var settings = AppSettings()

        settings.reportLanguage = .russian
        XCTAssertEqual(ReportFormatter.format(report, settings: settings), "Июль 2026\nЧасы: 52")

        settings.reportLanguage = .ukrainian
        XCTAssertEqual(ReportFormatter.format(report, settings: settings), "Липень 2026\nГодини: 52")

        settings.reportLanguage = .english
        XCTAssertEqual(ReportFormatter.format(report, settings: settings), "July 2026\nHours: 52")
    }

    func testReportFormatterUsesCustomCreditLabel() {
        let report = MonthlyReport(
            month: MonthKey(year: 2026, month: 7),
            rawServiceMinutes: 3_120,
            rawCreditMinutes: 420,
            serviceCarryIn: 0,
            creditCarryIn: 0,
            serviceHours: 52,
            creditHours: 7,
            serviceCarryOut: 0,
            creditCarryOut: 0
        )
        var settings = AppSettings()
        settings.reportLanguage = .ukrainian
        settings.creditLabelUkrainian = "Бетель"

        XCTAssertEqual(
            ReportFormatter.format(report, settings: settings),
            "Липень 2026\nГодини: 52\nБетель: 7"
        )
    }

    func testReportFormatterIncludesDistinctBibleStudiesInAllLanguages() {
        let report = MonthlyReport(
            month: MonthKey(year: 2026, month: 8),
            rawServiceMinutes: 3_120,
            rawCreditMinutes: 420,
            serviceCarryIn: 0,
            creditCarryIn: 0,
            serviceHours: 52,
            creditHours: 7,
            serviceCarryOut: 0,
            creditCarryOut: 0,
            bibleStudyCount: 1
        )
        var settings = AppSettings()

        settings.reportLanguage = .russian
        XCTAssertEqual(
            ReportFormatter.format(report, settings: settings),
            "Август 2026\nЧасы: 52\nКредит часов: 7\nИзучения Библии: 1"
        )

        settings.reportLanguage = .ukrainian
        XCTAssertEqual(
            ReportFormatter.format(report, settings: settings),
            "Серпень 2026\nГодини: 52\nКредит годин: 7\nВивчення Біблії: 1"
        )

        settings.reportLanguage = .english
        XCTAssertEqual(
            ReportFormatter.format(report, settings: settings),
            "August 2026\nHours: 52\nCredit hours: 7\nBible studies: 1"
        )
    }

    func testVersionedContractFixturesMatchServiceYearAndFormatterBehavior() throws {
        let fixture = try loadContractFixture()

        XCTAssertEqual(fixture.contract, "hourleaf-report-service-year")
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(
            fixture.serviceYearCases.map(\.id),
            [
                "service-year-excludes-credit",
                "service-year-exceeds-goal-without-capping"
            ]
        )

        for fixtureCase in fixture.serviceYearCases {
            let result = ServiceYearCalculator.progressMinutes(
                entries: try fixtureCase.entries.map { entry in
                    TimeEntry(
                        kind: try XCTUnwrap(EntryKind(rawValue: entry.kind)),
                        day: try XCTUnwrap(LocalDay(key: entry.day)),
                        minutes: entry.minutes
                    )
                },
                containing: try XCTUnwrap(LocalDay(key: fixtureCase.serviceYearContainingDate)),
                baselineMinutes: fixtureCase.baselineMinutes
            )

            XCTAssertEqual(result, fixtureCase.expectedProgressMinutes, fixtureCase.id)
            XCTAssertEqual(GoalPolicy.regularPioneer.targetMinutes, fixtureCase.goalTargetMinutes)
            XCTAssertEqual(
                result > fixtureCase.goalTargetMinutes,
                fixtureCase.expectedGoalExceeded,
                fixtureCase.id
            )
        }

        XCTAssertEqual(
            fixture.formatterCases.map(\.id),
            [
                "formatter-en-zero-credit",
                "formatter-ru-zero-credit",
                "formatter-uk-zero-credit",
                "formatter-en-credit-and-bible-study"
            ]
        )

        for fixtureCase in fixture.formatterCases {
            var settings = AppSettings()
            settings.reportLanguage = try XCTUnwrap(ReportLanguage(rawValue: fixtureCase.language))
            let report = MonthlyReport(
                month: try XCTUnwrap(MonthKey(key: fixtureCase.month)),
                rawServiceMinutes: 0,
                rawCreditMinutes: 0,
                serviceCarryIn: 0,
                creditCarryIn: 0,
                serviceHours: fixtureCase.serviceHours,
                creditHours: fixtureCase.creditHours,
                serviceCarryOut: 0,
                creditCarryOut: 0,
                bibleStudyCount: fixtureCase.bibleStudyCount
            )

            XCTAssertEqual(ReportFormatter.format(report, settings: settings), fixtureCase.expected, fixtureCase.id)
        }
    }

    private func loadContractFixture() throws -> ServiceYearFormatterContractFixture {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Contracts/report-service-year-fixtures-v1.json"
            )
        )
        return try JSONDecoder().decode(ServiceYearFormatterContractFixture.self, from: data)
    }

    private struct ServiceYearFormatterContractFixture: Decodable {
        let contract: String
        let schemaVersion: Int
        let monthlyReportCases: [IgnoredContractCase]
        let serviceYearCases: [ServiceYearCase]
        let formatterCases: [FormatterCase]
    }

    private struct IgnoredContractCase: Decodable {}

    private struct ServiceYearCase: Decodable {
        let id: String
        let serviceYearContainingDate: String
        let baselineMinutes: Int
        let entries: [Entry]
        let expectedProgressMinutes: Int
        let goalTargetMinutes: Int
        let expectedGoalExceeded: Bool

        struct Entry: Decodable {
            let kind: String
            let day: String
            let minutes: Int
        }
    }

    private struct FormatterCase: Decodable {
        let id: String
        let month: String
        let language: String
        let serviceHours: Int
        let creditHours: Int
        let bibleStudyCount: Int
        let expected: String
    }
}
