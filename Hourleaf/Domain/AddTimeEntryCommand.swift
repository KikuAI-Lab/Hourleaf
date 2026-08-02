import Foundation

enum EntryValidationError: LocalizedError, Equatable, Sendable {
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

enum LedgerRepositoryError: LocalizedError, Equatable, Sendable {
    case persistenceUnavailable(String)
    case invalidManagedObject(String)
    case normalizationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .persistenceUnavailable(message),
             let .invalidManagedObject(message),
             let .normalizationFailed(message):
            message
        }
    }
}
struct AddTimeEntryCommand: Sendable {
    let repository: any LedgerRepository

    @discardableResult
    func execute(
        kind: EntryKind,
        date: Date,
        hours: Int,
        minutes: Int,
        note: String?
    ) async throws -> TimeEntry {
        let total = hours * 60 + minutes
        guard total > 0 else { throw EntryValidationError.emptyDuration }
        guard total < 6_000 else { throw EntryValidationError.durationTooLarge }
        guard (note ?? "").count <= 280 else { throw EntryValidationError.noteTooLong }
        let entry = TimeEntry(kind: kind, day: LocalDay(date, calendar: .hourleaf), minutes: total, note: note)
        try await repository.saveEntry(entry)
        return entry
    }
}
