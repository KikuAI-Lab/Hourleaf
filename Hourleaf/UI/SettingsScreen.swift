import AppIntents
import SwiftUI

struct SettingsScreen: View {
    let dataManagementActions: DataManagementActions

    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var backupStatus: BackupConfidenceStatusModel
    @State private var showAddReminder = false
    @State private var creditLabelDraft = ""
    @State private var creditLabelLanguage: ReportLanguage = .preferredForCurrentLocale
    @FocusState private var creditLabelIsFocused: Bool

    init(dataManagementActions: DataManagementActions) {
        self.dataManagementActions = dataManagementActions
        _backupStatus = ObservedObject(wrappedValue: dataManagementActions.backupStatus)
    }

    private var currentPolicy: ReportingPolicy {
        ReportCalculator.policy(for: model.currentMonth, revisions: model.policies)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.reporting") {
                    Picker("settings.report_language", selection: reportLanguageBinding) {
                        ForEach(ReportLanguage.allCases) { Text($0.localizedName).tag($0) }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.credit_label")
                            .font(.subheadline.weight(.semibold))
                        TextField("settings.credit_label_placeholder", text: $creditLabelDraft)
                            .textFieldStyle(.roundedBorder)
                            .focused($creditLabelIsFocused)
                            .submitLabel(.done)
                            .onSubmit { saveCreditLabelDraft() }
                            .accessibilityLabel(String(localized: "settings.credit_label"))
                            .accessibilityIdentifier("creditLabelField")
                        Text("settings.credit_label_help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Picker("settings.minutes_policy", selection: remainderModeBinding) {
                        ForEach(RemainderMode.allCases) { Text($0.localizedName).tag($0) }
                    }
                    Text(policyExampleKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("minutePolicyExample")
                }

                Section {
                    Toggle(
                        "planning.toggle",
                        isOn: Binding(
                            get: { model.planningPreferences.isPaceVisible },
                            set: { _ in
                                model.queuePlanningVisibilityChange(
                                    !model.planningPreferences.isPaceVisible
                                )
                            }
                        )
                    )
                    .accessibilityHint(String(localized: "planning.footer"))
                    .accessibilityIdentifier("planningVisibilityToggle")
                } header: {
                    Text("settings.planning")
                } footer: {
                    Text("planning.footer")
                }

                Section {
                    ForEach(model.reminders) { reminder in
                        reminderRow(reminder)
                    }
                    Button { showAddReminder = true } label: {
                        Label("settings.add_reminder", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addReminderButton")
                } header: {
                    Text("settings.reminders")
                } footer: {
                    Text("settings.reminders_footer")
                }

                Section {
                    ShortcutsLink()
                        .accessibilityIdentifier("shortcutsLink")
                } header: {
                    Text("settings.shortcuts")
                } footer: {
                    Text("settings.shortcuts_footer")
                        .accessibilityIdentifier("shortcutsFooter")
                }

                Section {
                    NavigationLink {
                        DataManagementView(actions: dataManagementActions)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("data_management.title")
                                if let state = backupStatus.state {
                                    Text(state.localizedStatusText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .accessibilityIdentifier("dataManagementButton")

                    NavigationLink("settings.opening_balances") { StartingBalancesView() }
                        .accessibilityIdentifier("existingTimeButton")
                } header: {
                    Text("settings.data")
                } footer: {
                    Text("settings.data_help")
                }

                Section("settings.privacy") {
                    Label("settings.no_tracking", systemImage: "hand.raised.fill")
                    Text(privacyDetail).font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("settings.version", value: "0.1.0")
                    LabeledContent("settings.developer", value: "KikuAI")
                    Link(destination: URL(string: "https://kikuai.dev")!) {
                        Label("settings.developer_website", systemImage: "safari")
                    }
                    .accessibilityIdentifier("developerWebsiteLink")
                    Link(destination: URL(string: "https://t.me/kiku_ai")!) {
                        Label("settings.developer_telegram", systemImage: "paperplane")
                    }
                    .accessibilityIdentifier("developerTelegramLink")
                    Link(destination: URL(string: "https://github.com/kiku-jw")!) {
                        Label("settings.developer_github", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("developerGitHubLink")
                } header: { Text("settings.about") }
            }
            .navigationTitle("settings.title")
            .onAppear {
                synchronizeCreditLabelDraft()
                backupStatus.requestRefresh()
            }
            .onChange(of: creditLabelIsFocused) { _, isFocused in
                if !isFocused { saveCreditLabelDraft() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                backupStatus.requestRefresh()
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                backupStatus.requestRefresh()
            }
            .sheet(isPresented: $showAddReminder) {
                AddReminderView()
                    .environmentObject(model)
            }
        }
    }

    private var policyExampleKey: LocalizedStringKey {
        switch currentPolicy.mode {
        case .carry: "settings.policy_example_carry"
        case .roundNearest: "settings.policy_example_round"
        case .discard: "settings.policy_example_discard"
        }
    }

    private var privacyDetail: String {
        String(localized: "settings.privacy_detail")
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
        .accessibilityIdentifier("reminderRow_\(reminder.id.uuidString)")
        .swipeActions {
            Button(role: .destructive) {
                Task { await model.deleteReminder(reminder) }
            } label: { Label("common.delete", systemImage: "trash") }
        }
    }

    private var reportLanguageBinding: Binding<ReportLanguage> {
        Binding(get: { model.settings.reportLanguage }, set: { value in
            let previousLanguage = creditLabelLanguage
            let previousLabel = creditLabelDraft
            creditLabelLanguage = value
            creditLabelDraft = model.settings.creditLabel(for: value)
            model.queueReportLanguageChange(
                value,
                savingCreditLabel: previousLabel,
                for: previousLanguage
            )
        })
    }

    private func synchronizeCreditLabelDraft() {
        creditLabelLanguage = model.settings.reportLanguage
        creditLabelDraft = model.settings.creditLabel(for: creditLabelLanguage)
    }

    private func saveCreditLabelDraft() {
        let language = creditLabelLanguage
        let label = creditLabelDraft
        guard model.settings.creditLabel(for: language) != label else { return }
        model.queueCreditLabelChange(label, for: language)
    }

    private var remainderModeBinding: Binding<RemainderMode> {
        Binding(get: { currentPolicy.mode }, set: { value in
            Task { await model.updateReportingPolicy(mode: value) }
        })
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
                    .accessibilityIdentifier("confirmAddReminderButton")
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
            Section {
                Text("balances.intro")
                    .foregroundStyle(.secondary)
            }
            Section("balances.ledger") {
                DatePicker(
                    "balances.ledger_start",
                    selection: $ledgerStartDate,
                    in: Date.distantPast...maximumLedgerStartDate,
                    displayedComponents: .date
                )
            }
            Section {
                TimeWheelPicker(hours: $serviceHours, minutes: $serviceMinutes, usesDirectHourEntry: true)
            } header: {
                Text("balances.year_progress")
            } footer: {
                Text("balances.year_progress_help")
            }
            Section {
                Stepper(String(format: String(localized: "balances.service_carry_format"), serviceCarry), value: $serviceCarry, in: 0...59)
                Stepper(String(format: String(localized: "balances.credit_carry_format"), creditCarry), value: $creditCarry, in: 0...59)
            } header: {
                Text("balances.carry")
            } footer: {
                Text("balances.carry_help")
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
        let selectedLedgerStartMonth = settings.ledgerStartMonth
        settings.baselineServiceYearStart = ServiceYearCalculator.serviceYearStart(
            containing: LocalDay(
                year: selectedLedgerStartMonth.year,
                month: selectedLedgerStartMonth.month,
                day: 1
            )
        ).monthKey
        settings.openingServiceCarryMinutes = serviceCarry
        settings.openingCreditCarryMinutes = creditCarry
        Task { await model.saveSettings(settings) }
    }

    private var maximumLedgerStartDate: Date {
        model.entries.map { $0.day.date(calendar: .hourleaf) }.min() ?? model.currentDate
    }
}
