import SwiftUI
import UIKit

struct SettingsScreen: View {
    let dataManagementActions: DataManagementActions

    @EnvironmentObject private var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var backupStatus: BackupConfidenceStatusModel
    @AppStorage(AppAppearance.storageKey) private var appearanceRawValue = AppAppearance.system.rawValue
    @AppStorage(TimeSelectionFeedbackPreference.storageKey)
    private var timeSelectionFeedbackEnabled = TimeSelectionFeedbackPreference.defaultValue
    @State private var showAddReminder = false
    @State private var showQuickSurfaceResetConfirmation = false

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
                Section {
                    Picker("settings.appearance.mode", selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.localizedName).tag(appearance)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("appearancePicker")

                    Toggle(
                        "settings.time_selection_feedback",
                        isOn: $timeSelectionFeedbackEnabled
                    )
                    .accessibilityHint(Text("settings.time_selection_feedback_help"))
                    .accessibilityIdentifier("timeSelectionFeedbackToggle")
                } header: {
                    Text("settings.appearance.title")
                } footer: {
                    Text("settings.time_selection_feedback_help")
                }

                Section("settings.reporting") {
                    Picker("settings.report_language", selection: reportLanguageBinding) {
                        ForEach(ReportLanguage.allCases) { Text($0.localizedName).tag($0) }
                    }

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
                        "report_reminder.toggle",
                        isOn: Binding(
                            get: { model.monthlyReportReminderEnabled },
                            set: { value in
                                Task { await model.setMonthlyReportReminderEnabled(value) }
                            }
                        )
                    )
                    .accessibilityIdentifier("monthlyReportReminderToggle")

