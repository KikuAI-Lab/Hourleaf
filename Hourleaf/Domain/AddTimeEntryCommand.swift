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

struct OneTapProposal: Equatable, Sendable {
    let sourceEntryID: UUID
    let sourceRevision: Int64
    let sourceCreatedAt: Date
    let kind: EntryKind
    let minutes: Int
}

enum OneTapEntryError: LocalizedError, Equatable, Sendable {
    case unavailable
    case proposalChanged

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "error.one_tap_unavailable")
        case .proposalChanged:
            String(localized: "error.one_tap_changed")
        }
    }
}

struct RepeatLastEntryCommand: Sendable {
    let repository: any LedgerRepository

    static func proposal(
        from records: [LedgerEntryRecord]
    ) -> OneTapProposal? {
        records
            .filter { !$0.isDeleted }
            .max { lhs, rhs in
                if lhs.entry.createdAt != rhs.entry.createdAt {
                    return lhs.entry.createdAt < rhs.entry.createdAt
                }
                return lhs.id.uuidString.lowercased()
                    < rhs.id.uuidString.lowercased()
            }
            .map {
                OneTapProposal(
                    sourceEntryID: $0.id,
                    sourceRevision: $0.revision,
                    sourceCreatedAt: $0.entry.createdAt,
                    kind: $0.entry.kind,
                    minutes: $0.entry.minutes
                )
            }
    }

    func execute(
        expected proposal: OneTapProposal,
        at tappedAt: Date = .now,
        mutationID: UUID = UUID(),
        entryID: UUID = UUID()
    ) async throws -> EntryMutationReceipt {
        let snapshot = try await repository.ledgerSnapshot()
        guard let freshProposal = Self.proposal(from: snapshot.entries) else {
            throw OneTapEntryError.unavailable
        }
        guard freshProposal == proposal else {
            throw OneTapEntryError.proposalChanged
        }
        return try await AddTimeEntryCommand(repository: repository).execute(
            kind: freshProposal.kind,
            date: tappedAt,
            hours: freshProposal.minutes / 60,
            minutes: freshProposal.minutes % 60,
            note: nil,
            mutationID: mutationID,
            entryID: entryID,
            occurredAt: tappedAt,
            source: .appOneTap
        )
    }
}
