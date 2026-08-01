import Foundation

enum EntryValidationError: LocalizedError, Equatable {
    case emptyDuration
    case durationTooLarge
    case noteTooLong

    var errorDescription: String? {
        switch self {
        case .emptyDuration: String(localized: "error.empty_duration")
        case .durationTooLarge: String(localized: "error.duration_too_large")
        case .noteTooLong: String(localized: "error.note_too_long")
        }
    }
}
@MainActor
struct AddTimeEntryCommand {
    let repository: LedgerRepository

    @discardableResult
    func execute(kind: EntryKind, date: Date, hours: Int, minutes: Int, note: String?) throws -> TimeEntry {
        let total = hours * 60 + minutes
        guard total > 0 else { throw EntryValidationError.emptyDuration }
        guard total < 6_000 else { throw EntryValidationError.durationTooLarge }
        guard (note ?? "").count <= 280 else { throw EntryValidationError.noteTooLong }
        let entry = TimeEntry(kind: kind, day: LocalDay(date, calendar: .hourleaf), minutes: total, note: note)
        try repository.saveEntry(entry)
        return entry
    }
}
