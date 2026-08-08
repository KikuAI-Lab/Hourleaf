import CoreData
import XCTest
@testable import Hourleaf

final class CSVImportRepositoryTests: XCTestCase {
    private let authorizationTime = Date(timeIntervalSince1970: 1_786_179_600)

    func testFreshImportClassifiesAndUndoSoftDeletesOneBatch() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,service,1,30,90,Door to door\n")

        let preview = try await repository.previewCSVImport(document, candidateID: UUID())
        XCTAssertEqual(preview.totalRows, 1)
        XCTAssertEqual(preview.importableWhenSkippingMatches, 1)
        XCTAssertEqual(preview.previouslyImportedCount, 0)

        let result = try await repository.applyCSVImport(
            document,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.previouslyImportedCount, 0)
        XCTAssertNotNil(result.undoToken)

        let importedID = try XCTUnwrap(result.undoToken?.members.first?.entryID)
        let afterImport = try await repository.ledgerSnapshot()
        let imported = try XCTUnwrap(afterImport.entries.first(where: { $0.id == importedID }))
        XCTAssertFalse(imported.isDeleted)
        XCTAssertEqual(imported.source, EntryMutationSource.csvImport.rawValue)
        XCTAssertEqual(imported.revision, 1)
        XCTAssertEqual(imported.lastMutationID, result.undoToken?.members.first?.importMutationID)

