import Foundation

enum QuickSurfaceHostAvailability: Equatable, Sendable {
    case unavailable
    case ready
    case stale
    case resetRequired

    var isVisibleInSettings: Bool { self != .unavailable }
    var allowsInteraction: Bool { self == .ready }
}

enum QuickSurfaceHostError: LocalizedError, Equatable, Sendable {
    case unavailable
    case stateUnreadable
    case resetRequired
    case timerMustBeResolved
    case preferenceUpdateFailed
    case invalidReview
    case resetFailed
    case restoreProjectionFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "quick_surfaces.error.timer_unavailable")
        case .stateUnreadable:
            String(localized: "quick_surfaces.settings.unavailable")
        case .resetRequired:
            String(localized: "quick_surfaces.restore.reset_required")
        case .timerMustBeResolved:
            String(localized: "quick_surfaces.error.timer_active")
        case .preferenceUpdateFailed:
            String(localized: "quick_surfaces.settings.update_failed")
        case .invalidReview:
            String(localized: "quick_surfaces.review.invalid")
        case .resetFailed:
            String(localized: "quick_surfaces.settings.reset_failed")
        case .restoreProjectionFailed:
            QuickSurfaceHostError.resetRequired.errorDescription
        }
    }
}

struct QuickSurfaceHostSnapshot: Equatable, Sendable {
    let availability: QuickSurfaceHostAvailability
    let preferences: QuickSurfacePreferences
    let state: QuickSurfaceStateV1?

    static let unavailable = QuickSurfaceHostSnapshot(
        availability: .unavailable,
        preferences: .init(),
        state: nil
    )
}

struct QuickSurfaceHostUpdate: Sendable {
    let ledger: LedgerSnapshot
    let host: QuickSurfaceHostSnapshot
}

enum QuickSurfaceHostCapability: Sendable {
    /// The normal core-only build. Quick Surfaces have never been available,
    /// so the missing sidecar does not block the existing restore flow.
    case notExpected
    /// An extension-capable build expected a container but could not resolve
    /// it. This is fail-closed for restore and remains hidden in Settings.
    case expectedButUnavailable
    case available(QuickSurfaceStateStoreV1)
}

/// The host keeps the sidecar lease alive while the app owns the whole-store
/// restore boundary. The terminal callback is deliberately injected by the
/// app model so published state and reminders finish before the lease closes.
typealias QuickSurfaceRestoreTerminal = @MainActor @Sendable (
    LedgerSnapshot,
    QuickSurfaceHostSnapshot
) async throws -> Void

