import Darwin
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
    private let now: @Sendable () -> Date
    private let systemUptime: @Sendable () -> TimeInterval

    init(
        repository: any LedgerRepository,
        capability: QuickSurfaceHostCapability = .notExpected,
        calendar: Calendar = .hourleaf,
        timeZone: TimeZone = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { .now },
        systemUptime: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.repository = repository
        self.capability = capability
        let stateStore: QuickSurfaceStateStoreV1? = if case let .available(store) = capability {
            store
        } else {
            nil
        }
        self.stateStore = stateStore
        self.now = now
        self.systemUptime = systemUptime
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

    func reconcile(_ snapshot: LedgerSnapshot) -> QuickSurfaceHostSnapshot {
        guard let stateStore, let reconciler else { return .unavailable }
        let corePreferences = snapshot.settingsMetadata.quickSurfacePreferences

        do {
            let state = try reconcileAllowingBootstrap(
                reconciler: reconciler,
                snapshot: snapshot,
                preferences: corePreferences,
                permitElevation: false
            )
            return hostSnapshot(
                ledgerPreferences: corePreferences,
                state: state,
                availability: .ready
            )
        } catch {
            return failureSnapshot(
                error,
                stateStore: stateStore,
                ledgerPreferences: corePreferences
            )
        }
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
            return QuickSurfaceHostUpdate(ledger: snapshot, host: reconcile(snapshot))
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
            return QuickSurfaceHostUpdate(ledger: snapshot, host: reconcile(snapshot))
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
        let state: QuickSurfaceStateV1
        do {
            do {
                state = try stateStore.read()
            } catch QuickSurfaceStateStoreError.missingFile {
                state = try reconciler.bootstrap(
                    snapshot: snapshot,
                    preferences: snapshot.settingsMetadata.quickSurfacePreferences
                )
            }
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

        guard case .idle = state.timer else {
            throw QuickSurfaceHostError.timerMustBeResolved
        }
        guard state.revision < .max else {
            throw QuickSurfaceHostError.stateUnreadable
        }
    }

    func resetUnsavedState(using snapshot: LedgerSnapshot) throws -> QuickSurfaceHostSnapshot {
        guard let stateStore, let reconciler else { throw QuickSurfaceHostError.unavailable }
        do {
            try removeExactStateFile(from: stateStore)
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

    private func removeExactStateFile(from store: QuickSurfaceStateStoreV1) throws {
        let root = store.rootDirectory.standardizedFileURL
        guard root.isFileURL else { throw QuickSurfaceHostError.resetFailed }

        var file = root
        for component in QuickSurfaceStateStoreV1.relativePathComponents {
            file.appendPathComponent(component, isDirectory: false)
        }
        file = file.standardizedFileURL
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard file.path.hasPrefix(rootPrefix) else { throw QuickSurfaceHostError.resetFailed }

        var cursor = root
        for component in QuickSurfaceStateStoreV1.relativePathComponents.dropLast() {
            cursor.appendPathComponent(component, isDirectory: true)
            guard !isSymbolicLink(cursor.path) else { throw QuickSurfaceHostError.resetFailed }
        }
        guard !isSymbolicLink(file.path) else { throw QuickSurfaceHostError.resetFailed }

        var coordinationError: NSError?
        var removalError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: file,
            options: .forDeleting,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    try FileManager.default.removeItem(at: coordinatedURL)
                }
            } catch {
                removalError = error
            }
        }
        if coordinationError != nil || removalError != nil {
            throw QuickSurfaceHostError.resetFailed
        }
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            return errno != ENOENT
        }
        return (info.st_mode & S_IFMT) == S_IFLNK
    }
}
