import XCTest
@testable import Hourleaf

final class TimerSessionCommandTests: XCTestCase {
    func testStartRequiresEnabledTimerAndIsIdempotentForRunningState() throws {
        let disabled = try QuickSurfaceStateV1.idleHidden()
        XCTAssertThrowsError(
            try TimerSessionCommandV1.start(
                state: disabled,
                clock: .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20),
                sessionID: UUID()
            )
        )

        let enabled = QuickSurfaceStateV1(
            revision: 2,
            projection: try hiddenProjection(),
            timerEnabled: true,
            timer: .idle
        )
        let running = try TimerSessionCommandV1.start(
            state: enabled,
            clock: .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20),
            sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )
        let replay = try TimerSessionCommandV1.start(
            state: running,
            clock: .init(wallNowEpochSeconds: 120, uptimeNowSeconds: 40),
            sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        )

        XCTAssertEqual(running, replay)
    }

    func testStopUsesSameBootMonotonicSuggestionWhenBootAnchorMatches() throws {
        let running = try runningState(startedAt: 100, uptime: 20)

        let stopped = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(wallNowEpochSeconds: 3_700, uptimeNowSeconds: 3_620),
            mutationID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            entryID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )

        guard case .reviewPending(let review) = stopped.timer else {
            return XCTFail("Expected review pending state.")
        }
        XCTAssertEqual(review.elapsedSeconds, 3_600)
        XCTAssertEqual(review.clockAssessment, .sameBootMonotonic)
        XCTAssertEqual(review.suggestedMinutes, 60)
        XCTAssertEqual(stopped.revision, running.revision + 1)
    }

    func testStopFallsBackToRecoveredWallClockAfterRebootLikeAnchorShift() throws {
        let running = try runningState(startedAt: 100, uptime: 20)

        let stopped = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(wallNowEpochSeconds: 700, uptimeNowSeconds: 3),
            mutationID: UUID(),
            entryID: UUID()
        )

        guard case .reviewPending(let review) = stopped.timer else {
            return XCTFail("Expected review pending state.")
        }
        XCTAssertEqual(review.elapsedSeconds, 600)
        XCTAssertEqual(review.clockAssessment, .recoveredWallClock)
        XCTAssertEqual(review.suggestedMinutes, 10)
    }

    func testStopMarksManualRequiredForNegativeOrTooLargeRecoveredDuration() throws {
        let running = try runningState(startedAt: 100, uptime: 20)

        let negative = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(wallNowEpochSeconds: 90, uptimeNowSeconds: 2),
            mutationID: UUID(),
            entryID: UUID()
        )
        guard case .reviewPending(let negativeReview) = negative.timer else {
            return XCTFail("Expected review pending state.")
        }
        XCTAssertEqual(negativeReview.elapsedSeconds, 0)
        XCTAssertEqual(negativeReview.clockAssessment, .manualRequired)
        XCTAssertNil(negativeReview.suggestedMinutes)

        let veryLong = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(wallNowEpochSeconds: 600_000, uptimeNowSeconds: 2),
            mutationID: UUID(),
            entryID: UUID()
        )
        guard case .reviewPending(let longReview) = veryLong.timer else {
            return XCTFail("Expected review pending state.")
        }
        XCTAssertGreaterThan(longReview.elapsedSeconds, Int64(5_999 * 60))
        XCTAssertEqual(longReview.clockAssessment, .recoveredWallClock)
        XCTAssertNil(longReview.suggestedMinutes)
    }

    func testValidZeroElapsedKeepsClockAssessmentButRequiresManualDuration() throws {
        let running = try runningState(startedAt: 100, uptime: 20)

        let stopped = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(wallNowEpochSeconds: 100.5, uptimeNowSeconds: 20.5),
            mutationID: UUID(),
            entryID: UUID()
        )

        guard case .reviewPending(let review) = stopped.timer else {
            return XCTFail("Expected review pending state.")
        }
        XCTAssertEqual(review.elapsedSeconds, 0)
        XCTAssertEqual(review.clockAssessment, .sameBootMonotonic)
        XCTAssertNil(review.suggestedMinutes)
    }

    func testHugeClockValuesDoNotTrapAndRequireManualDuration() throws {
        let running = try runningState(startedAt: 0, uptime: 0)

        let stopped = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(
                wallNowEpochSeconds: 9_223_372_036_854_775_808.0,
                uptimeNowSeconds: 9_223_372_036_854_775_808.0
            ),
            mutationID: UUID(),
            entryID: UUID()
        )

        guard case .reviewPending(let review) = stopped.timer else {
            return XCTFail("Expected review pending state.")
        }
        XCTAssertEqual(review.elapsedSeconds, 0)
        XCTAssertEqual(review.clockAssessment, .manualRequired)
        XCTAssertNil(review.suggestedMinutes)
    }

    func testRepeatedStopReturnsSamePendingDraft() throws {
        let running = try runningState(startedAt: 100, uptime: 20)
        let first = try TimerSessionCommandV1.stop(
            state: running,
            clock: .init(wallNowEpochSeconds: 190, uptimeNowSeconds: 110),
            mutationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            entryID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )

        let replay = try TimerSessionCommandV1.stop(
            state: first,
            clock: .init(wallNowEpochSeconds: 400, uptimeNowSeconds: 300),
            mutationID: UUID(),
            entryID: UUID()
        )

        XCTAssertEqual(first, replay)
    }

    func testReviewAuthorizationUsesStableIdentityAndIsIdempotentAfterPublish() throws {
        let reviewState = try stoppedState()
        guard case let .reviewPending(review) = reviewState.timer else {
            return XCTFail("Expected review pending state.")
        }

        let finalizing = try TimerSessionCommandV1.authorizeReview(
            state: reviewState,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID,
            kind: .credit,
            day: "2026-08-03",
            minutes: 75,
            authorizedAtEpochSeconds: 500
        )
        let replay = try TimerSessionCommandV1.authorizeReview(
            state: finalizing,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID,
            kind: .credit,
            day: "2026-08-03",
            minutes: 75,
            authorizedAtEpochSeconds: 500
        )

        XCTAssertEqual(replay, finalizing)
        XCTAssertEqual(finalizing.revision, reviewState.revision + 1)
        guard case let .finalizing(payload) = finalizing.timer else {
            return XCTFail("Expected finalizing state.")
        }
        XCTAssertEqual(payload.authorizedKind, .credit)
        XCTAssertEqual(payload.authorizedDay, "2026-08-03")
        XCTAssertEqual(payload.authorizedMinutes, 75)

        XCTAssertThrowsError(
            try TimerSessionCommandV1.authorizeReview(
                state: reviewState,
                expectedSessionID: UUID(),
                expectedMutationID: review.mutationID,
                expectedEntryID: review.entryID,
                kind: .credit,
                day: "2026-08-03",
                minutes: 75,
                authorizedAtEpochSeconds: 500
            )
        ) { error in
            XCTAssertEqual(error as? TimerSessionCommandError, .staleSession)
        }
    }

    func testDiscardClearAndKnownNoCommitRecoveryFollowLegalTransitions() throws {
        let reviewState = try stoppedState()
        guard case let .reviewPending(review) = reviewState.timer else {
            return XCTFail("Expected review pending state.")
        }

        let discarded = try TimerSessionCommandV1.discardReview(
            state: reviewState,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID
        )
        XCTAssertEqual(discarded.timer, .idle)
        XCTAssertEqual(discarded.revision, reviewState.revision + 1)

        let finalizing = try TimerSessionCommandV1.authorizeReview(
            state: reviewState,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID,
            kind: .service,
            day: "2026-08-03",
            minutes: 61,
            authorizedAtEpochSeconds: 500
        )
        let recovered = try TimerSessionCommandV1.returnFinalizingToReview(
            state: finalizing,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID
        )
        guard case let .reviewPending(recoveredReview) = recovered.timer else {
            return XCTFail("Expected recovered review state.")
        }
        XCTAssertEqual(recoveredReview.suggestedMinutes, 61)
        XCTAssertEqual(recoveredReview.mutationID, review.mutationID)
        XCTAssertEqual(recoveredReview.entryID, review.entryID)

        let cleared = try TimerSessionCommandV1.clearFinalizing(
            state: finalizing,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID
        )
        XCTAssertEqual(cleared.timer, .idle)
        XCTAssertEqual(cleared.revision, finalizing.revision + 1)
    }

    func testPreferenceAndProjectionTransitionsPreserveTimerAndAvoidNoOpRevision() throws {
        let idle = QuickSurfaceStateV1(
            revision: 9,
            projection: try hiddenProjection(),
            timerEnabled: false,
            timer: .idle
        )
        let same = try TimerSessionCommandV1.setTimerEnabled(state: idle, enabled: false)
        XCTAssertEqual(same.revision, 9)

        let enabled = try TimerSessionCommandV1.setTimerEnabled(state: idle, enabled: true)
        XCTAssertTrue(enabled.timerEnabled)
        XCTAssertEqual(enabled.revision, 10)

        let running = try TimerSessionCommandV1.start(
            state: enabled,
            clock: .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20),
            sessionID: UUID()
        )
        let updatedProjection = try QuickSurfaceProjectionV1(
            privacyMode: .hideTotals,
            monthKey: nil,
            timeZoneIdentifier: nil,
            serviceMinutes: nil,
            creditMinutes: nil,
            generatedAtEpochSeconds: 200
        )
        let projected = try TimerSessionCommandV1.replaceProjection(
            state: running,
            projection: updatedProjection
        )
        XCTAssertEqual(projected.timer, running.timer)
        XCTAssertEqual(projected.revision, running.revision + 1)
        XCTAssertThrowsError(
            try TimerSessionCommandV1.setTimerEnabled(state: running, enabled: false)
        ) { error in
            XCTAssertEqual(error as? TimerSessionCommandError, .reviewRequired)
        }
    }

    private func runningState(startedAt: Double, uptime: Double) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 5,
            projection: try hiddenProjection(),
            timerEnabled: true,
            timer: .running(
                try .init(
                    sessionID: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
                    startedAtEpochSeconds: startedAt,
                    startedSystemUptimeSeconds: uptime
                )
            )
        )
    }

    private func stoppedState() throws -> QuickSurfaceStateV1 {
        try TimerSessionCommandV1.stop(
            state: runningState(startedAt: 100, uptime: 20),
            clock: .init(wallNowEpochSeconds: 190, uptimeNowSeconds: 110),
            mutationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            entryID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
    }

    private func hiddenProjection() throws -> QuickSurfaceProjectionV1 {
        try QuickSurfaceProjectionV1(
            privacyMode: .hideTotals,
            monthKey: nil,
            timeZoneIdentifier: nil,
            serviceMinutes: nil,
            creditMinutes: nil,
            generatedAtEpochSeconds: 0
        )
    }
}
