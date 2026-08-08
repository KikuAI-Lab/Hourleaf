import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class QuickSurfaceRestoreBoundaryTests: XCTestCase {
    private static let timeZone = TimeZone(identifier: "Europe/Uzhgorod")!
    private static let now = Date(timeIntervalSince1970: 1_785_837_600)

    func testExclusiveBoundaryRedactsBeforeConfirmationAndBlocksOrdinaryTimerMutation() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-success")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: true, privacyMode: .showTotals)
        )
        let initial = try await repository.ledgerSnapshot()
        try writeShownIdleState(root: root, attributes: attributes)
        let controller = makeController(repository: repository, capability: .available(store))
        let gate = RestoreBoundaryGate()
        let commit = makeRestoreBoundaryCommitResult()

        let task = Task {
            try await controller.performRestoreBoundary(
                originalSnapshot: initial,
                confirmation: {
                    XCTAssertEqual(try readRestoreBoundaryState(root: root).projection.privacyMode, .hideTotals)
                    await gate.pause()
                    return commit
                },
                terminal: { _, host in
                    XCTAssertEqual(host.state?.projection.privacyMode, .showTotals)
                }
            )
        }

        await gate.waitUntilEntered()
        do {
            _ = try await controller.startTimer()
            XCTFail("An ordinary timer mutation must fail while restore owns the lease.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        await gate.resume()
        _ = try await task.value

        XCTAssertEqual(try store.read().projection.privacyMode, .showTotals)
        let nextLease = try store.acquireExclusiveRestoreLease()
        try nextLease.release()
    }

    func testConfirmationFailureRecoversHiddenProjectionAndReleasesLease() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-failure")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: true, privacyMode: .showTotals)
        )
        let initial = try await repository.ledgerSnapshot()
        try writeShownIdleState(root: root, attributes: attributes)
        let controller = makeController(repository: repository, capability: .available(store))

        do {
            _ = try await controller.performRestoreBoundary(
                originalSnapshot: initial,
                confirmation: { throw RestoreBoundaryTestError.cancelled },
                terminal: { _, _ in XCTFail("A failed confirmation must not reach terminal refresh.") }
            )
            XCTFail("The injected confirmation failure must propagate.")
        } catch {
            XCTAssertEqual(error as? RestoreBoundaryTestError, .cancelled)
        }

        let recovered = try store.read()
        XCTAssertEqual(recovered.projection.privacyMode, .hideTotals)
        XCTAssertEqual(recovered.timer, .idle)
        let nextLease = try store.acquireExclusiveRestoreLease()
        try nextLease.release()
    }

    func testExpectedUnavailableBlocksBeforeConfirmation() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let controller = makeController(
            repository: repository,
            capability: .expectedButUnavailable
        )
        let called = RestoreBoundaryFlag()
        let commit = makeRestoreBoundaryCommitResult()

        do {
            _ = try await controller.performRestoreBoundary(
                originalSnapshot: snapshot,
                confirmation: {
                    await called.mark()
                    return commit
                },
                terminal: { _, _ in }
            )
            XCTFail("An unavailable expected capability must fail closed.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .stateUnreadable)
        }
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
    }

    func testNonIdleSidecarBlocksBeforeConfirmation() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-running")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        try QuickSurfaceStoreTestSupport.writeStateFile(
            QuickSurfaceStoreTestSupport.makeShownState(revision: 1),
            root: root
        )
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
        let controller = makeController(repository: repository, capability: .available(store))
        let called = RestoreBoundaryFlag()
        let commit = makeRestoreBoundaryCommitResult()

        do {
            _ = try await controller.performRestoreBoundary(
                originalSnapshot: snapshot,
                confirmation: {
                    await called.mark()
                    return commit
                },
                terminal: { _, _ in }
            )
            XCTFail("A running timer must block restore before confirmation.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .timerMustBeResolved)
        }
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
    }

    func testExhaustedHiddenRevisionBlocksBeforeConfirmation() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-exhausted-hidden")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let exhausted = QuickSurfaceStateV1(
            revision: UInt64.max - 1,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .hideTotals,
                monthKey: nil,
                timeZoneIdentifier: nil,
                serviceMinutes: nil,
                creditMinutes: nil,
                generatedAtEpochSeconds: Self.now.timeIntervalSince1970
            ),
            timerEnabled: false,
            timer: .idle
        )
        try QuickSurfaceStoreTestSupport.writeStateFile(exhausted, root: root)
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
        let controller = makeController(repository: repository, capability: .available(store))
        let called = RestoreBoundaryFlag()

        do {
            _ = try await controller.performRestoreBoundary(
                originalSnapshot: snapshot,
                confirmation: {
                    await called.mark()
                    return makeRestoreBoundaryCommitResult()
                },
                terminal: { _, _ in }
            )
            XCTFail("An exhausted hidden revision must block restore before confirmation.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .stateUnreadable)
        }
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
        XCTAssertEqual(try readRestoreBoundaryState(root: root), exhausted)
    }

    func testRedactionThatConsumesLastRevisionBlocksBeforeConfirmation() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-redaction-exhausts")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: true, privacyMode: .showTotals)
        )
        let snapshot = try await repository.ledgerSnapshot()
        try writeShownIdleState(
            root: root,
            attributes: attributes,
            revision: UInt64.max - 2
        )
        let controller = makeController(repository: repository, capability: .available(store))
        let called = RestoreBoundaryFlag()

        do {
            _ = try await controller.performRestoreBoundary(
                originalSnapshot: snapshot,
                confirmation: {
                    await called.mark()
                    return makeRestoreBoundaryCommitResult()
                },
                terminal: { _, _ in }
            )
            XCTFail("Redaction must not consume the last valid revision and then confirm restore.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .stateUnreadable)
        }
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
        let redacted = try readRestoreBoundaryState(root: root)
        XCTAssertEqual(redacted.revision, UInt64.max - 1)
        XCTAssertEqual(redacted.projection.privacyMode, .hideTotals)
        XCTAssertEqual(redacted.timer, .idle)
    }

    func testPreHeldExclusiveLeaseBlocksBeforeConfirmation() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-contention")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        try writeShownIdleState(root: root, attributes: attributes)
        let holder = try store.acquireExclusiveRestoreLease()
        defer { try? holder.release() }
        let controller = makeController(repository: repository, capability: .available(store))
        let called = RestoreBoundaryFlag()
        let commit = makeRestoreBoundaryCommitResult()

        do {
            _ = try await controller.performRestoreBoundary(
                originalSnapshot: snapshot,
                confirmation: {
                    await called.mark()
                    return commit
                },
                terminal: { _, _ in }
            )
            XCTFail("A pre-held exclusive lease must block restore before confirmation.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .stateUnreadable)
        }
        let wasCalled = await called.value
        XCTAssertFalse(wasCalled)
    }

    func testCoreOnlyBoundaryRunsConfirmationWithoutSidecarLease() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let controller = makeController(repository: repository, capability: .notExpected)
        let called = RestoreBoundaryFlag()
        let commit = makeRestoreBoundaryCommitResult()

        _ = try await controller.performRestoreBoundary(
            originalSnapshot: snapshot,
            confirmation: {
                await called.mark()
                return commit
            },
            terminal: { _, host in
                XCTAssertEqual(host, .unavailable)
            }
        )
        let wasCalled = await called.value
        XCTAssertTrue(wasCalled)
    }

    func testAppModelRejectsNewSettingsAndPlanningWritersDuringRestore() async throws {
        let repository = try await makeRepository()
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: RestoreBoundaryReminderScheduler(),
            quickSurfaceHost: makeController(repository: repository, capability: .notExpected),
            now: { fixedNow }
        )
        await model.loadInitialSnapshot()
        let original = try await repository.ledgerSnapshot()
        let originalPlanning = model.planningPreferences
        let blockedSettings: AppSettings = {
            var settings = original.settings
            settings.reportLanguage = settings.reportLanguage == .english ? .ukrainian : .english
            return settings
        }()
        let blockedPlanningVisibility = !model.planningPreferences.isPaceVisible

        try await model.performWholeStoreRestore {
            let startupState = await model.startupState
            XCTAssertEqual(startupState, .loading)
            await model.saveSettings(blockedSettings)
            await model.updatePlanningVisibility(blockedPlanningVisibility)
            return makeRestoreBoundaryCommitResult()
        }

        let readback = try await repository.ledgerSnapshot()
        XCTAssertEqual(readback.settings, original.settings)
        XCTAssertEqual(readback.settingsMetadata.planningVisible, original.settingsMetadata.planningVisible)
        XCTAssertEqual(readback.settingsMetadata.quietGapCheckEnabled, original.settingsMetadata.quietGapCheckEnabled)
        XCTAssertEqual(readback.settingsMetadata.quietGapDays, original.settingsMetadata.quietGapDays)
        XCTAssertEqual(model.settings, original.settings)
        XCTAssertEqual(model.planningPreferences, originalPlanning)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testAppModelRestoreRefreshesPublishedStateBeforeLeaseRelease() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-app-model")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: true, privacyMode: .showTotals)
        )
        try writeShownIdleState(root: root, attributes: attributes)
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: RestoreBoundaryReminderScheduler(),
            quickSurfaceHost: makeController(repository: repository, capability: .available(store)),
            now: { fixedNow }
        )
        await model.loadInitialSnapshot()
        let commit = makeRestoreBoundaryCommitResult()

        _ = try await model.performWholeStoreRestore {
            _ = try await AddTimeEntryCommand(repository: repository).execute(
                kind: .service,
                date: fixedNow,
                hours: 0,
                minutes: 45,
                note: "restore boundary fresh snapshot",
                occurredAt: fixedNow
            )
            return commit
        }

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.quickSurfaceAvailability, .ready)
        XCTAssertEqual(model.quickSurfaceState?.projection.privacyMode, .showTotals)
        XCTAssertEqual(model.quickSurfaceState?.projection.serviceMinutes, 45)
        XCTAssertEqual(model.quickSurfaceState?.timer, .idle)
        XCTAssertEqual(try store.read().projection.privacyMode, .showTotals)
        let nextLease = try store.acquireExclusiveRestoreLease()
        try nextLease.release()
    }

    func testPostConfirmationProjectionFailureMarksAppModelFailedAndKeepsHiddenState() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-boundary-projection-fault")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let fault = RestoreBoundaryFault()
        let store = QuickSurfaceStateStoreV1(
            rootDirectory: root,
            faults: .init { point in
                if fault.isEnabled {
                    throw QuickSurfaceStoreInjectedError.marker
                }
                _ = point
            },
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
        )
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: true, privacyMode: .showTotals)
        )
        try writeShownIdleState(root: root, attributes: attributes)
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: RestoreBoundaryReminderScheduler(),
            quickSurfaceHost: makeController(repository: repository, capability: .available(store)),
            now: { fixedNow }
        )
        await model.loadInitialSnapshot()
        let commit = makeRestoreBoundaryCommitResult()

        do {
            _ = try await model.performWholeStoreRestore {
                fault.enable()
                return commit
            }
            XCTFail("A post-confirmation projection fault must fail the app model.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .restoreProjectionFailed)
        }
        XCTAssertEqual(model.startupState, .failed)
        XCTAssertEqual(try readRestoreBoundaryState(root: root).projection.privacyMode, .hideTotals)
        let nextLease = try store.acquireExclusiveRestoreLease()
        try nextLease.release()
    }

    private func makeRepository() async throws -> CoreDataLedgerRepository {
        let fixedNow = Self.now
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { fixedNow }
        )
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 8)
        try await repository.saveSettings(settings)
        return repository
    }

    private func makeController(
        repository: any LedgerRepository,
        capability: QuickSurfaceHostCapability
    ) -> QuickSurfaceHostController {
        let fixedNow = Self.now
        return QuickSurfaceHostController(
            repository: repository,
            capability: capability,
            calendar: calendar(),
            timeZone: Self.timeZone,
            now: { fixedNow },
            systemUptime: { 1_000 }
        )
    }

    private func makeStore(
        root: URL,
        attributes: QuickSurfaceStoreAttributeLedger
    ) -> QuickSurfaceStateStoreV1 {
        QuickSurfaceStateStoreV1(
            rootDirectory: root,
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
        )
    }

    private func writeShownIdleState(
        root: URL,
        attributes: QuickSurfaceStoreAttributeLedger,
        revision: UInt64 = 1
    ) throws {
        let state = QuickSurfaceStateV1(
            revision: revision,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .showTotals,
                monthKey: "2026-08",
                timeZoneIdentifier: Self.timeZone.identifier,
                serviceMinutes: 120,
                creditMinutes: 15,
                generatedAtEpochSeconds: Self.now.timeIntervalSince1970
            ),
            timerEnabled: true,
            timer: .idle
        )
        try QuickSurfaceStoreTestSupport.writeStateFile(state, root: root)
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        return calendar
    }

}

private func readRestoreBoundaryState(root: URL) throws -> QuickSurfaceStateV1 {
    try QuickSurfaceStateV1.decodeStrict(
        Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))
    )
}

private func makeRestoreBoundaryCommitResult() -> RestoreCommitResult {
    RestoreCommitResult(
        selectedTarget: .candidate,
        recordsDigest: String(repeating: "a", count: 64),
        recordCounts: HourleafBackupRecordCountsV1(
            acknowledgements: 0,
            archives: 0,
            entries: 0,
            policies: 0,
            presets: 0,
            receipts: 0,
            reminders: 0,
            revisions: 0,
            states: 0
        )
    )
}

private enum RestoreBoundaryTestError: Error, Equatable {
    case cancelled
}

private actor RestoreBoundaryGate {
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func pause() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func resume() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RestoreBoundaryFlag {
    private(set) var value = false

    func mark() {
        value = true
    }
}

private final class RestoreBoundaryFault: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false

    var isEnabled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return enabled
    }

    func enable() {
        lock.lock()
        enabled = true
        lock.unlock()
    }
}

@MainActor
private final class RestoreBoundaryReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
