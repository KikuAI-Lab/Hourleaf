import Foundation

enum QuickSurfaceTimerControlRequestV1: Equatable, Sendable {
    case start
    case stop
}

enum QuickSurfaceTimerControlFailureV1: Equatable, Sendable {
    case disabled
    case unavailable
    case protected
    case corrupt
    case busy
    case revisionExhausted
    case invalidClock
}

enum QuickSurfaceTimerControlResultV1: Equatable, Sendable {
    case committed
    case unchanged
    case reviewRequired
    case failed(QuickSurfaceTimerControlFailureV1)
}

/// Performs one request as one state-store transaction. It can start and stop
/// a session, but it cannot authorize review or write a ledger entry.
struct QuickSurfaceTimerControlTransactionV1 {
    private let clock: () -> TimerClockSnapshotV1
    private let uuid: () -> UUID

    init(
        clock: @escaping () -> TimerClockSnapshotV1 = {
            TimerClockSnapshotV1(
                wallNow: .now,
                uptimeNowSeconds: ProcessInfo.processInfo.systemUptime
            )
        },
        uuid: @escaping () -> UUID = UUID.init
    ) {
        self.clock = clock
        self.uuid = uuid
    }

    func perform(
        request: QuickSurfaceTimerControlRequestV1,
        stateStore: QuickSurfaceStateStoreV1
    ) -> QuickSurfaceTimerControlResultV1 {
        do {
            _ = try stateStore.replace { current in
                guard let current else {
                    throw TransactionError.missing
                }

                switch current.timer {
                case .reviewPending, .finalizing:
                    throw TransactionError.reviewRequired
                case .idle:
                    guard request == .start else {
                        throw TransactionError.unchanged
                    }
                    let clockSnapshot = clock()
                    guard Self.isValid(clock: clockSnapshot) else {
                        throw TransactionError.invalidClock
                    }
                    return try TimerSessionCommandV1.start(
                        state: current,
                        clock: clockSnapshot,
                        sessionID: uuid()
                    )
                case .running:
                    guard request == .stop else {
                        guard current.timerEnabled else {
                            throw TransactionError.disabled
                        }
                        throw TransactionError.unchanged
                    }
                    let clockSnapshot = clock()
                    guard Self.isValid(clock: clockSnapshot) else {
                        throw TransactionError.invalidClock
                    }
                    return try TimerSessionCommandV1.stop(
                        state: current,
                        clock: clockSnapshot,
                        mutationID: uuid(),
                        entryID: uuid()
                    )
                }
            }
            return .committed
        } catch TransactionError.unchanged {
            return .unchanged
        } catch TransactionError.reviewRequired {
            return .reviewRequired
        } catch let error as TransactionError {
            return .failed(error.failure)
        } catch let error as TimerSessionCommandError {
            return .failed(Self.failure(for: error))
        } catch let error as QuickSurfaceStateStoreError {
            return .failed(Self.failure(for: error))
        } catch {
            return .failed(.unavailable)
        }
    }

    private static func isValid(clock: TimerClockSnapshotV1) -> Bool {
        clock.wallNowEpochSeconds.isFinite
            && clock.wallNowEpochSeconds >= 0
            && clock.uptimeNowSeconds.isFinite
            && clock.uptimeNowSeconds >= 0
    }

    private static func failure(
        for error: TimerSessionCommandError
    ) -> QuickSurfaceTimerControlFailureV1 {
        switch error {
        case .timerDisabled:
            return .disabled
        case .invalidWallClock:
            return .invalidClock
        case .reviewRequired:
            return .corrupt
        case .revisionExhausted:
            return .revisionExhausted
        case .timerNotRunning, .staleSession:
            return .unavailable
        }
    }

    private static func failure(
        for error: QuickSurfaceStateStoreError
    ) -> QuickSurfaceTimerControlFailureV1 {
        switch error {
        case .accessBusy,
             .leaseUnavailable:
            return .busy
        case .protectedBeforeFirstUnlock,
             .protectionReadbackFailed,
             .backupExclusionReadbackFailed,
             .attributeApplyFailed:
            return .protected
        case .revisionUnavailable,
             .invalidRevisionTransition,
             .invalidInitialRevision:
            return .revisionExhausted
        case .missingFile,
             .invalidRoot,
             .unavailableRoot,
             .leaseReleased,
             .leaseRootMismatch,
             .leaseIdentityMismatch,
             .leaseReleaseFailed:
            return .unavailable
        case .corrupt,
             .unsupportedVersion,
             .pathEscape,
             .symlinkDetected,
             .coordinationFailed,
             .readFailed,
             .writeFailed,
             .readbackMismatch,
             .currentStateMismatch,
             .lockFileInvalid:
            return .corrupt
        }
    }

    private enum TransactionError: Error {
        case missing
        case unchanged
        case reviewRequired
        case invalidClock
        case disabled

        var failure: QuickSurfaceTimerControlFailureV1 {
            switch self {
            case .missing:
                return .unavailable
            case .unchanged, .reviewRequired:
                return .unavailable
            case .invalidClock:
                return .invalidClock
            case .disabled:
                return .disabled
            }
        }
    }
}
