import Foundation

enum TimerEntryLedgerStatus: Equatable, Sendable {
    case applied
    case absent
    case mutationIDCollision
    case entryIDCollision
}

enum TimerEntryFinalizationStatus: Equatable, Sendable {
    case mutationIDCollision
    case entryIDCollision
    case sidecarStateChanged
    case ambiguousLedgerState
    case clearFailed
}

enum TimerEntryFinalizationResult: Equatable, Sendable {
    case noFinalizingState
    case idle(receipt: EntryMutationReceipt?)
    case returnedToReview
    case finalizing(TimerEntryFinalizationStatus)
}

private enum TimerEntryFinalizerError: Error {
    case stateChanged
}

/// The host-only bridge from a persisted finalizing timer session to the
/// ledger's existing idempotent mutation path. It never creates replacement
/// identifiers or keeps a second mutation journal.
struct TimerEntryFinalizer: @unchecked Sendable {
    private let repository: any LedgerRepository
    private let stateStore: QuickSurfaceStateStoreV1

    init(
        repository: any LedgerRepository,
        stateStore: QuickSurfaceStateStoreV1
    ) {
        self.repository = repository
        self.stateStore = stateStore
    }

    func finalize() async throws -> TimerEntryFinalizationResult {
        let state = try stateStore.read()
        guard case let .finalizing(finalizing) = state.timer else {
            return .noFinalizingState
        }
        return try await finalize(finalizing)
    }

    func finalize(
        _ finalizing: TimerSessionV1.Finalizing
    ) async throws -> TimerEntryFinalizationResult {
        guard try isCurrent(finalizing) else {
            return .finalizing(.sidecarStateChanged)
        }

        guard let initialSnapshot = try? await repository.ledgerSnapshot() else {
            return .finalizing(.ambiguousLedgerState)
        }

        switch Self.ledgerStatus(for: finalizing, in: initialSnapshot) {
        case .applied:
            return clearVerifiedFinalizing(finalizing, receipt: nil)

        case .mutationIDCollision:
            return .finalizing(.mutationIDCollision)

        case .entryIDCollision:
            return .finalizing(.entryIDCollision)

        case .absent:
            guard let commandInput = commandInput(for: finalizing) else {
                return returnToReview(finalizing)
            }
            guard try isCurrent(finalizing) else {
                return .finalizing(.sidecarStateChanged)
            }

            do {
                let receipt = try await AddTimeEntryCommand(repository: repository).execute(
                    kind: commandInput.kind,
                    date: commandInput.date,
                    hours: commandInput.minutes / 60,
                    minutes: commandInput.minutes % 60,
                    note: nil,
                    mutationID: finalizing.mutationID,
                    entryID: finalizing.entryID,
                    occurredAt: commandInput.occurredAt,
                    source: .timer
                )
                return try await verifyAfterLedgerAttempt(
                    finalizing,
                    receipt: receipt
                )
            } catch {
                return try await recoverAfterFailedLedgerAttempt(
                    error,
                    finalizing: finalizing
                )
            }
        }
    }

    static func ledgerStatus(
        for finalizing: TimerSessionV1.Finalizing,
        in snapshot: LedgerSnapshot
    ) -> TimerEntryLedgerStatus {
        let revisionsForMutation = snapshot.entryRevisions.filter {
            $0.mutationID == finalizing.mutationID
        }
        if !revisionsForMutation.isEmpty {
            guard revisionsForMutation.count == 1,
                  let revision = revisionsForMutation.first,
                  revisionMatches(finalizing, revision: revision)
            else {
                return .mutationIDCollision
            }

            let currentEntries = snapshot.entries.filter { $0.id == finalizing.entryID }
            guard currentEntries.count <= 1 else {
                return .entryIDCollision
            }
            if let currentEntry = currentEntries.first,
               !currentEntry.isDeleted,
               !currentEntryMatches(finalizing, entry: currentEntry) {
                return .entryIDCollision
            }
            return .applied
        }

        let entryExists = snapshot.entries.contains { $0.id == finalizing.entryID }
        let entryHistoryExists = snapshot.entryRevisions.contains { $0.entryID == finalizing.entryID }
        return entryExists || entryHistoryExists ? .entryIDCollision : .absent
    }

    private func verifyAfterLedgerAttempt(
        _ finalizing: TimerSessionV1.Finalizing,
        receipt: EntryMutationReceipt
    ) async throws -> TimerEntryFinalizationResult {
        guard let snapshot = try? await repository.ledgerSnapshot() else {
            return .finalizing(.ambiguousLedgerState)
        }

        switch Self.ledgerStatus(for: finalizing, in: snapshot) {
        case .applied:
            return clearVerifiedFinalizing(finalizing, receipt: receipt)
        case .mutationIDCollision:
            return .finalizing(.mutationIDCollision)
        case .entryIDCollision:
            return .finalizing(.entryIDCollision)
        case .absent:
            return .finalizing(.ambiguousLedgerState)
        }
    }