                    if model.monthlyReportReminderEnabled,
                       model.notificationAuthorizationStatus != .authorized,
                       model.notificationAuthorizationStatus != .provisional,
                       model.notificationAuthorizationStatus != .ephemeral {
                        if model.notificationAuthorizationStatus == .notDetermined {
                            Text("report_reminder.permission_needed")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("monthlyReportReminderStatus")
                        } else {
                            Text("report_reminder.notifications_off")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("monthlyReportReminderStatus")
                        }

                        if model.notificationAuthorizationStatus == .notDetermined {
                            Button("report_reminder.allow_notifications") {
                                Task { await model.requestMonthlyReportReminderAuthorization() }
                            }
                            .accessibilityIdentifier("allowMonthlyReportReminderButton")
                        } else {
                            Button("report_reminder.open_settings") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else {
                                    return
                                }
                                openURL(url)
                            }
                            .accessibilityIdentifier("openMonthlyReminderSettingsButton")
                        }
                    }

                    ForEach(model.reminders) { reminder in
                        reminderRow(reminder)
                    }
                    Button { showAddReminder = true } label: {
                        Label("settings.add_reminder", systemImage: "plus")
                    }
                    .accessibilityIdentifier("addReminderButton")

                    Toggle(
                        "quiet_gap.toggle",
                        isOn: Binding(
                            get: { model.planningPreferences.isQuietGapEnabled },
                            set: { _ in
                                Task {
                                    await model.updateQuietGapEnabled(
                                        !model.planningPreferences.isQuietGapEnabled
                                    )
                                }
                            }
                        )
                    )
                    .accessibilityHint(String(localized: "quiet_gap.footer"))
                    .accessibilityIdentifier("quietGapCheckToggle")

                    if model.notificationAuthorizationStatus.showsInlineGuidance,
                       !model.monthlyReportReminderEnabled {
                        Text("notifications.off")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("notificationAuthorizationStatus")

                        Button("notifications.open_settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else {
                                return
                            }
                            openURL(url)
                        }
                        .accessibilityIdentifier("openNotificationSettingsButton")
                    }
                } header: {
                    Text("settings.reminders")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("settings.reminders_footer")
                        Text("quiet_gap.footer")
                    }
                }

                Section {
                    guideLink(
                        title: "settings.guides.watch.title",
                        detail: "settings.guides.watch.detail",
                        systemImage: "applewatch",
                        anchor: "apple-watch",
                        identifier: "watchGuideLink"
                    )
                    guideLink(
                        title: "settings.guides.voice.title",
                        detail: "settings.guides.voice.detail",
                        systemImage: "waveform",
                        anchor: "voice",
                        identifier: "voiceGuideLink"
                    )
                } header: {
                    Text("settings.guides.title")
                } footer: {
                    Text("settings.guides.footer")
                        .accessibilityIdentifier("settingsGuidesFooter")
                }

                if model.quickSurfaceAvailability.isVisibleInSettings {
                    Section {
                        if model.quickSurfaceAvailability.allowsInteraction {
                            Toggle(
                                "quick_surfaces.settings.timer_toggle",
                                isOn: Binding(
                                    get: { model.quickSurfacePreferences.timerVisible },
                                    set: { value in
                                        Task { await model.updateQuickSurfaceTimerVisibility(value) }
                                    }
                                )
                            )
                            .disabled(model.isQuickSurfaceActionInFlight)
                            .accessibilityIdentifier("quickSurfaceTimerToggle")

                            Toggle(
                                "quick_surfaces.settings.show_monthly_totals",
                                isOn: Binding(
                                    get: { model.quickSurfacePreferences.privacyMode == .showTotals },
                                    set: { value in
                                        Task {
                                            await model.updateQuickSurfacePrivacyMode(
                                                value ? .showTotals : .hideTotals
                                            )
                                        }
                                    }
                                )
                            )
                            .disabled(model.isQuickSurfaceActionInFlight)
                            .accessibilityIdentifier("quickSurfaceTotalsToggle")
                        } else {
                            Label(
                                model.quickSurfaceAvailability == .resetRequired
                                    ? "quick_surfaces.settings.corrupt"
                                    : "quick_surfaces.settings.unavailable",
                                systemImage: "exclamationmark.triangle"
                            )
                            .foregroundStyle(.secondary)
                            Text(
                                model.quickSurfaceAvailability == .resetRequired
                                    ? "quick_surfaces.settings.read_only"
                                    : "quick_surfaces.settings.unavailable_detail"
                            )
                                .font(.footnote)
                                .foregroundStyle(.secondary)

                            if model.quickSurfaceAvailability == .resetRequired {
                                Button(role: .destructive) {
                                    showQuickSurfaceResetConfirmation = true
                                } label: {
                                    Label("quick_surfaces.settings.reset", systemImage: "arrow.counterclockwise")
                                }
                                .disabled(model.isQuickSurfaceActionInFlight)
                                .accessibilityIdentifier("resetQuickSurfacesButton")
                            }
                        }
                    } header: {
                        Text("quick_surfaces.settings.title")
                    } footer: {
                        Text("quick_surfaces.settings.footer")
                            .accessibilityIdentifier("quickSurfacesFooter")
                    }
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
                    LabeledContent(
                        "settings.version",
                        value: Bundle.main.object(
                            forInfoDictionaryKey: "CFBundleShortVersionString"
                        ) as? String ?? "—"
                    )
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
                backupStatus.requestRefresh()
                Task { await model.refreshReminderAuthorizationStatus() }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                backupStatus.requestRefresh()
                Task { await model.refreshReminderAuthorizationStatus() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)) { _ in
                backupStatus.requestRefresh()
            }
            .sheet(isPresented: $showAddReminder) {
                AddReminderView()
                    .environmentObject(model)
            }
            .confirmationDialog(
                "quick_surfaces.settings.reset.title",
                isPresented: $showQuickSurfaceResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("quick_surfaces.settings.reset.confirm", role: .destructive) {
                    Task { _ = await model.resetQuickSurfaceState() }
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("quick_surfaces.settings.reset.message")
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

    private func guideLink(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        systemImage: String,
        anchor: String,
        identifier: String
    ) -> some View {
        Link(destination: hourleafGuideURL(anchor: anchor)) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }

    private func hourleafGuideURL(anchor: String) -> URL {
        let preferredLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let languagePath = preferredLanguage.hasPrefix("ru") ? "ru/" : ""
        return URL(string: "https://kikuai.dev/hourleaf/guide/\(languagePath)#\(anchor)")!
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
            Task { await model.updateReportLanguage(value) }
        })
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { AppAppearance(storedValue: appearanceRawValue) },
            set: { appearanceRawValue = $0.rawValue }
        )
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
