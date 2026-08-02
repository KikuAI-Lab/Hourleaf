import Foundation

/// The one durable write request for a ledger entry. It deliberately carries
/// only accounting data, so every foreground and future system surface can use
/// the same validation and idempotency path.
enum EntryMutationOperation: String, Codable, CaseIterable, Sendable {
    case create
    case update
    case delete
    case restore
    case undo
}

enum EntryMutationSource: String, Codable, CaseIterable, Sendable {
    case appQuickEntry
    /// Reserved sources keep future foreground and system entry points on the
    /// same durable mutation contract without widening the operation surface.
    case appOneTap
    case shortcut
    case widget
    case watch
    case timer
    case appHistory
    case restore
    case undo
    case migration
}

struct EntryMutationValues: Codable, Equatable, Sendable {
    let kind: EntryKind
    let day: LocalDay
    let minutes: Int
    let note: String?

    init(kind: EntryKind, day: LocalDay, minutes: Int, note: String?) {
        self.kind = kind
        self.day = day
        self.minutes = minutes
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.note = trimmed?.isEmpty == false ? trimmed : nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case day
        case minutes
        case note
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            kind: try container.decode(EntryKind.self, forKey: .kind),
            day: try container.decode(LocalDay.self, forKey: .day),
            minutes: try container.decode(Int.self, forKey: .minutes),
            note: try container.decodeIfPresent(String.self, forKey: .note)
        )
    }
}

struct EntryMutationCommand: Codable, Equatable, Sendable {
    let mutationID: UUID
    let entryID: UUID
    let expectedRevision: Int64?
    let operation: EntryMutationOperation
    let values: EntryMutationValues?
    let revertedMutationID: UUID?
    let occurredAt: Date
    let source: EntryMutationSource

    init(
        mutationID: UUID = UUID(),
        entryID: UUID,
        expectedRevision: Int64?,
        operation: EntryMutationOperation,
        values: EntryMutationValues? = nil,
        revertedMutationID: UUID? = nil,
        occurredAt: Date = .now,
        source: EntryMutationSource
    ) {
        self.mutationID = mutationID
        self.entryID = entryID
        self.expectedRevision = expectedRevision
        self.operation = operation
        self.values = values
        self.revertedMutationID = revertedMutationID
        self.occurredAt = occurredAt
        self.source = source
    }
}

struct EntryMutationReceipt: Equatable, Identifiable, Sendable {
    let mutationID: UUID
    let entry: LedgerEntryRecord
    let operation: EntryMutationOperation
    let appliedRevision: Int64
    let occurredAt: Date
    let undoExpiresAt: Date?
    let wasReplay: Bool

    var id: UUID { mutationID }
}

struct EntryUndoCandidate: Equatable, Identifiable, Sendable {
    let mutationID: UUID
    let entryID: UUID
    let expectedRevision: Int64
    let operation: EntryMutationOperation
    let entry: LedgerEntryRecord
    let occurredAt: Date
    let expiresAt: Date

    var id: UUID { mutationID }
}

enum EntryMutationError: LocalizedError, Equatable, Sendable {
    case invalidCommand
    case entryNotFound
    case entryStateChanged
    case staleRevision
    case revisionExhausted
    case mutationIDCollision
    case invalidLocalDay
    case dateInFuture
    case beforeLedgerStart
    case undoUnavailable
    case undoExpired
    case undoSuperseded

    var errorDescription: String? {
        switch self {
        case .invalidCommand:
            String(localized: "error.entry_command_invalid")
        case .entryNotFound:
            String(localized: "error.entry_not_found")
        case .entryStateChanged, .staleRevision:
            String(localized: "error.entry_changed")
        case .revisionExhausted:
            String(localized: "error.entry_revision_exhausted")
        case .mutationIDCollision:
            String(localized: "error.entry_command_collision")
        case .invalidLocalDay:
            String(localized: "error.invalid_entry_date")
        case .dateInFuture:
            String(localized: "error.entry_future_date")
        case .beforeLedgerStart:
            String(localized: "error.before_ledger_start")
        case .undoUnavailable, .undoExpired:
            String(localized: "error.undo_unavailable")
        case .undoSuperseded:
            String(localized: "error.undo_superseded")
        }
    }
}
