import Foundation
import XCTest
@testable import Hourleaf

final class QuickSurfaceHostControllerTests: XCTestCase {
    private static let timeZone = TimeZone(identifier: "Europe/Uzhgorod")!
    private static let now = Date(timeIntervalSince1970: 1_785_837_600)

    func testCoreOnlyCapabilityAllowsRestoreAndRemainsUnavailable() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let controller = makeController(repository: repository, capability: .notExpected)

        XCTAssertFalse(controller.capabilityExpected)
        XCTAssertFalse(controller.capabilityAvailable)
        try await controller.requireIdleForRestore(using: snapshot)

        let host = await controller.reconcile(snapshot)
        XCTAssertEqual(host, .unavailable)
    }

    func testExpectedButUnavailableCapabilityBlocksRestore() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let controller = makeController(repository: repository, capability: .expectedButUnavailable)

        XCTAssertTrue(controller.capabilityExpected)
        XCTAssertFalse(controller.capabilityAvailable)
        do {
            try await controller.requireIdleForRestore(using: snapshot)
            XCTFail("An expected App Group must not be assumed idle when unavailable.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .stateUnreadable)
        }
    }

    func testAvailableMissingFileBootstrapsRevisionOneIdleBeforeRestore() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let controller = makeController(repository: repository, capability: .available(store))

        try await controller.requireIdleForRestore(using: snapshot)

        let state = try store.read()
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.timer, .idle)
        XCTAssertFalse(state.timerEnabled)
        XCTAssertEqual(state.projection.privacyMode, .hideTotals)
    }

    func testRestoreBlocksEveryUnresolvedTimerPhaseAndRevisionExhaustion() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let phases = [
            ("running", try runningState()),
            ("review pending", try reviewPendingState()),
            ("finalizing", try finalizingState())
        ]

        for (name, state) in phases {
            let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-\(name)")
            defer { QuickSurfaceStoreTestSupport.cleanup(root) }
            let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
            let store = makeStore(root: root, attributes: attributes)
            try write(state, root: root, attributes: attributes)
            let controller = makeController(repository: repository, capability: .available(store))

            do {
                try await controller.requireIdleForRestore(using: snapshot)
                XCTFail("Restore must be blocked while the timer is \(name).")
            } catch {
                XCTAssertEqual(error as? QuickSurfaceHostError, .timerMustBeResolved)
            }
        }

        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-max-revision")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        try write(
            QuickSurfaceStateV1(
                revision: .max,
                projection: try hiddenProjection(),
                timerEnabled: false,
                timer: .idle
            ),
            root: root,
            attributes: attributes
        )
        let controller = makeController(repository: repository, capability: .available(store))

        do {
            try await controller.requireIdleForRestore(using: snapshot)
            XCTFail("Restore must not proceed when the sidecar revision cannot advance.")
        } catch {
            XCTAssertEqual(error as? QuickSurfaceHostError, .stateUnreadable)
        }
    }

    func testRestoreCorruptAndUnsupportedSidecarsRequireReset() async throws {
        let repository = try await makeRepository()
        let snapshot = try await repository.ledgerSnapshot()
        let cases: [(String, Data)] = [
            ("corrupt", Data("not quick-surface json".utf8)),
            (
                "unsupported",
                Data(
                    "{\"schemaVersion\":2,\"revision\":1,\"projection\":{},\"timerEnabled\":false,\"timer\":{}}".utf8
                )
            )
        ]

        for (name, data) in cases {
            let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "restore-\(name)")
            defer { QuickSurfaceStoreTestSupport.cleanup(root) }
            let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
            let store = makeStore(root: root, attributes: attributes)
            try QuickSurfaceStoreTestSupport.writeData(
                data,
                to: QuickSurfaceStoreTestSupport.stateFileURL(root: root)
            )
            QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
            let controller = makeController(repository: repository, capability: .available(store))

            do {
                try await controller.requireIdleForRestore(using: snapshot)
                XCTFail("Restore must require an explicit reset for a \(name) sidecar.")
            } catch {
                XCTAssertEqual(error as? QuickSurfaceHostError, .resetRequired)
            }
        }
    }

    func testDisablingTimerIsRejectedForEveryNonIdleStateWithoutChangingCorePreferences() async throws {
        let repository = try await makeRepository()
        let requested = QuickSurfacePreferences(timerVisible: true, privacyMode: .hideTotals)
        try await repository.saveQuickSurfacePreferences(requested)
        let snapshot = try await repository.ledgerSnapshot()
        let phases = [
            ("running", try runningState()),
            ("review pending", try reviewPendingState()),
            ("finalizing", try finalizingState())
        ]

        for (name, state) in phases {
            let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "disable-\(name)")
            defer { QuickSurfaceStoreTestSupport.cleanup(root) }
            let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
            let store = makeStore(root: root, attributes: attributes)
            try write(state, root: root, attributes: attributes)
            let controller = makeController(repository: repository, capability: .available(store))

            do {
                _ = try await controller.setTimerVisible(false, snapshot: snapshot)
                XCTFail("Timer disable must not discard a \(name) session.")
            } catch {
                XCTAssertEqual(error as? QuickSurfaceHostError, .timerMustBeResolved)
            }

            let after = try await repository.ledgerSnapshot()
            XCTAssertEqual(after.settingsMetadata.quickSurfacePreferences, requested)
            XCTAssertEqual(try store.read(), state)
        }
    }

    func testExplicitShowAndEnableVerifyBothStoresWithoutStartingTimer() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let controller = makeController(repository: repository, capability: .available(store))

        let initiallyPersisted = try await repository.ledgerSnapshot()
        let shown = try await controller.setPrivacyMode(.showTotals, snapshot: initiallyPersisted)
        let shownState = try XCTUnwrap(shown.host.state)
        XCTAssertEqual(shown.host.preferences, .init(timerVisible: false, privacyMode: .showTotals))
        XCTAssertEqual(shown.ledger.settingsMetadata.quickSurfacePreferences, shown.host.preferences)
        XCTAssertEqual(try store.read(), shownState)
        XCTAssertEqual(shownState.projection.privacyMode, .showTotals)
        XCTAssertEqual(shownState.timer, .idle)

        let enabled = try await controller.setTimerVisible(true, snapshot: shown.ledger)
        let enabledState = try XCTUnwrap(enabled.host.state)
        XCTAssertEqual(enabled.host.preferences, .init(timerVisible: true, privacyMode: .showTotals))
        XCTAssertEqual(enabled.ledger.settingsMetadata.quickSurfacePreferences, enabled.host.preferences)
        XCTAssertEqual(try store.read(), enabledState)
        XCTAssertTrue(enabledState.timerEnabled)
        XCTAssertEqual(enabledState.timer, .idle)
    }

    func testOrdinaryReconciliationNeverElevatesHiddenDisabledSidecar() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try hiddenProjection(),
            timerEnabled: false,
            timer: .idle
        )
        try write(initial, root: root, attributes: attributes)
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: true, privacyMode: .showTotals)
        )
        let controller = makeController(repository: repository, capability: .available(store))

        let snapshot = try await repository.ledgerSnapshot()
        let host = await controller.reconcile(snapshot)

        XCTAssertEqual(host.availability, .ready)
        XCTAssertEqual(host.preferences, .init(timerVisible: false, privacyMode: .hideTotals))
        XCTAssertEqual(host.state, Optional(initial))
        XCTAssertEqual(try store.read(), initial)
    }

    func testExplicitRequestReconcilesAConservativeBootstrapWinner() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let initial = try await repository.ledgerSnapshot()
        let reconciler = makeReconciler(store: store)

        let conservative = try reconciler.bootstrap(
            snapshot: initial,
            preferences: .init(timerVisible: false, privacyMode: .hideTotals)
        )
        XCTAssertEqual(conservative.projection.privacyMode, .hideTotals)
        XCTAssertFalse(conservative.timerEnabled)

        let controller = makeController(repository: repository, capability: .available(store))
        let shown = try await controller.setPrivacyMode(.showTotals, snapshot: initial)
        let enabled = try await controller.setTimerVisible(true, snapshot: shown.ledger)
        let state = try XCTUnwrap(enabled.host.state)

        XCTAssertEqual(enabled.host.preferences, .init(timerVisible: true, privacyMode: .showTotals))
        XCTAssertTrue(state.timerEnabled)
        XCTAssertEqual(state.projection.privacyMode, .showTotals)
        XCTAssertEqual(state.timer, .idle)
    }

    func testResetCorruptSidecarPreservesLedgerAndRebuildsIdle() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let receipt = try await AddTimeEntryCommand(repository: repository).execute(
            kind: .service,
            date: Self.now,
            hours: 1,
            minutes: 15,
            note: "Ledger truth must survive sidecar reset.",
            occurredAt: Self.now
        )
        let snapshot = try await repository.ledgerSnapshot()
        try QuickSurfaceStoreTestSupport.writeData(
            Data("corrupt sidecar".utf8),
            to: QuickSurfaceStoreTestSupport.stateFileURL(root: root)
        )
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
        let controller = makeController(repository: repository, capability: .available(store))

        let unreadable = await controller.reconcile(snapshot)
        XCTAssertEqual(unreadable.availability, .resetRequired)
        let reset = try await controller.resetUnsavedState(using: snapshot)
        let ledgerAfterReset = try await repository.ledgerSnapshot()

        XCTAssertEqual(reset.availability, .ready)
        XCTAssertEqual(reset.state?.revision, 1)
        XCTAssertEqual(reset.state?.timer, .idle)
        XCTAssertEqual(ledgerAfterReset.activeEntries.map(\.id), [receipt.entry.id])
        XCTAssertEqual(ledgerAfterReset.activeEntries.first?.note, "Ledger truth must survive sidecar reset.")
    }

    private func makeRepository() async throws -> CoreDataLedgerRepository {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { Self.now }
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
        QuickSurfaceHostController(
            repository: repository,
            capability: capability,
            calendar: calendar(),
            timeZone: Self.timeZone,
            now: { Self.now },
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

    private func makeReconciler(store: QuickSurfaceStateStoreV1) -> QuickSurfaceReconciler {
        QuickSurfaceReconciler(
            stateStore: store,
            calendar: calendar(),
            timeZone: Self.timeZone,
            clock: { Self.now }
        )
    }

    private func write(
        _ state: QuickSurfaceStateV1,
        root: URL,
        attributes: QuickSurfaceStoreAttributeLedger
    ) throws {
        try QuickSurfaceStoreTestSupport.writeStateFile(state, root: root)
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
    }

    private func runningState() throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 1,
            projection: try hiddenProjection(),
            timerEnabled: true,
            timer: .running(
                try .init(
                    sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    startedAtEpochSeconds: Self.now.timeIntervalSince1970 - 120,
                    startedSystemUptimeSeconds: 880
                )
            )
        )
    }

    private func reviewPendingState() throws -> QuickSurfaceStateV1 {
        try TimerSessionCommandV1.stop(
            state: runningState(),
            clock: .init(
                wallNowEpochSeconds: Self.now.timeIntervalSince1970,
                uptimeNowSeconds: 1_000
            ),
            mutationID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            entryID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
    }

    private func finalizingState() throws -> QuickSurfaceStateV1 {
        let reviewState = try reviewPendingState()
        guard case let .reviewPending(review) = reviewState.timer else {
            throw HostControllerTestError.expectedReviewPending
        }
        return try TimerSessionCommandV1.authorizeReview(
            state: reviewState,
            expectedSessionID: review.sessionID,
            expectedMutationID: review.mutationID,
            expectedEntryID: review.entryID,
            kind: .service,
            day: "2026-08-03",
            minutes: 75,
            authorizedAtEpochSeconds: Self.now.timeIntervalSince1970
        )
    }

    private func hiddenProjection() throws -> QuickSurfaceProjectionV1 {
        try .init(
            privacyMode: .hideTotals,
            monthKey: nil,
            timeZoneIdentifier: nil,
            serviceMinutes: nil,
            creditMinutes: nil,
            generatedAtEpochSeconds: Self.now.timeIntervalSince1970
        )
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        return calendar
    }
}

private enum HostControllerTestError: Error {
    case expectedReviewPending
}
