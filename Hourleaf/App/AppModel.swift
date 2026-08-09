import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Tab: Hashable { case add, history, progress, settings }
    enum StartupState: Equatable {
        case loading
        case ready
        case failed
    }

    @Published private(set) var entries: [TimeEntry] = []
    @Published private(set) var entryRecords: [LedgerEntryRecord] = []
    @Published private(set) var deletedEntryRecords: [LedgerEntryRecord] = []
    @Published private(set) var policies: [ReportingPolicy] = []
    @Published private(set) var reminders: [ReminderSchedule] = []
    @Published private(set) var receipts: [ReportReceipt] = []
    @Published private(set) var reportSnapshots: [ReportSnapshotMetadata] = []
    @Published private(set) var reportStates: [ReportStateRecord] = []
    @Published private(set) var serviceYearArchives: [ServiceYearArchiveRecord] = []
    @Published private(set) var planningPreferences = PlanningPreferences()
    @Published private(set) var dayAcknowledgements: [DayAcknowledgementRecord] = []
    @Published private(set) var currentDate: Date
    @Published private(set) var currentMonth: MonthKey
    @Published var selectedReportMonth: MonthKey
    @Published private(set) var reviewingReportMonths: Set<MonthKey> = []
    @Published private(set) var preparingReportMonths: Set<MonthKey> = []
    @Published private(set) var markingSentSnapshotIDs: Set<UUID> = []
    @Published private(set) var closingServiceYearStarts: Set<MonthKey> = []
    @Published var settings = AppSettings()
    @Published var selectedTab: Tab = .add
    @Published var errorMessage: String?
    @Published private(set) var startupState: StartupState = .loading
    @Published private(set) var startupDiagnostic: String?
    @Published private(set) var lastErrorDiagnostic: String?
    @Published private(set) var undoCandidate: EntryUndoCandidate?
    @Published private(set) var visibleUndoCandidate: EntryUndoCandidate?
    @Published private(set) var notificationAuthorizationStatus: ReminderAuthorizationStatus = .notDetermined
    @Published private(set) var monthlyReportReminderEnabled: Bool
    @Published private(set) var quickEntryResetGeneration: UInt64 = 0
    @Published private(set) var isRepeatingLastEntry = false
    @Published private(set) var quickSurfaceHostSnapshot: QuickSurfaceHostSnapshot = .unavailable
    @Published private(set) var isQuickSurfaceActionInFlight = false

    let repository: any LedgerRepository
    private let reminderScheduler: ReminderScheduling
    private let quickSurfaceHost: QuickSurfaceHostController
    private let monthlyReportReminderDefaults: UserDefaults
    private let now: @Sendable () -> Date
    private var latestLedgerSnapshot: LedgerSnapshot?
    private var initialSnapshotLoaded = false
    private var settingsSaveGeneration = 0
    private var settingsSaveTask: Task<Void, Never>?
    private var planningSaveGeneration = 0
    private var planningSaveTask: Task<Void, Never>?
    private var restoringEntryIDs = Set<UUID>()
    private var isUndoing = false
    private var undoBannerTask: Task<Void, Never>?
    private var storeRefreshRequested = false
    private var storeRefreshShouldShowUndo = false
    private var isStoreRefreshInFlight = false
    private var isWholeStoreRestoreInProgress = false
    /// Only user-visible undo state changes invalidate an in-flight presentation.
    /// A passive store reload must not prevent a just-confirmed mutation from showing Undo.
    private var undoStateGeneration = 0

    init(
        repository: any LedgerRepository,
        reminderScheduler: ReminderScheduling,
        quickSurfaceHost: QuickSurfaceHostController? = nil,
        now: @escaping @Sendable () -> Date = { .now },
        monthlyReportReminderDefaults: UserDefaults = .standard
    ) {
        let initialDate = now()
        let initialMonth = ReportReadiness.currentMonth(asOf: initialDate)
        let monthlyReportReminderPreference = MonthlyReportReminderPreference.load(
            from: monthlyReportReminderDefaults
        )
        self.repository = repository
        self.reminderScheduler = reminderScheduler
        let resolvedQuickSurfaceHost = quickSurfaceHost
            ?? QuickSurfaceHostController(repository: repository, now: now)
        self.quickSurfaceHost = resolvedQuickSurfaceHost
        quickSurfaceHostSnapshot = resolvedQuickSurfaceHost.capabilityAvailable
            ? QuickSurfaceHostSnapshot(
                availability: .stale,
                preferences: .init(),
                state: nil
            )
            : .unavailable
        self.now = now
        self.monthlyReportReminderDefaults = monthlyReportReminderDefaults
        currentDate = initialDate
        currentMonth = initialMonth
        selectedReportMonth = initialMonth
        monthlyReportReminderEnabled = monthlyReportReminderPreference.isEnabled
    }

    func loadInitialSnapshot(markReady: Bool = true) async {
        startupState = .loading
        startupDiagnostic = nil
        initialSnapshotLoaded = false
        do {
            try await loadReconciledSnapshot(selectDefaultReportMonth: true)
            await recoverQuickSurfaceFinalizationIfNeeded()
            await refreshUndoCandidate(showBanner: true)
            initialSnapshotLoaded = true
            if markReady { startupState = .ready }
        } catch {
            startupDiagnostic = error.localizedDescription
            startupState = .failed
        }
    }

    func finishInitialLoad() {
        guard initialSnapshotLoaded, startupState == .loading else { return }
        startupState = .ready
    }

    func reload() async {
        await refreshFromStore(showUndoBanner: false)
    }

    /// Drains the only queued model-owned writer before restore acquires its
    /// repository lease. This prevents an old settings draft from resuming
    /// after a successful whole-store replacement and overwriting restored
    /// settings.
    func prepareForWholeStoreRestore() async {
        while let pendingSettingsSave = settingsSaveTask {
            await pendingSettingsSave.value
        }
        while let pendingPlanningSave = planningSaveTask {
            await pendingPlanningSave.value
        }
        while isStoreRefreshInFlight {
            await Task.yield()
        }
        undoBannerTask?.cancel()
        undoBannerTask = nil
        visibleUndoCandidate = nil
        undoCandidate = nil
        undoStateGeneration &+= 1
    }

    /// Owns the app-level restore transaction. The host controller keeps the
    /// cross-process sidecar lease alive while this operation confirms the
    /// journaled store replacement and while the terminal model refresh runs.
    func performWholeStoreRestore(
        confirmation: @escaping @Sendable () async throws -> RestoreCommitResult
    ) async throws {
        let previousStartupState = startupState
        isWholeStoreRestoreInProgress = true
        defer { isWholeStoreRestoreInProgress = false }
        startupState = .loading
        do {
            await prepareForWholeStoreRestore()
            let originalSnapshot = try await repository.ledgerSnapshot()
            _ = try await quickSurfaceHost.performRestoreBoundary(
                originalSnapshot: originalSnapshot,
                confirmation: confirmation,
                terminal: { restoredSnapshot, restoredHost in
                    try await self.finishRestoreRefresh(
                        snapshot: restoredSnapshot,
                        quickSurfaceHostSnapshot: restoredHost
                    )
                }
            )
        } catch let error as QuickSurfaceHostError where error == .restoreProjectionFailed {
            startupDiagnostic = error.localizedDescription
            startupState = .failed
            throw error
        } catch {
            if startupState == .loading {
                startupState = previousStartupState
            }
            throw error
        }
    }

    /// Reads every published value from the fresh container returned by the
    /// restore coordinator. Imported mutation history is intentionally not
    /// offered as a current-session Undo action.
    func refreshAfterRestore() async throws {
        beginRestoreRefresh()

        do {
            try await loadReconciledSnapshot(
                waitForPendingSettingsSave: false,
                selectDefaultReportMonth: true
            )
            try await reconcileLoadedReminderState()
            initialSnapshotLoaded = true
            errorMessage = nil
            startupState = .ready
        } catch {
            startupDiagnostic = error.localizedDescription
            startupState = .failed
            throw error
        }
    }

    private func finishRestoreRefresh(
        snapshot: LedgerSnapshot,
        quickSurfaceHostSnapshot: QuickSurfaceHostSnapshot
    ) async throws {
        beginRestoreRefresh()
        do {
            let refreshInstant = now()
            currentDate = refreshInstant
            currentMonth = ReportReadiness.currentMonth(asOf: refreshInstant)
            apply(snapshot)
            updateSelectedReportMonth(from: snapshot, preferLatestClosed: true)
            self.quickSurfaceHostSnapshot = quickSurfaceHostSnapshot
            try await reconcileLoadedReminderState()
            initialSnapshotLoaded = true
            errorMessage = nil
            startupState = .ready
        } catch {
            startupDiagnostic = error.localizedDescription
            startupState = .failed
            throw error
        }
    }

    private func beginRestoreRefresh() {
        startupState = .loading
        startupDiagnostic = nil
        settingsSaveGeneration &+= 1
        settingsSaveTask = nil
        planningSaveGeneration &+= 1
        planningSaveTask = nil
        storeRefreshRequested = false
        storeRefreshShouldShowUndo = false
        reviewingReportMonths.removeAll()
        preparingReportMonths.removeAll()
        markingSentSnapshotIDs.removeAll()
        closingServiceYearStarts.removeAll()
        restoringEntryIDs.removeAll()
        isUndoing = false
        undoBannerTask?.cancel()
        undoBannerTask = nil
        visibleUndoCandidate = nil
        undoCandidate = nil
        undoStateGeneration &+= 1
    }

    /// Refreshes the one live app model after the scene becomes active. This
    /// is the fallback for a shortcut write that happened while the scene was
    /// suspended and therefore could not deliver its retained router signal.
    func refreshAfterForegrounding() async {
        guard startupState == .ready else { return }
        await refreshFromStore(showUndoBanner: true)
    }

    /// Applies an already-signalled shortcut write while the scene remains
    /// active. Requests coalesce so foreground and router events cannot race
    /// into overlapping repository snapshots.
    func refreshAfterExternalLedgerChange() async {
        guard startupState == .ready else { return }
        await refreshFromStore(showUndoBanner: true)
    }

    func prepareQuickEntry() {
        quickEntryResetGeneration &+= 1
        selectedTab = .add
    }

    func prepareProgress(reportMonth: MonthKey? = nil) {
        selectedTab = .progress
        guard let reportMonth else { return }
        selectedReportMonth = min(
            max(reportMonth, settings.ledgerStartMonth),
            currentMonth
        )
    }

    var oneTapProposal: OneTapProposal? {
        RepeatLastEntryCommand.proposal(from: entryRecords)
    }

    @discardableResult
    func repeatLastEntry(expected proposal: OneTapProposal) async -> Bool {
        guard !isRepeatingLastEntry else { return false }
        let tappedAt = now()
        isRepeatingLastEntry = true
        defer { isRepeatingLastEntry = false }

        do {
            let receipt = try await RepeatLastEntryCommand(repository: repository).execute(
                expected: proposal,
                at: tappedAt
            )
            await refreshAfterEntryMutation(receipt, showUndoBanner: true)
            return true
        } catch let error as OneTapEntryError {
            await refreshFromStore(showUndoBanner: true)
            present(error)
            return false
        } catch {
            present(error)
            return false
        }
    }

    private func refreshFromStore(showUndoBanner: Bool) async {
        storeRefreshRequested = true
        storeRefreshShouldShowUndo = storeRefreshShouldShowUndo || showUndoBanner
        guard !isStoreRefreshInFlight else { return }

        isStoreRefreshInFlight = true
        defer { isStoreRefreshInFlight = false }
        while storeRefreshRequested {
            storeRefreshRequested = false
            let shouldShowUndoBanner = storeRefreshShouldShowUndo
            storeRefreshShouldShowUndo = false
            do {
                try await loadReconciledSnapshot(selectDefaultReportMonth: false)
                await recoverQuickSurfaceFinalizationIfNeeded()
                await refreshUndoCandidate(showBanner: shouldShowUndoBanner)
                try await reconcileLoadedReminderState()
            } catch {
                present(error)
            }
        }
    }

    private func loadReconciledSnapshot(
        waitForPendingSettingsSave: Bool = true,
        selectDefaultReportMonth: Bool
    ) async throws {
        if waitForPendingSettingsSave {
            while let pendingSettingsSave = settingsSaveTask {
                await pendingSettingsSave.value
            }
        }

        let refreshInstant = now()
        let refreshedMonth = ReportReadiness.currentMonth(asOf: refreshInstant)
        while true {
            let generationBeforeFetch = settingsSaveGeneration
            let snapshot = try await repository.reconcileReportLifecycle(asOf: refreshInstant)
            guard
                !waitForPendingSettingsSave
                    || (settingsSaveTask == nil && generationBeforeFetch == settingsSaveGeneration)
            else {
                while let pendingSettingsSave = settingsSaveTask {
                    await pendingSettingsSave.value
                }
                continue
            }

            currentDate = refreshInstant
            currentMonth = refreshedMonth
            await applyAuthoritativeSnapshot(snapshot)
            updateSelectedReportMonth(
                from: snapshot,
                preferLatestClosed: selectDefaultReportMonth
            )
            return
        }
    }

    private func loadSnapshot(
        waitForPendingSettingsSave: Bool = true,
        onlyIfSettingsGeneration requiredGeneration: Int? = nil
    ) async throws {
        if waitForPendingSettingsSave {
            while true {
                while let pendingSettingsSave = settingsSaveTask {
                    await pendingSettingsSave.value
                }
                let generationBeforeFetch = settingsSaveGeneration
                let snapshot = try await repository.ledgerSnapshot()
                guard
                    settingsSaveTask == nil,
                    generationBeforeFetch == settingsSaveGeneration
                else { continue }
                await applyAuthoritativeSnapshot(snapshot)
                return
            }
        }

        let snapshot = try await repository.ledgerSnapshot()
        if let requiredGeneration, requiredGeneration != settingsSaveGeneration { return }
        await applyAuthoritativeSnapshot(snapshot)
    }

    private func apply(_ snapshot: LedgerSnapshot) {
        latestLedgerSnapshot = snapshot
        entryRecords = snapshot.entries.filter { !$0.isDeleted }
        deletedEntryRecords = snapshot.deletedEntries.sorted {
            ($0.deletedAt ?? .distantPast, $0.id.uuidString) > ($1.deletedAt ?? .distantPast, $1.id.uuidString)
        }
        entries = entryRecords.map(\.entry)
        settings = snapshot.settings
        policies = snapshot.policies
        reminders = snapshot.reminderSchedules
        receipts = snapshot.receipts
        reportSnapshots = snapshot.reportSnapshots
        reportStates = snapshot.reportStates
        serviceYearArchives = snapshot.serviceYearArchives
        planningPreferences = planningPreferences(from: snapshot)
        dayAcknowledgements = snapshot.dayAcknowledgements
        updateSelectedReportMonth(from: snapshot, preferLatestClosed: false)
    }

    private func applyAuthoritativeSnapshot(_ snapshot: LedgerSnapshot) async {
        apply(snapshot)
        await reconcileQuickSurfaces(using: snapshot)
    }

    var quickSurfaceAvailability: QuickSurfaceHostAvailability {
        quickSurfaceHostSnapshot.availability
    }

    var quickSurfacePreferences: QuickSurfacePreferences {
        quickSurfaceHostSnapshot.preferences
    }

    var quickSurfaceState: QuickSurfaceStateV1? {
        quickSurfaceHostSnapshot.state
    }

    var quickSurfaceTimerWasRequested: Bool {
        latestLedgerSnapshot?.settingsMetadata.quickSurfacePreferences.timerVisible ?? false
    }

    private func reconcileQuickSurfaces(using snapshot: LedgerSnapshot) async {
        guard quickSurfaceHost.capabilityExpected else {
            quickSurfaceHostSnapshot = .unavailable
            return
        }
        quickSurfaceHostSnapshot = await quickSurfaceHost.reconcile(snapshot)
    }

    func updateQuickSurfacePrivacyMode(_ mode: WidgetPrivacyMode) async {
        guard !isQuickSurfaceActionInFlight else { return }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let snapshot = try await authoritativeSnapshotForQuickSurfaces()
            let update = try await quickSurfaceHost.setPrivacyMode(mode, snapshot: snapshot)
            await applyAuthoritativeSnapshot(update.ledger)
            quickSurfaceHostSnapshot = update.host
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.settings.update_failed")
        }
    }

    func updateQuickSurfaceTimerVisibility(_ isVisible: Bool) async {
        guard !isQuickSurfaceActionInFlight else { return }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let snapshot = try await authoritativeSnapshotForQuickSurfaces()
            let update = try await quickSurfaceHost.setTimerVisible(isVisible, snapshot: snapshot)
            await applyAuthoritativeSnapshot(update.ledger)
            quickSurfaceHostSnapshot = update.host
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.settings.update_failed")
        }
    }

    func startQuickSurfaceTimer() async {
        guard !isQuickSurfaceActionInFlight else { return }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let state = try await quickSurfaceHost.startTimer()
            acceptQuickSurfaceState(state)
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.error.timer_start")
        }
    }

    func stopQuickSurfaceTimer() async {
        guard !isQuickSurfaceActionInFlight else { return }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let state = try await quickSurfaceHost.stopTimer()
            acceptQuickSurfaceState(state)
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            let key: String.LocalizationValue = (error as? TimerSessionCommandError) == .invalidWallClock
                ? "quick_surfaces.error.timer_clock"
                : "quick_surfaces.error.timer_stop"
            presentQuickSurfaceError(error, fallbackKey: key)
        }
    }

    func discardQuickSurfaceReview(
        sessionID: UUID,
        mutationID: UUID,
        entryID: UUID
    ) async -> Bool {
        guard !isQuickSurfaceActionInFlight else { return false }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let state = try await quickSurfaceHost.discardReview(
                sessionID: sessionID,
                mutationID: mutationID,
                entryID: entryID
            )
            acceptQuickSurfaceState(state)
            return true
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.error.timer_save")
            return false
        }
    }

    func saveQuickSurfaceReview(
        sessionID: UUID,
        mutationID: UUID,
        entryID: UUID,
        kind: EntryKind,
        day: LocalDay,
        minutes: Int
    ) async -> Bool {
        guard !isQuickSurfaceActionInFlight else { return false }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let finalizing = try await quickSurfaceHost.authorizeReview(
                sessionID: sessionID,
                mutationID: mutationID,
                entryID: entryID,
                kind: kind,
                day: day,
                minutes: minutes
            )
            acceptQuickSurfaceState(finalizing)
            let result = try await quickSurfaceHost.finalizeTimerEntry()
            return await handleQuickSurfaceFinalizationResult(result, showError: true)
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.error.timer_save")
            return false
        }
    }

    func retryQuickSurfaceFinalization() async -> Bool {
        guard !isQuickSurfaceActionInFlight else { return false }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let result = try await quickSurfaceHost.finalizeTimerEntry()
            return await handleQuickSurfaceFinalizationResult(result, showError: true)
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.error.timer_save")
            return false
        }
    }

    func resetQuickSurfaceState() async -> Bool {
        guard !isQuickSurfaceActionInFlight else { return false }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let snapshot = try await authoritativeSnapshotForQuickSurfaces()
            quickSurfaceHostSnapshot = try await quickSurfaceHost.resetUnsavedState(using: snapshot)
            return true
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.settings.reset_failed")
            return false
        }
    }

    func requireQuickSurfaceIdleForRestore() async throws {
        // Restore is gated by a fresh actor-owned read at both preview and
        // confirmation; a cached model snapshot is not evidence of Idle.
        let snapshot = try await repository.ledgerSnapshot()
        try await quickSurfaceHost.requireIdleForRestore(using: snapshot)
    }

    private func authoritativeSnapshotForQuickSurfaces() async throws -> LedgerSnapshot {
        let snapshot = try await repository.ledgerSnapshot()
        await applyAuthoritativeSnapshot(snapshot)
        return snapshot
    }

    private func acceptQuickSurfaceState(_ state: QuickSurfaceStateV1) {
        quickSurfaceHostSnapshot = QuickSurfaceHostSnapshot(
            availability: .ready,
            preferences: quickSurfaceHostSnapshot.preferences,
            state: state
        )
    }

    private func refreshQuickSurfaceStateAfterFailure() async {
        guard let snapshot = try? await repository.ledgerSnapshot() else {
            quickSurfaceHostSnapshot = QuickSurfaceHostSnapshot(
                availability: .stale,
                preferences: .init(),
                state: nil
            )
            return
        }
        await applyAuthoritativeSnapshot(snapshot)
    }

    private func recoverQuickSurfaceFinalizationIfNeeded() async {
        guard !isQuickSurfaceActionInFlight else { return }
        guard let state = quickSurfaceState, case .finalizing = state.timer else { return }
        isQuickSurfaceActionInFlight = true
        defer { isQuickSurfaceActionInFlight = false }
        do {
            let result = try await quickSurfaceHost.finalizeTimerEntry()
            _ = await handleQuickSurfaceFinalizationResult(result, showError: true)
        } catch {
            await refreshQuickSurfaceStateAfterFailure()
            presentQuickSurfaceError(error, fallbackKey: "quick_surfaces.error.timer_save")
        }
    }

    private func handleQuickSurfaceFinalizationResult(
        _ result: TimerEntryFinalizationResult,
        showError: Bool
    ) async -> Bool {
        switch result {
        case let .idle(receipt):
            if let receipt {
                await refreshAfterEntryMutation(receipt, showUndoBanner: true)
            } else {
                await refreshFromStore(showUndoBanner: false)
            }
            return true

        case .returnedToReview:
            await refreshQuickSurfaceStateAfterFailure()
            if showError {
                errorMessage = String(localized: "quick_surfaces.error.timer_save")
            }
            return false

        case .noFinalizingState:
            await refreshQuickSurfaceStateAfterFailure()
            return false

        case .finalizing:
            await refreshQuickSurfaceStateAfterFailure()
            if showError {
                errorMessage = String(localized: "quick_surfaces.error.timer_save")
            }
            return false
        }
    }

    private func presentQuickSurfaceError(_ error: Error, fallbackKey: String.LocalizationValue) {
        if let hostError = error as? QuickSurfaceHostError,
           let description = hostError.errorDescription {
            errorMessage = description
        } else {
            errorMessage = String(localized: fallbackKey)
        }
        lastErrorDiagnostic = error.localizedDescription
    }

    private func planningPreferences(from snapshot: LedgerSnapshot) -> PlanningPreferences {
        let quietGapDays = snapshot.settingsMetadata.quietGapDays
        let quietGapConfigurationIsValid = (1...30).contains(quietGapDays)
        return PlanningPreferences(
            isPaceVisible: snapshot.settingsMetadata.planningVisible,
            isQuietGapEnabled: snapshot.settingsMetadata.quietGapCheckEnabled && quietGapConfigurationIsValid,
            quietGapDays: quietGapConfigurationIsValid ? quietGapDays : 7
        )
    }

    private func reminderReconciliationRequest(from snapshot: LedgerSnapshot) -> ReminderReconciliationRequest {
        let preferences = planningPreferences(from: snapshot)
        return ReminderReconciliationRequest(
            reminders: snapshot.reminderSchedules,
            quietGap: QuietGapSchedulingRequest(
                isEnabled: preferences.isQuietGapEnabled,
                gapDays: preferences.quietGapDays,
                ledgerStartMonth: snapshot.settings.ledgerStartMonth,
                entries: snapshot.entries,
                acknowledgements: snapshot.dayAcknowledgements
            ),
            monthlyReportReminderEnabled: monthlyReportReminderEnabled
        )
    }

    private func reconcileLoadedReminderState() async throws {
        guard let snapshot = latestLedgerSnapshot else { return }
        try await reminderScheduler.reconcile(reminderReconciliationRequest(from: snapshot))
        notificationAuthorizationStatus = await reminderScheduler.notificationAuthorizationStatus()
    }

    func refreshReminderAuthorizationStatus() async {
        notificationAuthorizationStatus = await reminderScheduler.notificationAuthorizationStatus()
    }

    func setMonthlyReportReminderEnabled(_ isEnabled: Bool) async {
        monthlyReportReminderEnabled = isEnabled
        MonthlyReportReminderPreference(isEnabled: isEnabled)
            .save(to: monthlyReportReminderDefaults)

        do {
            if isEnabled {
                _ = try await authorizeReminderSettingsChangeIfNeeded()
            }
            try await reconcileLoadedReminderState()
        } catch {
            present(error)
        }
    }

    func requestMonthlyReportReminderAuthorization() async {
        guard monthlyReportReminderEnabled else { return }
        do {
            _ = try await authorizeReminderSettingsChangeIfNeeded()
            try await reconcileLoadedReminderState()
        } catch {
            present(error)
        }
    }

    private func authorizeReminderSettingsChangeIfNeeded() async throws -> Bool {
        let status = await reminderScheduler.notificationAuthorizationStatus()
        notificationAuthorizationStatus = status
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .unknown:
            return false
        case .notDetermined:
            let granted = try await reminderScheduler.requestAuthorization()
            notificationAuthorizationStatus = await reminderScheduler.notificationAuthorizationStatus()
            return granted && notificationAuthorizationStatus.allowsScheduling
        }
    }

    private func updateSelectedReportMonth(
        from snapshot: LedgerSnapshot,
        preferLatestClosed: Bool
    ) {
        let previousMonth = currentMonth.advanced(by: -1, calendar: .hourleaf)
        let defaultMonth = previousMonth >= snapshot.settings.ledgerStartMonth
            ? previousMonth
            : currentMonth
        if preferLatestClosed
            || selectedReportMonth < snapshot.settings.ledgerStartMonth
            || selectedReportMonth > currentMonth {
            selectedReportMonth = defaultMonth
        }
    }

    func addEntry(kind: EntryKind, date: Date, hours: Int, minutes: Int, note: String?) async -> Bool {
        let entryMonth = MonthKey(date, calendar: .hourleaf)
        guard entryMonth >= settings.ledgerStartMonth else {
            errorMessage = String(localized: "error.before_ledger_start")
            return false
        }
        do {
            let receipt = try await AddTimeEntryCommand(repository: repository)
                .execute(
                    kind: kind,
                    date: date,
                    hours: hours,
                    minutes: minutes,
                    note: note,
                    occurredAt: now()
                )
            await refreshAfterEntryMutation(receipt, showUndoBanner: true)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func updateEntry(
        _ record: LedgerEntryRecord,
        kind: EntryKind,
        date: Date,
        hours: Int,
        minutes: Int,
        note: String?
    ) async -> Bool {
        let total: Int
        do {
            total = try EntryDuration.totalMinutes(hours: hours, minutes: minutes)
        } catch {
            present(error)
            return false
        }
        let updatedMonth = MonthKey(date, calendar: .hourleaf)
        guard updatedMonth >= settings.ledgerStartMonth else {
            errorMessage = String(localized: "error.before_ledger_start")
            return false
        }
        guard (note ?? "").count <= 280 else {
            errorMessage = EntryValidationError.noteTooLong.localizedDescription
            return false
        }
        do {
            let receipt = try await repository.apply(
                EntryMutationCommand(
                    entryID: record.id,
                    expectedRevision: record.revision,
                    operation: .update,
                    values: EntryMutationValues(
                        kind: kind,
                        day: LocalDay(date, calendar: .hourleaf),
                        minutes: total,
                        note: note
                    ),
                    occurredAt: now(),
                    source: .appHistory
                )
            )
            await refreshAfterEntryMutation(receipt, showUndoBanner: true)
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func deleteEntry(_ record: LedgerEntryRecord) async -> Bool {
        do {
            let receipt = try await repository.apply(
                EntryMutationCommand(
                    entryID: record.id,
                    expectedRevision: record.revision,
                    operation: .delete,
                    occurredAt: now(),
                    source: .appHistory
                )
            )
            await refreshAfterEntryMutation(receipt, showUndoBanner: true)
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func restoreEntry(_ record: LedgerEntryRecord) async -> Bool {
        guard restoringEntryIDs.insert(record.id).inserted else { return false }
        defer { restoringEntryIDs.remove(record.id) }
        do {
            let receipt = try await repository.apply(
                EntryMutationCommand(
                    entryID: record.id,
                    expectedRevision: record.revision,
                    operation: .restore,
                    occurredAt: now(),
                    source: .restore
                )
            )
            await refreshAfterEntryMutation(receipt, showUndoBanner: true)
            return true
        } catch {
            present(error)
            return false
        }
    }

    func undoLatestMutation() async {
        guard !isUndoing else { return }
        guard let candidate = undoCandidate else {
            present(EntryMutationError.undoUnavailable)
            return
        }
        isUndoing = true
        defer { isUndoing = false }
        undoStateGeneration += 1
        visibleUndoCandidate = nil
        undoBannerTask?.cancel()
        do {
            let receipt = try await repository.apply(
                EntryMutationCommand(
                    entryID: candidate.entryID,
                    expectedRevision: candidate.expectedRevision,
                    operation: .undo,
                    revertedMutationID: candidate.mutationID,
                    occurredAt: now(),
                    source: .undo
                )
            )
            await refreshAfterEntryMutation(receipt, showUndoBanner: false)
        } catch {
            visibleUndoCandidate = nil
            undoBannerTask?.cancel()
            present(error)
            await refreshUndoCandidate(showBanner: false)
        }
    }

    func resumeUndoAvailability() async {
        await refreshUndoCandidate(showBanner: true)
    }

    func dismissUndoBanner() {
        undoStateGeneration += 1
        visibleUndoCandidate = nil
        undoBannerTask?.cancel()
    }

    private func refreshAfterEntryMutation(
        _ receipt: EntryMutationReceipt,
        showUndoBanner shouldShowUndoBanner: Bool
    ) async {
        undoStateGeneration += 1
        let generation = undoStateGeneration
        do {
            try await loadSnapshot()
            let candidate = try await repository.latestUndoCandidate(asOf: now())
            guard generation == undoStateGeneration else { return }
            undoCandidate = candidate
            try await reconcileLoadedReminderState()
            guard
                shouldShowUndoBanner,
                let candidate,
                candidate.mutationID == receipt.mutationID
            else {
                if candidate == nil { visibleUndoCandidate = nil }
                return
            }
            showUndoBanner(for: candidate)
        } catch {
            presentMutationRefreshFailure(error)
        }
    }

    private func refreshUndoCandidate(showBanner: Bool) async {
        let generation = undoStateGeneration
        do {
            let candidate = try await repository.latestUndoCandidate(asOf: now())
            guard generation == undoStateGeneration else { return }
            undoCandidate = candidate
            if let candidate, showBanner {
                showUndoBanner(for: candidate)
            } else if candidate == nil {
                visibleUndoCandidate = nil
                undoBannerTask?.cancel()
            }
        } catch {
            present(error)
        }
    }

    private func showUndoBanner(for candidate: EntryUndoCandidate) {
        undoBannerTask?.cancel()
        visibleUndoCandidate = candidate
        undoBannerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, self?.visibleUndoCandidate?.mutationID == candidate.mutationID else { return }
            self?.visibleUndoCandidate = nil
        }
    }

    func lifecycleState(for month: MonthKey) -> ReportLifecycleState {
        guard let snapshot = latestLedgerSnapshot else { return .draft }
        guard month >= snapshot.settings.ledgerStartMonth else { return .draft }
        guard month < currentMonth else { return .draft }

        if let state = snapshot.reportStates.first(where: { $0.month == month }) {
            return state.state == .draft ? .ready : state.state
        }
        if let saved = newestReportSnapshot(for: month, in: snapshot) {
            return saved.receipt.confirmedSentAt == nil ? .prepared : .sent
        }
        return .ready
    }

    func reportDraft(for month: MonthKey) -> ReportDraft {
        guard
            let snapshot = latestLedgerSnapshot,
            let draft = ReportReadiness.draft(for: month, in: snapshot)
        else {
            preconditionFailure("A report draft requires a loaded month at or after the ledger start.")
        }
        return draft
    }

    func openReport(_ month: MonthKey) {
        selectedReportMonth = month
        selectedTab = .progress
    }

    @discardableResult
    func reviewReport(_ draft: ReportDraft) async -> Bool {
        guard reviewingReportMonths.insert(draft.month).inserted else { return false }
        let reviewedAt = now()
        defer { reviewingReportMonths.remove(draft.month) }

        do {
            let ledger = try await repository.reviewReport(
                ReviewReportRequest(
                    month: draft.month,
                    expectedCalculationFingerprint: draft.calculationFingerprint,
                    expectedPresentationFingerprint: draft.presentationFingerprint,
                    reviewedAt: reviewedAt
                )
            )
            await applyAuthoritativeSnapshot(ledger)
            return true
        } catch {
            await handleLifecycleFailure(error)
            return false
        }
    }

    func prepareReport(_ draft: ReportDraft) async -> ReportSnapshotMetadata? {
        guard preparingReportMonths.insert(draft.month).inserted else { return nil }
        let snapshotID = UUID()
        let preparedAt = now()
        defer { preparingReportMonths.remove(draft.month) }

        if let ledger = latestLedgerSnapshot,
           let state = ledger.reportStates.first(where: { $0.month == draft.month }),
           state.state == .prepared || state.state == .sent,
           let currentSnapshotID = state.currentSnapshotID,
           let currentSnapshot = ledger.reportSnapshots.first(where: { $0.id == currentSnapshotID }),
           ReportReadiness.snapshotMatchesDraft(currentSnapshot, draft: draft, ledger: ledger) {
            return currentSnapshot
        }

        do {
            let result = try await repository.prepareReport(
                PrepareReportRequest(
                    month: draft.month,
                    expectedCalculationFingerprint: draft.calculationFingerprint,
                    expectedPresentationFingerprint: draft.presentationFingerprint,
                    snapshotID: snapshotID,
                    preparedAt: preparedAt
                )
            )
            await applyAuthoritativeSnapshot(result.ledger)
            return result.snapshot
        } catch {
            await handleLifecycleFailure(error)
            return nil
        }
    }

    @discardableResult
    func markReportSent(_ snapshot: ReportSnapshotMetadata) async -> Bool {
        guard markingSentSnapshotIDs.insert(snapshot.id).inserted else { return false }
        let confirmedAt = now()
        defer { markingSentSnapshotIDs.remove(snapshot.id) }

        do {
            let ledger = try await repository.markReportSent(
                MarkReportSentRequest(snapshotID: snapshot.id, confirmedAt: confirmedAt)
            )
            await applyAuthoritativeSnapshot(ledger)
            return true
        } catch {
            await handleLifecycleFailure(error)
            return false
        }
    }

    func serviceYearDraft(starting startMonth: MonthKey) -> ServiceYearDraft {
        guard
            let snapshot = latestLedgerSnapshot,
            let draft = ReportReadiness.serviceYearDraft(starting: startMonth, in: snapshot)
        else {
            preconditionFailure("A service-year draft requires a loaded September-to-August period.")
        }
        return draft
    }

    func closeServiceYear(_ draft: ServiceYearDraft) async -> ServiceYearArchiveRecord? {
        guard closingServiceYearStarts.insert(draft.startMonth).inserted else { return nil }
        let archiveID = UUID()
        let createdAt = now()
        defer { closingServiceYearStarts.remove(draft.startMonth) }

        do {
            let result = try await repository.closeServiceYear(
                CloseServiceYearRequest(
                    startMonth: draft.startMonth,
                    expectedCalculationFingerprint: draft.calculationFingerprint,
                    archiveID: archiveID,
                    createdAt: createdAt
                )
            )
            await applyAuthoritativeSnapshot(result.ledger)
            return result.archive
        } catch {
            await handleLifecycleFailure(error)
            return nil
        }
    }

    private func newestReportSnapshot(
        for month: MonthKey,
        in ledger: LedgerSnapshot
    ) -> ReportSnapshotMetadata? {
        ledger.reportSnapshots
            .filter { $0.receipt.month == month }
            .max {
                ($0.receipt.preparedAt, $0.id.uuidString)
                    < ($1.receipt.preparedAt, $1.id.uuidString)
            }
    }

    private func handleLifecycleFailure(_ error: Error) async {
        if let lifecycleError = error as? ReportLifecycleError,
           lifecycleError == .reportChanged || lifecycleError == .archiveChanged {
            do {
                try await loadReconciledSnapshot(selectDefaultReportMonth: false)
            } catch {
                present(error)
                return
            }
        }
        present(error)
    }

    func reports(through month: MonthKey) -> [MonthlyReport] {
        ReportCalculator.timeline(
            entries: entries,
            from: settings.ledgerStartMonth,
            through: month,
            openingServiceCarry: settings.openingServiceCarryMinutes,
            openingCreditCarry: settings.openingCreditCarryMinutes,
            policies: policies
        )
    }

    func report(for month: MonthKey) -> MonthlyReport {
        reports(through: month).last(where: { $0.month == month })
            ?? MonthlyReport(
                month: month,
                rawServiceMinutes: 0,
                rawCreditMinutes: 0,
                serviceCarryIn: 0,
                creditCarryIn: 0,
                serviceHours: 0,
                creditHours: 0,
                serviceCarryOut: 0,
                creditCarryOut: 0
            )
    }

    func serviceYearProgress(containing day: LocalDay? = nil) -> Int {
        let day = day ?? LocalDay(year: currentMonth.year, month: currentMonth.month, day: 1)
        let selectedStart = ServiceYearCalculator.serviceYearStart(containing: day).monthKey
        let baseline = selectedStart == settings.baselineServiceYearStart
            ? settings.baselineServiceYearMinutes
            : 0
        let ledgerEntries = entries.filter { $0.day.monthKey >= settings.ledgerStartMonth }
        return ServiceYearCalculator.progressMinutes(
            entries: ledgerEntries,
            containing: day,
            baselineMinutes: baseline
        )
    }

    func currentServiceYearPace(calendar: Calendar = .hourleaf) -> ServiceYearPace {
        guard let snapshot = latestLedgerSnapshot else {
            preconditionFailure("A service-year pace requires a loaded ledger snapshot.")
        }
        do {
            return try ServiceYearPaceCalculator.calculate(
                records: snapshot.entries,
                settings: snapshot.settings,
                asOf: LocalDay(currentDate, calendar: calendar),
                calendar: calendar
            )
        } catch {
            preconditionFailure("Invalid service-year pace data: \(error)")
        }
    }

    func updatePlanningVisibility(_ isVisible: Bool) async {
        var updated = planningPreferences
        updated.isPaceVisible = isVisible
        await enqueuePlanningPreferencesSave(updated).value
    }

    func queuePlanningVisibilityChange(_ isVisible: Bool) {
        var updated = planningPreferences
        updated.isPaceVisible = isVisible
        enqueuePlanningPreferencesSave(updated)
    }

    @discardableResult
    private func enqueuePlanningPreferencesSave(
        _ updated: PlanningPreferences
    ) -> Task<Void, Never> {
        guard !isWholeStoreRestoreInProgress else { return Task {} }
        planningPreferences = updated
        planningSaveGeneration &+= 1
        let generation = planningSaveGeneration
        let previousTask = planningSaveTask
        let repository = repository
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }

            do {
                try await repository.savePlanningPreferences(updated)
                let snapshot = try await repository.ledgerSnapshot()
                guard generation == self.planningSaveGeneration else { return }
                await self.applyAuthoritativeSnapshot(snapshot)
                try await self.reconcileLoadedReminderState()
            } catch {
                guard generation == self.planningSaveGeneration else { return }
                self.present(error)
                do {
                    let snapshot = try await repository.ledgerSnapshot()
                    guard generation == self.planningSaveGeneration else { return }
                    await self.applyAuthoritativeSnapshot(snapshot)
                    try await self.reconcileLoadedReminderState()
                } catch {
                    self.present(error)
                }
            }
            if generation == self.planningSaveGeneration {
                self.planningSaveTask = nil
            }
        }
        planningSaveTask = task
        return task
    }

    func saveSettings(_ updated: AppSettings) async {
        await enqueueSettingsSave(updated).value
    }

    func queueReportLanguageChange(
        _ language: ReportLanguage,
        savingCreditLabel label: String,
        for labelLanguage: ReportLanguage
    ) {
        var updated = settings
        Self.setCreditLabel(label, for: labelLanguage, in: &updated)
        updated.reportLanguage = language
        enqueueSettingsSave(updated)
    }

    func queueCreditLabelChange(_ label: String, for language: ReportLanguage) {
        var updated = settings
        Self.setCreditLabel(label, for: language, in: &updated)
        enqueueSettingsSave(updated)
    }

    @discardableResult
    private func enqueueSettingsSave(_ updated: AppSettings) -> Task<Void, Never> {
        guard !isWholeStoreRestoreInProgress else { return Task {} }
        settings = updated
        settingsSaveGeneration += 1
        let generation = settingsSaveGeneration
        let previousTask = settingsSaveTask
        let repository = repository
        let task = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            do {
                try await repository.saveSettings(updated)
                try await self.loadSnapshot(
                    waitForPendingSettingsSave: false,
                    onlyIfSettingsGeneration: generation
                )
                try await self.reconcileLoadedReminderState()
            } catch {
                guard generation == self.settingsSaveGeneration else { return }
                self.present(error)
                do {
                    try await self.loadSnapshot(
                        waitForPendingSettingsSave: false,
                        onlyIfSettingsGeneration: generation
                    )
                    try await self.reconcileLoadedReminderState()
                } catch {
                    self.present(error)
                }
            }
            if generation == self.settingsSaveGeneration {
                self.settingsSaveTask = nil
            }
        }
        settingsSaveTask = task
        return task
    }

    func updateReportLanguage(_ language: ReportLanguage) async {
        var updated = settings
        updated.reportLanguage = language
        await saveSettings(updated)
    }

    func updateCreditLabel(_ label: String, for language: ReportLanguage) async {
        var updated = settings
        Self.setCreditLabel(label, for: language, in: &updated)
        await saveSettings(updated)
    }

    private static func setCreditLabel(
        _ label: String,
        for language: ReportLanguage,
        in settings: inout AppSettings
    ) {
        switch language {
        case .english: settings.creditLabelEnglish = label
        case .russian: settings.creditLabelRussian = label
        case .ukrainian: settings.creditLabelUkrainian = label
        }
    }

    func updateReportingPolicy(mode: RemainderMode) async {
        let current = currentMonth
        let effective = hasConfirmedReceipt(in: current) ? current.advanced(by: 1, calendar: .hourleaf) : current
        do {
            try await repository.savePolicy(ReportingPolicy(
                effectiveMonth: effective,
                mode: mode
            ))
            await reload()
        } catch {
            present(error)
        }
    }

    func addReminder(weekday: Int, time: Date) async {
        let components = Calendar.hourleaf.dateComponents([.hour, .minute], from: time)
        let reminder = ReminderSchedule(
            weekday: weekday,
            hour: components.hour ?? 9,
            minute: components.minute ?? 0
        )
        do {
            guard try await authorizeReminderSettingsChangeIfNeeded() else {
                return
            }
            try await repository.saveReminder(reminder)
            let snapshot = try await repository.ledgerSnapshot()
            await applyAuthoritativeSnapshot(snapshot)
            try await reconcileLoadedReminderState()
        } catch {
            present(error)
        }
    }

    func toggleReminder(_ reminder: ReminderSchedule) async {
        do {
            var updated = reminder
            updated.isEnabled.toggle()
            if updated.isEnabled {
                guard try await authorizeReminderSettingsChangeIfNeeded() else {
                    return
                }
            }
            try await repository.saveReminder(updated)
            let snapshot = try await repository.ledgerSnapshot()
            await applyAuthoritativeSnapshot(snapshot)
            try await reconcileLoadedReminderState()
        } catch {
            present(error)
        }
    }

    func deleteReminder(_ reminder: ReminderSchedule) async {
        do {
            try await repository.deleteReminder(id: reminder.id)
            let snapshot = try await repository.ledgerSnapshot()
            await applyAuthoritativeSnapshot(snapshot)
            try await reconcileLoadedReminderState()
        } catch {
            present(error)
        }
    }

    func updateQuietGapEnabled(_ isEnabled: Bool) async {
        do {
            if isEnabled {
                guard try await authorizeReminderSettingsChangeIfNeeded() else {
                    return
                }
            }
            var updated = planningPreferences
            updated.isQuietGapEnabled = isEnabled
            updated.quietGapDays = 7
            await enqueuePlanningPreferencesSave(updated).value
        } catch {
            present(error)
        }
    }

    func rescheduleReminders() async {
        do {
            let snapshot: LedgerSnapshot
            if let latestLedgerSnapshot {
                snapshot = latestLedgerSnapshot
            } else {
                snapshot = try await repository.ledgerSnapshot()
                await applyAuthoritativeSnapshot(snapshot)
            }
            try await reminderScheduler.reconcile(reminderReconciliationRequest(from: snapshot))
            notificationAuthorizationStatus = await reminderScheduler.notificationAuthorizationStatus()
        } catch {
            present(error)
        }
    }

    func handleReminderEvent(_ event: ReminderNotificationEvent) async {
        switch event {
        case let .response(context):
            await handleReminderResponse(context)
        }
    }

    private func handleReminderResponse(_ context: ReminderNotificationResponseContext) async {
        do {
            let snapshot = try await repository.ledgerSnapshot()
            await applyAuthoritativeSnapshot(snapshot)

            switch context.action {
            case .nothingToRecord:
                guard let event = context.nothingToRecordEvent(calendar: .hourleaf) else { return }
                guard !isCovered(day: event.day, in: snapshot) else {
                    try await reconcileLoadedReminderState()
                    return
                }
                _ = try await repository.acknowledgeNothingToRecord(
                    on: event.day,
                    source: acknowledgementSource(for: event.source),
                    at: context.responseDate
                )
                let refreshed = try await repository.ledgerSnapshot()
                await applyAuthoritativeSnapshot(refreshed)
                try await reconcileLoadedReminderState()

            case .later:
                guard let targetDay = context.targetDay(calendar: .hourleaf) else { return }
                guard !isCovered(day: targetDay, in: snapshot) else {
                    try await reconcileLoadedReminderState()
                    return
                }
                let status = await reminderScheduler.notificationAuthorizationStatus()
                notificationAuthorizationStatus = status
                guard status.allowsScheduling else {
                    try await reconcileLoadedReminderState()
                    return
                }
                try await reminderScheduler.scheduleFollowUp(from: context)
                notificationAuthorizationStatus = await reminderScheduler.notificationAuthorizationStatus()

            case .open, .addTime, .unknown:
                return
            }
        } catch {
            present(error)
        }
    }

    private func isCovered(day: LocalDay, in snapshot: LedgerSnapshot) -> Bool {
        if snapshot.entries.contains(where: {
            $0.deletedAt == nil
                && $0.entry.kind == .service
                && $0.entry.day == day
        }) {
            return true
        }
        return snapshot.dayAcknowledgements.contains(where: {
            $0.day == day && $0.status == DayAcknowledgementStatus.nothingToday.rawValue
        })
    }

    private func acknowledgementSource(
        for source: ReminderNothingToRecordSource
    ) -> DayAcknowledgementSource {
        switch source {
        case .scheduledReminder:
            return .scheduledReminder
        case .quietGap:
            return .quietGap
        }
    }

    func hasConfirmedReceipt(in month: MonthKey) -> Bool {
        receipts.contains { $0.month == month && $0.confirmedSentAt != nil }
    }

    func changeAffectsConfirmedReport(from month: MonthKey) -> Bool {
        let checkpointStates: Set<ReportLifecycleState> = [.reviewed, .prepared, .sent, .changed]
        return reportStates.contains { $0.month >= month && checkpointStates.contains($0.state) }
            || receipts.contains { $0.month >= month && $0.confirmedSentAt != nil }
            || serviceYearArchives.contains { archive in
                archive.startMonth <= month && month <= archive.endMonth
            }
    }

    private func present(_ error: Error) {
        lastErrorDiagnostic = error.localizedDescription
        if let validationError = error as? EntryValidationError {
            errorMessage = validationError.localizedDescription
        } else if let oneTapError = error as? OneTapEntryError {
            errorMessage = oneTapError.localizedDescription
        } else if let mutationError = error as? EntryMutationError {
            errorMessage = mutationError.localizedDescription
        } else if let lifecycleError = error as? ReportLifecycleError {
            switch lifecycleError {
            case .beforeLedgerStart:
                errorMessage = String(localized: "error.before_ledger_start")
            case .monthStillOpen:
                errorMessage = String(localized: "error.month_still_open")
            case .reportChanged:
                errorMessage = String(localized: "error.report_changed")
            case .reviewRequired:
                errorMessage = String(localized: "error.report_review_required")
            case .serviceYearStillOpen:
                errorMessage = String(localized: "error.service_year_still_open")
            case .archiveChanged:
                errorMessage = String(localized: "error.archive_changed")
            case .snapshotNotFound,
                    .invalidSnapshotHistory,
                    .receiptVersionExhausted,
                    .archiveVersionExhausted:
                errorMessage = String(localized: "error.action_failed")
            }
        } else if let repositoryError = error as? LedgerRepositoryError,
                  repositoryError == .maintenanceInProgress {
            errorMessage = String(localized: "error.restore_in_progress")
        } else if error is LedgerRepositoryError || error is PersistenceStartupError {
            errorMessage = String(localized: "error.local_data")
        } else {
            errorMessage = String(localized: "error.action_failed")
        }
    }

    private func presentMutationRefreshFailure(_ error: Error) {
        lastErrorDiagnostic = error.localizedDescription
        errorMessage = String(localized: "error.mutation_saved_refresh_failed")
    }
}
