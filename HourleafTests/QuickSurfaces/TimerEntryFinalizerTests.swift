import Foundation
import XCTest
@testable import Hourleaf

final class TimerEntryFinalizerTests: XCTestCase {
    func testAbsentFinalizingStateCreatesExactlyOneTimerEntryAndReturnsReceipt() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing()
        let store = makeStore(root: root).store
        try seed(finalizing: finalizing, in: store)

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: store).finalize()

        guard case let .idle(receipt: receipt?) = result else {
            return XCTFail("Expected an applied receipt and idle state, got \(result).")
        }
        XCTAssertEqual(receipt.mutationID, finalizing.mutationID)
        XCTAssertEqual(receipt.entry.id, finalizing.entryID)
        XCTAssertEqual(receipt.entry.entry.kind, .credit)
        XCTAssertEqual(receipt.entry.entry.day.key, finalizing.authorizedDay)
        XCTAssertEqual(receipt.entry.entry.minutes, finalizing.authorizedMinutes)
        XCTAssertNil(receipt.entry.entry.note)
        XCTAssertEqual(receipt.entry.source, EntryMutationSource.timer.rawValue)

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.count, 1)
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.mutationID == finalizing.mutationID }.count, 1)
        XCTAssertEqual(try store.read().timer, .idle)
    }

    func testLaterDeletedExactAppliedMutationClearsWithoutCreatingOrResurrectingEntry() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing()
        let commandReceipt = try await applyExactTimerCommand(finalizing, repository: repository)
        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(),
                entryID: finalizing.entryID,
                expectedRevision: commandReceipt.appliedRevision,
                operation: .delete,
                occurredAt: now,
                source: .appHistory
            )
        )
        let store = makeStore(root: root).store
        try seed(finalizing: finalizing, in: store)

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: store).finalize()

        XCTAssertEqual(result, .idle(receipt: nil))
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertTrue(snapshot.entries[0].isDeleted)
        XCTAssertTrue(snapshot.activeEntries.isEmpty)
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.mutationID == finalizing.mutationID }.count, 1)
        XCTAssertEqual(try store.read().timer, .idle)
    }

    func testChangedCurrentEntryAfterExactAppliedMutationKeepsFinalizing() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing()
        let commandReceipt = try await applyExactTimerCommand(finalizing, repository: repository)
        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(),
                entryID: finalizing.entryID,
                expectedRevision: commandReceipt.appliedRevision,
                operation: .update,
                values: .init(
                    kind: .credit,
                    day: .init(year: 2026, month: 8, day: 3),
                    minutes: finalizing.authorizedMinutes - 1,
                    note: nil
                ),
                occurredAt: now,
                source: .appHistory
            )
        )
        let store = makeStore(root: root).store
        try seed(finalizing: finalizing, in: store)

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: store).finalize()

        XCTAssertEqual(result, .finalizing(.entryIDCollision))
        XCTAssertEqual(try store.read().timer, .finalizing(finalizing))
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.count, 1)
        XCTAssertEqual(snapshot.activeEntries[0].minutes, finalizing.authorizedMinutes - 1)
        XCTAssertEqual(snapshot.entryRevisions.count, 2)
    }

    func testMutationIDCollisionKeepsFinalizingAndDoesNotGenerateReplacementIDs() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing()
        _ = try await AddTimeEntryCommand(repository: repository).execute(
            kind: .service,
            date: date(year: 2026, month: 8, day: 3, hour: 12),
            hours: 1,
            minutes: 0,
            note: nil,
            mutationID: finalizing.mutationID,
            entryID: UUID(),
            occurredAt: Date(timeIntervalSince1970: finalizing.authorizedAtEpochSeconds),
            source: .timer
        )
        let store = makeStore(root: root).store
        try seed(finalizing: finalizing, in: store)

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: store).finalize()

        XCTAssertEqual(result, .finalizing(.mutationIDCollision))
        XCTAssertEqual(try store.read().timer, .finalizing(finalizing))
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertFalse(snapshot.entries.contains { $0.id == finalizing.entryID })
    }

    func testEntryIDCollisionKeepsFinalizingAndDoesNotWriteSecondEntry() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing()
        _ = try await AddTimeEntryCommand(repository: repository).execute(
            kind: .service,
            date: date(year: 2026, month: 8, day: 3, hour: 12),
            hours: 1,
            minutes: 0,
            note: nil,
            mutationID: UUID(),
            entryID: finalizing.entryID,
            occurredAt: Date(timeIntervalSince1970: finalizing.authorizedAtEpochSeconds),
            source: .appQuickEntry
        )
        let store = makeStore(root: root).store
        try seed(finalizing: finalizing, in: store)

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: store).finalize()

        XCTAssertEqual(result, .finalizing(.entryIDCollision))
        XCTAssertEqual(try store.read().timer, .finalizing(finalizing))
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.entryID == finalizing.entryID }.count, 1)
    }

    func testKnownNoCommitValidationReturnsReviewWithStableIDs() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing(
            day: "2026-08-04",
            authorizedAt: date(year: 2026, month: 8, day: 3, hour: 10)
        )
        let store = makeStore(root: root).store
        try seed(finalizing: finalizing, in: store)

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: store).finalize()

        XCTAssertEqual(result, .returnedToReview)
        guard case let .reviewPending(review) = try store.read().timer else {
            return XCTFail("Expected review pending after known validation failure.")
        }
        XCTAssertEqual(review.sessionID, finalizing.sessionID)
        XCTAssertEqual(review.mutationID, finalizing.mutationID)
        XCTAssertEqual(review.entryID, finalizing.entryID)
        XCTAssertEqual(review.suggestedMinutes, finalizing.authorizedMinutes)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)
    }

    func testVerifiedCommitRemainsFinalizingWhenSidecarClearFails() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let now = date(year: 2026, month: 8, day: 3, hour: 20)
        let repository = try await makeRepository(now: now)
        let finalizing = try makeFinalizing()
        _ = try await applyExactTimerCommand(finalizing, repository: repository)
        let storeParts = makeStore(root: root)
        try seed(finalizing: finalizing, in: storeParts.store)
        let faultingStore = QuickSurfaceStateStoreV1(
            rootDirectory: root,
            faults: .init { point in
                if case .beforePublish = point {
                    throw TimerEntryFinalizerFault.marker
                }
            },
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: storeParts.attributes)
        )

        let result = try await TimerEntryFinalizer(repository: repository, stateStore: faultingStore).finalize()

        XCTAssertEqual(result, .finalizing(.clearFailed))
        XCTAssertEqual(try storeParts.store.read().timer, .finalizing(finalizing))
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
    }

    private func makeStore(root: URL) -> (store: QuickSurfaceStateStoreV1, attributes: QuickSurfaceStoreAttributeLedger) {
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        return (
            QuickSurfaceStateStoreV1(
                rootDirectory: root,
                attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
            ),
            attributes
        )
    }

    private func makeRepository(now: Date) async throws -> CoreDataLedgerRepository {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { now }
        )
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 1)
        try await repository.saveSettings(settings)
        return repository
    }

    private func seed(
        finalizing: TimerSessionV1.Finalizing,
        in store: QuickSurfaceStateStoreV1
    ) throws {
        _ = try store.createIfAbsent(
            QuickSurfaceStateV1(
                revision: 1,
                projection: try .init(
                    privacyMode: .hideTotals,
                    monthKey: nil,
                    timeZoneIdentifier: nil,
                    serviceMinutes: nil,
                    creditMinutes: nil,
                    generatedAtEpochSeconds: 1
                ),
                timerEnabled: true,
                timer: .finalizing(finalizing)
            )
        )
    }

    private func makeFinalizing(
        day: String = "2026-08-03",
        authorizedAt: Date? = nil
    ) throws -> TimerSessionV1.Finalizing {
        let occurredAt = authorizedAt ?? date(year: 2026, month: 8, day: 3, hour: 10)
        return try .init(
            sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAtEpochSeconds: occurredAt.timeIntervalSince1970 - 3_600,
            stoppedAtEpochSeconds: occurredAt.timeIntervalSince1970 - 60,
            elapsedSeconds: 3_540,
            clockAssessment: .sameBootMonotonic,
            suggestedMinutes: 59,
            mutationID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            entryID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            authorizedKind: .credit,
            authorizedDay: day,
            authorizedMinutes: 75,
            authorizedAtEpochSeconds: occurredAt.timeIntervalSince1970
        )
    }

    private func applyExactTimerCommand(
        _ finalizing: TimerSessionV1.Finalizing,
        repository: any LedgerRepository
    ) async throws -> EntryMutationReceipt {
        try await AddTimeEntryCommand(repository: repository).execute(
            kind: .credit,
            date: date(year: 2026, month: 8, day: 3, hour: 12),
            hours: finalizing.authorizedMinutes / 60,
            minutes: finalizing.authorizedMinutes % 60,
            note: nil,
            mutationID: finalizing.mutationID,
            entryID: finalizing.entryID,
            occurredAt: Date(timeIntervalSince1970: finalizing.authorizedAtEpochSeconds),
            source: .timer
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Uzhgorod")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}

private enum TimerEntryFinalizerFault: Error {
    case marker
}
