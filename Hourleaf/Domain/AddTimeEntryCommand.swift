import Foundation

enum EntryValidationError: LocalizedError, Equatable, Sendable {
    case invalidHours
    case invalidMinutes
    case emptyDuration
    case durationTooLarge
    case noteTooLong

    var errorDescription: String? {
        switch self {
        case .invalidHours: String(localized: "error.invalid_hours")
        case .invalidMinutes: String(localized: "error.invalid_minutes")
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
    case maintenanceInProgress

    var errorDescription: String? {
        switch self {
        case let .persistenceUnavailable(message),
             let .invalidManagedObject(message),
             let .normalizationFailed(message):
            message
        case .maintenanceInProgress:
            String(localized: "error.restore_in_progress")
        }
    }
}

enum EntryDuration {
    /// Validates components before arithmetic so externally supplied `Int`
    /// values cannot overflow the duration calculation.
    static func totalMinutes(hours: Int, minutes: Int) throws -> Int {
        guard hours >= 0 else { throw EntryValidationError.invalidHours }
        guard (0...59).contains(minutes) else { throw EntryValidationError.invalidMinutes }
        guard hours <= 99 else { throw EntryValidationError.durationTooLarge }

        let total = hours * 60 + minutes
        guard total > 0 else { throw EntryValidationError.emptyDuration }
        guard total <= 5_999 else { throw EntryValidationError.durationTooLarge }
        return total
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
        note: String?,
        mutationID: UUID = UUID(),
        entryID: UUID = UUID(),
        occurredAt: Date = .now,
        source: EntryMutationSource = .appQuickEntry
    ) async throws -> EntryMutationReceipt {
        let total = try EntryDuration.totalMinutes(hours: hours, minutes: minutes)
        guard (note ?? "").count <= 280 else { throw EntryValidationError.noteTooLong }
        return try await repository.apply(
            EntryMutationCommand(
                mutationID: mutationID,
                entryID: entryID,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: kind,
                    day: LocalDay(date, calendar: .hourleaf),
                    minutes: total,
                    note: note
                ),
                occurredAt: occurredAt,
                source: source
            )
        )
    }
}
