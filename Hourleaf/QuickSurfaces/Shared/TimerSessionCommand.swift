import Foundation

enum TimerSessionCommandError: LocalizedError, Equatable, Sendable {
    case timerDisabled
    case timerNotRunning
    case reviewRequired
    case staleSession
    case invalidWallClock
    case revisionExhausted

    var errorDescription: String? {
        switch self {
        case .timerDisabled:
            return "Quick-surface timer controls are disabled."
        case .timerNotRunning:
            return "No running timer session is available."
        case .reviewRequired:
            return "The current timer session must be reviewed before starting again."
        case .staleSession:
            return "The timer state changed. Read it again before continuing."
        case .invalidWallClock:
            return "The local wall clock is invalid."
        case .revisionExhausted:
            return "The quick-surface revision cannot advance further."
        }
    }
}

struct TimerClockSnapshotV1: Equatable, Sendable {
    let wallNowEpochSeconds: Double
    let uptimeNowSeconds: Double

    init(wallNowEpochSeconds: Double, uptimeNowSeconds: Double) {
        self.wallNowEpochSeconds = wallNowEpochSeconds
        self.uptimeNowSeconds = uptimeNowSeconds
    }

    init(wallNow: Date, uptimeNowSeconds: TimeInterval) {
        self.init(
            wallNowEpochSeconds: wallNow.timeIntervalSince1970,
            uptimeNowSeconds: uptimeNowSeconds
        )
    }
}

enum TimerSessionCommandV1 {
    private static let bootAnchorToleranceSeconds = 5.0

    static func start(
        state: QuickSurfaceStateV1,
        clock: TimerClockSnapshotV1,
        sessionID: UUID
    ) throws -> QuickSurfaceStateV1 {
        guard state.timerEnabled else {
            throw TimerSessionCommandError.timerDisabled
        }

        switch state.timer {
        case .idle:
            guard clock.wallNowEpochSeconds.isFinite, clock.wallNowEpochSeconds >= 0 else {
                throw TimerSessionCommandError.invalidWallClock
            }
            guard clock.uptimeNowSeconds.isFinite, clock.uptimeNowSeconds >= 0 else {
                throw TimerSessionCommandError.invalidWallClock
            }
            let nextRevision = try nextRevision(from: state)
            return QuickSurfaceStateV1(
                revision: nextRevision,
                projection: state.projection,
                timerEnabled: state.timerEnabled,
                timer: .running(
                    try .init(
                        sessionID: sessionID,
                        startedAtEpochSeconds: clock.wallNowEpochSeconds,
                        startedSystemUptimeSeconds: clock.uptimeNowSeconds
                    )
                )
            )

        case .running:
            return state

        case .reviewPending, .finalizing:
            throw TimerSessionCommandError.reviewRequired
        }
    }

    static func stop(
        state: QuickSurfaceStateV1,
        clock: TimerClockSnapshotV1,
        mutationID: UUID,
        entryID: UUID
    ) throws -> QuickSurfaceStateV1 {
        guard clock.wallNowEpochSeconds.isFinite, clock.wallNowEpochSeconds >= 0 else {
            throw TimerSessionCommandError.invalidWallClock
        }

        switch state.timer {
        case .idle:
            throw TimerSessionCommandError.timerNotRunning

        case .running(let running):
            let evaluation = evaluateStop(running: running, clock: clock)
            let nextRevision = try nextRevision(from: state)
            return QuickSurfaceStateV1(
                revision: nextRevision,
                projection: state.projection,
                timerEnabled: state.timerEnabled,
                timer: .reviewPending(
                    try .init(
                        sessionID: running.sessionID,
                        startedAtEpochSeconds: running.startedAtEpochSeconds,
                        stoppedAtEpochSeconds: clock.wallNowEpochSeconds,
                        elapsedSeconds: evaluation.elapsedSeconds,
                        clockAssessment: evaluation.assessment,
                        suggestedMinutes: evaluation.suggestedMinutes,
                        mutationID: mutationID,
                        entryID: entryID
                    )
                )
            )

        case .reviewPending, .finalizing:
            return state
        }
    }

