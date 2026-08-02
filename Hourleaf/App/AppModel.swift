import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Tab: Hashable { case add, history, progress, settings }

    @Published private(set) var entries: [TimeEntry] = []
    @Published private(set) var policies: [ReportingPolicy] = []
    @Published private(set) var reminders: [ReminderSchedule] = []
    @Published private(set) var receipts: [ReportReceipt] = []
    @Published var settings = AppSettings()
    @Published var selectedTab: Tab = .add
    @Published var errorMessage: String?

    let repository: LedgerRepository
    private let reminderScheduler: ReminderScheduling

    init(repository: LedgerRepository, reminderScheduler: ReminderScheduling) {
        self.repository = repository
        self.reminderScheduler = reminderScheduler
        reload()
    }

    func reload() {
        do {
            entries = try repository.fetchEntries()
            settings = try repository.loadSettings()
            policies = try repository.fetchPolicies()
            reminders = try repository.fetchReminders()
            receipts = try repository.fetchReceipts()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addEntry(kind: EntryKind, date: Date, hours: Int, minutes: Int, note: String?) -> Bool {
        let entryMonth = MonthKey(date, calendar: .hourleaf)
        guard entryMonth >= settings.ledgerStartMonth else {
            errorMessage = String(localized: "error.before_ledger_start")
            return false
        }
        do {
            _ = try AddTimeEntryCommand(repository: repository)
                .execute(kind: kind, date: date, hours: hours, minutes: minutes, note: note)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func updateEntry(_ entry: TimeEntry, kind: EntryKind, date: Date, hours: Int, minutes: Int, note: String?) -> Bool {
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
            try repository.saveEntry(updated)
            reload()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func deleteEntry(_ entry: TimeEntry) {
        do {
            try repository.deleteEntry(id: entry.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
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

    func saveSettings(_ updated: AppSettings) {
        do {
            try repository.saveSettings(updated)
            settings = updated
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func updateReportingPolicy(mode: RemainderMode) {
        let current = MonthKey(Date(), calendar: .hourleaf)
        let effective = hasConfirmedReceipt(in: current) ? current.advanced(by: 1, calendar: .hourleaf) : current
        do {
            try repository.savePolicy(ReportingPolicy(
                effectiveMonth: effective,
                mode: mode
            ))
            reload()
        } catch {
            errorMessage = error.localizedDescription
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
            try repository.saveReminder(reminder)
            reminders = try repository.fetchReminders()
            try await reminderScheduler.reschedule(reminders)
        } catch {
            errorMessage = error.localizedDescription
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
            try repository.saveReminder(updated)
            reminders = try repository.fetchReminders()
            try await reminderScheduler.reschedule(reminders)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteReminder(_ reminder: ReminderSchedule) async {
        do {
            try repository.deleteReminder(id: reminder.id)
            reminders = try repository.fetchReminders()
            try await reminderScheduler.reschedule(reminders)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rescheduleReminders() async {
        do {
            try await reminderScheduler.reschedule(reminders)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func createReceipt(for report: MonthlyReport, text: String) -> ReportReceipt? {
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
            try repository.saveReceipt(receipt)
            receipts = try repository.fetchReceipts()
            return receipt
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func markReceiptSent(_ receipt: ReportReceipt) {
        do {
            var updated = receipt
            updated.confirmedSentAt = .now
            try repository.saveReceipt(updated)
            receipts = try repository.fetchReceipts()
        } catch {
            errorMessage = error.localizedDescription
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
}