/// Owns the host-app side of the redacted quick-surface state. A nil store is
/// intentional: the ordinary iOS 17 app remains fully functional before the
/// owner-approved App Group capability is installed.
actor QuickSurfaceHostController {
    nonisolated let capabilityAvailable: Bool
    nonisolated let capabilityExpected: Bool

    private let repository: any LedgerRepository
    private let capability: QuickSurfaceHostCapability
    private let stateStore: QuickSurfaceStateStoreV1?
    private let reconciler: QuickSurfaceReconciler?
    private let finalizer: TimerEntryFinalizer?
    private let calendar: Calendar
    private let timeZone: TimeZone
    private let now: @Sendable () -> Date
    private let systemUptime: @Sendable () -> TimeInterval
    private let executionActivity: QuickSurfaceHostExecutionActivity

    init(
        repository: any LedgerRepository,
        capability: QuickSurfaceHostCapability = .notExpected,
        calendar: Calendar = .hourleaf,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { .now },
        systemUptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        executionActivity: QuickSurfaceHostExecutionActivity = .immediate
    ) {
        self.repository = repository
        self.capability = capability
        var resolvedCalendar = calendar
        resolvedCalendar.timeZone = timeZone
        self.calendar = resolvedCalendar
        self.timeZone = timeZone
        let stateStore: QuickSurfaceStateStoreV1? = if case let .available(store) = capability {
            store
        } else {
            nil
        }
        self.stateStore = stateStore
        self.now = now
        self.systemUptime = systemUptime
        self.executionActivity = executionActivity
        capabilityAvailable = stateStore != nil
        capabilityExpected = if case .notExpected = capability { false } else { true }
        reconciler = stateStore.map {
            QuickSurfaceReconciler(
                stateStore: $0,
                calendar: calendar,
                timeZone: timeZone,
                clock: now
            )
        }
        finalizer = stateStore.map {
            TimerEntryFinalizer(repository: repository, stateStore: $0)
        }
    }

    func reconcile(_ snapshot: LedgerSnapshot) async -> QuickSurfaceHostSnapshot {
        guard let stateStore, let reconciler else { return .unavailable }
        let executionLease = await executionActivity.begin()
        let corePreferences = snapshot.settingsMetadata.quickSurfacePreferences

        let result: QuickSurfaceHostSnapshot
        do {
            let state = try reconcileAllowingBootstrap(
                reconciler: reconciler,
                snapshot: snapshot,
                preferences: corePreferences,
                permitElevation: false
            )
            result = hostSnapshot(
                ledgerPreferences: corePreferences,
                state: state,
                availability: .ready
            )
        } catch {
            result = failureSnapshot(
                error,
                stateStore: stateStore,
                ledgerPreferences: corePreferences
            )
        }
        await executionLease.end()
        return result
    }

    func readCurrent(using snapshot: LedgerSnapshot) -> QuickSurfaceHostSnapshot {
        guard let stateStore else { return .unavailable }
        let preferences = snapshot.settingsMetadata.quickSurfacePreferences
        do {
            return hostSnapshot(
                ledgerPreferences: preferences,
                state: try stateStore.read(),
                availability: .ready
            )
        } catch {
            return failureSnapshot(
                error,
                stateStore: stateStore,
                ledgerPreferences: preferences
            )
        }
    }

    func setPrivacyMode(
        _ mode: WidgetPrivacyMode,
        snapshot: LedgerSnapshot
    ) async throws -> QuickSurfaceHostUpdate {
        let current = snapshot.settingsMetadata.quickSurfacePreferences
        guard current.privacyMode != mode else {
            return QuickSurfaceHostUpdate(ledger: snapshot, host: await reconcile(snapshot))
        }
        var requested = current
        requested.privacyMode = mode

        switch mode {
        case .hideTotals:
            _ = try reconcileExplicitly(
                snapshot: snapshot,
                preferences: requested,
                permitElevation: false
            )
            do {
                let fresh = try await saveAndVerify(requested)
                let state = try reconcileExplicitly(
                    snapshot: fresh,
                    preferences: requested,
                    permitElevation: false
                )
                return try verifiedUpdate(ledger: fresh, state: state, requested: requested)
            } catch {
                throw QuickSurfaceHostError.preferenceUpdateFailed
            }

        case .showTotals:
            let fresh: LedgerSnapshot
            do {
                fresh = try await saveAndVerify(requested)
            } catch {
                throw QuickSurfaceHostError.preferenceUpdateFailed
            }
            do {
                let state = try reconcileExplicitly(
                    snapshot: fresh,
                    preferences: requested,
                    permitElevation: true
                )
                return try verifiedUpdate(ledger: fresh, state: state, requested: requested)
            } catch {
                await compensateToHidden(from: requested)
                throw QuickSurfaceHostError.preferenceUpdateFailed
            }
        }
    }

    func setTimerVisible(
        _ isVisible: Bool,
        snapshot: LedgerSnapshot
    ) async throws -> QuickSurfaceHostUpdate {
        let current = snapshot.settingsMetadata.quickSurfacePreferences
        guard current.timerVisible != isVisible else {
            return QuickSurfaceHostUpdate(ledger: snapshot, host: await reconcile(snapshot))
        }
        var requested = current
        requested.timerVisible = isVisible

        if !isVisible {
            guard let stateStore else { throw QuickSurfaceHostError.unavailable }
            let currentState: QuickSurfaceStateV1
            do {
                currentState = try stateStore.read()
            } catch {
                throw QuickSurfaceHostError.stateUnreadable
            }
            guard case .idle = currentState.timer else {
                throw QuickSurfaceHostError.timerMustBeResolved
            }
            do {
                _ = try reconcileExplicitly(
                    snapshot: snapshot,
                    preferences: requested,
                    permitElevation: false
                )
            } catch let error as TimerSessionCommandError where error == .reviewRequired {
                throw QuickSurfaceHostError.timerMustBeResolved
            } catch {
                throw QuickSurfaceHostError.preferenceUpdateFailed
            }
            do {
                let fresh = try await saveAndVerify(requested)
                let state = try reconcileExplicitly(
                    snapshot: fresh,
                    preferences: requested,
                    permitElevation: false
                )
                return try verifiedUpdate(ledger: fresh, state: state, requested: requested)
            } catch {
                throw QuickSurfaceHostError.preferenceUpdateFailed
            }
        }

        let fresh: LedgerSnapshot
        do {
            fresh = try await saveAndVerify(requested)
        } catch {
            throw QuickSurfaceHostError.preferenceUpdateFailed
        }
        do {
            let state = try reconcileExplicitly(
                snapshot: fresh,
                preferences: requested,
                permitElevation: true
            )
            return try verifiedUpdate(ledger: fresh, state: state, requested: requested)
        } catch {
            await compensateTimerDisabled(from: requested)
            throw QuickSurfaceHostError.preferenceUpdateFailed
        }
    }

    func startTimer() throws -> QuickSurfaceStateV1 {
        let store = try requireStore()
        let sessionID = UUID()
        let clock = timerClock()
        return try store.replace { current in
            guard let current else { throw QuickSurfaceStateStoreError.missingFile }
            return try TimerSessionCommandV1.start(
                state: current,
                clock: clock,
                sessionID: sessionID
            )
        }
    }

    func stopTimer() throws -> QuickSurfaceStateV1 {
        let store = try requireStore()
        let clock = timerClock()
        let mutationID = UUID()
        let entryID = UUID()
        return try store.replace { current in
            guard let current else { throw QuickSurfaceStateStoreError.missingFile }
            return try TimerSessionCommandV1.stop(
                state: current,
                clock: clock,
                mutationID: mutationID,
                entryID: entryID
            )
        }
    }

    func authorizeReview(
        sessionID: UUID,
        mutationID: UUID,
        entryID: UUID,
        kind: EntryKind,
        day: LocalDay,
        minutes: Int
    ) throws -> QuickSurfaceStateV1 {
        guard (1...5_999).contains(minutes) else {
            throw QuickSurfaceHostError.invalidReview
        }
        let store = try requireStore()
        let authorizedKind: QuickSurfaceAuthorizedKindV1 = kind == .service ? .service : .credit
        let authorizedAt = now().timeIntervalSince1970
        return try store.replace { current in
            guard let current else { throw QuickSurfaceStateStoreError.missingFile }
            return try TimerSessionCommandV1.authorizeReview(
                state: current,
                expectedSessionID: sessionID,
                expectedMutationID: mutationID,
                expectedEntryID: entryID,
                kind: authorizedKind,
                day: day.key,
                minutes: minutes,
                authorizedAtEpochSeconds: authorizedAt
            )
        }
    }

    func discardReview(
        sessionID: UUID,
        mutationID: UUID,
        entryID: UUID
    ) throws -> QuickSurfaceStateV1 {
        let store = try requireStore()
        return try store.replace { current in
            guard let current else { throw QuickSurfaceStateStoreError.missingFile }
            return try TimerSessionCommandV1.discardReview(
                state: current,
                expectedSessionID: sessionID,
                expectedMutationID: mutationID,
                expectedEntryID: entryID
            )
        }
    }

    func finalizeTimerEntry() async throws -> TimerEntryFinalizationResult {
        guard let finalizer else { throw QuickSurfaceHostError.unavailable }
        return try await finalizer.finalize()
    }

    func requireIdleForRestore(using snapshot: LedgerSnapshot) throws {
        switch capability {
        case .notExpected:
            return
        case .expectedButUnavailable:
            throw QuickSurfaceHostError.stateUnreadable
        case .available:
            break
        }
        guard let stateStore, let reconciler else {
            throw QuickSurfaceHostError.stateUnreadable
        }
        do {
            let state = try restoreState(
                using: stateStore,
                reconciler: reconciler,
                snapshot: snapshot
            )
            try requireIdleAndAvailableRevision(state)
        } catch let error as QuickSurfaceHostError {
            throw error
        } catch let error as QuickSurfaceStateStoreError {
            switch error {
            case .corrupt, .unsupportedVersion:
                throw QuickSurfaceHostError.resetRequired
            default:
                throw QuickSurfaceHostError.stateUnreadable
            }
        } catch {
            throw QuickSurfaceHostError.stateUnreadable
        }
    }

    /// Runs the restore confirmation while an exclusive sidecar lease is held.
    /// The lease spans final timer validation, privacy redaction, the existing
    /// journaled confirmation, authoritative readback, sidecar reconciliation,
    /// and the app-model terminal refresh callback.
    func performRestoreBoundary(
        originalSnapshot: LedgerSnapshot,
        confirmation: @escaping @Sendable () async throws -> RestoreCommitResult,
        terminal: @escaping QuickSurfaceRestoreTerminal
    ) async throws -> RestoreCommitResult {
        switch capability {
        case .notExpected:
            let result = try await confirmation()
            do {
                let restoredSnapshot = try await repository.reconcileReportLifecycle(asOf: now())
                try await terminal(restoredSnapshot, .unavailable)
            } catch {
                throw QuickSurfaceHostError.restoreProjectionFailed
            }
            return result

        case .expectedButUnavailable:
            throw QuickSurfaceHostError.stateUnreadable

        case let .available(baseStore):
            let lease: QuickSurfaceStateStoreLease
            do {
                lease = try baseStore.acquireExclusiveRestoreLease()
            } catch let error as QuickSurfaceStateStoreError {
                throw mapRestoreBoundaryError(error)
            } catch {
                throw QuickSurfaceHostError.stateUnreadable
            }

            var released = false
            defer {
                if !released { try? lease.release() }
            }

            let leasedStore: QuickSurfaceStateStoreV1
            do {
                leasedStore = try baseStore.leasedView(using: lease)
            } catch let error as QuickSurfaceStateStoreError {
                throw mapRestoreBoundaryError(error)
            } catch {
                throw QuickSurfaceHostError.stateUnreadable
            }

            let leasedReconciler = QuickSurfaceReconciler(
                stateStore: leasedStore,
                calendar: calendar,
                timeZone: timeZone,
                clock: now
            )
            let preRestoreState: QuickSurfaceStateV1
            do {
                preRestoreState = try restoreState(
                    using: leasedStore,
                    reconciler: leasedReconciler,
                    snapshot: originalSnapshot
                )
                try requireIdleAndAvailableRevision(preRestoreState)
                // The state store intentionally rejects publishing UInt64.max.
                // A current revision of max-1 is therefore exhausted even when
                // redaction would otherwise be a semantic no-op. Check before
                // redaction so confirmation can never begin without one more
                // usable transition, then verify the same invariant after the
                // redaction readback below.
                try requireUsableNextRevision(preRestoreState)
                let redactedState = try redactForRestore(
                    state: preRestoreState,
                    snapshot: originalSnapshot,
                    store: leasedStore,
                    reconciler: leasedReconciler
                )
                // Reserve one valid transition for the authoritative restored
                // projection. The store deliberately rejects UInt64.max.
                try requireIdleAndAvailableRevision(redactedState)
            } catch let error as QuickSurfaceHostError {
                throw error
            } catch let error as QuickSurfaceStateStoreError {
                throw mapRestoreBoundaryError(error)
            } catch {
                throw QuickSurfaceHostError.stateUnreadable
            }

            var confirmationReturned = false
            var terminalCompleted = false
            do {
                let result = try await confirmation()
                confirmationReturned = true

                let restoredSnapshot = try await repository.reconcileReportLifecycle(asOf: now())
                let restoredState = try reconcileForRestore(
                    snapshot: restoredSnapshot,
                    reconciler: leasedReconciler,
                    permitElevation: true
                )
                let readback = try leasedStore.read()
                guard readback == restoredState else {
                    throw QuickSurfaceStateStoreError.readbackMismatch
                }
                let restoredHost = hostSnapshot(
                    ledgerPreferences: restoredSnapshot.settingsMetadata.quickSurfacePreferences,
                    state: readback,
                    availability: .ready
                )

                try await terminal(restoredSnapshot, restoredHost)
                terminalCompleted = true
                do {
                    try lease.release()
                    released = true
                } catch {
                    throw QuickSurfaceHostError.stateUnreadable
                }
                return result
            } catch {
                // Before the confirmation returns, restore the original
                // authoritative snapshot when possible. After a returned
                // commit, never show pre-restore totals again: retain a
                // conservative hidden projection until startup recovery or a
                // later authoritative reconciliation completes.
                if !terminalCompleted {
                    if confirmationReturned {
                        let fallbackSnapshot = (try? await repository.reconcileReportLifecycle(asOf: now()))
                            ?? originalSnapshot
                        try? redactAfterRestoreFailure(
                            snapshot: fallbackSnapshot,
                            store: leasedStore,
                            reconciler: leasedReconciler
                        )
                        throw QuickSurfaceHostError.restoreProjectionFailed
                    } else {
                        try? recoverOriginalProjection(
                            snapshot: originalSnapshot,
                            state: preRestoreState,
                            store: leasedStore,
                            reconciler: leasedReconciler
                        )
                    }
                }
                throw error
            }
        }
    }

    func resetUnsavedState(using snapshot: LedgerSnapshot) throws -> QuickSurfaceHostSnapshot {
        guard let stateStore, let reconciler else { throw QuickSurfaceHostError.unavailable }
        do {
            try stateStore.removeStateFile()
            let state = try reconciler.bootstrap(
                snapshot: snapshot,
                preferences: snapshot.settingsMetadata.quickSurfacePreferences
            )
            return hostSnapshot(
                ledgerPreferences: snapshot.settingsMetadata.quickSurfacePreferences,
                state: state,
                availability: .ready
            )
        } catch {
            throw QuickSurfaceHostError.resetFailed
        }
    }

    private func reconcileExplicitly(
        snapshot: LedgerSnapshot,
        preferences: QuickSurfacePreferences,
        permitElevation: Bool
    ) throws -> QuickSurfaceStateV1 {
        guard let reconciler else { throw QuickSurfaceHostError.unavailable }
        return try reconcileAllowingBootstrap(
            reconciler: reconciler,
            snapshot: snapshot,
            preferences: preferences,
            permitElevation: permitElevation
        )
    }

    private func restoreState(
        using store: QuickSurfaceStateStoreV1,
        reconciler: QuickSurfaceReconciler,
        snapshot: LedgerSnapshot
    ) throws -> QuickSurfaceStateV1 {
        do {
            return try store.read()
        } catch QuickSurfaceStateStoreError.missingFile {
            return try reconciler.bootstrap(
                snapshot: snapshot,
                preferences: snapshot.settingsMetadata.quickSurfacePreferences
            )
        }
    }

    private func requireIdleAndAvailableRevision(_ state: QuickSurfaceStateV1) throws {
        guard case .idle = state.timer else {
            throw QuickSurfaceHostError.timerMustBeResolved
        }
        guard state.revision < UInt64.max - 1 else {
            throw QuickSurfaceHostError.stateUnreadable
        }
    }

    private func requireUsableNextRevision(_ state: QuickSurfaceStateV1) throws {
        guard state.revision < (.max - 1) else {
            throw QuickSurfaceHostError.stateUnreadable
        }
    }

    private func redactForRestore(
        state: QuickSurfaceStateV1,
        snapshot: LedgerSnapshot,
        store: QuickSurfaceStateStoreV1,
        reconciler: QuickSurfaceReconciler
    ) throws -> QuickSurfaceStateV1 {
        var preferences = snapshot.settingsMetadata.quickSurfacePreferences
        preferences.privacyMode = .hideTotals
        // Preserve the effective sidecar timer preference while the restore
        // boundary is held. The restored Core Data preference is authoritative
        // only after the durable confirmation succeeds.
        preferences.timerVisible = state.timerEnabled
        let redacted = try reconcileForRestore(
            snapshot: snapshot,
            preferences: preferences,
            reconciler: reconciler,
            permitElevation: false
        )
        let readback = try store.read()
        guard readback == redacted,
              readback.projection.privacyMode == .hideTotals,
              case .idle = readback.timer
        else {
            throw QuickSurfaceStateStoreError.readbackMismatch
        }
        try requireUsableNextRevision(readback)
        return readback
    }

    private func recoverOriginalProjection(
        snapshot: LedgerSnapshot,
        state: QuickSurfaceStateV1,
        store: QuickSurfaceStateStoreV1,
        reconciler: QuickSurfaceReconciler
    ) throws {
        var preferences = snapshot.settingsMetadata.quickSurfacePreferences
        preferences.privacyMode = .hideTotals
        preferences.timerVisible = state.timerEnabled
        let recovered = try reconcileForRestore(
            snapshot: snapshot,
            preferences: preferences,
            reconciler: reconciler,
            permitElevation: false
        )
        let readback = try store.read()
        guard readback == recovered,
              readback.projection.privacyMode == .hideTotals else {
            throw QuickSurfaceStateStoreError.readbackMismatch
        }
    }

    private func redactAfterRestoreFailure(
        snapshot: LedgerSnapshot,
        store: QuickSurfaceStateStoreV1,
        reconciler: QuickSurfaceReconciler
    ) throws {
        var preferences = snapshot.settingsMetadata.quickSurfacePreferences
        preferences.privacyMode = .hideTotals
        if let current = try? store.read() {
            preferences.timerVisible = current.timerEnabled
        }
        let hidden = try reconcileForRestore(
            snapshot: snapshot,
            preferences: preferences,
            reconciler: reconciler,
            permitElevation: false
        )
        let readback = try store.read()
        guard readback == hidden,
              readback.projection.privacyMode == .hideTotals else {
            throw QuickSurfaceStateStoreError.readbackMismatch
        }
    }

    private func reconcileForRestore(
        snapshot: LedgerSnapshot,
        reconciler: QuickSurfaceReconciler,
        permitElevation: Bool
    ) throws -> QuickSurfaceStateV1 {
        try reconcileAllowingBootstrap(
            reconciler: reconciler,
            snapshot: snapshot,
            preferences: snapshot.settingsMetadata.quickSurfacePreferences,
            permitElevation: permitElevation
        )
    }

    private func reconcileForRestore(
        snapshot: LedgerSnapshot,
        preferences: QuickSurfacePreferences,
        reconciler: QuickSurfaceReconciler,
        permitElevation: Bool
    ) throws -> QuickSurfaceStateV1 {
        try reconcileAllowingBootstrap(
            reconciler: reconciler,
            snapshot: snapshot,
            preferences: preferences,
            permitElevation: permitElevation
        )
    }

    private func mapRestoreBoundaryError(_ error: QuickSurfaceStateStoreError) -> QuickSurfaceHostError {
        switch error {
        case .corrupt, .unsupportedVersion:
            return .resetRequired
        case .accessBusy, .leaseUnavailable, .leaseReleased, .leaseRootMismatch,
             .leaseIdentityMismatch, .leaseReleaseFailed, .lockFileInvalid:
            return .stateUnreadable
        default:
            return .stateUnreadable
        }
    }

    private func reconcileAllowingBootstrap(
        reconciler: QuickSurfaceReconciler,
        snapshot: LedgerSnapshot,
        preferences: QuickSurfacePreferences,
        permitElevation: Bool
    ) throws -> QuickSurfaceStateV1 {
        do {
            return try reconciler.reconcile(
                snapshot: snapshot,
                preferences: preferences,
                permitElevation: permitElevation
            )
        } catch QuickSurfaceStateStoreError.missingFile {
            _ = try reconciler.bootstrap(snapshot: snapshot, preferences: preferences)
            // Bootstrap may lose a create-if-absent race to another process.
            // Reconcile once more so the winning state receives this caller's
            // projection and explicit elevation policy.
            return try reconciler.reconcile(
                snapshot: snapshot,
                preferences: preferences,
                permitElevation: permitElevation
            )
        }
    }

    private func saveAndVerify(_ requested: QuickSurfacePreferences) async throws -> LedgerSnapshot {
        try await repository.saveQuickSurfacePreferences(requested)
        let snapshot = try await repository.ledgerSnapshot()
        guard snapshot.settingsMetadata.quickSurfacePreferences == requested else {
            throw QuickSurfaceHostError.preferenceUpdateFailed
        }
        return snapshot
    }

    private func verifiedUpdate(
        ledger: LedgerSnapshot,
        state: QuickSurfaceStateV1,
        requested: QuickSurfacePreferences
    ) throws -> QuickSurfaceHostUpdate {
        let effective = Self.effectivePreferences(
            ledger: ledger.settingsMetadata.quickSurfacePreferences,
            sidecar: state
        )
        guard effective == requested else {
            throw QuickSurfaceHostError.preferenceUpdateFailed
        }
        return QuickSurfaceHostUpdate(
            ledger: ledger,
            host: QuickSurfaceHostSnapshot(
                availability: .ready,
                preferences: effective,
                state: state
            )
        )
    }

    private func compensateToHidden(from failed: QuickSurfacePreferences) async {
        var conservative = failed
        conservative.privacyMode = .hideTotals
        guard let fresh = try? await saveAndVerify(conservative) else { return }
        _ = try? reconcileExplicitly(
            snapshot: fresh,
            preferences: conservative,
            permitElevation: false
        )
    }

    private func compensateTimerDisabled(from failed: QuickSurfacePreferences) async {
        var conservative = failed
        conservative.timerVisible = false
        guard let fresh = try? await saveAndVerify(conservative) else { return }
        _ = try? reconcileExplicitly(
            snapshot: fresh,
            preferences: conservative,
            permitElevation: false
        )
    }

    private func hostSnapshot(
        ledgerPreferences: QuickSurfacePreferences,
        state: QuickSurfaceStateV1,
        availability: QuickSurfaceHostAvailability
    ) -> QuickSurfaceHostSnapshot {
        QuickSurfaceHostSnapshot(
            availability: availability,
            preferences: Self.effectivePreferences(ledger: ledgerPreferences, sidecar: state),
            state: state
        )
    }

    private func failureSnapshot(
        _ error: Error,
        stateStore: QuickSurfaceStateStoreV1,
        ledgerPreferences: QuickSurfacePreferences
    ) -> QuickSurfaceHostSnapshot {
        let availability: QuickSurfaceHostAvailability
        if let storeError = error as? QuickSurfaceStateStoreError {
            switch storeError {
            case .corrupt, .unsupportedVersion:
                availability = .resetRequired
            default:
                availability = .stale
            }
        } else if let codecError = error as? QuickSurfaceStateCodecError,
                  case .unsupportedVersion = codecError {
            availability = .resetRequired
        } else {
            availability = .stale
        }

        let readable = try? stateStore.read()
        return QuickSurfaceHostSnapshot(
            availability: availability,
            preferences: readable.map {
                Self.effectivePreferences(ledger: ledgerPreferences, sidecar: $0)
            } ?? QuickSurfacePreferences(),
            state: readable
        )
    }

    private static func effectivePreferences(
        ledger: QuickSurfacePreferences,
        sidecar: QuickSurfaceStateV1
    ) -> QuickSurfacePreferences {
        QuickSurfacePreferences(
            timerVisible: ledger.timerVisible && sidecar.timerEnabled,
            privacyMode: ledger.privacyMode == .showTotals
                && sidecar.projection.privacyMode == .showTotals
                ? .showTotals
                : .hideTotals
        )
    }

    private func timerClock() -> TimerClockSnapshotV1 {
        TimerClockSnapshotV1(
            wallNow: now(),
            uptimeNowSeconds: systemUptime()
        )
    }

    private func requireStore() throws -> QuickSurfaceStateStoreV1 {
        guard let stateStore else { throw QuickSurfaceHostError.unavailable }
        return stateStore
    }

}