    private func recoverAfterFailedLedgerAttempt(
        _ error: Error,
        finalizing: TimerSessionV1.Finalizing
    ) async throws -> TimerEntryFinalizationResult {
        guard let snapshot = try? await repository.ledgerSnapshot() else {
            return .finalizing(.ambiguousLedgerState)
        }

        switch Self.ledgerStatus(for: finalizing, in: snapshot) {
        case .applied:
            return clearVerifiedFinalizing(finalizing, receipt: nil)
        case .mutationIDCollision:
            return .finalizing(.mutationIDCollision)
        case .entryIDCollision:
            return .finalizing(.entryIDCollision)
        case .absent:
            return isKnownPrecommitValidation(error)
                ? returnToReview(finalizing)
                : .finalizing(.ambiguousLedgerState)
        }
    }

    private func clearVerifiedFinalizing(
        _ finalizing: TimerSessionV1.Finalizing,
        receipt: EntryMutationReceipt?
    ) -> TimerEntryFinalizationResult {
        do {
            _ = try stateStore.replace { state in
                guard let state, case let .finalizing(current) = state.timer, current == finalizing else {
                    throw TimerEntryFinalizerError.stateChanged
                }
                return try TimerSessionCommandV1.clearFinalizing(
                    state: state,
                    expectedSessionID: finalizing.sessionID,
                    expectedMutationID: finalizing.mutationID,
                    expectedEntryID: finalizing.entryID
                )
            }
            return .idle(receipt: receipt)
        } catch TimerEntryFinalizerError.stateChanged {
            return .finalizing(.sidecarStateChanged)
        } catch {
            return .finalizing(.clearFailed)
        }
    }

    private func returnToReview(
        _ finalizing: TimerSessionV1.Finalizing
    ) -> TimerEntryFinalizationResult {
        do {
            _ = try stateStore.replace { state in
                guard let state, case let .finalizing(current) = state.timer, current == finalizing else {
                    throw TimerEntryFinalizerError.stateChanged
                }
                return try TimerSessionCommandV1.returnFinalizingToReview(
                    state: state,
                    expectedSessionID: finalizing.sessionID,
                    expectedMutationID: finalizing.mutationID,
                    expectedEntryID: finalizing.entryID
                )
            }
            return .returnedToReview
        } catch {
            return .finalizing(.sidecarStateChanged)
        }
    }

    private func isCurrent(
        _ finalizing: TimerSessionV1.Finalizing
    ) throws -> Bool {
        let state = try stateStore.read()
        guard case let .finalizing(current) = state.timer else { return false }
        return current == finalizing
    }

    private func commandInput(
        for finalizing: TimerSessionV1.Finalizing
    ) -> CommandInput? {
        guard let day = LocalDay(key: finalizing.authorizedDay) else { return nil }
        let date = day.date(calendar: .hourleaf)
        guard LocalDay(date, calendar: .hourleaf) == day else { return nil }

        let kind: EntryKind = switch finalizing.authorizedKind {
        case .service: .service
        case .credit: .credit
        }
        return CommandInput(
            kind: kind,
            date: date,
            minutes: finalizing.authorizedMinutes,
            occurredAt: Date(timeIntervalSince1970: finalizing.authorizedAtEpochSeconds)
        )
    }

    private static func revisionMatches(
        _ finalizing: TimerSessionV1.Finalizing,
        revision: EntryRevisionRecord
    ) -> Bool {
        revision.entryID == finalizing.entryID
            && revision.operation == EntryMutationOperation.create.rawValue
            && revision.source == EntryMutationSource.timer.rawValue
            && revision.kind == finalizing.authorizedKind.rawValue
            && revision.localDay == finalizing.authorizedDay
            && revision.minutes == finalizing.authorizedMinutes
            && revision.note == nil
            && revision.occurredAt == Date(timeIntervalSince1970: finalizing.authorizedAtEpochSeconds)
    }

    private static func currentEntryMatches(
        _ finalizing: TimerSessionV1.Finalizing,
        entry: LedgerEntryRecord
    ) -> Bool {
        entry.entry.kind.rawValue == finalizing.authorizedKind.rawValue
            && entry.entry.day.key == finalizing.authorizedDay
            && entry.entry.minutes == finalizing.authorizedMinutes
            && entry.entry.note == nil
    }

    private func isKnownPrecommitValidation(_ error: Error) -> Bool {
        if error is EntryValidationError { return true }
        guard let mutationError = error as? EntryMutationError else { return false }
        switch mutationError {
        case .invalidCommand, .invalidLocalDay, .dateInFuture, .beforeLedgerStart:
            return true
        case .entryNotFound,
             .entryStateChanged,
             .staleRevision,
             .revisionExhausted,
             .mutationIDCollision,
             .undoUnavailable,
             .undoExpired,
             .undoSuperseded:
            return false
        }
    }

    private struct CommandInput {
        let kind: EntryKind
        let date: Date
        let minutes: Int
        let occurredAt: Date
    }
}
