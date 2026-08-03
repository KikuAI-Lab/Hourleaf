@preconcurrency import CoreData
import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class LedgerMaintenanceTests: XCTestCase {
    func testEveryOrdinaryRepositoryAPIIsBlockedDuringLeaseAndResumesAfterRelease() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        let settings = try await repository.loadSettings()
        let lease = try await repository.acquireMaintenanceLease()

        await assertMaintenanceBlocked { try await repository.ledgerSnapshot() }
        await assertMaintenanceBlocked { try await repository.portableBackupRecords() }
        await assertMaintenanceBlocked { try await repository.fetchEntries() }
        await assertMaintenanceBlocked { try await repository.fetchAllEntries() }
        await assertMaintenanceBlocked { try await repository.latestUndoCandidate(asOf: .now) }
        await assertMaintenanceBlocked { try await repository.loadSettings() }
        await assertMaintenanceBlocked { try await repository.saveSettings(settings) }
        await assertMaintenanceBlocked {
            try await repository.savePolicy(ReportingPolicy(
                effectiveMonth: MonthKey(Date(), calendar: .hourleaf),
                mode: .carry
            ))
        }
        await assertMaintenanceBlocked { try await repository.fetchPolicies() }
        await assertMaintenanceBlocked { try await repository.fetchReminders() }
        await assertMaintenanceBlocked {
            try await repository.saveReminder(ReminderSchedule(weekday: 2, hour: 9, minute: 0))
        }
        await assertMaintenanceBlocked { try await repository.deleteReminder(id: UUID()) }
        await assertMaintenanceBlocked { try await repository.fetchReceipts() }
        await assertMaintenanceBlocked {
            try await repository.saveReceipt(
                ReportReceipt(
                    id: UUID(),
                    month: MonthKey(Date(), calendar: .hourleaf),
                    text: "blocked",
                    serviceHours: 0,
                    creditHours: 0,
                    serviceCarryOut: 0,
                    creditCarryOut: 0,
                    preparedAt: .now
                ),
                details: nil
            )
        }
        await assertMaintenanceBlocked {
            try await repository.apply(
                EntryMutationCommand(
                    entryID: UUID(),
                    expectedRevision: nil,
                    operation: .create,
                    values: EntryMutationValues(
                        kind: .service,
                        day: LocalDay(Date(), calendar: .hourleaf),
                        minutes: 1,
                        note: nil
                    ),
                    source: .appQuickEntry
                )
            )
        }

        try await repository.releaseMaintenanceLease(lease)
        let resumedSettings = try await repository.loadSettings()
        XCTAssertEqual(resumedSettings, settings)
    }

    func testCaptureIsExactAndDetectsUnexpectedSecondContextWrite() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence)
        _ = try await repository.loadSettings()
        let lease = try await repository.acquireMaintenanceLease()
        let capture = try await repository.maintenanceCapture(for: lease)

        let exported = try await CapturedMaintenanceBackupSource(capture: capture).portableBackupRecords()
        XCTAssertEqual(try HourleafBackupCodec.storeDigest(exported), capture.recordsDigest)

        let context = persistence.container.viewContext
        try context.performAndWait {
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            let settings = try XCTUnwrap(context.fetch(request).first)
            settings.creditLabelEnglish = "External change"
            try context.save()
        }

        do {
            try await repository.currentStoreMatchesCapture(capture, for: lease)
            XCTFail("A second context write must invalidate the captured A boundary.")
        } catch let error as LedgerRepositoryError {
            guard case .invalidManagedObject = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        try await repository.releaseMaintenanceLease(lease)
    }

    func testLocalSQLiteClosesCopiesThroughCoordinatorAndReopensFreshContainer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let liveURL = directory.appendingPathComponent("Hourleaf.sqlite")
        let evidence = try PersistentStoreArtifact.make(
            in: directory,
            named: "evidence.sqlite",
            purpose: .evidence
        )
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: liveURL
        )
        XCTAssertNil(persistence.startupError)
        XCTAssertEqual(persistence.mode, .localOnlySQLite)

        let repository = CoreDataLedgerRepository(persistence: persistence)
        _ = try await repository.loadSettings()
        let lease = try await repository.acquireMaintenanceLease()
        let capture = try await repository.maintenanceCapture(for: lease)
        let originalContainer = persistence.container
        let closed = try await repository.validateCaptureAndCloseStore(capture, for: lease)
        XCTAssertEqual(closed.url, liveURL)
        XCTAssertEqual(closed.mode, .localOnlySQLite)
        try persistence.copyClosedStore(closed, to: evidence)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("evidence.sqlite").path))

        XCTAssertNil(persistence.reopenFreshContainerAfterTransition())
        XCTAssertFalse(persistence.container === originalContainer)
        try await repository.resetAfterPersistentStoreTransition(for: lease)
        let readback = try await repository.validatedReadback(for: lease)
        XCTAssertEqual(readback.recordsDigest, capture.recordsDigest)
        XCTAssertEqual(readback.rawBeforeNormalizationDigest, readback.rawAfterNormalizationDigest)
        try await repository.releaseMaintenanceLease(lease)
    }

    func testCoordinatorBoundaryPreventsSecondContextSaveAfterFinalDigest() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boundaryReached = AsyncBoundary()
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: directory.appendingPathComponent("Hourleaf.sqlite"),
            transitionBoundaryObserver: {
                boundaryReached.open()
            }
        )
        let repository = CoreDataLedgerRepository(persistence: persistence)
        _ = try await repository.loadSettings()
        let lease = try await repository.acquireMaintenanceLease()
        let capture = try await repository.maintenanceCapture(for: lease)

        let writerContext = UnsafeContextBox(persistence.container.newBackgroundContext())
        let writer = Task.detached { () -> Bool in
            await boundaryReached.wait()
            do {
                try writerContext.context.performAndWait {
                    let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
                    guard let settings = try writerContext.context.fetch(request).first else {
                        throw LedgerRepositoryError.invalidManagedObject("The transition removed the external writer store.")
                    }
                    settings.creditLabelEnglish = "must not land after final A digest"
                    try writerContext.context.save()
                }
                return true
            } catch {
                return false
            }
        }

        _ = try await repository.validateCaptureAndCloseStore(capture, for: lease)
        let writerSaved = await writer.value
        XCTAssertFalse(writerSaved, "A writer released at the coordinator boundary must wait/fail after store removal.")

        XCTAssertNil(persistence.reopenFreshContainerAfterTransition())
        try await repository.resetAfterPersistentStoreTransition(for: lease)
        let readback = try await repository.validatedReadback(for: lease)
        XCTAssertEqual(readback.recordsDigest, capture.recordsDigest)
        try await repository.releaseMaintenanceLease(lease)
    }

    func testFinalCoordinatorValidationAbortsWhenSecondContextAlreadySaved() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: directory.appendingPathComponent("Hourleaf.sqlite")
        )
        let repository = CoreDataLedgerRepository(persistence: persistence)
        _ = try await repository.loadSettings()
        let lease = try await repository.acquireMaintenanceLease()
        let capture = try await repository.maintenanceCapture(for: lease)

        let externalContext = persistence.container.newBackgroundContext()
        try externalContext.performAndWait {
            let request: NSFetchRequest<SettingsEntity> = SettingsEntity.request()
            guard let settings = try externalContext.fetch(request).first else {
                throw LedgerRepositoryError.invalidManagedObject("Missing settings fixture.")
            }
            settings.creditLabelEnglish = "arrived before final barrier"
            try externalContext.save()
        }

        do {
            _ = try await repository.validateCaptureAndCloseStore(capture, for: lease)
            XCTFail("A saved second context must invalidate the final A digest.")
        } catch {
            // Expected: the coordinator barrier saw the changed raw store and
            // refused to remove the live persistent store.
        }
        // The failed final digest leaves the live store open, so the caller can
        // abort without replacing anything and the external write remains A.
        try await repository.releaseMaintenanceLease(lease)
        let settings = try await repository.loadSettings()
        XCTAssertEqual(settings.creditLabelEnglish, "arrived before final barrier")
    }

    func testFailedFreshReopenLeavesControllerClosedAndRetryable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failure = LockedFailureMessage("injected reopen failure")
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: directory.appendingPathComponent("Hourleaf.sqlite"),
            reopenFailureMessage: { failure.takeOnce() }
        )
        XCTAssertNil(persistence.startupError)
        _ = try persistence.closePersistentStoreForTransition()

        XCTAssertNotNil(persistence.reopenFreshContainerAfterTransition())
        XCTAssertThrowsError(try persistence.closePersistentStoreForTransition()) { error in
            XCTAssertEqual(error as? PersistentStoreTransitionError, .storeAlreadyClosed)
        }
        XCTAssertNil(persistence.reopenFreshContainerAfterTransition())
    }

    func testOnlyOwnedTypedStagingArtifactCanBeDestroyed() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owned = try PersistentStoreArtifact.make(
            in: directory,
            named: "owned.sqlite",
            purpose: .staging
        )
        let unowned = try PersistentStoreArtifact.make(
            in: directory,
            named: "unowned.sqlite",
            purpose: .staging
        )
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            transitionArtifact: owned
        )
        XCTAssertNil(persistence.startupError)
        _ = try persistence.closePersistentStoreForTransition()

        XCTAssertThrowsError(try persistence.destroyOwnedTransitionStore(unowned)) { error in
            XCTAssertEqual(error as? PersistentStoreTransitionError, .unexpectedStoreURL)
        }
        XCTAssertNoThrow(try persistence.destroyOwnedTransitionStore(owned))
    }

    private func assertMaintenanceBlocked<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected maintenance gate to reject the ordinary repository API.")
        } catch let error as LedgerRepositoryError {
            XCTAssertEqual(error, .maintenanceInProgress)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafLedgerMaintenanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class UnsafeContextBox: @unchecked Sendable {
    let context: NSManagedObjectContext

    init(_ context: NSManagedObjectContext) {
        self.context = context
    }
}

private final class LockedFailureMessage: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String) {
        self.value = value
    }

    func takeOnce() -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { value = nil }
        return value
    }
}

private final class AsyncBoundary: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        var capturedContinuation: AsyncStream<Void>.Continuation?
        stream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            capturedContinuation = continuation
        }
        continuation = capturedContinuation!
    }

    func open() {
        continuation.yield(())
        continuation.finish()
    }

    func wait() async {
        for await _ in stream {
            return
        }
    }
}
