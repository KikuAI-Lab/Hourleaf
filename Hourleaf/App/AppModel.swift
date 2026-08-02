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
    @Published private(set) var policies: [ReportingPolicy] = []
    @Published private(set) var reminders: [ReminderSchedule] = []
    @Published private(set) var receipts: [ReportReceipt] = []
    @Published var settings = AppSettings()
    @Published var selectedTab: Tab = .add
    @Published var errorMessage: String?
    @Published private(set) var startupState: StartupState = .loading
    @Published private(set) var startupDiagnostic: String?
    @Published private(set) var lastErrorDiagnostic: String?

    let repository: any LedgerRepository
    private let reminderScheduler: ReminderScheduling
    private var initialSnapshotLoaded = false
    private var settingsSaveGeneration = 0
    private var settingsSaveTask: Task<Void, Never>?
    private var reportPreparationsInFlight = Set<MonthKey>()

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
        do {
            try await loadSnapshot()
        } catch {
            present(error)
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
        entries = snapshot.activeEntries
        settings = snapshot.settings
        policies = snapshot.policies
        reminders = snapshot.reminderSchedules
        receipts = snapshot.receipts
    }

    func addEntry(kind: EntryKind, date: Date, hours: Int, minutes: Int, note: String?) async -> Bool {
        let entryMonth = MonthKey(date, calendar: .hourleaf)
        guard entryMonth >= settings.ledgerStartMonth else {
            errorMessage = String(localized: "error.before_ledger_start")
            return false
        }
        do {
            _ = try await AddTimeEntryCommand(repository: repository)
                .execute(kind: kind, date: date, hours: hours, minutes: minutes, note: note)
            await reload()
            return true
        } catch {
            present(error)
            return false
        }
    }

    func updateEntry(
        _ entry: TimeEntry,
        kind: EntryKind,
        date: Date,
        hours: Int,
        minutes: Int,
        note: String?
    ) async -> Bool {
        let total = hours * 60 + minutes
        let updatedMonth = MonthKey(date, calendar: .hourleaf)
        guard updatedMonth >= settings.ledgerStartMonth else {
            errorMessage = String(localized: "error.before_ledger_start")
            return false
        }
        guard total > 0 else {
            errorMessage = EntryValidationError.emptyDuration.localizedDescription
            return false
        }
        guard total < 6_000 else {
            errorMessage = EntryValidationError.durationTooLarge.localizedDescription
            return false
        }
        guard (note ?? "").count <= 280 else {
            errorMessage = EntryValidationError.noteTooLong.localizedDescription
            return false
        }
        do {
            var updated = entry
            updated.kind = kind
            updated.day = LocalDay(date, calendar: .hourleaf)
            updated.minutes = total
            let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            updated.note = trimmedNote?.isEmpty == false ? trimmedNote : nil
            updated.updatedAt = .now
            try await repository.saveEntry(updated)
            await reload()
            return true
        } catch {
            present(error)
            return false
        }
    }

    @discardableResult
    func deleteEntry(_ entry: TimeEntry) async -> Bool {
        do {
            try await repository.deleteEntry(id: entry.id)
            await reload()
            return true
        } catch {
            present(error)
            return false
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
            receipts = try await repository.fetchReceipts()
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
        } else if error is LedgerRepositoryError || error is PersistenceStartupError {
            errorMessage = String(localized: "error.local_data")
        } else {
            errorMessage = String(localized: "error.action_failed")
        }
    }
}
