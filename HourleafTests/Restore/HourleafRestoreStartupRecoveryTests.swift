import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class HourleafRestoreStartupRecoveryTests: XCTestCase {
    func testCriticalPreflightDoesNotInvokeEitherRuntimeFactoryOrCleanup() async {
        let journal = BootstrapJournalSpy(
            disposition: .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-journal"))
        )
        let normalCalls = RestoreLockedCounter()
        let localCalls = RestoreLockedCounter()
        let result = await HourleafRestoreCoordinator.bootstrap(
            journalStore: journal,
            reminderScheduler: RestoreTestReminderScheduler(),
            makeNormalRuntime: {
                normalCalls.increment()
                fatalError("Critical preflight must not construct normal persistence.")
            },
            makeLocalRecoveryRuntime: {
                localCalls.increment()
                fatalError("Critical preflight must not construct recovery persistence.")
            }
        )

        guard case let .blocked(state) = result else {
            return XCTFail("Critical preflight must return a blocked result.")
        }
        XCTAssertEqual(state, RedactedRestoreCriticalState(reasonCode: "untrusted-journal"))
        XCTAssertEqual(normalCalls.read(), 0)
        XCTAssertEqual(localCalls.read(), 0)
        XCTAssertEqual(journal.calls(), ["inspect"])
    }

    func testIdlePreflightCleansCompletedMetadataBeforeItCallsNormalFactory() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let runtime = RestoreTestRuntime(storeURL: sandbox.appendingPathComponent("live.sqlite"))
        defer { runtime.close() }
        try runtime.seed(RestoreFixture.records())
        let readyRuntime = runtime.readyRuntime()
        let journal = BootstrapJournalSpy(disposition: .idle)
        let normalCalls = RestoreLockedCounter()
        let localCalls = RestoreLockedCounter()
        let result = await HourleafRestoreCoordinator.bootstrap(
            journalStore: journal,
            reminderScheduler: RestoreTestReminderScheduler(),
            makeNormalRuntime: {
                normalCalls.increment()
                return readyRuntime
            },
            makeLocalRecoveryRuntime: {
                localCalls.increment()
                fatalError("Idle preflight must not construct a recovery runtime.")
            }
        )

        guard case .ready = result else {
            return XCTFail("Idle cleanup should permit the normal runtime.")
        }
        XCTAssertEqual(normalCalls.read(), 1)
        XCTAssertEqual(localCalls.read(), 0)
        XCTAssertEqual(journal.calls(), ["inspect", "cleanup-completed", "inspect"])
    }

    func testPreRestoreBackupVerifiedDirectlyTerminalizesFreshAWithoutReplacementOrRollback() async throws {
        try await assertDirectARecovery(from: .preRestoreBackupVerified)
    }

    func testOldStoreCopyStartedDirectlyTerminalizesFreshAWithoutReplacementOrRollback() async throws {
        try await assertDirectARecovery(from: .oldStoreCopyStarted)
    }

    func testOldStoreCopyVerifiedDirectlyTerminalizesFreshAWithoutCandidateReplacementOrRollback() async throws {
        try await assertDirectARecovery(from: .oldStoreCopyVerified)
    }

    private func assertDirectARecovery(from sourcePhase: RestoreJournalPhase) async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let liveURL = sandbox.appendingPathComponent("live.sqlite")
        let interruptedRuntime = RestoreTestRuntime(storeURL: liveURL)
        defer { interruptedRuntime.close() }
        let aRecords = RestoreFixture.records(acknowledgementCount: 1)
        let bRecords = RestoreFixture.records(acknowledgementCount: 4)
        try interruptedRuntime.seed(aRecords)
        let backupURL = sandbox.appendingPathComponent("candidate.hourleafbackup")
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(exportedAt: 456, records: bRecords)
        ).data.write(to: backupURL)

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true),
            protectionReader: protection
        )
        let recordingJournal = RecordingRestoreJournal(base: journal)
        let interruptedCoordinator = HourleafRestoreCoordinator(
            persistence: interruptedRuntime.persistence,
            repository: interruptedRuntime.repository,
            rootDirectory: sandbox.appendingPathComponent("RestoreStaging", isDirectory: true),
            protectionReader: protection,
            journalStore: recordingJournal,
            reminderScheduler: RestoreTestReminderScheduler(),
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "RestoreRecoveryArtifacts",
                isDirectory: true
            ),
            faultInjector: { point in
                if point == .journalPhase(sourcePhase.rawValue) {
                    throw StartupInjectedFault.reachedPhase
                }
            }
        )

        let preview = try await interruptedCoordinator.prepare(from: backupURL)
        do {
            _ = try await interruptedCoordinator.confirm(preview.candidateID)
            XCTFail("Injected interruption must leave a durable recovery phase.")
        } catch let error as HourleafRestoreError {
            XCTAssertEqual(error, .recoveryRequired)
        }
        guard case let .recover(pending) = try journal.inspectBeforeStoreLoad() else {
            return XCTFail("The journal should remain trusted at the direct A source phase.")
        }
        XCTAssertEqual(pending.journal.content.phase, sourcePhase)

        // The interrupted process intentionally retains its maintenance gate.
        // A fresh recovery runtime models a restart and must be the first one
        // exposed only after terminal readback and lease release.
        interruptedRuntime.close()

        let recoveredRuntime = RestoreTestRuntime(storeURL: liveURL)
        defer { recoveredRuntime.close() }
        let retryScheduler = RestoreTestReminderScheduler()
        let normalCalls = RestoreLockedCounter()
        let localCalls = RestoreLockedCounter()
        let readyRuntime = recoveredRuntime.readyRuntime()
        let result = await HourleafRestoreCoordinator.bootstrap(
            journalStore: recordingJournal,
            reminderScheduler: retryScheduler,
            makeNormalRuntime: {
                normalCalls.increment()
                return readyRuntime
            },
            makeLocalRecoveryRuntime: {
                localCalls.increment()
                return readyRuntime
            },
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "RestoreRecoveryArtifacts",
                isDirectory: true
            ),
            protectionReader: protection
        )

        guard case .ready = result else {
            guard case let .recover(remaining) = try journal.inspectBeforeStoreLoad() else {
                return XCTFail("A blocked recovery must preserve a trusted, inspectable journal.")
            }
            XCTAssertEqual(remaining.journal.content.phase, sourcePhase)
            return XCTFail("Fresh exact A must terminalize the trusted direct A source phase.")
        }
        let restoredRecords = try await recoveredRuntime.repository.portableBackupRecords()
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(restoredRecords),
            try HourleafBackupCodec.storeDigest(aRecords)
        )
        XCTAssertEqual(normalCalls.read(), 0)
        XCTAssertEqual(localCalls.read(), 1)
        XCTAssertEqual(retryScheduler.rescheduled.count, 1)
        XCTAssertEqual(recordingJournal.completionTargets(), [.a])
        XCTAssertEqual(
            recordingJournal.advancedPhases().filter { $0 == .oldStoreVerifiedRemindersPending }.count,
            1
        )
        XCTAssertFalse(recordingJournal.advancedPhases().contains(.replacementStarted))
        XCTAssertFalse(recordingJournal.advancedPhases().contains(.replacementReturned))
        XCTAssertFalse(recordingJournal.advancedPhases().contains(.rollbackStarted))
        let maintenanceInProgress = await recoveredRuntime.repository.maintenanceIsInProgress()
        XCTAssertFalse(maintenanceInProgress)
        XCTAssertEqual(try journal.inspectBeforeStoreLoad(), .idle)
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HourleafRestoreStartupRecoveryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }
}