        let undo = try await repository.undoCSVImport(try XCTUnwrap(result.undoToken))
        XCTAssertEqual(undo.deletedCount, 1)
        let afterUndo = try await repository.ledgerSnapshot()
        let deleted = try XCTUnwrap(afterUndo.entries.first(where: { $0.id == importedID }))
        XCTAssertTrue(deleted.isDeleted)
        XCTAssertEqual(deleted.revision, 2)
        XCTAssertEqual(deleted.source, EntryMutationSource.undo.rawValue)
        XCTAssertEqual(
            afterUndo.entryRevisions.filter { $0.entryID == importedID }.count,
            2
        )
    }

    func testReimportRecognizesEditedAndDeletedImportedRows() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,service,1,30,90,Original\n")
        let first = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        let member = try XCTUnwrap(first.undoToken?.members.first)

        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: member.entryID,
                expectedRevision: 1,
                operation: .update,
                values: EntryMutationValues(
                    kind: .service,
                    day: LocalDay(key: "2026-08-07")!,
                    minutes: 120,
                    note: "Edited"
                ),
                occurredAt: authorizationTime,
                source: .appHistory
            )
        )
        let editedReplay = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        XCTAssertEqual(editedReplay.importedCount, 0)
        XCTAssertEqual(editedReplay.previouslyImportedCount, 1)

        let editedSnapshot = try await repository.ledgerSnapshot()
        let latest = try XCTUnwrap(editedSnapshot.entries.first)
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: member.entryID,
                expectedRevision: latest.revision,
                operation: .delete,
                occurredAt: authorizationTime,
                source: .appHistory
            )
        )
        let deletedReplay = try await repository.applyCSVImport(document, policy: .includePossibleMatches)
        XCTAssertEqual(deletedReplay.importedCount, 0)
        XCTAssertEqual(deletedReplay.previouslyImportedCount, 1)
        let deletedSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(deletedSnapshot.entries.count, 1)
    }

    func testManualActiveMatchSkipsByDefaultAndIncludesExplicitly() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,credit,0,30,30,Manual match\n")
        let values = try XCTUnwrap(document.rows.first?.values)
        _ = try await AddTimeEntryCommand(repository: repository).execute(
            kind: values.kind,
            date: values.day.date(),
            hours: 0,
            minutes: values.minutes,
            note: values.note,
            occurredAt: authorizationTime
        )

        let preview = try await repository.previewCSVImport(document, candidateID: UUID())
        XCTAssertEqual(preview.possibleMatchCount, 1)
        XCTAssertEqual(preview.importableWhenSkippingMatches, 0)
        XCTAssertEqual(preview.importableWhenIncludingMatches, 1)

        let skipped = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        XCTAssertEqual(skipped.importedCount, 0)
        XCTAssertEqual(skipped.skippedPossibleMatchCount, 1)

        let included = try await repository.applyCSVImport(document, policy: .includePossibleMatches)
        XCTAssertEqual(included.importedCount, 1)
        let includedSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(includedSnapshot.entries.count, 2)
    }

    func testBatchUndoRejectsChangedMemberWithoutPartialRevision() async throws {
        let repository = makeRepository()
        let document = try document(
            "2026-08-07,service,0,30,30,One\n2026-08-06,credit,0,20,20,Two\n"
        )
        let result = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        let token = try XCTUnwrap(result.undoToken)
        let changed = try XCTUnwrap(token.members.first)
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: changed.entryID,
                expectedRevision: changed.expectedRevision,
                operation: .update,
                values: EntryMutationValues(
                    kind: .service,
                    day: LocalDay(key: "2026-08-07")!,
                    minutes: 45,
                    note: "Changed"
                ),
                occurredAt: authorizationTime,
                source: .appHistory
            )
        )

        do {
            _ = try await repository.undoCSVImport(token)
            XCTFail("Changed members must reject the whole batch")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .undoUnavailable)
        }
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.filter(\.isDeleted).count, 0)
        XCTAssertEqual(snapshot.entryRevisions.count, 3)
    }

    func testOrdinaryUndoDoesNotSurfaceCSVImportCreate() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,service,0,30,30,Only import\n")
        _ = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        let candidate = try await repository.latestUndoCandidate(asOf: authorizationTime)
        XCTAssertNil(candidate)
    }

    func testPreviewUsesRepositoryDateAndLedgerStartValidation() async throws {
        let repository = makeRepository()
        let future = try document("2026-08-09,service,0,30,30,Future\n")
        do {
            _ = try await repository.previewCSVImport(future, candidateID: UUID())
            XCTFail("Future rows must fail at preview")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .validationFailed)
        }

        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 9)
        try await repository.saveSettings(settings)
        let beforeStart = try document("2026-08-07,service,0,30,30,Before start\n")
        do {
            _ = try await repository.previewCSVImport(beforeStart, candidateID: UUID())
            XCTFail("Rows before ledger start must fail at preview")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .validationFailed)
        }
    }

    func testIdentityCollisionsFailPreviewAndApplyWithoutWrites() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { Date(timeIntervalSince1970: 1_786_179_600) }
        )
        let document = try document("2026-08-07,service,0,30,30,Collision\n")
        let row = try XCTUnwrap(document.rows.first)
        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: row.mutationID,
                entryID: UUID(),
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: .credit,
                    day: row.values.day,
                    minutes: row.values.minutes,
                    note: "Unrelated"
                ),
                occurredAt: authorizationTime,
                source: .appQuickEntry
            )
        )

        do {
            _ = try await repository.previewCSVImport(document, candidateID: UUID())
            XCTFail("Mutation-ID collisions must fail preview")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .identityCollision)
        }
        do {
            _ = try await repository.applyCSVImport(document, policy: .includePossibleMatches)
            XCTFail("Mutation-ID collisions must fail apply")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .identityCollision)
        }
        let collisionSnapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(collisionSnapshot.entries.count, 1)
    }

    func testValidationFailureOnLaterRowRollsBackEarlierRows() async throws {
        let repository = makeRepository()
        let document = try document(
            "2026-08-07,service,0,30,30,Valid\n2026-08-09,credit,0,20,20,Future\n"
        )
        do {
            _ = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
            XCTFail("A future row must fail the whole transaction")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .validationFailed)
        }
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.entryRevisions.isEmpty)
    }

    func testUndoIsStrictAtTenMinuteBoundaryAndImmediateReplayIsIdempotent() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let now = authorizationTime
        let repository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { now }
        )
        let document = try document("2026-08-07,service,0,30,30,Boundary\n")
        let result = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        let token = try XCTUnwrap(result.undoToken)
        let replay = try await repository.undoCSVImport(token)
        XCTAssertEqual(replay.deletedCount, 1)
        let secondReplay = try await repository.undoCSVImport(token)
        XCTAssertEqual(secondReplay.deletedCount, 1)

        let boundaryRepository = CoreDataLedgerRepository(
            persistence: persistence,
            clock: { token.expiresAt }
        )
        do {
            _ = try await boundaryRepository.undoCSVImport(token)
            XCTFail("The exact ten-minute boundary must be expired")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .undoExpired)
        }
    }

    func testEmptyValidDocumentWritesNothing() async throws {
        let repository = makeRepository()
        let document = try document("")
        let before = try await repository.ledgerSnapshot()

        let result = try await repository.applyCSVImport(
            document,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.previouslyImportedCount, 0)
        XCTAssertEqual(result.skippedPossibleMatchCount, 0)
        XCTAssertNil(result.undoToken)
        let after = try await repository.ledgerSnapshot()
        XCTAssertEqual(after, before)
    }

    func testActiveManualMultisetConsumesOneEntryPerSourceOccurrence() async throws {
        let repository = makeRepository()
        let document = try document(
            "2026-08-07,service,0,30,30,Repeated\n"
                + "2026-08-07,service,0,30,30,Repeated\n"
                + "2026-08-07,service,0,30,30,Repeated\n"
        )
        let values = try XCTUnwrap(document.rows.first?.values)
        for _ in 0..<2 {
            _ = try await repository.apply(
                EntryMutationCommand(
                    entryID: UUID(),
                    expectedRevision: nil,
                    operation: .create,
                    values: values,
                    occurredAt: authorizationTime,
                    source: .appQuickEntry
                )
            )
        }

        let preview = try await repository.previewCSVImport(document, candidateID: UUID())
        XCTAssertEqual(preview.possibleMatchCount, 2)
        XCTAssertEqual(preview.importableWhenSkippingMatches, 1)
        XCTAssertEqual(preview.importableWhenIncludingMatches, 3)

        let result = try await repository.applyCSVImport(
            document,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(result.importedCount, 1)
        XCTAssertEqual(result.skippedPossibleMatchCount, 2)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 3)
        XCTAssertEqual(
            snapshot.entries.filter { $0.source == EntryMutationSource.csvImport.rawValue }.count,
            1
        )
    }

    func testDeletedManualEntryDoesNotMatchCSVImport() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,service,0,30,30,Deleted manual\n")
        let values = try XCTUnwrap(document.rows.first?.values)
        let created = try await repository.apply(
            EntryMutationCommand(
                entryID: UUID(),
                expectedRevision: nil,
                operation: .create,
                values: values,
                occurredAt: authorizationTime,
                source: .appQuickEntry
            )
        )
        _ = try await repository.apply(
            EntryMutationCommand(
                entryID: created.entry.id,
                expectedRevision: created.appliedRevision,
                operation: .delete,
                occurredAt: authorizationTime,
                source: .appHistory
            )
        )

        let preview = try await repository.previewCSVImport(document, candidateID: UUID())
        XCTAssertEqual(preview.possibleMatchCount, 0)
        XCTAssertEqual(preview.importableWhenSkippingMatches, 1)
        let result = try await repository.applyCSVImport(
            document,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(result.importedCount, 1)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.filter(\.isDeleted).count, 1)
        XCTAssertEqual(snapshot.activeEntries.count, 1)
    }

    func testDeterministicEntryIDCollisionFailsPreviewAndApplyWithoutWrites() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,service,0,30,30,Entry collision\n")
        let row = try XCTUnwrap(document.rows.first)
        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "C3E55A65-4A07-4979-AB4A-1D96D2B2C682")!,
                entryID: row.entryID,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: .credit,
                    day: row.values.day,
                    minutes: row.values.minutes,
                    note: "Unrelated entry"
                ),
                occurredAt: authorizationTime,
                source: .appQuickEntry
            )
        )
        let before = try await repository.ledgerSnapshot()

        do {
            _ = try await repository.previewCSVImport(document, candidateID: UUID())
            XCTFail("An entry-ID collision must fail preview")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .identityCollision)
        }
        do {
            _ = try await repository.applyCSVImport(document, policy: .includePossibleMatches)
            XCTFail("An entry-ID collision must fail apply")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .identityCollision)
        }
        let after = try await repository.ledgerSnapshot()
        XCTAssertEqual(after, before)
    }

    func testReorderedEquivalentReimportAddsNothing() async throws {
        let repository = makeRepository()
        let firstDocument = try document(
            "2026-08-07,service,0,30,30,First\n"
                + "2026-08-06,credit,0,20,20,Second\n"
        )
        let first = try await repository.applyCSVImport(
            firstDocument,
            policy: .skipPossibleMatches
        )
        XCTAssertEqual(first.importedCount, 2)
        let beforeReplay = try await repository.ledgerSnapshot()

        let reordered = try document(
            "2026-08-06,credit,0,20,20,Second\n"
                + "2026-08-07,service,0,30,30,First\n"
        )
        let replay = try await repository.applyCSVImport(
            reordered,
            policy: .includePossibleMatches
        )
        XCTAssertEqual(replay.importedCount, 0)
        XCTAssertEqual(replay.previouslyImportedCount, 2)
        let afterReplay = try await repository.ledgerSnapshot()
        XCTAssertEqual(afterReplay, beforeReplay)
    }

    func testImportedRecordsRoundTripThroughBackupCodec() async throws {
        let repository = makeRepository()
        let document = try document("2026-08-07,service,0,30,30,Backup import\n")
        _ = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)

        let records = try await repository.portableBackupRecords()
        XCTAssertEqual(records.entries.count, 1)
        XCTAssertEqual(records.entries.first?.source, EntryMutationSource.csvImport.rawValue)
        XCTAssertEqual(records.revisions.first?.source, EntryMutationSource.csvImport.rawValue)
        let verified = try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(
                exportedAt: authorizationTime.timeIntervalSince1970,
                records: records
            )
        )
        let decoded = try HourleafBackupCodec.decodeAndVerify(verified.data)
        XCTAssertEqual(decoded.content.records.entries.first?.source, EntryMutationSource.csvImport.rawValue)
        XCTAssertEqual(decoded.content.records.revisions.first?.source, EntryMutationSource.csvImport.rawValue)
    }

    func testFaultBeforeImportSaveLeavesSnapshotUnchanged() async throws {
        let fault = CSVImportFaultBox(throwing: [.importBeforeSave])
        let repository = makeRepository { try fault.inject($0) }
        let document = try document(
            "2026-08-07,service,0,30,30,Atomic one\n"
                + "2026-08-06,credit,0,20,20,Atomic two\n"
        )
        let before = try await repository.ledgerSnapshot()

        do {
            _ = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
            XCTFail("The injected pre-save fault must fail the import")
        } catch let error as CSVImportRepositoryError {
            XCTAssertEqual(error, .transactionFailed)
        }
        XCTAssertEqual(fault.count(of: .importBeforeSave), 1)
        let after = try await repository.ledgerSnapshot()
        XCTAssertEqual(after, before)
    }

    func testFaultAfterImportSaveRetriesToVerifiedCompleteResult() async throws {
        let fault = CSVImportFaultBox(throwing: [.importAfterSaveBeforeReadback])
        let repository = makeRepository { try fault.inject($0) }
        let document = try document(
            "2026-08-07,service,0,30,30,Retry one\n"
                + "2026-08-06,credit,0,20,20,Retry two\n"
        )

        let result = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(fault.count(of: .importAfterSaveBeforeReadback), 1)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.count, 2)
        XCTAssertEqual(snapshot.entryRevisions.count, 2)
        XCTAssertEqual(snapshot.entries.filter { $0.source == EntryMutationSource.csvImport.rawValue }.count, 2)
    }

    func testFaultAfterUndoSaveRetriesToVerifiedIdempotentResult() async throws {
        let fault = CSVImportFaultBox(throwing: [.undoAfterSaveBeforeReadback])
        let repository = makeRepository { try fault.inject($0) }
        let document = try document("2026-08-07,service,0,30,30,Undo retry\n")
        let imported = try await repository.applyCSVImport(document, policy: .skipPossibleMatches)
        let token = try XCTUnwrap(imported.undoToken)

        let firstUndo = try await repository.undoCSVImport(token)
        XCTAssertEqual(firstUndo.deletedCount, 1)
        XCTAssertEqual(fault.count(of: .undoAfterSaveBeforeReadback), 1)
        let replay = try await repository.undoCSVImport(token)
        XCTAssertEqual(replay.deletedCount, 1)
        XCTAssertEqual(fault.count(of: .undoAfterSaveBeforeReadback), 1)

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.entries.filter(\.isDeleted).count, 1)
        XCTAssertEqual(snapshot.entryRevisions.count, 2)
    }

    private func makeRepository(
        _ faultInjector: @escaping CSVImportFaultInjector = { _ in }
    ) -> CoreDataLedgerRepository {
        let now = authorizationTime
        return CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { now },
            csvImportFaultInjector: faultInjector
        )
    }

    private func document(_ rows: String) throws -> CSVImportDocument {
        try CSVImportCodec.decode(
            data: Data(
                ("date,kind,hours,minutes,total_minutes,note\n" + rows).utf8
            )
        )
    }
}

private struct CSVImportInjectedFault: Error {}

private final class CSVImportFaultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Set<CSVImportFaultPoint>
    private var seen = [CSVImportFaultPoint]()

    init(throwing points: Set<CSVImportFaultPoint>) {
        remaining = points
    }

    func inject(_ point: CSVImportFaultPoint) throws {
        lock.lock()
        defer { lock.unlock() }
        seen.append(point)
        if remaining.remove(point) != nil {
            throw CSVImportInjectedFault()
        }
    }

    func count(of point: CSVImportFaultPoint) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return seen.filter { $0 == point }.count
    }
}
