import SwiftUI

@main
struct HourleafApp: App {
    @StateObject private var model: AppModel

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("-uiTesting")
        let usesTestStore = isUITesting || arguments.contains("-onboardingUITest")
        let persistence = usesTestStore
            ? PersistenceController(inMemory: true, cloudSyncEnabled: false)
            : PersistenceController.shared
        let repository = CoreDataLedgerRepository(persistence: persistence)
        let reminderScheduler: any ReminderScheduling = usesTestStore
            ? UITestReminderScheduler()
            : ReminderScheduler.shared
        let appModel = AppModel(repository: repository, reminderScheduler: reminderScheduler)
        _model = StateObject(wrappedValue: appModel)
        Task { @MainActor in
            await appModel.loadInitialSnapshot(markReady: !isUITesting)
            guard appModel.startupState != .failed else { return }
            if isUITesting {
                var settings = appModel.settings
                settings.onboardingComplete = true
                if arguments.contains("-seedUITestData") || arguments.contains("-pastDateUITest") {
                    let previous = MonthKey(Date(), calendar: .hourleaf).advanced(by: -1, calendar: .hourleaf)
                    settings.ledgerStartMonth = previous
                    await appModel.saveSettings(settings)
                    if arguments.contains("-seedUITestData") {
                        let seedDate = LocalDay(year: previous.year, month: previous.month, day: 15)
                            .date(calendar: .hourleaf)
                        _ = await appModel.addEntry(
                            kind: .service,
                            date: seedDate,
                            hours: 52,
                            minutes: 0,
                            note: nil
                        )
                        _ = await appModel.addEntry(
                            kind: .credit,
                            date: seedDate,
                            hours: 7,
                            minutes: 0,
                            note: nil
                        )
                    }
                } else {
                    await appModel.saveSettings(settings)
                }
                appModel.finishInitialLoad()
            }
            if !usesTestStore {
                ReminderScheduler.shared.configure()
                await appModel.rescheduleReminders()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
        }
    }
}

@MainActor
private final class UITestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
