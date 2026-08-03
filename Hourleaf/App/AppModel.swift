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
    @Published var settings = AppSettings()
    @Published var selectedTab: Tab = .add
    @Published var errorMessage: String?
    @Published private(set) var startupState: StartupState = .loading
    @Published private(set) var startupDiagnostic: String?
    @Published private(set) var lastErrorDiagnostic: String?
    @Published private(set) var undoCandidate: EntryUndoCandidate?
    @Published private(set) var visibleUndoCandidate: EntryUndoCandidate?
    @Published private(set) var quickEntryResetGeneration: UInt64 = 0

    let repository: any LedgerRepository
    private let reminderScheduler: ReminderScheduling
    private var initialSnapshotLoaded = false
    private var settingsSaveGeneration = 0
    private var settingsSaveTask: Task<Void, Never>?
    private var reportPreparationsInFlight = Set<MonthKey>()
    private var restoringEntryIDs = Set<UUID>()
    private var isUndoing = false
    private var undoBannerTask: Task<Void, Never>?
    private var storeRefreshRequested = false
    private var storeRefreshShouldShowUndo = false
    private var isStoreRefreshInFlight = false
    /// Only user-visible undo state changes invalidate an in-flight presentation.
    /// A passive store reload must not prevent a just-confirmed mutation from showing Undo.
    private var undoStateGeneration = 0

    init(repository: any LedgerRepository, reminderScheduler: ReminderScheduling) {
        self.repository = repository
        self.reminderScheduler = reminderScheduler
    }

    func loadInitialSnapshot(markReady: Bool = true) async {
        startupState = .loading
        startupDiagnostic = nil
        initialSnapshotLoaded = false
        do {
            try await loadSnapshot()
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
        while isStoreRefreshInFlight {
            await Task.yield()
        }
        undoBannerTask?.cancel()
        undoBannerTask = nil
        visibleUndoCandidate = nil
        undoCandidate = nil
        undoStateGeneration &+= 1
    }

    /// Reads every published value from the fresh container returned by the
    /// restore coordinator. Imported mutation history is intentionally not
    /// offered as a current-session Undo action.
    func refreshAfterRestore() async throws {
        startupState = .loading
        startupDiagnostic = nil
        settingsSaveGeneration &+= 1
        settingsSaveTask = nil
        storeRefreshRequested = false
        storeRefreshShouldShowUndo = false
        reportPreparationsInFlight.removeAll()
        restoringEntryIDs.removeAll()
        isUndoing = false
        undoBannerTask?.cancel()
        undoBannerTask = nil
        visibleUndoCandidate = nil
        undoCandidate = nil
        undoStateGeneration &+= 1

        do {
            try await loadSnapshot(waitForPendingSettingsSave: false)
            initialSnapshotLoaded = true
            errorMessage = nil
            startupState = .ready
        } catch {
            startupDiagnostic = error.localizedDescription
            startupState = .failed
            throw error
        }
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
                try await loadSnapshot()
                await refreshUndoCandidate(showBanner: shouldShowUndoBanner)
            } catch {
                present(error)
            }
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
                apply(snapshot)
                return
            }
        }

        let snapshot = try await repository.ledgerSnapshot()
        if let requiredGeneration, requiredGeneration != settingsSaveGeneration { return }
        apply(snapshot)
    }

    private func apply(_ snapshot: LedgerSnapshot) {
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
    }

    func addEntry(kind: EntryKind, date: Date, hours: Int, minutes: Int, note: String?) async -> Bool {
        let entryMonth = MonthKey(date, calendar: .hourleaf)
        guard entryMonth >= settings.ledgerStartMonth else {
            errorMessage = String(localized: "error.before_ledger_start")
            return false
        }
        do {
            let receipt = try await AddTimeEntryCommand(repository: repository)
                .execute(kind: kind, date: date, hours: hours, minutes: minutes, note: note)
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
            let candidate = try await repository.latestUndoCandidate(asOf: .now)
            guard generation == undoStateGeneration else { return }
            undoCandidate = candidate
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
            let candidate = try await repository.latestUndoCandidate(asOf: .now)
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

    func serviceYearProgress(containing day: LocalDay = LocalDay(Date(), calendar: .hourleaf)) -> Int {
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
            } catch {
                guard generation == self.settingsSaveGeneration else { return }
                self.present(error)
                do {
                    try await self.loadSnapshot(
                        waitForPendingSettingsSave: false,
                        onlyIfSettingsGeneration: generation
                    )
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
        let current = MonthKey(Date(), calendar: .hourleaf)
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
            guard try await reminderScheduler.requestAuthorization() else {
                errorMessage = String(localized: "error.notifications_denied")
                return
            }
            try await repository.saveReminder(reminder)
            reminders = try await repository.fetchReminders()
            try await reminderScheduler.reschedule(reminders)
        } catch {
            present(error)
        }
    }

    func toggleReminder(_ reminder: ReminderSchedule) async {
        do {
            var updated = reminder
            updated.isEnabled.toggle()
            if updated.isEnabled {
                guard try await reminderScheduler.requestAuthorization() else {
                    errorMessage = String(localized: "error.notifications_denied")
                    return
                }
            }
            try await repository.saveReminder(updated)
            reminders = try await repository.fetchReminders()
            try await reminderScheduler.reschedule(reminders)
        } catch {
            present(error)
        }
    }

    func deleteReminder(_ reminder: ReminderSchedule) async {
        do {
            try await repository.deleteReminder(id: reminder.id)
            reminders = try await repository.fetchReminders()
            try await reminderScheduler.reschedule(reminders)
        } catch {
            present(error)
        }
    }

    func rescheduleReminders() async {
        do {
            try await reminderScheduler.reschedule(reminders)
        } catch {
            present(error)
        }
    }

    func createReceipt(for report: MonthlyReport, text: String) async -> ReportReceipt? {
        guard reportPreparationsInFlight.insert(report.month).inserted else { return nil }
        defer { reportPreparationsInFlight.remove(report.month) }

        let entriesSnapshot = entries
        let settingsSnapshot = settings
        let policiesSnapshot = policies
        let currentReport = ReportCalculator.timeline(
            entries: entriesSnapshot,
            from: settingsSnapshot.ledgerStartMonth,
            through: report.month,
            openingServiceCarry: settingsSnapshot.openingServiceCarryMinutes,
            openingCreditCarry: settingsSnapshot.openingCreditCarryMinutes,
            policies: policiesSnapshot
        ).last(where: { $0.month == report.month })
        guard
            currentReport == report,
            ReportFormatter.format(report, settings: settingsSnapshot) == text
        else {
            errorMessage = String(localized: "error.report_changed")
            return nil
        }

        let receipt = ReportReceipt(
            id: UUID(),
            month: report.month,
            text: text,
            serviceHours: report.serviceHours,
            creditHours: report.creditHours,
            serviceCarryOut: report.serviceCarryOut,
            creditCarryOut: report.creditCarryOut,
            preparedAt: .now,
            confirmedSentAt: nil
        )
        do {
            let policy = ReportCalculator.policy(for: report.month, revisions: policiesSnapshot)
            let calculationFingerprint = ReportFingerprint.calculation(
                report: report,
                entries: entriesSnapshot,
                settings: settingsSnapshot,
                policies: policiesSnapshot
            )
            let details = ReportSnapshotDetails(
                report: report,
                reportingMode: policy.mode,
                reportLanguage: settingsSnapshot.reportLanguage,
                creditLabel: settingsSnapshot.creditLabel(for: settingsSnapshot.reportLanguage),
                templateID: "standard",
                calculationFingerprint: calculationFingerprint,
                presentationFingerprint: ReportFingerprint.presentation(
                    calculationFingerprint: calculationFingerprint,
                    language: settingsSnapshot.reportLanguage,
                    creditLabel: settingsSnapshot.creditLabel(for: settingsSnapshot.reportLanguage),
                    templateID: "standard",
                    text: text
                )
            )
            try await repository.saveReceipt(receipt, details: details)
            try await loadSnapshot()
            return receipt
        } catch {
            present(error)
            return nil
        }
    }

    func markReceiptSent(_ receipt: ReportReceipt) async {
        do {
            var updated = receipt
            updated.confirmedSentAt = .now
            try await repository.saveReceipt(updated, details: nil)
            receipts = try await repository.fetchReceipts()
        } catch {
            present(error)
        }
    }

    func hasConfirmedReceipt(in month: MonthKey) -> Bool {
        receipts.contains { $0.month == month && $0.confirmedSentAt != nil }
    }

    func changeAffectsConfirmedReport(from month: MonthKey) -> Bool {
        receipts.contains { $0.month >= month && $0.confirmedSentAt != nil }
    }

    func isStale(_ receipt: ReportReceipt) -> Bool {
        let current = report(for: receipt.month)
        if let snapshot = reportSnapshots.first(where: { $0.id == receipt.id }),
           !snapshot.legacyCalculationUnavailable,
           let storedCalculationFingerprint = snapshot.calculationFingerprint,
           let storedPresentationFingerprint = snapshot.presentationFingerprint,
           let templateID = snapshot.templateID {
            let calculationFingerprint = ReportFingerprint.calculation(
                report: current,
                entries: entries,
                settings: settings,
                policies: policies
            )
            let presentationFingerprint = ReportFingerprint.presentation(
                calculationFingerprint: calculationFingerprint,
                language: settings.reportLanguage,
                creditLabel: settings.creditLabel(for: settings.reportLanguage),
                templateID: templateID,
                text: ReportFormatter.format(current, settings: settings)
            )
            return calculationFingerprint != storedCalculationFingerprint
                || presentationFingerprint != storedPresentationFingerprint
        }
        return current.serviceHours != receipt.serviceHours
            || current.creditHours != receipt.creditHours
            || current.serviceCarryOut != receipt.serviceCarryOut
            || current.creditCarryOut != receipt.creditCarryOut
            || ReportFormatter.format(current, settings: settings) != receipt.text
    }

    private func present(_ error: Error) {
        lastErrorDiagnostic = error.localizedDescription
        if let validationError = error as? EntryValidationError {
            errorMessage = validationError.localizedDescription
        } else if let mutationError = error as? EntryMutationError {
            errorMessage = mutationError.localizedDescription
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