private enum StartupInjectedFault: Error {
    case reachedPhase
}

private final class RecordingRestoreJournal: RestoreJournalStoring, @unchecked Sendable {
    private let base: any RestoreJournalStoring
    private let lock = NSLock()
    private var phases: [RestoreJournalPhase] = []
    private var targets: [RestoreTerminalTargetV1] = []

    init(base: any RestoreJournalStoring) {
        self.base = base
    }

    func inspectBeforeStoreLoad() throws -> RestoreStartupDisposition {
        try base.inspectBeforeStoreLoad()
    }

    func arm(_ prepared: RestoreJournalContentV1) throws {
        try base.arm(prepared)
    }

    func advance(
        to phase: RestoreJournalPhase,
        mutate: (inout RestoreJournalContentV1) throws -> Void
    ) throws {
        try base.advance(to: phase, mutate: mutate)
        lock.withLock { phases.append(phase) }
    }

    func removeTrustedReservedPartials() throws {
        try base.removeTrustedReservedPartials()
    }

    func discardProvisionalPortableAArtifacts(
        afterProvingLiveA decision: RestoreTerminalDecisionV1
    ) throws {
        try base.discardProvisionalPortableAArtifacts(afterProvingLiveA: decision)
    }

    func complete(_ decision: RestoreTerminalDecisionV1) throws {
        try base.complete(decision)
        lock.withLock { targets.append(decision.target) }
    }

    func cleanupCompletedTransactions() throws {
        try base.cleanupCompletedTransactions()
    }

    func advancedPhases() -> [RestoreJournalPhase] {
        lock.withLock { phases }
    }

    func completionTargets() -> [RestoreTerminalTargetV1] {
        lock.withLock { targets }
    }
}

private final class BootstrapJournalSpy: RestoreJournalStoring, @unchecked Sendable {
    private let lock = NSLock()
    private let disposition: RestoreStartupDisposition
    private var recordedCalls: [String] = []

    init(disposition: RestoreStartupDisposition) {
        self.disposition = disposition
    }

    func inspectBeforeStoreLoad() throws -> RestoreStartupDisposition {
        record("inspect")
        return disposition
    }

    func arm(_: RestoreJournalContentV1) throws { throw BootstrapSpyFailure.unexpectedMutation }

    func advance(
        to _: RestoreJournalPhase,
        mutate _: (inout RestoreJournalContentV1) throws -> Void
    ) throws {
        throw BootstrapSpyFailure.unexpectedMutation
    }

    func removeTrustedReservedPartials() throws { record("remove-partials") }

    func discardProvisionalPortableAArtifacts(
        afterProvingLiveA _: RestoreTerminalDecisionV1
    ) throws {
        throw BootstrapSpyFailure.unexpectedMutation
    }

    func complete(_: RestoreTerminalDecisionV1) throws { throw BootstrapSpyFailure.unexpectedMutation }

    func cleanupCompletedTransactions() throws { record("cleanup-completed") }

    func calls() -> [String] {
        lock.withLock { recordedCalls }
    }

    private func record(_ value: String) {
        lock.withLock { recordedCalls.append(value) }
    }
}

private enum BootstrapSpyFailure: Error {
    case unexpectedMutation
}
