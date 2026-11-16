import XCTest
@testable import Hourleaf

final class ScrollPerformanceTests: XCTestCase {
    func testHistoryDateFormattingPerformance() {
        let days = (0..<200).map { LocalDay(year: 2026, month: 10, day: $0 % 28 + 1) }
        _ = AppDateText.day(days[0])
        measure {
            for day in days { XCTAssertFalse(AppDateText.day(day).isEmpty) }
        }
    }

    func testHistoryDateFormattingPreservesCurrentLocalePresentation() {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        for day in [LocalDay(year: 2026, month: 1, day: 1), LocalDay(year: 2026, month: 11, day: 17)] {
            XCTAssertEqual(AppDateText.day(day), formatter.string(from: day.date(calendar: .hourleaf)))
        }
    }

    func testLargeLedgerTimelinePerformance() {
        let entries = (0..<2_000).map { index in
            TimeEntry(
                kind: index.isMultiple(of: 3) ? .credit : .service,
                day: LocalDay(year: 2022 + index % 5, month: index % 12 + 1, day: index % 28 + 1),
                minutes: index % 180 + 1
            )
        }
        measure {
            let timeline = ReportCalculator.timeline(
                entries: entries,
                from: MonthKey(year: 2022, month: 1),
                through: MonthKey(year: 2026, month: 12),
                openingServiceCarry: 17,
                openingCreditCarry: 29,
                policies: []
            )
            XCTAssertEqual(timeline.count, 60)
        }
    }
}
