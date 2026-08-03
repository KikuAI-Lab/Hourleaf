@preconcurrency import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class EntryMutationTests: XCTestCase {
    func testCreateReplayIsIdempotentAndCollisionFailsClosed() async throws {
        let repository = try await makeRepository()
        let mutationID = UUID()
        let entry = makeEntry(minutes: 75, note: "First")
        let command = createCommand(for: entry, mutationID: mutationID)

        let first = try await repository.apply(command)
        let replay = try await repository.apply(command)

        XCTAssertFalse(first.wasReplay)
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.entry, first.entry)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 1)
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.entryID == entry.id }.count, 1)

        let collision = EntryMutationCommand(
            mutationID: mutationID,
            entryID: entry.id,
            expectedRevision: nil,
            operation: .create,
            values: EntryMutationValues(kind: .service, day: entry.day, minutes: 90, note: "Different"),
            occurredAt: command.occurredAt,
            source: .appQuickEntry
        )
        do {
            _ = try await repository.apply(collision)
            XCTFail("A reused mutation ID with different values must fail closed.")
        } catch let error as EntryMutationError {
            XCTAssertEqual(error, .mutationIDCollision)
        }
    }

    func testUpdateReplayIsIdempotentAndDoesNotAppendAnotherRevision() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(minutes: 45)
        let created = try await repository.apply(createCommand(for: entry))
        let mutationID = UUID()
        let update = updateCommand(
            entryID: entry.id,
            expectedRevision: created.appliedRevision,
            minutes: 75,
            note: "Updated",
            mutationID: mutationID
        )

        let first = try await repository.apply(update)
        let replay = try await repository.apply(update)

        XCTAssertFalse(first.wasReplay)
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.mutationID, first.mutationID)
        XCTAssertEqual(replay.entry, first.entry)
        XCTAssertEqual(replay.operation, first.operation)
        XCTAssertEqual(replay.appliedRevision, first.appliedRevision)
        XCTAssertEqual(replay.occurredAt, first.occurredAt)
        XCTAssertEqual(replay.undoExpiresAt, first.undoExpiresAt)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.entryID == entry.id }.count, 2)
        XCTAssertEqual(snapshot.activeEntries.first?.minutes, 75)
        XCTAssertEqual(snapshot.activeEntries.first?.note, "Updated")
    }

    func testDeleteAndRestoreReplaysDoNotAppendDuplicateRevisions() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(minutes: 45)
        let created = try await repository.apply(createCommand(for: entry))
        let delete = EntryMutationCommand(
            entryID: entry.id,
            expectedRevision: created.appliedRevision,
            operation: .delete,
            source: .appHistory
        )

        let deleted = try await repository.apply(delete)
        let deletedReplay = try await repository.apply(delete)
        XCTAssertFalse(deleted.wasReplay)
        XCTAssertTrue(deletedReplay.wasReplay)
        XCTAssertEqual(deletedReplay.appliedRevision, deleted.appliedRevision)

        let restore = EntryMutationCommand(
            entryID: entry.id,
            expectedRevision: deleted.appliedRevision,
            operation: .restore,
            source: .restore
        )
        let restored = try await repository.apply(restore)
        let restoredReplay = try await repository.apply(restore)
        XCTAssertFalse(restored.wasReplay)
        XCTAssertTrue(restoredReplay.wasReplay)
        XCTAssertEqual(restoredReplay.appliedRevision, restored.appliedRevision)

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.entryID == entry.id }.count, 3)
        XCTAssertEqual(snapshot.activeEntries.first?.id, entry.id)
    }

    func testStateMismatchesFailClosed() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(minutes: 30)
        let created = try await repository.apply(createCommand(for: entry))

        await assertMutationError(.entryStateChanged) {
            _ = try await repository.apply(createCommand(for: entry))
        }
        await assertMutationError(.entryStateChanged) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: entry.id,
                    expectedRevision: created.appliedRevision,
                    operation: .restore,
                    source: .restore
                )
            )
        }

        let deleted = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                source: .appHistory
            )
        )

        await assertMutationError(.entryStateChanged) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: entry.id,
                    expectedRevision: deleted.appliedRevision,
                    operation: .delete,
                    source: .appHistory
                )
            )
        }
        await assertMutationError(.entryStateChanged) {
            _ = try await repository.apply(
                updateCommand(
                    entryID: entry.id,
                    expectedRevision: deleted.appliedRevision,
                    minutes: 45
                )
            )
        }
        await assertMutationError(.entryNotFound) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: UUID(),
                    expectedRevision: 1,
                    operation: .delete,
                    source: .appHistory
                )
            )
        }
    }

    func testSourceMatrixRejectsCrossOperationSources() async throws {
        let repository = try await makeRepository()
        let allowedCreateSources: [EntryMutationSource] = [
            .appQuickEntry,
            .appOneTap,
            .shortcut,
            .widget,
            .watch,
            .timer
        ]
        for source in allowedCreateSources {
            let entry = makeEntry(minutes: 15)
            let created = try await repository.apply(createCommand(for: entry, source: source))
            XCTAssertEqual(created.entry.id, entry.id)
        }

        let entry = makeEntry(minutes: 30)
        let created = try await repository.apply(createCommand(for: entry))
        await assertMutationError(.invalidCommand) {
            _ = try await repository.apply(createCommand(for: makeEntry(minutes: 15), source: .restore))
        }
        await assertMutationError(.invalidCommand) {
            _ = try await repository.apply(createCommand(for: makeEntry(minutes: 15), source: .undo))
        }
        await assertMutationError(.invalidCommand) {
            _ = try await repository.apply(createCommand(for: makeEntry(minutes: 15), source: .migration))
        }
        await assertMutationError(.invalidCommand) {
            _ = try await repository.apply(
                updateCommand(
                    entryID: entry.id,
                    expectedRevision: created.appliedRevision,
                    minutes: 45,
                    source: .shortcut
                )
            )
        }
        await assertMutationError(.invalidCommand) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: entry.id,
                    expectedRevision: created.appliedRevision,
                    operation: .delete,
                    source: .restore
                )
            )
        }

        let deleted = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                source: .appHistory
            )
        )
        await assertMutationError(.invalidCommand) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: entry.id,
                    expectedRevision: deleted.appliedRevision,
                    operation: .restore,
                    source: .appHistory
                )
            )
        }
    }

    func testDurationComponentsAreValidatedBeforeArithmetic() async throws {
        let repository = try await makeRepository()
        let command = AddTimeEntryCommand(repository: repository)

        await assertValidationError(.invalidHours) {
            _ = try await command.execute(kind: .service, date: Date(), hours: -1, minutes: 0, note: nil)
        }
        await assertValidationError(.invalidMinutes) {
            _ = try await command.execute(kind: .service, date: Date(), hours: 0, minutes: -1, note: nil)
        }
        await assertValidationError(.invalidMinutes) {
            _ = try await command.execute(kind: .service, date: Date(), hours: 0, minutes: 60, note: nil)
        }
        await assertValidationError(.durationTooLarge) {
            _ = try await command.execute(kind: .service, date: Date(), hours: Int.max, minutes: 0, note: nil)
        }
        await assertValidationError(.durationTooLarge) {
            _ = try await command.execute(kind: .service, date: Date(), hours: 100, minutes: 0, note: nil)
        }

        let accepted = try await command.execute(
            kind: .service,
            date: Date(),
            hours: 99,
            minutes: 59,
            note: nil
        )
        XCTAssertEqual(accepted.entry.entry.minutes, 5_999)
    }

    func testImpossibleLocalDayIsRejectedAtTheCommandBoundary() async throws {
        let repository = try await makeRepository()
        let invalidDay = LocalDay(year: 2026, month: 2, day: 31)
        XCTAssertNil(LocalDay(key: invalidDay.key))

        await assertMutationError(.invalidLocalDay) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: UUID(),
                    expectedRevision: nil,
                    operation: .create,
                    values: EntryMutationValues(
                        kind: .service,
                        day: invalidDay,
                        minutes: 15,
                        note: nil
                    ),
                    source: .appQuickEntry
                )
            )
        }
    }

    func testRevisionCeilingReturnsTypedErrorWithoutOverflowing() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        try await configureLedgerStart(repository)
        let entry = makeEntry(minutes: 30)
        let created = try await repository.apply(createCommand(for: entry))

        let context = persistence.container.viewContext
        let request: NSFetchRequest<EntryEntity> = EntryEntity.request()
        request.predicate = NSPredicate(format: "id == %@", entry.id as CVarArg)
        let stored = try XCTUnwrap(context.fetch(request).first)
        stored.revision = Int64.max
        try context.save()

        await assertMutationError(.revisionExhausted) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: entry.id,
                    expectedRevision: Int64.max,
                    operation: .delete,
                    source: .appHistory
                )
            )
        }
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.first(where: { $0.id == entry.id })?.revision, Int64.max)
        XCTAssertEqual(snapshot.entries.first(where: { $0.id == entry.id })?.entry.minutes, entry.minutes)
        XCTAssertEqual(created.appliedRevision, 1)
    }

    func testNewFutureCommandsAreRejectedButExactReplaysSurviveClockRollback() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let commandTime = Date(timeIntervalSince1970: 2_000_000_000)
        let forwardRepository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { commandTime }
        )
        try await configureLedgerStart(forwardRepository)
        let entry = makeEntry(minutes: 15, updatedAt: commandTime)
        let command = createCommand(for: entry, occurredAt: commandTime)
        _ = try await forwardRepository.apply(command)

        let rolledBackRepository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { commandTime.addingTimeInterval(-1) }
        )
        let replay = try await rolledBackRepository.apply(command)
        XCTAssertTrue(replay.wasReplay)
        await assertMutationError(.invalidCommand) {
            _ = try await rolledBackRepository.apply(
                createCommand(for: makeEntry(minutes: 15), occurredAt: commandTime)
            )
        }
    }

    func testStaleEditFailsAfterTheEntryIsDeleted() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(minutes: 60)
        let created = try await repository.apply(createCommand(for: entry))
        let staleEdit = updateCommand(
            entryID: entry.id,
            expectedRevision: created.appliedRevision,
            minutes: 90
        )

        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                source: .appHistory
            )
        )

        await assertMutationError(.staleRevision) {
            _ = try await repository.apply(staleEdit)
        }
    }

    func testNoteNormalizationAndLedgerStartBoundsAreEnforcedAtTheCommandBoundary() async throws {
        let repository = try await makeRepository()
        let settings = try await repository.loadSettings()
        let startDay = LocalDay(
            year: settings.ledgerStartMonth.year,
            month: settings.ledgerStartMonth.month,
            day: 1
        )
        let inBoundsEntry = TimeEntry(
            kind: .service,
            day: startDay,
            minutes: 15,
            note: nil,
            createdAt: .now,
            updatedAt: .now
        )
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: inBoundsEntry.id,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: inBoundsEntry.kind,
                    day: inBoundsEntry.day,
                    minutes: inBoundsEntry.minutes,
                    note: "  Morning call  \n"
                ),
                source: .appQuickEntry
            )
        )
        let snapshot = try await repository.ledgerSnapshot()
        let stored = snapshot.activeEntries.first { $0.id == inBoundsEntry.id }
        XCTAssertEqual(stored?.note, "Morning call")

        let beforeStart = settings.ledgerStartMonth.advanced(by: -1, calendar: .hourleaf)
        await assertMutationError(.beforeLedgerStart) {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: UUID(),
                    expectedRevision: nil,
                    operation: .create,
                    values: EntryMutationValues(
                        kind: .service,
                        day: LocalDay(year: beforeStart.year, month: beforeStart.month, day: 1),
                        minutes: 15,
                        note: "Before start"
                    ),
                    source: .appQuickEntry
                )
            )
        }
    }

    func testConcurrentStaleUpdatesApplyOnlyOneExactRevision() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(minutes: 60)
        let created = try await repository.apply(createCommand(for: entry))
        let first = updateCommand(
            entryID: entry.id,
            expectedRevision: created.appliedRevision,
            minutes: 75,
            occurredAt: Date()
        )
        let second = updateCommand(
            entryID: entry.id,
            expectedRevision: created.appliedRevision,
            minutes: 90,
            occurredAt: Date()
        )

        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            group.addTask { (try? await repository.apply(first)) != nil }
            group.addTask { (try? await repository.apply(second)) != nil }
            var collected: [Bool] = []
            for await result in group { collected.append(result) }
            return collected
        }

        XCTAssertEqual(results.filter { $0 }.count, 1)
        let snapshot = try await repository.ledgerSnapshot()
        let record = try XCTUnwrap(snapshot.entries.first { $0.id == entry.id })
        XCTAssertEqual(record.revision, 2)
        XCTAssertTrue([75, 90].contains(record.entry.minutes))
        XCTAssertEqual(snapshot.entryRevisions.filter { $0.entryID == entry.id }.count, 2)
    }

    func testDeleteImmediatelyExcludesTotalsAndRestoreReturnsEntry() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(kind: .service, minutes: 75)
        let created = try await repository.apply(createCommand(for: entry))
        let deleted = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                occurredAt: Date(),
                source: .appHistory
            )
        )

        var snapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(snapshot.activeEntries.isEmpty)
        XCTAssertEqual(snapshot.deletedEntries.map(\.id), [entry.id])
        let reportAfterDelete = ReportCalculator.timeline(
            entries: snapshot.activeEntries,
            from: entry.day.monthKey,
            through: entry.day.monthKey,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: entry.day.monthKey)]
        )
        XCTAssertEqual(reportAfterDelete.first?.rawServiceMinutes, 0)

        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: deleted.appliedRevision,
                operation: .restore,
                occurredAt: Date(),
                source: .restore
            )
        )
        snapshot = try await repository.ledgerSnapshot()
        let restored = try XCTUnwrap(snapshot.activeEntries.first)
        XCTAssertEqual(restored.id, entry.id)
        XCTAssertEqual(restored.kind, entry.kind)
        XCTAssertEqual(restored.day, entry.day)
        XCTAssertEqual(restored.minutes, entry.minutes)
        XCTAssertEqual(restored.note, entry.note)
        XCTAssertTrue(snapshot.deletedEntries.isEmpty)
    }

    func testUndoCreateMovesEntryToRecentlyDeleted() async throws {
        let repository = try await makeRepository()
        let entry = makeEntry(minutes: 45)
        let created = try await repository.apply(createCommand(for: entry))
        let maybeCandidate = try await repository.latestUndoCandidate(asOf: Date())
        let candidate = try XCTUnwrap(maybeCandidate)
        XCTAssertEqual(candidate.mutationID, created.mutationID)

        let undone = try await undo(repository, candidate: candidate)
        let snapshot = try await repository.ledgerSnapshot()

        XCTAssertEqual(undone.operation, .undo)
        XCTAssertTrue(snapshot.activeEntries.isEmpty)
        XCTAssertEqual(snapshot.deletedEntries.first?.id, entry.id)
        XCTAssertEqual(snapshot.entryRevisions.last?.revertedMutationID, created.mutationID)
    }

    func testUndoUpdateRestoresPriorSnapshot() async throws {
        let repository = try await makeRepository()
        let createdAt = Date().addingTimeInterval(-60)
        let entry = makeEntry(kind: .credit, minutes: 45, note: "Original", updatedAt: createdAt)
        let created = try await repository.apply(createCommand(for: entry, occurredAt: createdAt))
        let updated = try await repository.apply(
            updateCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                minutes: 90,
                note: "Changed",
                occurredAt: createdAt.addingTimeInterval(1)
            )
        )
        let maybeCandidate = try await repository.latestUndoCandidate(asOf: Date())
        let candidate = try XCTUnwrap(maybeCandidate)
        XCTAssertEqual(candidate.mutationID, updated.mutationID)

        _ = try await undo(repository, candidate: candidate)
        let restoredSnapshot = try await repository.ledgerSnapshot()
        let restored = try XCTUnwrap(restoredSnapshot.activeEntries.first)
        XCTAssertEqual(restored.kind, .credit)
        XCTAssertEqual(restored.minutes, 45)
        XCTAssertEqual(restored.note, "Original")
    }

    func testUndoDeleteRestoresAndUndoRestoreDeletesAgain() async throws {
        let repository = try await makeRepository()
        let createdAt = Date().addingTimeInterval(-60)
        let entry = makeEntry(minutes: 30, updatedAt: createdAt)
        let created = try await repository.apply(createCommand(for: entry, occurredAt: createdAt))
        let deleted = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                occurredAt: createdAt.addingTimeInterval(1),
                source: .appHistory
            )
        )
        let maybeDeleteCandidate = try await repository.latestUndoCandidate(asOf: Date())
        let deleteCandidate = try XCTUnwrap(maybeDeleteCandidate)
        XCTAssertEqual(deleteCandidate.mutationID, deleted.mutationID)
        let undoDelete = try await undo(repository, candidate: deleteCandidate)
        XCTAssertFalse(undoDelete.entry.isDeleted)

        // Make a fresh delete and restore, then undo that restore.
        try? await Task.sleep(for: .milliseconds(5))
        let afterUndoSnapshot = try await repository.ledgerSnapshot()
        let active = try XCTUnwrap(afterUndoSnapshot.entries.first)
        let deletedAgain = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: active.revision,
                operation: .delete,
                occurredAt: Date(),
                source: .appHistory
            )
        )
        try? await Task.sleep(for: .milliseconds(5))
        let actuallyRestored = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: deletedAgain.appliedRevision,
                operation: .restore,
                occurredAt: Date(),
                source: .restore
            )
        )
        let maybeRestoreCandidate = try await repository.latestUndoCandidate(asOf: Date())
        let restoreCandidate = try XCTUnwrap(maybeRestoreCandidate)
        XCTAssertEqual(restoreCandidate.mutationID, actuallyRestored.mutationID)
        _ = try await undo(repository, candidate: restoreCandidate)
        let finalSnapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(finalSnapshot.activeEntries.isEmpty)
    }

    func testUndoWindowIsStrictlyLessThanTenMinutes() async throws {
        let repository = try await makeRepository()
        let occurredAt = Date().addingTimeInterval(-600)
        let entry = makeEntry(minutes: 15, updatedAt: occurredAt)
        _ = try await repository.apply(createCommand(for: entry, occurredAt: occurredAt))

        let beforeBoundary = try await repository.latestUndoCandidate(
            asOf: occurredAt.addingTimeInterval(599.999)
        )
        let atBoundary = try await repository.latestUndoCandidate(
            asOf: occurredAt.addingTimeInterval(600)
        )

        XCTAssertNotNil(beforeBoundary)
        XCTAssertNil(atBoundary)
    }

    func testApplyUndoHonorsStrictTenMinuteBoundaryWithInjectedClock() async throws {
        let beforeBoundary = Date(timeIntervalSince1970: 2_000_000_000)
        let beforePersistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let beforeRepository = CoreDataLedgerRepository(
            persistence: beforePersistence,
            clock: { beforeBoundary }
        )
        try await configureLedgerStart(beforeRepository)
        let beforeEntry = makeEntry(
            minutes: 15,
            updatedAt: beforeBoundary.addingTimeInterval(-599.999)
        )
        let beforeCreated = try await beforeRepository.apply(
            createCommand(for: beforeEntry, occurredAt: beforeEntry.updatedAt)
        )
        let beforeUndo = try await beforeRepository.apply(
            EntryMutationCommand(
                entryID: beforeEntry.id,
                expectedRevision: beforeCreated.appliedRevision,
                operation: .undo,
                revertedMutationID: beforeCreated.mutationID,
                occurredAt: beforeBoundary,
                source: .undo
            )
        )
        XCTAssertEqual(beforeUndo.operation, .undo)

        let atBoundary = Date(timeIntervalSince1970: 2_000_001_000)
        let boundaryPersistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let boundaryRepository = CoreDataLedgerRepository(
            persistence: boundaryPersistence,
            clock: { atBoundary }
        )
        try await configureLedgerStart(boundaryRepository)
        let boundaryEntry = makeEntry(
            minutes: 15,
            updatedAt: atBoundary.addingTimeInterval(-600)
        )
        let boundaryCreated = try await boundaryRepository.apply(
            createCommand(for: boundaryEntry, occurredAt: boundaryEntry.updatedAt)
        )
        await assertMutationError(.undoExpired) {
            _ = try await boundaryRepository.apply(
                EntryMutationCommand(
                    entryID: boundaryEntry.id,
                    expectedRevision: boundaryCreated.appliedRevision,
                    operation: .undo,
                    revertedMutationID: boundaryCreated.mutationID,
                    occurredAt: atBoundary,
                    source: .undo
                )
            )
        }

        let afterBoundary = Date(timeIntervalSince1970: 2_000_002_000)
        let afterPersistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let afterRepository = CoreDataLedgerRepository(
            persistence: afterPersistence,
            clock: { afterBoundary }
        )
        try await configureLedgerStart(afterRepository)
        let afterEntry = makeEntry(
            minutes: 15,
            updatedAt: afterBoundary.addingTimeInterval(-600.001)
        )
        let afterCreated = try await afterRepository.apply(
            createCommand(for: afterEntry, occurredAt: afterEntry.updatedAt)
        )
        await assertMutationError(.undoExpired) {
            _ = try await afterRepository.apply(
                EntryMutationCommand(
                    entryID: afterEntry.id,
                    expectedRevision: afterCreated.appliedRevision,
                    operation: .undo,
                    revertedMutationID: afterCreated.mutationID,
                    occurredAt: afterBoundary,
                    source: .undo
                )
            )
        }
    }

    func testRestartKeepsEligibleUndoButAnUndoRevisionBlocksOlderCandidates() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        try await configureLedgerStart(repository)
        let first = makeEntry(minutes: 15, updatedAt: Date().addingTimeInterval(-30))
        let second = makeEntry(minutes: 20, updatedAt: Date().addingTimeInterval(-10))
        _ = try await repository.apply(createCommand(for: first, occurredAt: first.updatedAt))
        _ = try await repository.apply(createCommand(for: second, occurredAt: second.updatedAt))

        let restartedRepository = CoreDataLedgerRepository(persistence: persistence)
        let maybeCandidate = try await restartedRepository.latestUndoCandidate(asOf: Date())
        let candidate = try XCTUnwrap(maybeCandidate)
        XCTAssertEqual(candidate.entryID, second.id)
        _ = try await undo(restartedRepository, candidate: candidate)
        let afterUndo = try await restartedRepository.latestUndoCandidate(asOf: Date())
        XCTAssertNil(afterUndo)
    }

    func testFutureAccountingDateIsRejected() async throws {
        let repository = try await makeRepository()
        let tomorrow = Calendar.hourleaf.date(byAdding: .day, value: 1, to: Date())!
        let entry = TimeEntry(
            kind: .service,
            day: LocalDay(tomorrow, calendar: .hourleaf),
            minutes: 15,
            createdAt: .now,
            updatedAt: .now
        )

        do {
            _ = try await repository.apply(createCommand(for: entry))
            XCTFail("A future accounting day must be rejected.")
        } catch let error as EntryMutationError {
            XCTAssertEqual(error, .dateInFuture)
        }
    }

    func testMigrationRevisionsNeverSurfaceAsUndoCandidates() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        try await configureLedgerStart(repository)
        let entry = makeEntry(minutes: 15)
        _ = try await repository.apply(createCommand(for: entry))

        let context = persistence.container.viewContext
        let request: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        request.predicate = NSPredicate(format: "entryID == %@", entry.id as CVarArg)
        let revision = try XCTUnwrap(context.fetch(request).first)
        revision.source = EntryMutationSource.migration.rawValue
        try context.save()

        let undoCandidate = try await repository.latestUndoCandidate(asOf: Date())
        XCTAssertNil(undoCandidate)
    }

    func testAppModelShowsUndoForAConfirmedQuickEntry() async throws {
        let repository = try await makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: NoopReminderScheduler())
        await model.loadInitialSnapshot()

        let added = await model.addEntry(kind: .service, date: Date(), hours: 1, minutes: 15, note: nil)

        XCTAssertTrue(added)
        XCTAssertNotNil(model.undoCandidate)
        XCTAssertNotNil(model.visibleUndoCandidate)
    }

    func testRefreshAfterRestoreReplacesSnapshotAndClearsUndoState() async throws {
        let repository = try await makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: NoopReminderScheduler())
        await model.loadInitialSnapshot()

        let added = await model.addEntry(
            kind: .service,
            date: Date(),
            hours: 1,
            minutes: 15,
            note: nil
        )
        XCTAssertTrue(added)
        let staleRecord = try XCTUnwrap(model.entryRecords.first)
        XCTAssertNotNil(model.undoCandidate)
        XCTAssertNotNil(model.visibleUndoCandidate)

        _ = try await repository.apply(updateCommand(
            entryID: staleRecord.id,
            expectedRevision: staleRecord.revision,
            minutes: 30,
            note: "Restored"
        ))
        XCTAssertEqual(model.entries.first?.minutes, 75)

        try await model.refreshAfterRestore()

        XCTAssertEqual(model.entries.first?.minutes, 30)
        XCTAssertEqual(model.entryRecords.first?.revision, staleRecord.revision + 1)
        XCTAssertNil(model.undoCandidate)
        XCTAssertNil(model.visibleUndoCandidate)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testAppModelExplainsMaintenanceInsteadOfShowingAGenericDataError() async throws {
        let repository = try await makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: NoopReminderScheduler())
        await model.loadInitialSnapshot()
        let lease = try await repository.acquireMaintenanceLease()

        await model.reload()

        XCTAssertEqual(model.errorMessage, String(localized: "error.restore_in_progress"))
        try await repository.releaseMaintenanceLease(lease)
    }

    func testAppModelRejectsInvalidUpdateComponentsWithoutChangingTheRecord() async throws {
        let repository = try await makeRepository()
        let model = AppModel(repository: repository, reminderScheduler: NoopReminderScheduler())
        await model.loadInitialSnapshot()
        let added = await model.addEntry(kind: .service, date: Date(), hours: 1, minutes: 0, note: nil)
        XCTAssertTrue(added)
        let record = try XCTUnwrap(model.entryRecords.first)

        let negativeHours = await model.updateEntry(
            record,
            kind: .service,
            date: Date(),
            hours: -1,
            minutes: 0,
            note: nil
        )
        XCTAssertFalse(negativeHours)
        XCTAssertEqual(model.errorMessage, EntryValidationError.invalidHours.localizedDescription)
        let invalidMinutes = await model.updateEntry(
            record,
            kind: .service,
            date: Date(),
            hours: 0,
            minutes: 60,
            note: nil
        )
        XCTAssertFalse(invalidMinutes)
        XCTAssertEqual(model.errorMessage, EntryValidationError.invalidMinutes.localizedDescription)
        let overflowingHours = await model.updateEntry(
            record,
            kind: .service,
            date: Date(),
            hours: Int.max,
            minutes: 0,
            note: nil
        )
        XCTAssertFalse(overflowingHours)
        XCTAssertEqual(model.errorMessage, EntryValidationError.durationTooLarge.localizedDescription)

        let snapshot = try await repository.ledgerSnapshot()
        let stored = try XCTUnwrap(snapshot.entries.first(where: { $0.id == record.id }))
        XCTAssertEqual(stored.revision, record.revision)
        XCTAssertEqual(stored.entry.minutes, record.entry.minutes)
    }

    func testAppModelRetainsDeletedRecordsOlderThanThirtyDays() async throws {
        let repository = try await makeRepository()
        let deletedAt = Date().addingTimeInterval(-31 * 24 * 60 * 60)
        let entry = makeEntry(minutes: 15, updatedAt: deletedAt)
        let created = try await repository.apply(createCommand(for: entry, occurredAt: deletedAt))
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                occurredAt: deletedAt.addingTimeInterval(1),
                source: .appHistory
            )
        )

        let model = AppModel(repository: repository, reminderScheduler: NoopReminderScheduler())
        await model.loadInitialSnapshot()
        XCTAssertTrue(model.entryRecords.isEmpty)
        XCTAssertEqual(model.deletedEntryRecords.map(\.id), [entry.id])
    }

    func testRelevantMutationsMoveReviewedAndSentCheckpointsToChangedAndExactReversalRestoresStableState() async throws {
        let june = MonthKey(year: 2026, month: 6)
        let july = MonthKey(year: 2026, month: 7)
        let authorizationTime = makeDate(year: 2026, month: 8, day: 1, hour: 13, minute: 8)
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { authorizationTime }
        )
        try await configureLedgerStart(repository, month: june)
        let baseDay = LocalDay(year: 2026, month: 7, day: 5)
        let secondDay = LocalDay(year: 2026, month: 7, day: 6)
        let baseEntry = makeFixedEntry(
            id: "50000000-0000-0000-0000-000000000001",
            day: baseDay,
            minutes: 120,
            createdAt: makeDate(year: 2026, month: 7, day: 5, hour: 9)
        )
        let baseCreate = try await repository.apply(
            createCommand(for: baseEntry, occurredAt: baseEntry.updatedAt)
        )
        let reviewedDraft = try await reportDraft(from: repository, month: july)
        let reviewedAt = makeDate(year: 2026, month: 8, day: 1, hour: 8)
        let reviewedLedger = try await repository.reviewReport(
            ReviewReportRequest(
                month: july,
                expectedCalculationFingerprint: reviewedDraft.calculationFingerprint,
                expectedPresentationFingerprint: reviewedDraft.presentationFingerprint,
                reviewedAt: reviewedAt
            )
        )
        let reviewedState = try reportState(for: july, in: reviewedLedger)
        XCTAssertEqual(reviewedState.state, .reviewed)
        XCTAssertNil(reviewedState.currentSnapshotID)

        let extraEntry = makeFixedEntry(
            id: "50000000-0000-0000-0000-000000000002",
            day: secondDay,
            minutes: 30,
            createdAt: makeDate(year: 2026, month: 8, day: 1, hour: 9)
        )
        let extraCreate = try await repository.apply(
            createCommand(for: extraEntry, occurredAt: extraEntry.updatedAt)
        )
        let afterRelevantCreate = try await repository.ledgerSnapshot()
        let changedReviewedState = try reportState(for: july, in: afterRelevantCreate)
        XCTAssertEqual(changedReviewedState.state, .changed)
        XCTAssertEqual(changedReviewedState.lastStableState, .reviewed)
        XCTAssertNil(changedReviewedState.currentSnapshotID)
        XCTAssertEqual(changedReviewedState.reviewedCalculationFingerprint, reviewedState.reviewedCalculationFingerprint)
        XCTAssertEqual(changedReviewedState.reviewedPresentationFingerprint, reviewedState.reviewedPresentationFingerprint)

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000003")!,
                entryID: extraEntry.id,
                expectedRevision: extraCreate.appliedRevision,
                operation: .delete,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 10),
                source: .appHistory
            )
        )
        let afterExactDelete = try await repository.ledgerSnapshot()
        let restoredReviewedState = try reportState(for: july, in: afterExactDelete)
        XCTAssertEqual(restoredReviewedState.state, .reviewed)
        XCTAssertNil(restoredReviewedState.lastStableState)
        XCTAssertNil(restoredReviewedState.changedAt)
        XCTAssertEqual(restoredReviewedState.currentSnapshotID, reviewedState.currentSnapshotID)
        XCTAssertEqual(restoredReviewedState.reviewedCalculationFingerprint, reviewedState.reviewedCalculationFingerprint)
        XCTAssertEqual(restoredReviewedState.reviewedPresentationFingerprint, reviewedState.reviewedPresentationFingerprint)

        let sentDraft = try await reportDraft(from: repository, month: july)
        let prepared = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: sentDraft.calculationFingerprint,
                expectedPresentationFingerprint: sentDraft.presentationFingerprint,
                snapshotID: UUID(uuidString: "50000000-0000-0000-0000-000000000010")!,
                preparedAt: makeDate(year: 2026, month: 8, day: 1, hour: 11)
            )
        )
        let sentLedger = try await repository.markReportSent(
            MarkReportSentRequest(
                snapshotID: prepared.snapshot.id,
                confirmedAt: makeDate(year: 2026, month: 8, day: 1, hour: 12)
            )
        )
        let sentState = try reportState(for: july, in: sentLedger)
        let immutableSnapshot = try reportSnapshot(id: prepared.snapshot.id, in: sentLedger)
        XCTAssertEqual(sentState.state, .sent)
        XCTAssertEqual(sentState.currentSnapshotID, prepared.snapshot.id)

        let updateReceipt = try await repository.apply(
            updateCommand(
                entryID: baseEntry.id,
                expectedRevision: baseCreate.appliedRevision,
                kind: .service,
                day: baseDay,
                minutes: 180,
                note: nil,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 13),
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000011")!
            )
        )
        let afterSentUpdate = try await repository.ledgerSnapshot()
        let changedSentState = try reportState(for: july, in: afterSentUpdate)
        XCTAssertEqual(changedSentState.state, .changed)
        XCTAssertEqual(changedSentState.lastStableState, .sent)
        XCTAssertEqual(changedSentState.currentSnapshotID, prepared.snapshot.id)
        XCTAssertEqual(try reportSnapshot(id: prepared.snapshot.id, in: afterSentUpdate), immutableSnapshot)

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000012")!,
                entryID: baseEntry.id,
                expectedRevision: updateReceipt.appliedRevision,
                operation: .undo,
                revertedMutationID: updateReceipt.mutationID,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 13, minute: 5),
                source: .undo
            )
        )
        let afterExactUndo = try await repository.ledgerSnapshot()
        let restoredSentAfterUndo = try reportState(for: july, in: afterExactUndo)
        XCTAssertEqual(restoredSentAfterUndo.state, .sent)
        XCTAssertNil(restoredSentAfterUndo.lastStableState)
        XCTAssertNil(restoredSentAfterUndo.changedAt)
        XCTAssertEqual(restoredSentAfterUndo.currentSnapshotID, prepared.snapshot.id)
        XCTAssertEqual(try reportSnapshot(id: prepared.snapshot.id, in: afterExactUndo), immutableSnapshot)

        let currentBaseRecord = try ledgerRecord(id: baseEntry.id, in: afterExactUndo)
        let deleteReceipt = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000013")!,
                entryID: baseEntry.id,
                expectedRevision: currentBaseRecord.revision,
                operation: .delete,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 13, minute: 6),
                source: .appHistory
            )
        )
        let afterSentDelete = try await repository.ledgerSnapshot()
        let changedSentAfterDelete = try reportState(for: july, in: afterSentDelete)
        XCTAssertEqual(changedSentAfterDelete.state, .changed)
        XCTAssertEqual(changedSentAfterDelete.lastStableState, .sent)
        XCTAssertEqual(changedSentAfterDelete.currentSnapshotID, prepared.snapshot.id)
        XCTAssertEqual(try reportSnapshot(id: prepared.snapshot.id, in: afterSentDelete), immutableSnapshot)

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000014")!,
                entryID: baseEntry.id,
                expectedRevision: deleteReceipt.appliedRevision,
                operation: .restore,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 13, minute: 7),
                source: .restore
            )
        )
        let afterExactRestore = try await repository.ledgerSnapshot()
        let restoredSentAfterRestore = try reportState(for: july, in: afterExactRestore)
        XCTAssertEqual(restoredSentAfterRestore.state, .sent)
        XCTAssertNil(restoredSentAfterRestore.lastStableState)
        XCTAssertNil(restoredSentAfterRestore.changedAt)
        XCTAssertEqual(restoredSentAfterRestore.currentSnapshotID, prepared.snapshot.id)
        XCTAssertEqual(try reportSnapshot(id: prepared.snapshot.id, in: afterExactRestore), immutableSnapshot)
    }

    func testNoteOnlyEditLeavesPreparedCheckpointAndImmutableSnapshotUnchanged() async throws {
        let june = MonthKey(year: 2026, month: 6)
        let july = MonthKey(year: 2026, month: 7)
        let repository = try await makeRepository(ledgerStartMonth: june)
        let entry = makeFixedEntry(
            id: "60000000-0000-0000-0000-000000000001",
            day: LocalDay(year: 2026, month: 7, day: 8),
            minutes: 75,
            note: "Initial note",
            createdAt: makeDate(year: 2026, month: 7, day: 8, hour: 9)
        )
        let created = try await repository.apply(createCommand(for: entry, occurredAt: entry.updatedAt))
        let draft = try await reportDraft(from: repository, month: july)
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                reviewedAt: makeDate(year: 2026, month: 8, day: 1, hour: 8)
            )
        )
        let prepared = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                snapshotID: UUID(uuidString: "60000000-0000-0000-0000-000000000010")!,
                preparedAt: makeDate(year: 2026, month: 8, day: 1, hour: 9)
            )
        )
        let beforeEdit = prepared.ledger
        let preparedState = try reportState(for: july, in: beforeEdit)
        let immutableSnapshot = try reportSnapshot(id: prepared.snapshot.id, in: beforeEdit)

        _ = try await repository.apply(
            updateCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                kind: .service,
                day: entry.day,
                minutes: entry.minutes,
                note: "Edited note only",
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 10),
                mutationID: UUID(uuidString: "60000000-0000-0000-0000-000000000011")!
            )
        )
        let afterEdit = try await repository.ledgerSnapshot()
        XCTAssertEqual(try reportState(for: july, in: afterEdit), preparedState)
        XCTAssertEqual(try reportSnapshot(id: prepared.snapshot.id, in: afterEdit), immutableSnapshot)
        XCTAssertEqual(try ledgerRecord(id: entry.id, in: afterEdit).entry.note, "Edited note only")
    }

    func testCrossMonthMoveUnderDiscardMarksBothPreparedMonthsChangedWithoutReplacingSnapshots() async throws {
        let june = MonthKey(year: 2026, month: 6)
        let july = MonthKey(year: 2026, month: 7)
        let repository = try await makeRepository(ledgerStartMonth: june)
        try await repository.savePolicy(
            ReportingPolicy(
                id: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!,
                effectiveMonth: june,
                mode: .discard,
                createdAt: makeDate(year: 2026, month: 6, day: 1, hour: 0)
            )
        )

        let juneEntry = makeFixedEntry(
            id: "70000000-0000-0000-0000-000000000010",
            day: LocalDay(year: 2026, month: 6, day: 30),
            minutes: 60,
            createdAt: makeDate(year: 2026, month: 6, day: 30, hour: 9)
        )
        let julyEntry = makeFixedEntry(
            id: "70000000-0000-0000-0000-000000000011",
            day: LocalDay(year: 2026, month: 7, day: 10),
            minutes: 30,
            createdAt: makeDate(year: 2026, month: 7, day: 10, hour: 9)
        )
        let juneCreate = try await repository.apply(createCommand(for: juneEntry, occurredAt: juneEntry.updatedAt))
        _ = try await repository.apply(createCommand(for: julyEntry, occurredAt: julyEntry.updatedAt))

        let juneDraft = try await reportDraft(from: repository, month: june)
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: june,
                expectedCalculationFingerprint: juneDraft.calculationFingerprint,
                expectedPresentationFingerprint: juneDraft.presentationFingerprint,
                reviewedAt: makeDate(year: 2026, month: 7, day: 1, hour: 8)
            )
        )
        let junePrepared = try await repository.prepareReport(
            PrepareReportRequest(
                month: june,
                expectedCalculationFingerprint: juneDraft.calculationFingerprint,
                expectedPresentationFingerprint: juneDraft.presentationFingerprint,
                snapshotID: UUID(uuidString: "70000000-0000-0000-0000-000000000020")!,
                preparedAt: makeDate(year: 2026, month: 7, day: 1, hour: 9)
            )
        )

        let julyDraft = try await reportDraft(from: repository, month: july)
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: july,
                expectedCalculationFingerprint: julyDraft.calculationFingerprint,
                expectedPresentationFingerprint: julyDraft.presentationFingerprint,
                reviewedAt: makeDate(year: 2026, month: 8, day: 1, hour: 8)
            )
        )
        let julyPrepared = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: julyDraft.calculationFingerprint,
                expectedPresentationFingerprint: julyDraft.presentationFingerprint,
                snapshotID: UUID(uuidString: "70000000-0000-0000-0000-000000000021")!,
                preparedAt: makeDate(year: 2026, month: 8, day: 1, hour: 9)
            )
        )

        _ = try await repository.apply(
            updateCommand(
                entryID: juneEntry.id,
                expectedRevision: juneCreate.appliedRevision,
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 1),
                minutes: juneEntry.minutes,
                note: juneEntry.note,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 10),
                mutationID: UUID(uuidString: "70000000-0000-0000-0000-000000000030")!
            )
        )
        let afterMove = try await repository.ledgerSnapshot()
        let juneState = try reportState(for: june, in: afterMove)
        let julyState = try reportState(for: july, in: afterMove)
        XCTAssertEqual(juneState.state, .changed)
        XCTAssertEqual(juneState.lastStableState, .prepared)
        XCTAssertEqual(juneState.currentSnapshotID, junePrepared.snapshot.id)
        XCTAssertEqual(julyState.state, .changed)
        XCTAssertEqual(julyState.lastStableState, .prepared)
        XCTAssertEqual(julyState.currentSnapshotID, julyPrepared.snapshot.id)
        XCTAssertEqual(afterMove.reportSnapshots.count, 2)
        XCTAssertEqual(try reportSnapshot(id: junePrepared.snapshot.id, in: afterMove).supersedesID, nil)
        XCTAssertEqual(try reportSnapshot(id: julyPrepared.snapshot.id, in: afterMove).supersedesID, nil)
    }

    func testLegacyCheckpointStaysChangedAfterExactUndoOfDayOnlyMutation() async throws {
        let june = MonthKey(year: 2026, month: 6)
        let july = MonthKey(year: 2026, month: 7)
        let authorizationTime = makeDate(year: 2026, month: 8, day: 1, hour: 11, minute: 8)
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { authorizationTime }
        )
        try await configureLedgerStart(repository, month: june)
        let originalDay = LocalDay(year: 2026, month: 7, day: 5)
        let movedDay = LocalDay(year: 2026, month: 7, day: 6)
        let entry = makeFixedEntry(
            id: "80000000-0000-0000-0000-000000000001",
            day: originalDay,
            minutes: 60,
            createdAt: makeDate(year: 2026, month: 7, day: 5, hour: 9)
        )
        let created = try await repository.apply(createCommand(for: entry, occurredAt: entry.updatedAt))
        let draft = try await reportDraft(from: repository, month: july)
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                reviewedAt: makeDate(year: 2026, month: 8, day: 1, hour: 8)
            )
        )
        let prepared = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                snapshotID: UUID(uuidString: "80000000-0000-0000-0000-000000000010")!,
                preparedAt: makeDate(year: 2026, month: 8, day: 1, hour: 9)
            )
        )
        _ = try await repository.markReportSent(
            MarkReportSentRequest(
                snapshotID: prepared.snapshot.id,
                confirmedAt: makeDate(year: 2026, month: 8, day: 1, hour: 10)
            )
        )
        try markSnapshotLegacy(
            persistence: persistence,
            snapshotID: prepared.snapshot.id,
            month: july,
            updatedAt: makeDate(year: 2026, month: 8, day: 1, hour: 10)
        )

        let moved = try await repository.apply(
            updateCommand(
                entryID: entry.id,
                expectedRevision: created.appliedRevision,
                kind: .service,
                day: movedDay,
                minutes: entry.minutes,
                note: entry.note,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 11),
                mutationID: UUID(uuidString: "80000000-0000-0000-0000-000000000011")!
            )
        )
        let afterMove = try await repository.ledgerSnapshot()
        let changedState = try reportState(for: july, in: afterMove)
        XCTAssertEqual(changedState.state, .changed)
        XCTAssertEqual(changedState.lastStableState, .sent)
        XCTAssertEqual(changedState.currentSnapshotID, prepared.snapshot.id)
        let firstChangedAt = try XCTUnwrap(changedState.changedAt)

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "80000000-0000-0000-0000-000000000012")!,
                entryID: entry.id,
                expectedRevision: moved.appliedRevision,
                operation: .undo,
                revertedMutationID: moved.mutationID,
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 11, minute: 5),
                source: .undo
            )
        )
        let afterUndo = try await repository.ledgerSnapshot()
        let stillChanged = try reportState(for: july, in: afterUndo)
        XCTAssertEqual(stillChanged.state, .changed)
        XCTAssertEqual(stillChanged.lastStableState, .sent)
        XCTAssertEqual(stillChanged.currentSnapshotID, prepared.snapshot.id)
        XCTAssertEqual(stillChanged.changedAt, firstChangedAt)
        XCTAssertEqual(try ledgerRecord(id: entry.id, in: afterUndo).entry.day, originalDay)
    }

    private func makeRepository() async throws -> CoreDataLedgerRepository {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false)
        )
        try await configureLedgerStart(repository)
        return repository
    }

    private func makeRepository(ledgerStartMonth: MonthKey) async throws -> CoreDataLedgerRepository {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false)
        )
        try await configureLedgerStart(repository, month: ledgerStartMonth)
        return repository
    }

    private func makeRepositoryWithPersistence() -> (PersistenceController, CoreDataLedgerRepository) {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        return (persistence, repository)
    }

    private func configureLedgerStart(_ repository: CoreDataLedgerRepository) async throws {
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = LocalDay(Date(), calendar: .hourleaf).monthKey
        try await repository.saveSettings(settings)
    }

    private func configureLedgerStart(
        _ repository: CoreDataLedgerRepository,
        month: MonthKey
    ) async throws {
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = month
        try await repository.saveSettings(settings)
    }

    private func makeEntry(
        kind: EntryKind = .service,
        minutes: Int,
        note: String? = nil,
        updatedAt: Date = .now
    ) -> TimeEntry {
        TimeEntry(
            kind: kind,
            day: LocalDay(Date(), calendar: .hourleaf),
            minutes: minutes,
            note: note,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    private func createCommand(
        for entry: TimeEntry,
        mutationID: UUID = UUID(),
        occurredAt: Date? = nil,
        source: EntryMutationSource = .appQuickEntry
    ) -> EntryMutationCommand {
        EntryMutationCommand(
            mutationID: mutationID,
            entryID: entry.id,
            expectedRevision: nil,
            operation: .create,
            values: EntryMutationValues(
                kind: entry.kind,
                day: entry.day,
                minutes: entry.minutes,
                note: entry.note
            ),
            occurredAt: occurredAt ?? entry.updatedAt,
            source: source
        )
    }

    private func updateCommand(
        entryID: UUID,
        expectedRevision: Int64,
        kind: EntryKind = .service,
        day: LocalDay? = nil,
        minutes: Int,
        note: String? = nil,
        occurredAt: Date = .now,
        mutationID: UUID = UUID(),
        source: EntryMutationSource = .appHistory
    ) -> EntryMutationCommand {
        EntryMutationCommand(
            mutationID: mutationID,
            entryID: entryID,
            expectedRevision: expectedRevision,
            operation: .update,
            values: EntryMutationValues(
                kind: kind,
                day: day ?? LocalDay(Date(), calendar: .hourleaf),
                minutes: minutes,
                note: note
            ),
            occurredAt: occurredAt,
            source: source
        )
    }

    private func reportDraft(
        from repository: CoreDataLedgerRepository,
        month: MonthKey
    ) async throws -> ReportDraft {
        let snapshot = try await repository.ledgerSnapshot()
        return try XCTUnwrap(ReportReadiness.draft(for: month, in: snapshot))
    }

    private func reportState(
        for month: MonthKey,
        in snapshot: LedgerSnapshot
    ) throws -> ReportStateRecord {
        try XCTUnwrap(snapshot.reportStates.first(where: { $0.month == month }))
    }

    private func reportSnapshot(
        id: UUID,
        in snapshot: LedgerSnapshot
    ) throws -> ReportSnapshotMetadata {
        try XCTUnwrap(snapshot.reportSnapshots.first(where: { $0.id == id }))
    }

    private func ledgerRecord(
        id: UUID,
        in snapshot: LedgerSnapshot
    ) throws -> LedgerEntryRecord {
        try XCTUnwrap(snapshot.entries.first(where: { $0.id == id }))
    }

    private func makeFixedEntry(
        id: String,
        kind: EntryKind = .service,
        day: LocalDay,
        minutes: Int,
        note: String? = nil,
        createdAt: Date
    ) -> TimeEntry {
        TimeEntry(
            id: UUID(uuidString: id)!,
            kind: kind,
            day: day,
            minutes: minutes,
            note: note,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.hourleaf
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }

    private func markSnapshotLegacy(
        persistence: PersistenceController,
        snapshotID: UUID,
        month: MonthKey,
        updatedAt: Date
    ) throws {
        let context = persistence.container.viewContext
        let receiptRequest: NSFetchRequest<ReportReceiptEntity> = ReportReceiptEntity.request()
        receiptRequest.fetchLimit = 1
        receiptRequest.predicate = NSPredicate(format: "id == %@", snapshotID as CVarArg)
        let receipt = try XCTUnwrap(context.fetch(receiptRequest).first)
        receipt.legacyCalculationUnavailable = true
        receipt.calculationFingerprint = nil
        receipt.presentationFingerprint = nil
        receipt.reportLanguage = nil
        receipt.creditLabel = nil
        receipt.templateID = nil
        receipt.createdBySource = nil

        let stateRequest: NSFetchRequest<ReportStateEntity> = ReportStateEntity.request()
        stateRequest.fetchLimit = 1
        stateRequest.predicate = NSPredicate(format: "monthKey == %@", month.key)
        let state = try XCTUnwrap(context.fetch(stateRequest).first)
        state.state = ReportLifecycleState.sent.rawValue
        state.lastStableState = nil
        state.changedAt = nil
        state.currentSnapshotID = snapshotID
        state.reviewedCalculationFingerprint = nil
        state.reviewedPresentationFingerprint = nil
        state.updatedAt = updatedAt
        try context.save()
    }

    private func undo(
        _ repository: CoreDataLedgerRepository,
        candidate: EntryUndoCandidate
    ) async throws -> EntryMutationReceipt {
        try await repository.apply(
            EntryMutationCommand(
                entryID: candidate.entryID,
                expectedRevision: candidate.expectedRevision,
                operation: .undo,
                revertedMutationID: candidate.mutationID,
                source: .undo
            )
        )
    }

    private func assertMutationError(
        _ expected: EntryMutationError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected), but the mutation succeeded.", file: file, line: line)
        } catch let error as EntryMutationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error).", file: file, line: line)
        }
    }

    private func assertValidationError(
        _ expected: EntryValidationError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected), but the command succeeded.", file: file, line: line)
        } catch let error as EntryValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error).", file: file, line: line)
        }
    }
}

@MainActor
private final class NoopReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
