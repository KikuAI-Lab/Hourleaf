import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class HourleafRestoreConfirmationTests: XCTestCase {
    func testConfirmReplacesLocalAWithFreshlyProvedBThenReconcilesReminders() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let runtime = RestoreTestRuntime(storeURL: sandbox.appendingPathComponent("live.sqlite"))
        defer { runtime.close() }
        try runtime.seed(RestoreFixture.records(acknowledgementCount: 1))

        let bRecords = RestoreFixture.records(acknowledgementCount: 2)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 123, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let scheduler = RestoreTestReminderScheduler()
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: scheduler,
            protection: protection
        )

        let preview = try await coordinator.prepare(from: backupURL)
        let result = try await coordinator.confirm(preview.candidateID)

        let expectedDigest = try HourleafBackupCodec.storeDigest(bRecords)
        let liveReminders = try await runtime.repository.fetchReminders()
        let liveRecords = try await runtime.repository.portableBackupRecords()
        XCTAssertEqual(result.selectedTarget, .candidate)
        XCTAssertEqual(result.recordsDigest, expectedDigest)
        XCTAssertEqual(result.recordCounts, bRecords.counts)
        XCTAssertEqual(scheduler.requestsAuthorizationCount, 0)
        XCTAssertEqual(scheduler.rescheduled.count, 1)
        XCTAssertEqual(scheduler.rescheduled.first, liveReminders)
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(liveRecords),
            expectedDigest
        )
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testEqualProofConfirmationReconcilesRemindersWhileWriterGateIsHeld() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let runtime = RestoreTestRuntime(storeURL: sandbox.appendingPathComponent("live.sqlite"))
        defer { runtime.close() }
        let records = RestoreFixture.records()
        try runtime.seed(records)
        let backupURL = sandbox.appendingPathComponent("same.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 123, records: records)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let scheduler = RestoreLeaseCheckingReminderScheduler(repository: runtime.repository)
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: scheduler,
            protection: protection
        )

        let preview = try await coordinator.prepare(from: backupURL)
        let result = try await coordinator.confirm(preview.candidateID)

        XCTAssertEqual(result.selectedTarget, .original)
        XCTAssertEqual(result.recordsDigest, try HourleafBackupCodec.storeDigest(records))
        XCTAssertEqual(scheduler.rescheduled.count, 1)
        XCTAssertTrue(scheduler.observedMaintenanceLease)
        XCTAssertTrue(scheduler.observedOrdinaryWriterBlocked)
        XCTAssertNil(runtime.persistence.startupError)
        let maintenanceInProgress = await runtime.repository.maintenanceIsInProgress()
        XCTAssertFalse(maintenanceInProgress)
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testReminderFailureLeavesBPendingAndBootstrapRetriesWithoutRepeatingReplacement() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let runtime = RestoreTestRuntime(storeURL: sandbox.appendingPathComponent("live.sqlite"))
        defer { runtime.close() }
        try runtime.seed(RestoreFixture.records(acknowledgementCount: 1))
        let bRecords = RestoreFixture.records(acknowledgementCount: 3)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 123, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journalRoot = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let journal = RestoreJournalStoreV1(rootDirectory: journalRoot, protectionReader: protection)
        let failingScheduler = RestoreTestReminderScheduler()
        failingScheduler.failsReschedule = true
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: failingScheduler,
            protection: protection
        )

        let preview = try await coordinator.prepare(from: backupURL)
        do {
            _ = try await coordinator.confirm(preview.candidateID)
            XCTFail("A reminder failure must leave the transaction pending.")
        } catch let error as HourleafRestoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }

        guard case let .recover(pending) = try journal.inspectBeforeStoreLoad() else {
            return XCTFail("B proof must be durable before scheduler work.")
        }
        XCTAssertEqual(pending.journal.content.phase, .newStoreVerifiedRemindersPending)
        let bPendingMaintenance = await runtime.repository.maintenanceIsInProgress()
        XCTAssertTrue(bPendingMaintenance)
        do {
            _ = try await runtime.repository.portableBackupRecords()
            XCTFail("An armed B-pending transaction must retain the ordinary writer/read gate.")
        } catch let error as LedgerRepositoryError {
            XCTAssertEqual(error, .maintenanceInProgress)
        }

        runtime.close()
        let recoveredRuntime = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("live.sqlite")
        )
        defer { recoveredRuntime.close() }

        let retryScheduler = RestoreTestReminderScheduler()
        let normalFactoryCalls = RestoreLockedCounter()
        let localFactoryCalls = RestoreLockedCounter()
        let readyRuntime = recoveredRuntime.readyRuntime()
        let bootstrap = await HourleafRestoreCoordinator.bootstrap(
            journalStore: journal,
            reminderScheduler: retryScheduler,
            makeNormalRuntime: {
                normalFactoryCalls.increment()
                return readyRuntime
            },
            makeLocalRecoveryRuntime: {
                localFactoryCalls.increment()
                return readyRuntime
            },
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "RestoreRecoveryArtifacts",
                isDirectory: true
            ),
            protectionReader: protection
        )

        guard case .ready = bootstrap else {
            return XCTFail("Trusted B-pending recovery should be ready after reconciliation.")
        }
        XCTAssertEqual(normalFactoryCalls.read(), 0)
        XCTAssertEqual(localFactoryCalls.read(), 1)
        XCTAssertEqual(retryScheduler.rescheduled.count, 1)
        let recoveredRecords = try await recoveredRuntime.repository.portableBackupRecords()
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(recoveredRecords),
            try HourleafBackupCodec.storeDigest(bRecords)
        )
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testFailedBReopenRollsBackThroughPhysicalAAndSchedulesOnlyFreshA() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let oneShotReopenFailure = RestoreOneShotReopenFailure(message: "injected B reopen failure")
        let runtime = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("live.sqlite"),
            reopenFailureMessage: { oneShotReopenFailure.consume() }
        )
        defer { runtime.close() }
        let aRecords = RestoreFixture.records(acknowledgementCount: 1)
        let bRecords = RestoreFixture.records(acknowledgementCount: 5)
        try runtime.seed(aRecords)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 789, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let scheduler = RestoreTestReminderScheduler()
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: scheduler,
            protection: protection
        )

        let preview = try await coordinator.prepare(from: backupURL)
        let result: RestoreCommitResult
        do {
            result = try await coordinator.confirm(preview.candidateID)
        } catch {
            return XCTFail("B reopen fallback unexpectedly failed: \(error)")
        }

        let restoredRecords = try await runtime.repository.portableBackupRecords()
        XCTAssertEqual(result.selectedTarget, .original)
        XCTAssertEqual(result.recordsDigest, try HourleafBackupCodec.storeDigest(aRecords))
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(restoredRecords),
            try HourleafBackupCodec.storeDigest(aRecords)
        )
        XCTAssertEqual(scheduler.rescheduled.count, 1)
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testFailedFreshBProofRollsBackAfterBWasOpened() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let runtime = RestoreTestRuntime(storeURL: sandbox.appendingPathComponent("live.sqlite"))
        defer { runtime.close() }
        let aRecords = RestoreFixture.records(acknowledgementCount: 1)
        let bRecords = RestoreFixture.records(acknowledgementCount: 6)
        try runtime.seed(aRecords)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 790, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let scheduler = RestoreTestReminderScheduler()
        let fault = RestoreOneShotFault(point: .confirmationBoundary("after-b-proof"))
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: scheduler,
            protection: protection,
            faultInjector: fault.inject
        )

        let preview = try await coordinator.prepare(from: backupURL)
        let result = try await coordinator.confirm(preview.candidateID)

        let restoredRecords = try await runtime.repository.portableBackupRecords()
        XCTAssertEqual(result.selectedTarget, .original)
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(restoredRecords),
            try HourleafBackupCodec.storeDigest(aRecords)
        )
        XCTAssertEqual(scheduler.rescheduled.count, 1)
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testRollbackReminderFailureLeavesAPendingForBootstrapRetry() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let oneShotReopenFailure = RestoreOneShotReopenFailure(message: "injected B reopen failure")
        let runtime = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("live.sqlite"),
            reopenFailureMessage: { oneShotReopenFailure.consume() }
        )
        defer { runtime.close() }
        let aRecords = RestoreFixture.records(acknowledgementCount: 1)
        let bRecords = RestoreFixture.records(acknowledgementCount: 7)
        try runtime.seed(aRecords)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 791, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let failingScheduler = RestoreTestReminderScheduler()
        failingScheduler.failsReschedule = true
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: failingScheduler,
            protection: protection
        )

        let preview = try await coordinator.prepare(from: backupURL)
        do {
            _ = try await coordinator.confirm(preview.candidateID)
            XCTFail("A rollback reminder failure must leave A pending.")
        } catch let error as HourleafRestoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }

        guard case let .recover(pending) = try journal.inspectBeforeStoreLoad() else {
            return XCTFail("Rollback proof must be durable before reminders.")
        }
        XCTAssertEqual(pending.journal.content.phase, .oldStoreVerifiedRemindersPending)
        let aPendingMaintenance = await runtime.repository.maintenanceIsInProgress()
        XCTAssertTrue(aPendingMaintenance)
        do {
            _ = try await runtime.repository.portableBackupRecords()
            XCTFail("An armed A-pending transaction must retain the ordinary writer/read gate.")
        } catch let error as LedgerRepositoryError {
            XCTAssertEqual(error, .maintenanceInProgress)
        }

        runtime.close()
        let recoveredRuntime = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("live.sqlite")
        )
        defer { recoveredRuntime.close() }

        let retryScheduler = RestoreTestReminderScheduler()
        let normalFactoryCalls = RestoreLockedCounter()
        let localFactoryCalls = RestoreLockedCounter()
        let readyRuntime = recoveredRuntime.readyRuntime()
        let bootstrap = await HourleafRestoreCoordinator.bootstrap(
            journalStore: journal,
            reminderScheduler: retryScheduler,
            makeNormalRuntime: {
                normalFactoryCalls.increment()
                return readyRuntime
            },
            makeLocalRecoveryRuntime: {
                localFactoryCalls.increment()
                return readyRuntime
            },
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "RestoreRecoveryArtifacts",
                isDirectory: true
            ),
            protectionReader: protection
        )

        guard case .ready = bootstrap else {
            return XCTFail("A-pending bootstrap retry should be ready.")
        }
        XCTAssertEqual(failingScheduler.rescheduled.count, 1)
        XCTAssertEqual(retryScheduler.rescheduled.count, 1)
        XCTAssertEqual(normalFactoryCalls.read(), 0)
        XCTAssertEqual(localFactoryCalls.read(), 1)
        let recoveredRecords = try await recoveredRuntime.repository.portableBackupRecords()
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(recoveredRecords),
            try HourleafBackupCodec.storeDigest(aRecords)
        )
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testInvalidPhysicalAFallsBackToPortableADuringRollback() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let oneShotReopenFailure = RestoreOneShotReopenFailure(message: "injected B reopen failure")
        let runtime = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("live.sqlite"),
            reopenFailureMessage: { oneShotReopenFailure.consume() }
        )
        defer { runtime.close() }
        let aRecords = RestoreFixture.records(acknowledgementCount: 1)
        let bRecords = RestoreFixture.records(acknowledgementCount: 8)
        try runtime.seed(aRecords)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 792, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let artifactsDirectory = sandbox.appendingPathComponent(
            "RestoreRecoveryArtifacts",
            isDirectory: true
        )
        let evidenceArtifact = try PersistentStoreArtifact.make(
            in: artifactsDirectory,
            named: RestoreJournalV1.physicalAStoreBasename,
            purpose: .evidence
        )
        let invalidatePhysicalA = RestoreOneShotAction(
            point: .confirmationBoundary("before-physical-a-rollback-proof"),
            action: {
                let capability = try PersistenceController.orphanedTransitionStoreCleanupCapability(
                    evidenceArtifact,
                    in: artifactsDirectory,
                    named: RestoreJournalV1.physicalAStoreBasename
                )
                try PersistenceController.destroyRelinquishedTransitionStore(capability)
            }
        )
        let scheduler = RestoreTestReminderScheduler()
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: scheduler,
            protection: protection,
            faultInjector: invalidatePhysicalA.inject
        )

        let preview = try await coordinator.prepare(from: backupURL)
        let result = try await coordinator.confirm(preview.candidateID)

        let restoredRecords = try await runtime.repository.portableBackupRecords()
        XCTAssertEqual(result.selectedTarget, .original)
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(restoredRecords),
            try HourleafBackupCodec.storeDigest(aRecords)
        )
        XCTAssertEqual(scheduler.rescheduled.count, 1)
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    func testUnprovedPhysicalAndPortableAPersistCriticalWithoutReminderWork() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let oneShotReopenFailure = RestoreOneShotReopenFailure(message: "injected B reopen failure")
        let runtime = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("live.sqlite"),
            reopenFailureMessage: { oneShotReopenFailure.consume() }
        )
        defer { runtime.close() }
        try runtime.seed(RestoreFixture.records(acknowledgementCount: 1))
        let bRecords = RestoreFixture.records(acknowledgementCount: 9)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 793, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let artifactsDirectory = sandbox.appendingPathComponent(
            "RestoreRecoveryArtifacts",
            isDirectory: true
        )
        let evidenceArtifact = try PersistentStoreArtifact.make(
            in: artifactsDirectory,
            named: RestoreJournalV1.physicalAStoreBasename,
            purpose: .evidence
        )
        let invalidateAllA = RestoreOneShotAction(
            point: .confirmationBoundary("before-physical-a-rollback-proof"),
            action: {
                let capability = try PersistenceController.orphanedTransitionStoreCleanupCapability(
                    evidenceArtifact,
                    in: artifactsDirectory,
                    named: RestoreJournalV1.physicalAStoreBasename
                )
                try PersistenceController.destroyRelinquishedTransitionStore(capability)
                guard case let .recover(transaction) = try journal.inspectBeforeStoreLoad(),
                      let basename = transaction.journal.content.portableABasename else {
                    throw RestoreTestFault.injected
                }
                let portableA = transaction.activeDirectory.appendingPathComponent(
                    basename,
                    isDirectory: false
                )
                try FileManager.default.removeItem(at: portableA)
            }
        )
        let scheduler = RestoreTestReminderScheduler()
        let coordinator = makeCoordinator(
            runtime: runtime,
            sandbox: sandbox,
            journal: journal,
            scheduler: scheduler,
            protection: protection,
            faultInjector: invalidateAllA.inject
        )

        let preview = try await coordinator.prepare(from: backupURL)
        do {
            _ = try await coordinator.confirm(preview.candidateID)
            XCTFail("Unproved rollback sources must block in critical recovery.")
        } catch let error as HourleafRestoreError {
            XCTAssertEqual(error, .criticalRecoveryRequired)
        }

        guard case .critical = try journal.inspectBeforeStoreLoad() else {
            return XCTFail("Unproved A sources must persist a critical journal state.")
        }
        XCTAssertEqual(scheduler.rescheduled, [])
    }

    private func makeCoordinator(
        runtime: RestoreTestRuntime,
        sandbox: URL,
        journal: any RestoreJournalStoring,
        scheduler: any ReminderScheduling,
        protection: any HourleafFileProtectionReading,
        faultInjector: @escaping RestoreFaultInjector = { _ in }
    ) -> HourleafRestoreCoordinator {
        HourleafRestoreCoordinator(
            persistence: runtime.persistence,
            repository: runtime.repository,
            rootDirectory: sandbox.appendingPathComponent("RestoreStaging", isDirectory: true),
            protectionReader: protection,
            journalStore: journal,
            reminderScheduler: scheduler,
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "RestoreRecoveryArtifacts",
                isDirectory: true
            ),
            faultInjector: faultInjector
        )
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HourleafRestoreConfirmationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }
}
