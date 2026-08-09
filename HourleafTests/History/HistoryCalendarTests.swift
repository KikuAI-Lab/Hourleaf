import XCTest
@testable import Hourleaf

final class HistoryCalendarTests: XCTestCase {
    func testCellsPreserveLeadingWeekdayPositionsAndAllMonthDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2 // Monday

        let month = MonthKey(year: 2026, month: 2)
        let cells = HistoryCalendar.cells(in: month, calendar: calendar)

        XCTAssertEqual(cells.count, 34)
        XCTAssertEqual(cells.prefix(6).compactMap(\.day).count, 0)
        XCTAssertEqual(cells.compactMap(\.day).first, LocalDay(year: 2026, month: 2, day: 1))
        XCTAssertEqual(cells.compactMap(\.day).last, LocalDay(year: 2026, month: 2, day: 28))
    }

    func testActiveDaysIgnoreDeletedRecordsAndOtherMonths() {
        let month = MonthKey(year: 2026, month: 8)
        let active = makeRecord(day: LocalDay(year: 2026, month: 8, day: 9))
        let deleted = makeRecord(day: LocalDay(year: 2026, month: 8, day: 10), deletedAt: Date())
        let otherMonth = makeRecord(day: LocalDay(year: 2026, month: 9, day: 1))

        XCTAssertEqual(
            HistoryCalendar.activeDays(in: month, records: [active, deleted, otherMonth]),
            [LocalDay(year: 2026, month: 8, day: 9)]
        )
    }

    func testEntriesForDayReturnOnlyActiveMatchingRecordsInInputOrder() {
        let day = LocalDay(year: 2026, month: 8, day: 9)
        let first = makeRecord(day: day, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let deleted = makeRecord(day: day, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, deletedAt: Date())
        let other = makeRecord(day: LocalDay(year: 2026, month: 8, day: 10), id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let second = makeRecord(day: day, id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!)

        XCTAssertEqual(
            HistoryCalendar.activeEntries(on: day, records: [first, deleted, other, second]).map(\.id),
            [first.id, second.id]
        )
    }

    func testMonthBoundsClampWithoutCrossingLedgerRange() {
        let start = MonthKey(year: 2026, month: 3)
        let current = MonthKey(year: 2026, month: 8)

        XCTAssertEqual(HistoryCalendar.clampedMonth(MonthKey(year: 2026, month: 1), start: start, current: current), start)
        XCTAssertEqual(HistoryCalendar.clampedMonth(MonthKey(year: 2026, month: 12), start: start, current: current), current)
        XCTAssertEqual(HistoryCalendar.clampedMonth(MonthKey(year: 2026, month: 5), start: start, current: current), MonthKey(year: 2026, month: 5))
    }

    private func makeRecord(
        day: LocalDay,
        id: UUID = UUID(),
        deletedAt: Date? = nil
    ) -> LedgerEntryRecord {
        LedgerEntryRecord(
            entry: TimeEntry(
                id: id,
                kind: .service,
                day: day,
                minutes: 60,
                createdAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 2_000)
            ),
            deletedAt: deletedAt,
            source: nil,
            revision: 1,
            lastMutationID: nil
        )
    }
}