    static func authorizeReview(
        state: QuickSurfaceStateV1,
        expectedSessionID: UUID,
        expectedMutationID: UUID,
        expectedEntryID: UUID,
        kind: QuickSurfaceAuthorizedKindV1,
        day: String,
        minutes: Int,
        authorizedAtEpochSeconds: Double
    ) throws -> QuickSurfaceStateV1 {
        switch state.timer {
        case let .reviewPending(review):
            try requireIdentity(
                sessionID: review.sessionID,
                mutationID: review.mutationID,
                entryID: review.entryID,
                expectedSessionID: expectedSessionID,
                expectedMutationID: expectedMutationID,
                expectedEntryID: expectedEntryID
            )
            return QuickSurfaceStateV1(
                revision: try nextRevision(from: state),
                projection: state.projection,
                timerEnabled: state.timerEnabled,
                timer: .finalizing(
                    try .init(
                        sessionID: review.sessionID,
                        startedAtEpochSeconds: review.startedAtEpochSeconds,
                        stoppedAtEpochSeconds: review.stoppedAtEpochSeconds,
                        elapsedSeconds: review.elapsedSeconds,
                        clockAssessment: review.clockAssessment,
                        suggestedMinutes: review.suggestedMinutes,
                        mutationID: review.mutationID,
                        entryID: review.entryID,
                        authorizedKind: kind,
                        authorizedDay: day,
                        authorizedMinutes: minutes,
                        authorizedAtEpochSeconds: authorizedAtEpochSeconds
                    )
                )
            )

        case let .finalizing(finalizing):
            try requireIdentity(
                sessionID: finalizing.sessionID,
                mutationID: finalizing.mutationID,
                entryID: finalizing.entryID,
                expectedSessionID: expectedSessionID,
                expectedMutationID: expectedMutationID,
                expectedEntryID: expectedEntryID
            )
            guard
                finalizing.authorizedKind == kind,
                finalizing.authorizedDay == day,
                finalizing.authorizedMinutes == minutes,
                finalizing.authorizedAtEpochSeconds == authorizedAtEpochSeconds
            else {
                throw TimerSessionCommandError.staleSession
            }
            return state

        case .idle, .running:
            throw TimerSessionCommandError.reviewRequired
        }
    }

    static func discardReview(
        state: QuickSurfaceStateV1,
        expectedSessionID: UUID,
        expectedMutationID: UUID,
        expectedEntryID: UUID
    ) throws -> QuickSurfaceStateV1 {
        switch state.timer {
        case .idle:
            return state
        case let .reviewPending(review):
            try requireIdentity(
                sessionID: review.sessionID,
                mutationID: review.mutationID,
                entryID: review.entryID,
                expectedSessionID: expectedSessionID,
                expectedMutationID: expectedMutationID,
                expectedEntryID: expectedEntryID
            )
            return try idleState(advancing: state)
        case .running, .finalizing:
            throw TimerSessionCommandError.reviewRequired
        }
    }

    static func clearFinalizing(
        state: QuickSurfaceStateV1,
        expectedSessionID: UUID,
        expectedMutationID: UUID,
        expectedEntryID: UUID
    ) throws -> QuickSurfaceStateV1 {
        switch state.timer {
        case .idle:
            return state
        case let .finalizing(finalizing):
            try requireIdentity(
                sessionID: finalizing.sessionID,
                mutationID: finalizing.mutationID,
                entryID: finalizing.entryID,
                expectedSessionID: expectedSessionID,
                expectedMutationID: expectedMutationID,
                expectedEntryID: expectedEntryID
            )
            return try idleState(advancing: state)
        case .running, .reviewPending:
            throw TimerSessionCommandError.staleSession
        }
    }

    static func returnFinalizingToReview(
        state: QuickSurfaceStateV1,
        expectedSessionID: UUID,
        expectedMutationID: UUID,
        expectedEntryID: UUID
    ) throws -> QuickSurfaceStateV1 {
        guard case let .finalizing(finalizing) = state.timer else {
            throw TimerSessionCommandError.staleSession
        }
        try requireIdentity(
            sessionID: finalizing.sessionID,
            mutationID: finalizing.mutationID,
            entryID: finalizing.entryID,
            expectedSessionID: expectedSessionID,
            expectedMutationID: expectedMutationID,
            expectedEntryID: expectedEntryID
        )
        return QuickSurfaceStateV1(
            revision: try nextRevision(from: state),
            projection: state.projection,
            timerEnabled: state.timerEnabled,
            timer: .reviewPending(
                try .init(
                    sessionID: finalizing.sessionID,
                    startedAtEpochSeconds: finalizing.startedAtEpochSeconds,
                    stoppedAtEpochSeconds: finalizing.stoppedAtEpochSeconds,
                    elapsedSeconds: finalizing.elapsedSeconds,
                    clockAssessment: finalizing.clockAssessment,
                    suggestedMinutes: finalizing.authorizedMinutes,
                    mutationID: finalizing.mutationID,
                    entryID: finalizing.entryID
                )
            )
        )
    }

