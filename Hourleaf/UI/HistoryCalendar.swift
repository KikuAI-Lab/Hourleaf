import Foundation

/// The value shown for a single position in the month grid. Leading positions
/// are represented by `day == nil` so the UI can preserve the weekday layout.
struct HistoryCalendarCell: Identifiable, Equatable, Sendable {
    let id: String
    let day: LocalDay?

    init(day: LocalDay?) {
        self.day = day
        id = day?.key ?? "blank"
    }

    fileprivate init(id: String, day: LocalDay?) {
        self.id = id
        self.day = day
    }
}

enum HistoryCalendar {
    static func cells(
        in month: MonthKey,
        calendar: Calendar = .hourleaf
    ) -> [HistoryCalendarCell] {
        let firstDate = month.date(calendar: calendar)
        let firstWeekday = calendar.component(.weekday, from: firstDate)
        let leadingBlankCount = (firstWeekday - calendar.firstWeekday + 7) % 7
        let dayCount = calendar.range(of: .day, in: .month, for: firstDate)?.count ?? 0

        var cells = (0..<leadingBlankCount).map { index in
            HistoryCalendarCell(id: "blank-\(index)", day: nil)
        }
        cells.append(contentsOf: (1...dayCount).map { day in
            HistoryCalendarCell(day: LocalDay(year: month.year, month: month.month, day: day))
        })
        return cells
    }

    static func weekdaySymbols(calendar: Calendar = .hourleaf) -> [String] {
        let symbols = calendar.shortStandaloneWeekdaySymbols
        guard !symbols.isEmpty else { return [] }
        let firstIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        return Array(symbols[firstIndex...]) + Array(symbols[..<firstIndex])
    }

    static func activeDays(
        in month: MonthKey,
        records: [LedgerEntryRecord]
    ) -> Set<LocalDay> {
        Set(
            records.compactMap { record in
                guard !record.isDeleted, record.entry.day.monthKey == month else { return nil }
                return record.entry.day
            }
        )
    }

    static func activeEntries(
        on day: LocalDay,
        records: [LedgerEntryRecord]
    ) -> [LedgerEntryRecord] {
        records.filter { record in
            !record.isDeleted && record.entry.day == day
        }
    }

    static func clampedMonth(
        _ month: MonthKey,
        start: MonthKey,
        current: MonthKey
    ) -> MonthKey {
        // A valid ledger always has start <= current. Keeping the bounds
        // ordered here also leaves the UI deterministic while a fresh snapshot
        // is being applied after a settings change.
        guard start <= current else { return start }
        return min(max(month, start), current)
    }
}
