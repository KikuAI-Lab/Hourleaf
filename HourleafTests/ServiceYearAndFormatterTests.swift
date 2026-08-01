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
}
