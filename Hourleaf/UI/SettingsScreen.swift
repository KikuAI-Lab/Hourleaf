import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAddReminder = false

    private var currentPolicy: ReportingPolicy {
        ReportCalculator.policy(for: MonthKey(Date(), calendar: .hourleaf), revisions: model.policies)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.reporting") {
                    Picker("settings.report_language", selection: reportLanguageBinding) {
                        ForEach(ReportLanguage.allCases) { Text($0.localizedName).tag($0) }
                    }
                    TextField("settings.credit_label", text: creditLabelBinding)
                    Picker("settings.minutes_policy", selection: remainderModeBinding) {
                        ForEach(RemainderMode.allCases) { Text($0.localizedName).tag($0) }
                    }
                    if currentPolicy.mode == .carry {
                        Toggle("settings.carry_service_year", isOn: carryAcrossYearBinding)
                    }
                    Text("settings.policy_footer").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    ForEach(model.reminders) { reminder in
                        reminderRow(reminder)
                    }
                    Button { showAddReminder = true } label: {
                        Label("settings.add_reminder", systemImage: "plus")
                    }
                } header: {
                    Text("settings.reminders")
                } footer: {
                    Text("settings.reminders_footer")
                }

                Section("settings.data") {
                    NavigationLink("settings.opening_balances") { StartingBalancesView() }
                    LabeledContent("settings.storage", value: String(localized: "settings.storage_value"))
                    LabeledContent("settings.sync", value: String(localized: "settings.sync_value"))
                }

                Section("settings.privacy") {
                    Label("settings.no_tracking", systemImage: "hand.raised.fill")
                    Text("settings.privacy_detail").font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("settings.version", value: "0.1.0")
                    LabeledContent("settings.app_store_name", value: "Hourleaf: Ministry Hours")
                } header: { Text("settings.about") }
            }
            .navigationTitle("settings.title")
            .sheet(isPresented: $showAddReminder) {
                AddReminderView()
                    .environmentObject(model)
            }
        }
    }

    private func reminderRow(_ reminder: ReminderSchedule) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(AppDateText.weekday(reminder.weekday))
                Text(DateComponents(calendar: .hourleaf, hour: reminder.hour, minute: reminder.minute).date ?? .now, style: .time)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { reminder.isEnabled },
                set: { _ in Task { await model.toggleReminder(reminder) } }
            ))
            .labelsHidden()
        }
        .swipeActions {
            Button(role: .destructive) {
                Task { await model.deleteReminder(reminder) }
            } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    private var reportLanguageBinding: Binding<ReportLanguage> {
        Binding(get: { model.settings.reportLanguage }, set: { value in
            var settings = model.settings
            settings.reportLanguage = value
            model.saveSettings(settings)
        })
    }

    private var creditLabelBinding: Binding<String> {
        Binding(get: { model.settings.creditLabel(for: model.settings.reportLanguage) }, set: { value in
            var settings = model.settings
            switch settings.reportLanguage {
            case .english: settings.creditLabelEnglish = value
            case .russian: settings.creditLabelRussian = value
            case .ukrainian: settings.creditLabelUkrainian = value
            }
            model.saveSettings(settings)
        })
    }

    private var remainderModeBinding: Binding<RemainderMode> {
        Binding(get: { currentPolicy.mode }, set: { model.updateReportingPolicy(mode: $0, carryAcrossServiceYear: currentPolicy.carryAcrossServiceYear) })
    }

    private var carryAcrossYearBinding: Binding<Bool> {
        Binding(get: { currentPolicy.carryAcrossServiceYear }, set: { model.updateReportingPolicy(mode: currentPolicy.mode, carryAcrossServiceYear: $0) })
    }
}

private struct AddReminderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var weekday = 2
    @State private var time = Calendar.hourleaf.date(from: DateComponents(hour: 13, minute: 0)) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                Picker("reminder.weekday", selection: $weekday) {
                    ForEach(1...7, id: \.self) { Text(AppDateText.weekday($0)).tag($0) }
                }
                DatePicker("reminder.time", selection: $time, displayedComponents: .hourAndMinute)
            }
            .navigationTitle("reminder.add")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.add") {
                        Task {
                            await model.addReminder(weekday: weekday, time: time)
                            if model.errorMessage == nil { dismiss() }
                        }
                    }
                }
            }
        }
    }
}

private struct StartingBalancesView: View {
    @EnvironmentObject private var model: AppModel
    @State private var serviceHours = 0
    @State private var serviceMinutes = 0
    @State private var serviceCarry = 0
    @State private var creditCarry = 0
    @State private var ledgerStartDate = Date()

    var body: some View {
        Form {
            Section("balances.ledger") {
                DatePicker(
                    "balances.ledger_start",
                    selection: $ledgerStartDate,
                    in: Date.distantPast...maximumLedgerStartDate,
                    displayedComponents: .date
                )
            }
            Section("balances.year_progress") {
                TimeWheelPicker(hours: $serviceHours, minutes: $serviceMinutes, maximumHours: 600)
            }
            Section("balances.carry") {
                Stepper(String(format: String(localized: "balances.service_carry_format"), serviceCarry), value: $serviceCarry, in: 0...59)
                Stepper(String(format: String(localized: "balances.credit_carry_format"), creditCarry), value: $creditCarry, in: 0...59)
            }
            Section {
                Button("common.save") { save() }
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("balances.footer")
            }
        }
        .navigationTitle("settings.opening_balances")
        .onAppear {
            serviceHours = model.settings.baselineServiceYearMinutes / 60
            serviceMinutes = model.settings.baselineServiceYearMinutes % 60
            serviceCarry = model.settings.openingServiceCarryMinutes
            creditCarry = model.settings.openingCreditCarryMinutes
            ledgerStartDate = model.settings.ledgerStartMonth.date(calendar: .hourleaf)
        }
    }

    private func save() {
        var settings = model.settings
        settings.ledgerStartMonth = MonthKey(ledgerStartDate, calendar: .hourleaf)
        settings.baselineServiceYearMinutes = serviceHours * 60 + serviceMinutes
        settings.baselineServiceYearStart = ServiceYearCalculator.serviceYearStart(
            containing: LocalDay(Date(), calendar: .hourleaf)
        ).monthKey
        settings.openingServiceCarryMinutes = serviceCarry
        settings.openingCreditCarryMinutes = creditCarry
        model.saveSettings(settings)
    }

    private var maximumLedgerStartDate: Date {
        model.entries.map { $0.day.date(calendar: .hourleaf) }.min() ?? Date()
    }
}
