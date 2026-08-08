@preconcurrency import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class EntryRevisionGraphValidatorTests: XCTestCase {
    func testEmptyGraphAndShuffledValidHistoryPassWithoutMutation() throws {
        XCTAssertNoThrow(try EntryRevisionGraphValidator.validate(entries: [], revisions: []))

        let createdAt = Date(timeIntervalSinceReferenceDate: 10)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 11)
        let entryID = id(1)
        let createMutation = id(101)
        let updateMutation = id(102)
        let entry = makeEntry(
            id: entryID,
            revision: 2,
            lastMutationID: updateMutation,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 90,
            note: "  exact note  ",
            createdAt: createdAt,
            updatedAt: updatedAt,
            source: .appHistory
        )
        let create = makeRevision(
            id: id(2),
            entryID: entryID,
            mutationID: createMutation,
            parent: nil,
            reverted: nil,
            revision: 1,
            operation: .create,
            source: .appQuickEntry,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "  original  ",
            createdAt: createdAt,
            updatedAt: createdAt,
            deletedAt: nil,
            occurredAt: createdAt
        )
        let update = makeRevision(
            id: id(3),
            entryID: entryID,
            mutationID: updateMutation,
            parent: createMutation,
            reverted: nil,
            revision: 2,
            operation: .update,
            source: .appHistory,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 90,
            note: "  exact note  ",
            createdAt: createdAt,
            updatedAt: updatedAt,
            deletedAt: nil,
            occurredAt: updatedAt
        )

        let entriesBefore = [entry]
        let revisionsBefore = [update, create]
        XCTAssertNoThrow(
            try EntryRevisionGraphValidator.validate(
                entries: entriesBefore,
                revisions: revisionsBefore
            )
        )
        XCTAssertEqual(entriesBefore, [entry])
        XCTAssertEqual(revisionsBefore, [update, create])
    }

    func testEveryPermittedCreateSourceAndMigrationTimestampExceptionPass() throws {
        let sources: [EntryMutationSource] = [
            .appQuickEntry, .appOneTap, .shortcut, .widget, .watch, .timer, .csvImport
        ]
        for (offset, source) in sources.enumerated() {
            let occurredAt = Date(timeIntervalSinceReferenceDate: Double(20 + offset))
            let entryID = id(30 + offset)
            let mutationID = id(130 + offset)
            let day = LocalDay(year: 2026, month: 7, day: 12)
            let revision = makeRevision(
                id: id(230 + offset),
                entryID: entryID,
                mutationID: mutationID,
                parent: nil,
                reverted: nil,
                revision: 1,
                operation: .create,
                source: source,
                kind: .service,
                day: day,
                minutes: 30,
                note: "source \(source.rawValue)",
                createdAt: occurredAt,
                updatedAt: occurredAt,
                deletedAt: nil,
                occurredAt: occurredAt
            )
            XCTAssertNoThrow(
                try EntryRevisionGraphValidator.validate(
                    entries: [record(from: revision)],
                    revisions: [revision]
                )
            )
        }

        let migrationRevision = makeRevision(
            id: id(240),
            entryID: id(40),
            mutationID: id(140),
            parent: nil,
            reverted: nil,
            revision: 1,
            operation: .create,
            source: .migration,
            kind: .credit,
            day: LocalDay(year: 2025, month: 9, day: 1),
            minutes: 60,
            note: "legacy",
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2),
            deletedAt: nil,
            occurredAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        XCTAssertNoThrow(
            try EntryRevisionGraphValidator.validate(
                entries: [record(from: migrationRevision)],
                revisions: [migrationRevision]
            )
        )
    }

    func testValidUpdateDeleteRestoreAndAllUndoInversionsPass() throws {
        let day = LocalDay(year: 2026, month: 7, day: 12)
        let t10 = Date(timeIntervalSinceReferenceDate: 10)
        let t11 = Date(timeIntervalSinceReferenceDate: 11)
        let t12 = Date(timeIntervalSinceReferenceDate: 12)
        let t13 = Date(timeIntervalSinceReferenceDate: 13)

        // Undo create.
        let createID = id(301)
        let create = makeRevision(
            id: id(302), entryID: id(300), mutationID: createID,
            parent: nil, reverted: nil, revision: 1, operation: .create,
            source: .appQuickEntry, kind: .service, day: day, minutes: 30,
            note: "base", createdAt: t10, updatedAt: t10, deletedAt: nil, occurredAt: t10
        )
        let undoCreate = makeRevision(
            id: id(303), entryID: id(300), mutationID: id(304),
            parent: createID, reverted: createID, revision: 2, operation: .undo,
            source: .undo, kind: .service, day: day, minutes: 30,
            note: "base", createdAt: t10, updatedAt: t11, deletedAt: t11, occurredAt: t11
        )
        assertValid(entry: record(from: undoCreate), revisions: [create, undoCreate])

        // Undo update restores the values from the update's parent.
        let updateCreate = makeRevision(
            id: id(312), entryID: id(310), mutationID: id(311),
            parent: nil, reverted: nil, revision: 1, operation: .create,
            source: .appQuickEntry, kind: .service, day: day, minutes: 30,
            note: "base", createdAt: t10, updatedAt: t10, deletedAt: nil, occurredAt: t10
        )
        let update = makeRevision(
            id: id(313), entryID: id(310), mutationID: id(314),
            parent: updateCreate.mutationID, reverted: nil, revision: 2, operation: .update,
            source: .appHistory, kind: .service, day: day, minutes: 45,
            note: "changed", createdAt: t10, updatedAt: t11, deletedAt: nil, occurredAt: t11
        )
        let undoUpdate = makeRevision(
            id: id(315), entryID: id(310), mutationID: id(316),
            parent: update.mutationID, reverted: update.mutationID, revision: 3, operation: .undo,
            source: .undo, kind: .service, day: day, minutes: 30,
            note: "base", createdAt: t10, updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        assertValid(entry: record(from: undoUpdate), revisions: [updateCreate, update, undoUpdate])

        // Undo delete restores the deleted revision's values as active.
        let deleteCreate = makeRevision(
            id: id(322), entryID: id(320), mutationID: id(321),
            parent: nil, reverted: nil, revision: 1, operation: .create,
            source: .appQuickEntry, kind: .credit, day: day, minutes: 60,
            note: "credit", createdAt: t10, updatedAt: t10, deletedAt: nil, occurredAt: t10
        )
        let delete = makeRevision(
            id: id(323), entryID: id(320), mutationID: id(324),
            parent: deleteCreate.mutationID, reverted: nil, revision: 2, operation: .delete,
            source: .appHistory, kind: .credit, day: day, minutes: 60,
            note: "credit", createdAt: t10, updatedAt: t11, deletedAt: t11, occurredAt: t11
        )
        let undoDelete = makeRevision(
            id: id(325), entryID: id(320), mutationID: id(326),
            parent: delete.mutationID, reverted: delete.mutationID, revision: 3, operation: .undo,
            source: .undo, kind: .credit, day: day, minutes: 60,
            note: "credit", createdAt: t10, updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        assertValid(entry: record(from: undoDelete), revisions: [deleteCreate, delete, undoDelete])

        // Undo restore returns the entry to the deleted state from its parent.
        let restoreCreate = makeRevision(
            id: id(332), entryID: id(330), mutationID: id(331),
            parent: nil, reverted: nil, revision: 1, operation: .create,
            source: .appQuickEntry, kind: .service, day: day, minutes: 75,
            note: "restore", createdAt: t10, updatedAt: t10, deletedAt: nil, occurredAt: t10
        )
        let restoreDelete = makeRevision(
            id: id(333), entryID: id(330), mutationID: id(334),
            parent: restoreCreate.mutationID, reverted: nil, revision: 2, operation: .delete,
            source: .appHistory, kind: .service, day: day, minutes: 75,
            note: "restore", createdAt: t10, updatedAt: t11, deletedAt: t11, occurredAt: t11
        )
        let restore = makeRevision(
            id: id(335), entryID: id(330), mutationID: id(336),
            parent: restoreDelete.mutationID, reverted: nil, revision: 3, operation: .restore,
            source: .restore, kind: .service, day: day, minutes: 75,
            note: "restore", createdAt: t10, updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        let undoRestore = makeRevision(
            id: id(337), entryID: id(330), mutationID: id(338),
            parent: restore.mutationID, reverted: restore.mutationID, revision: 4, operation: .undo,
            source: .undo, kind: .service, day: day, minutes: 75,
            note: "restore", createdAt: t10, updatedAt: t13, deletedAt: t11, occurredAt: t13
        )
        assertValid(
            entry: record(from: undoRestore),
            revisions: [restoreCreate, restoreDelete, restore, undoRestore]
        )
    }

    func testGraphFailuresHaveStableTypedReasons() throws {
        let createdAt = Date(timeIntervalSinceReferenceDate: 10)
        let entryID = id(11)
        let mutationID = id(111)
        let entry = makeEntry(
            id: entryID,
            revision: 1,
            lastMutationID: mutationID,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "note",
            createdAt: createdAt,
            updatedAt: createdAt,
            source: .appQuickEntry
        )
        let create = makeRevision(
            id: id(12),
            entryID: entryID,
            mutationID: mutationID,
            parent: nil,
            reverted: nil,
            revision: 1,
            operation: .create,
            source: .appQuickEntry,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 75,
            note: "note",
            createdAt: createdAt,
            updatedAt: createdAt,
            deletedAt: nil,
            occurredAt: createdAt
        )

        let duplicateMutation = EntryRevisionRecord(
            id: id(13),
            entryID: create.entryID,
            mutationID: create.mutationID,
            parentMutationID: create.parentMutationID,
            revertedMutationID: create.revertedMutationID,
            revision: create.revision,
            operation: create.operation,
            kind: create.kind,
            localDay: create.localDay,
            minutes: create.minutes,
            note: create.note,
            entryCreatedAt: create.entryCreatedAt,
            entryUpdatedAt: create.entryUpdatedAt,
            entryDeletedAt: create.entryDeletedAt,
            source: create.source,
            occurredAt: create.occurredAt
        )
        assertGraphError(
            entries: [entry],
            revisions: [create, duplicateMutation],
            reason: .duplicateMutationID
        )

        var brokenTimeEntry = entry.entry
        brokenTimeEntry.minutes = 90
        let brokenCurrent = LedgerEntryRecord(
            entry: brokenTimeEntry,
            deletedAt: entry.deletedAt,
            source: entry.source,
            revision: entry.revision,
            lastMutationID: entry.lastMutationID
        )
        assertGraphError(
            entries: [brokenCurrent],
            revisions: [create],
            reason: .currentRevisionMismatch
        )

        let orphan = EntryRevisionRecord(
            id: create.id,
            entryID: id(999),
            mutationID: create.mutationID,
            parentMutationID: create.parentMutationID,
            revertedMutationID: create.revertedMutationID,
            revision: create.revision,
            operation: create.operation,
            kind: create.kind,
            localDay: create.localDay,
            minutes: create.minutes,
            note: create.note,
            entryCreatedAt: create.entryCreatedAt,
            entryUpdatedAt: create.entryUpdatedAt,
            entryDeletedAt: create.entryDeletedAt,
            source: create.source,
            occurredAt: create.occurredAt
        )
        assertGraphError(
            entries: [entry],
            revisions: [orphan],
            reason: .revisionMissingEntry
        )
    }

    func testGraphRejectsIdentityTopologyAndCurrentFieldFailures() throws {
        let day = LocalDay(year: 2026, month: 7, day: 12)
        let createdAt = Date(timeIntervalSinceReferenceDate: 10)
        let updatedAt = Date(timeIntervalSinceReferenceDate: 11)
        let t11 = Date(timeIntervalSinceReferenceDate: 11)
        let create = makeRevision(
            id: id(401), entryID: id(400), mutationID: id(402),
            parent: nil, reverted: nil, revision: 1, operation: .create,
            source: .appQuickEntry, kind: .service, day: day, minutes: 30,
            note: "base", createdAt: createdAt, updatedAt: createdAt, deletedAt: nil, occurredAt: createdAt
        )
        let entry = record(from: create)

        let initialDelete = copyRevision(create, id: id(502), mutationID: id(503), operation: .delete)
        assertGraphError(entries: [record(from: initialDelete)], revisions: [initialDelete], reason: .invalidInitialRevision)

        let inconsistentCreate = copyRevision(
            create,
            id: id(504),
            mutationID: id(505),
            updatedAt: t11
        )
        assertGraphError(entries: [record(from: inconsistentCreate)], revisions: [inconsistentCreate], reason: .inconsistentCreateTimestamps)

        let initialUndo = copyRevision(create, id: id(506), mutationID: id(507), operation: .undo, source: .undo)
        assertGraphError(entries: [record(from: initialUndo)], revisions: [initialUndo], reason: .invalidInitialRevision)

        let duplicateEntry = entry
        assertGraphError(
            entries: [entry, duplicateEntry],
            revisions: [create],
            reason: .duplicateEntryID
        )

        let duplicateRevisionID = copyRevision(create, id: create.id)
        assertGraphError(
            entries: [entry],
            revisions: [create, duplicateRevisionID],
            reason: .duplicateRevisionRecordID
        )

        let duplicateMutation = copyRevision(create, id: id(403), revisionNumber: 2)
        assertGraphError(
            entries: [entry],
            revisions: [create, duplicateMutation],
            reason: .duplicateMutationID
        )

        let noRevisionEntry = makeEntry(
            id: id(404), revision: 1, lastMutationID: id(405), kind: .service,
            day: day, minutes: 15, note: nil, createdAt: createdAt, updatedAt: createdAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [noRevisionEntry], revisions: [create], reason: .revisionMissingEntry)

        let noRevisionGraphEntry = makeEntry(
            id: id(406), revision: 1, lastMutationID: id(407), kind: .service,
            day: day, minutes: 15, note: nil, createdAt: createdAt, updatedAt: createdAt,
            source: .appQuickEntry
        )
        assertGraphError(
            entries: [noRevisionGraphEntry],
            revisions: [],
            reason: .entryMissingRevision
        )

        let gap = copyRevision(create, id: id(410), mutationID: id(411), revisionNumber: 2)
        assertGraphError(entries: [entry], revisions: [gap], reason: .nonContiguousRevisions)

        let branch = copyRevision(create, id: id(412), mutationID: id(413), revisionNumber: 1)
        assertGraphError(entries: [entry], revisions: [create, branch], reason: .nonContiguousRevisions)

        let brokenParent = makeRevision(
            id: id(414), entryID: entry.id, mutationID: id(415), parent: id(999), reverted: nil,
            revision: 2, operation: .update, source: .appHistory, kind: .service, day: day,
            minutes: 45, note: "changed", createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: nil, occurredAt: updatedAt
        )
        assertGraphError(entries: [record(from: brokenParent)], revisions: [create, brokenParent], reason: .brokenParent)

        let changedCreatedAt = copyRevision(
            makeRevision(
                id: id(416), entryID: entry.id, mutationID: id(417), parent: create.mutationID,
                reverted: nil, revision: 2, operation: .update, source: .appHistory,
                kind: .service, day: day, minutes: 45, note: "changed", createdAt: createdAt,
                updatedAt: updatedAt, deletedAt: nil, occurredAt: updatedAt
            ),
            createdAt: Date(timeIntervalSinceReferenceDate: 99)
        )
        assertGraphError(entries: [record(from: changedCreatedAt)], revisions: [create, changedCreatedAt], reason: .brokenParent)

        var unknownOperation = copyRevision(create, id: id(418), mutationID: id(419))
        unknownOperation = EntryRevisionRecord(
            id: unknownOperation.id, entryID: unknownOperation.entryID, mutationID: unknownOperation.mutationID,
            parentMutationID: unknownOperation.parentMutationID, revertedMutationID: unknownOperation.revertedMutationID,
            revision: unknownOperation.revision, operation: "future", kind: unknownOperation.kind,
            localDay: unknownOperation.localDay, minutes: unknownOperation.minutes, note: unknownOperation.note,
            entryCreatedAt: unknownOperation.entryCreatedAt, entryUpdatedAt: unknownOperation.entryUpdatedAt,
            entryDeletedAt: unknownOperation.entryDeletedAt, source: unknownOperation.source,
            occurredAt: unknownOperation.occurredAt
        )
        assertGraphError(entries: [entry], revisions: [unknownOperation], reason: .unknownOperationOrSource)

        let unknownSource = EntryRevisionRecord(
            id: id(424), entryID: create.entryID, mutationID: id(425),
            parentMutationID: nil, revertedMutationID: nil, revision: 1,
            operation: EntryMutationOperation.create.rawValue, kind: create.kind,
            localDay: create.localDay, minutes: create.minutes, note: create.note,
            entryCreatedAt: create.entryCreatedAt, entryUpdatedAt: create.entryUpdatedAt,
            entryDeletedAt: nil, source: "futureSurface", occurredAt: create.occurredAt
        )
        assertGraphError(entries: [entry], revisions: [unknownSource], reason: .unknownOperationOrSource)

        let update = makeRevision(
            id: id(420), entryID: entry.id, mutationID: id(421), parent: create.mutationID, reverted: nil,
            revision: 2, operation: .update, source: .appHistory, kind: .service, day: day,
            minutes: 45, note: "changed", createdAt: createdAt, updatedAt: updatedAt,
            deletedAt: nil, occurredAt: updatedAt
        )
        let createAfterFirst = copyRevision(update, id: id(422), mutationID: id(423), operation: .create)
        assertGraphError(entries: [record(from: createAfterFirst)], revisions: [create, createAfterFirst], reason: .brokenParent)

        let changedEntry = makeEntry(
            id: entry.id, revision: 1, lastMutationID: entry.lastMutationID!, kind: .credit,
            day: day, minutes: entry.entry.minutes, note: entry.entry.note,
            createdAt: entry.entry.createdAt, updatedAt: entry.entry.updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedEntry], revisions: [create], reason: .currentRevisionMismatch)

        let changedNote = makeEntry(
            id: entry.id, revision: 1, lastMutationID: entry.lastMutationID!, kind: .service,
            day: day, minutes: entry.entry.minutes, note: "different",
            createdAt: entry.entry.createdAt, updatedAt: entry.entry.updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedNote], revisions: [create], reason: .currentRevisionMismatch)

        let changedUpdatedAt = makeEntry(
            id: entry.id, revision: 1, lastMutationID: entry.lastMutationID!, kind: .service,
            day: day, minutes: entry.entry.minutes, note: entry.entry.note,
            createdAt: entry.entry.createdAt, updatedAt: updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedUpdatedAt], revisions: [create], reason: .currentRevisionMismatch)

        let changedRevision = makeEntry(
            id: entry.id, revision: 2, lastMutationID: entry.lastMutationID!, kind: .service,
            day: day, minutes: entry.entry.minutes, note: entry.entry.note,
            createdAt: entry.entry.createdAt, updatedAt: entry.entry.updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedRevision], revisions: [create], reason: .currentRevisionMismatch)

        let changedMutation = makeEntry(
            id: entry.id, revision: entry.revision, lastMutationID: id(426), kind: .service,
            day: day, minutes: entry.entry.minutes, note: entry.entry.note,
            createdAt: entry.entry.createdAt, updatedAt: entry.entry.updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedMutation], revisions: [create], reason: .currentRevisionMismatch)

        let changedDay = makeEntry(
            id: entry.id, revision: entry.revision, lastMutationID: entry.lastMutationID!, kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 13), minutes: entry.entry.minutes,
            note: entry.entry.note, createdAt: entry.entry.createdAt, updatedAt: entry.entry.updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedDay], revisions: [create], reason: .currentRevisionMismatch)

        let changedCreatedAtEntry = makeEntry(
            id: entry.id, revision: entry.revision, lastMutationID: entry.lastMutationID!, kind: .service,
            day: day, minutes: entry.entry.minutes, note: entry.entry.note,
            createdAt: Date(timeIntervalSinceReferenceDate: 99), updatedAt: entry.entry.updatedAt,
            source: .appQuickEntry
        )
        assertGraphError(entries: [changedCreatedAtEntry], revisions: [create], reason: .currentRevisionMismatch)

        var changedDeletedEntry = entry
        changedDeletedEntry = LedgerEntryRecord(
            entry: entry.entry,
            deletedAt: updatedAt,
            source: entry.source,
            revision: entry.revision,
            lastMutationID: entry.lastMutationID
        )
        assertGraphError(entries: [changedDeletedEntry], revisions: [create], reason: .currentRevisionMismatch)

        let changedSource = makeEntry(
            id: entry.id, revision: entry.revision, lastMutationID: entry.lastMutationID!, kind: .service,
            day: day, minutes: entry.entry.minutes, note: entry.entry.note,
            createdAt: entry.entry.createdAt, updatedAt: entry.entry.updatedAt,
            source: .migration
        )
        assertGraphError(entries: [changedSource], revisions: [create], reason: .currentRevisionMismatch)
    }

    func testGraphRejectsInvalidTransitionsAndUndoInverses() throws {
        let day = LocalDay(year: 2026, month: 7, day: 12)
        let t10 = Date(timeIntervalSinceReferenceDate: 10)
        let t11 = Date(timeIntervalSinceReferenceDate: 11)
        let t12 = Date(timeIntervalSinceReferenceDate: 12)
        let create = makeRevision(
            id: id(501), entryID: id(500), mutationID: id(502), parent: nil, reverted: nil,
            revision: 1, operation: .create, source: .appQuickEntry, kind: .service,
            day: day, minutes: 30, note: "base", createdAt: t10, updatedAt: t10,
            deletedAt: nil, occurredAt: t10
        )
        let entry = record(from: create)

        let updateWrongSource = makeRevision(
            id: id(503), entryID: entry.id, mutationID: id(504), parent: create.mutationID,
            reverted: nil, revision: 2, operation: .update, source: .shortcut,
            kind: .service, day: day, minutes: 45, note: "changed", createdAt: t10,
            updatedAt: t11, deletedAt: nil, occurredAt: t11
        )
        assertGraphError(entries: [record(from: updateWrongSource)], revisions: [create, updateWrongSource], reason: .invalidUpdateTransition)

        let updateDeleted = copyRevision(updateWrongSource, id: id(505), mutationID: id(506), source: .appHistory, deletedAt: t11)
        assertGraphError(entries: [record(from: updateDeleted)], revisions: [create, updateDeleted], reason: .invalidUpdateTransition)

        let updateReverted = copyRevision(
            updateWrongSource,
            id: id(507),
            mutationID: id(508),
            reverted: create.mutationID,
            source: .appHistory
        )
        assertGraphError(entries: [record(from: updateReverted)], revisions: [create, updateReverted], reason: .invalidUpdateTransition)

        let updateWrongTime = copyRevision(
            updateWrongSource,
            id: id(509),
            mutationID: id(510),
            source: .appHistory,
            occurredAt: t12
        )
        assertGraphError(entries: [record(from: updateWrongTime)], revisions: [create, updateWrongTime], reason: .invalidUpdateTransition)

        let deleteChangedValues = makeRevision(
            id: id(511), entryID: entry.id, mutationID: id(512), parent: create.mutationID,
            reverted: nil, revision: 2, operation: .delete, source: .appHistory,
            kind: .service, day: day, minutes: 45, note: "changed", createdAt: t10,
            updatedAt: t11, deletedAt: t11, occurredAt: t11
        )
        assertGraphError(entries: [record(from: deleteChangedValues)], revisions: [create, deleteChangedValues], reason: .invalidDeleteTransition)

        let deleteNoTimestamp = copyRevision(
            makeRevision(
            id: id(513), entryID: entry.id, mutationID: id(514), parent: create.mutationID,
                reverted: nil, revision: 2, operation: .delete, source: .appHistory,
                kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
                updatedAt: t11, deletedAt: nil, occurredAt: t11
            ),
            id: id(509)
        )
        assertGraphError(entries: [record(from: deleteNoTimestamp)], revisions: [create, deleteNoTimestamp], reason: .invalidDeleteTransition)

        let restoreFromActive = makeRevision(
            id: id(515), entryID: entry.id, mutationID: id(516), parent: create.mutationID,
            reverted: nil, revision: 2, operation: .restore, source: .restore,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: t11, deletedAt: nil, occurredAt: t11
        )
        assertGraphError(entries: [record(from: restoreFromActive)], revisions: [create, restoreFromActive], reason: .invalidRestoreTransition)

        let delete = makeRevision(
            id: id(517), entryID: entry.id, mutationID: id(518), parent: create.mutationID,
            reverted: nil, revision: 2, operation: .delete, source: .appHistory,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: t11, deletedAt: t11, occurredAt: t11
        )
        let restoreWrongSource = copyRevision(
            makeRevision(
                id: id(519), entryID: entry.id, mutationID: id(520), parent: delete.mutationID,
                reverted: nil, revision: 3, operation: .restore, source: .appHistory,
                kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
                updatedAt: t12, deletedAt: nil, occurredAt: t12
            ),
            source: .appHistory
        )
        assertGraphError(entries: [record(from: restoreWrongSource)], revisions: [create, delete, restoreWrongSource], reason: .invalidRestoreTransition)

        let validRestore = makeRevision(
            id: id(521), entryID: entry.id, mutationID: id(522), parent: delete.mutationID,
            reverted: nil, revision: 3, operation: .restore, source: .restore,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        let undoWrongRevertedID = copyRevision(
            makeRevision(
                id: id(523), entryID: entry.id, mutationID: id(524), parent: validRestore.mutationID,
                reverted: id(999), revision: 4, operation: .undo, source: .undo,
                kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
                updatedAt: Date(timeIntervalSinceReferenceDate: 13), deletedAt: t11,
                occurredAt: Date(timeIntervalSinceReferenceDate: 13)
            )
        )
        assertGraphError(
            entries: [record(from: undoWrongRevertedID)],
            revisions: [create, delete, validRestore, undoWrongRevertedID],
            reason: .invalidUndoHeader
        )

        let undoWrongParent = copyRevision(undoWrongRevertedID, id: id(525), mutationID: id(526), parent: create.mutationID, reverted: validRestore.mutationID)
        assertGraphError(
            entries: [record(from: undoWrongParent)],
            revisions: [create, delete, validRestore, undoWrongParent],
            reason: .brokenParent
        )

        let undoWrongState = copyRevision(
            undoWrongRevertedID,
            id: id(527),
            mutationID: id(528),
            parent: validRestore.mutationID,
            reverted: validRestore.mutationID,
            clearDeletedAt: true
        )
        assertGraphError(
            entries: [record(from: undoWrongState)],
            revisions: [create, delete, validRestore, undoWrongState],
            reason: .undoRestoreInverse
        )

        let validUpdate = makeRevision(
            id: id(529), entryID: entry.id, mutationID: id(530), parent: create.mutationID,
            reverted: nil, revision: 2, operation: .update, source: .appHistory,
            kind: .service, day: day, minutes: 45, note: "changed", createdAt: t10,
            updatedAt: t11, deletedAt: nil, occurredAt: t11
        )
        let validUndoUpdate = makeRevision(
            id: id(531), entryID: entry.id, mutationID: id(532), parent: validUpdate.mutationID,
            reverted: validUpdate.mutationID, revision: 3, operation: .undo, source: .undo,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        let undoUndo = makeRevision(
            id: id(533), entryID: entry.id, mutationID: id(534), parent: validUndoUpdate.mutationID,
            reverted: validUndoUpdate.mutationID, revision: 4, operation: .undo, source: .undo,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: Date(timeIntervalSinceReferenceDate: 14), deletedAt: nil,
            occurredAt: Date(timeIntervalSinceReferenceDate: 14)
        )
        assertGraphError(
            entries: [record(from: undoUndo)],
            revisions: [create, validUpdate, validUndoUpdate, undoUndo],
            reason: .invalidUndoHeader
        )

        let undoCreateWrongState = makeRevision(
            id: id(535), entryID: entry.id, mutationID: id(536), parent: create.mutationID,
            reverted: create.mutationID, revision: 2, operation: .undo, source: .undo,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: t11, deletedAt: nil, occurredAt: t11
        )
        assertGraphError(
            entries: [record(from: undoCreateWrongState)],
            revisions: [create, undoCreateWrongState],
            reason: .undoCreateInverse
        )

        let undoCreateWrongSource = copyRevision(
            makeRevision(
                id: id(537), entryID: entry.id, mutationID: id(538), parent: create.mutationID,
                reverted: create.mutationID, revision: 2, operation: .undo, source: .appHistory,
                kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
                updatedAt: t11, deletedAt: t11, occurredAt: t11
            ),
            source: .appHistory
        )
        assertGraphError(
            entries: [record(from: undoCreateWrongSource)],
            revisions: [create, undoCreateWrongSource],
            reason: .invalidUndoHeader
        )

        let updateForUndo = makeRevision(
            id: id(539), entryID: entry.id, mutationID: id(540), parent: create.mutationID,
            reverted: nil, revision: 2, operation: .update, source: .appHistory,
            kind: .service, day: day, minutes: 45, note: "changed", createdAt: t10,
            updatedAt: t11, deletedAt: nil, occurredAt: t11
        )
        let undoUpdateWrongValues = makeRevision(
            id: id(541), entryID: entry.id, mutationID: id(542), parent: updateForUndo.mutationID,
            reverted: updateForUndo.mutationID, revision: 3, operation: .undo, source: .undo,
            kind: .service, day: day, minutes: 99, note: "wrong", createdAt: t10,
            updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        assertGraphError(
            entries: [record(from: undoUpdateWrongValues)],
            revisions: [create, updateForUndo, undoUpdateWrongValues],
            reason: .undoUpdateInverse
        )

        let undoDeleteWrongValues = makeRevision(
            id: id(543), entryID: entry.id, mutationID: id(544), parent: delete.mutationID,
            reverted: delete.mutationID, revision: 3, operation: .undo, source: .undo,
            kind: .service, day: day, minutes: 99, note: "wrong", createdAt: t10,
            updatedAt: t12, deletedAt: nil, occurredAt: t12
        )
        assertGraphError(
            entries: [record(from: undoDeleteWrongValues)],
            revisions: [create, delete, undoDeleteWrongValues],
            reason: .undoDeleteInverse
        )

        let undoRestoreWrongTime = makeRevision(
            id: id(545), entryID: entry.id, mutationID: id(546), parent: validRestore.mutationID,
            reverted: validRestore.mutationID, revision: 4, operation: .undo, source: .undo,
            kind: .service, day: day, minutes: 30, note: "base", createdAt: t10,
            updatedAt: t12, deletedAt: t11, occurredAt: Date(timeIntervalSinceReferenceDate: 13)
        )
        assertGraphError(
            entries: [record(from: undoRestoreWrongTime)],
            revisions: [create, delete, validRestore, undoRestoreWrongTime],
            reason: .invalidUndoHeader
        )

        let migrationCreate = makeRevision(
            id: id(547), entryID: id(548), mutationID: id(549), parent: nil, reverted: nil,
            revision: 1, operation: .create, source: .migration, kind: .service, day: day,
            minutes: 30, note: "legacy", createdAt: Date(timeIntervalSinceReferenceDate: 1),
            updatedAt: Date(timeIntervalSinceReferenceDate: 2), deletedAt: nil,
            occurredAt: Date(timeIntervalSinceReferenceDate: 99)
        )
        let undoMigration = makeRevision(
            id: id(550), entryID: migrationCreate.entryID, mutationID: id(551),
            parent: migrationCreate.mutationID, reverted: migrationCreate.mutationID,
            revision: 2, operation: .undo, source: .undo, kind: .service, day: day,
            minutes: 30, note: "legacy", createdAt: migrationCreate.entryCreatedAt,
            updatedAt: Date(timeIntervalSinceReferenceDate: 100), deletedAt: Date(timeIntervalSinceReferenceDate: 100),
            occurredAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        assertGraphError(
            entries: [record(from: undoMigration)],
            revisions: [migrationCreate, undoMigration],
            reason: .invalidUndoHeader
        )
    }

    func testCorruptLiveGraphFailsClosedAndApplyPerformsNoWrites() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = LocalDay(Date(), calendar: .hourleaf).monthKey
        try await repository.saveSettings(settings)

        let now = Date(timeIntervalSinceReferenceDate: 100)
        let entryID = id(21)
        let createMutationID = id(221)
        let entry = TimeEntry(
            id: entryID,
            kind: .service,
            day: LocalDay(Date(), calendar: .hourleaf),
            minutes: 45,
            note: "unchanged",
            createdAt: now,
            updatedAt: now
        )
        let created = try await repository.apply(
            EntryMutationCommand(
                mutationID: createMutationID,
                entryID: entry.id,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: entry.kind,
                    day: entry.day,
                    minutes: entry.minutes,
                    note: entry.note
                ),
                occurredAt: now,
                source: .appQuickEntry
            )
        )

        let context = persistence.container.viewContext
        let entryRequest: NSFetchRequest<EntryEntity> = EntryEntity.request()
        entryRequest.predicate = NSPredicate(format: "id == %@", entryID as CVarArg)
        let revisionRequest: NSFetchRequest<EntryRevisionEntity> = EntryRevisionEntity.request()
        revisionRequest.predicate = NSPredicate(format: "mutationID == %@", createMutationID as CVarArg)
        let storedEntry = try XCTUnwrap(try context.fetch(entryRequest).first)
        let storedRevision = try XCTUnwrap(try context.fetch(revisionRequest).first)

        storedEntry.note = "  unchanged  "
        storedRevision.note = "  unchanged  "
        try context.save()
        let validSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(validSnapshot.entries.first(where: { $0.id == entryID })?.entry.note, "unchanged")
        XCTAssertEqual(storedEntry.note, "  unchanged  ")
        XCTAssertEqual(storedRevision.note, "  unchanged  ")

        // A zero current revision must reach the shared graph validator without
        // being normalized back to revision one.
        storedEntry.revision = 0
        try context.save()
        let before = (
            storedEntry.revision,
            storedEntry.lastMutationID,
            storedEntry.minutes,
            storedEntry.note,
            storedRevision.parentMutationID,
            try context.fetch(entryRequest).count,
            try context.fetch(revisionRequest).count
        )

        do {
            _ = try await repository.ledgerSnapshot()
            XCTFail("A damaged live revision graph must not produce a snapshot.")
        } catch let error as LedgerRepositoryError {
            XCTAssertEqual(
                error,
                .invalidManagedObject("Hourleaf entry history is unavailable.")
            )
        }

        let updateTime = Date(timeIntervalSinceReferenceDate: 101)
        do {
            _ = try await repository.apply(
                EntryMutationCommand(
                    mutationID: id(222),
                    entryID: entryID,
                    expectedRevision: created.appliedRevision,
                    operation: .update,
                    values: EntryMutationValues(
                        kind: .service,
                        day: entry.day,
                        minutes: 60,
                        note: "must not write"
                    ),
                    occurredAt: updateTime,
                    source: .appHistory
                )
            )
            XCTFail("Mutation must be blocked by the invalid pre-write snapshot.")
        } catch let error as LedgerRepositoryError {
            XCTAssertEqual(
                error,
                .invalidManagedObject("Hourleaf entry history is unavailable.")
            )
        }

        XCTAssertEqual(storedEntry.revision, before.0)
        XCTAssertEqual(storedEntry.lastMutationID, before.1)
        XCTAssertEqual(storedEntry.minutes, before.2)
        XCTAssertEqual(storedEntry.note, before.3)
        XCTAssertEqual(storedRevision.parentMutationID, before.4)
        XCTAssertEqual(try context.fetch(entryRequest).count, before.5)
        XCTAssertEqual(try context.fetch(revisionRequest).count, before.6)
    }

    private func assertGraphError(
        entries: [LedgerEntryRecord],
        revisions: [EntryRevisionRecord],
        reason: EntryRevisionGraphError.Reason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try EntryRevisionGraphValidator.validate(entries: entries, revisions: revisions),
            file: file,
            line: line
        ) { error in
            guard let graphError = error as? EntryRevisionGraphError else {
                return XCTFail("Expected EntryRevisionGraphError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(graphError.reasonCode, reason, file: file, line: line)
        }
    }

    private func assertValid(
        entry: LedgerEntryRecord,
        revisions: [EntryRevisionRecord],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNoThrow(
            try EntryRevisionGraphValidator.validate(entries: [entry], revisions: revisions),
            file: file,
            line: line
        )
    }

    private func record(from revision: EntryRevisionRecord) -> LedgerEntryRecord {
        var timeEntry = TimeEntry(
            id: revision.entryID,
            kind: EntryKind(rawValue: revision.kind)!,
            day: LocalDay(key: revision.localDay)!,
            minutes: revision.minutes,
            note: revision.note,
            createdAt: revision.entryCreatedAt,
            updatedAt: revision.entryUpdatedAt
        )
        timeEntry.note = revision.note
        return LedgerEntryRecord(
            entry: timeEntry,
            deletedAt: revision.entryDeletedAt,
            source: revision.source,
            revision: revision.revision,
            lastMutationID: revision.mutationID
        )
    }

    private func copyRevision(
        _ record: EntryRevisionRecord,
        id: UUID? = nil,
        entryID: UUID? = nil,
        mutationID: UUID? = nil,
        parent: UUID? = nil,
        reverted: UUID? = nil,
        revisionNumber: Int64? = nil,
        operation: EntryMutationOperation? = nil,
        source: EntryMutationSource? = nil,
        kind: EntryKind? = nil,
        day: LocalDay? = nil,
        minutes: Int? = nil,
        note: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        clearDeletedAt: Bool = false,
        occurredAt: Date? = nil
    ) -> EntryRevisionRecord {
        EntryRevisionRecord(
            id: id ?? record.id,
            entryID: entryID ?? record.entryID,
            mutationID: mutationID ?? record.mutationID,
            parentMutationID: parent ?? record.parentMutationID,
            revertedMutationID: reverted ?? record.revertedMutationID,
            revision: revisionNumber ?? record.revision,
            operation: (operation?.rawValue ?? record.operation),
            kind: (kind?.rawValue ?? record.kind),
            localDay: (day?.key ?? record.localDay),
            minutes: minutes ?? record.minutes,
            note: note ?? record.note,
            entryCreatedAt: createdAt ?? record.entryCreatedAt,
            entryUpdatedAt: updatedAt ?? record.entryUpdatedAt,
            entryDeletedAt: clearDeletedAt ? nil : (deletedAt ?? record.entryDeletedAt),
            source: (source?.rawValue ?? record.source),
            occurredAt: occurredAt ?? record.occurredAt
        )
    }

    private func makeEntry(
        id: UUID,
        revision: Int64,
        lastMutationID: UUID,
        kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        note: String?,
        createdAt: Date,
        updatedAt: Date,
        source: EntryMutationSource
    ) -> LedgerEntryRecord {
        var entry = TimeEntry(
            id: id,
            kind: kind,
            day: day,
            minutes: minutes,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        entry.note = note
        return LedgerEntryRecord(
            entry: entry,
            deletedAt: nil,
            source: source.rawValue,
            revision: revision,
            lastMutationID: lastMutationID
        )
    }

    private func makeRevision(
        id: UUID,
        entryID: UUID,
        mutationID: UUID,
        parent: UUID?,
        reverted: UUID?,
        revision: Int64,
        operation: EntryMutationOperation,
        source: EntryMutationSource,
        kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        note: String?,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date?,
        occurredAt: Date
    ) -> EntryRevisionRecord {
        EntryRevisionRecord(
            id: id,
            entryID: entryID,
            mutationID: mutationID,
            parentMutationID: parent,
            revertedMutationID: reverted,
            revision: revision,
            operation: operation.rawValue,
            kind: kind.rawValue,
            localDay: day.key,
            minutes: minutes,
            note: note,
            entryCreatedAt: createdAt,
            entryUpdatedAt: updatedAt,
            entryDeletedAt: deletedAt,
            source: source.rawValue,
            occurredAt: occurredAt
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