    static func setTimerEnabled(
        state: QuickSurfaceStateV1,
        enabled: Bool
    ) throws -> QuickSurfaceStateV1 {
        guard state.timerEnabled != enabled else { return state }
        guard case .idle = state.timer else {
            throw TimerSessionCommandError.reviewRequired
        }
        return QuickSurfaceStateV1(
            revision: try nextRevision(from: state),
            projection: state.projection,
            timerEnabled: enabled,
            timer: state.timer
        )
    }

    static func replaceProjection(
        state: QuickSurfaceStateV1,
        projection: QuickSurfaceProjectionV1
    ) throws -> QuickSurfaceStateV1 {
        guard state.projection != projection else { return state }
        return QuickSurfaceStateV1(
            revision: try nextRevision(from: state),
            projection: projection,
            timerEnabled: state.timerEnabled,
            timer: state.timer
        )
    }

    static func evaluateStop(
        running: TimerSessionV1.Running,
        clock: TimerClockSnapshotV1
    ) -> TimerStopEvaluationV1 {
        let sameBoot: Bool = {
            guard clock.uptimeNowSeconds.isFinite, clock.uptimeNowSeconds >= 0 else {
                return false
            }
            guard clock.uptimeNowSeconds >= running.startedSystemUptimeSeconds else {
                return false
            }
            let startBootAnchor = running.startedAtEpochSeconds - running.startedSystemUptimeSeconds
            let currentBootAnchor = clock.wallNowEpochSeconds - clock.uptimeNowSeconds
            return abs(startBootAnchor - currentBootAnchor) <= bootAnchorToleranceSeconds
        }()

        let elapsedSeconds: Int64
        let assessment: QuickSurfaceClockAssessmentV1

        if sameBoot {
            let monotonicElapsed = floor(clock.uptimeNowSeconds - running.startedSystemUptimeSeconds)
            if let exact = int64IfRepresentable(monotonicElapsed), exact >= 0 {
                elapsedSeconds = exact
                assessment = .sameBootMonotonic
            } else {
                elapsedSeconds = 0
                assessment = .manualRequired
            }
        } else {
            let wallElapsed = clock.wallNowEpochSeconds - running.startedAtEpochSeconds
            if wallElapsed.isFinite, wallElapsed >= 0, let exact = int64IfRepresentable(floor(wallElapsed)) {
                elapsedSeconds = exact
                assessment = .recoveredWallClock
            } else {
                elapsedSeconds = 0
                assessment = .manualRequired
            }
        }

        let suggestedMinutes: Int? = {
            guard assessment != .manualRequired else { return nil }
            guard elapsedSeconds >= 60 else { return nil }
            let minutes = Int(elapsedSeconds / 60)
            return (1...5_999).contains(minutes) ? minutes : nil
        }()

        return TimerStopEvaluationV1(
            elapsedSeconds: elapsedSeconds,
            assessment: assessment,
            suggestedMinutes: suggestedMinutes
        )
    }

    private static func nextRevision(from state: QuickSurfaceStateV1) throws -> UInt64 {
        do {
            return try state.nextRevision()
        } catch {
            throw TimerSessionCommandError.revisionExhausted
        }
    }

    private static func idleState(advancing state: QuickSurfaceStateV1) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: try nextRevision(from: state),
            projection: state.projection,
            timerEnabled: state.timerEnabled,
            timer: .idle
        )
    }

    private static func requireIdentity(
        sessionID: UUID,
        mutationID: UUID,
        entryID: UUID,
        expectedSessionID: UUID,
        expectedMutationID: UUID,
        expectedEntryID: UUID
    ) throws {
        guard
            sessionID == expectedSessionID,
            mutationID == expectedMutationID,
            entryID == expectedEntryID
        else {
            throw TimerSessionCommandError.staleSession
        }
    }

    private static func int64IfRepresentable(_ value: Double) -> Int64? {
        guard value.isFinite, value >= 0 else { return nil }
        // Double(Int64.max) rounds up to 2^63, which traps when converted.
        guard value < 9_223_372_036_854_775_808.0 else { return nil }
        return Int64(value)
    }
}

struct TimerStopEvaluationV1: Equatable, Sendable {
    let elapsedSeconds: Int64
    let assessment: QuickSurfaceClockAssessmentV1
    let suggestedMinutes: Int?
}
