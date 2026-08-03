import SwiftUI

@main
@MainActor
struct HourleafApp: App {
    private static let runtime = HourleafAppRuntime(arguments: ProcessInfo.processInfo.arguments)

    @StateObject private var model: AppModel
    @StateObject private var router: AppRouter

    init() {
        let runtime = Self.runtime
        let appModel = AppModel(
            repository: runtime.repository,
            reminderScheduler: runtime.reminderScheduler
        )
        _model = StateObject(wrappedValue: appModel)
        _router = StateObject(wrappedValue: runtime.router)
        HourleafShortcuts.updateAppShortcutParameters()

        // Install the notification delegate before asynchronous startup work so a
        // cold notification launch can queue its destination on this router.
        if !runtime.usesTestStore {
            ReminderScheduler.shared.configure(router: runtime.router)
        }

        if runtime.arguments.contains("-coldQuickEntryRouteUITest") {
            appModel.selectedTab = .history
            runtime.router.route(to: .quickEntry)
        }

        Task { @MainActor in
            await appModel.loadInitialSnapshot(markReady: !runtime.isUITesting)
            guard appModel.startupState != .failed else { return }
            if runtime.isUITesting {
                var settings = appModel.settings
                settings.onboardingComplete = true
                if runtime.arguments.contains("-seedUITestData") || runtime.arguments.contains("-pastDateUITest") {
                    let previous = MonthKey(Date(), calendar: .hourleaf).advanced(by: -1, calendar: .hourleaf)
                    settings.ledgerStartMonth = previous
                    await appModel.saveSettings(settings)
                    if runtime.arguments.contains("-seedUITestData") {
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
            if !runtime.usesTestStore {
                await appModel.rescheduleReminders()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(router)
        }
    }
}

@MainActor
private final class HourleafAppRuntime {
    let arguments: [String]
    let isUITesting: Bool
    let usesTestStore: Bool
    let repository: CoreDataLedgerRepository
    let router: AppRouter
    let reminderScheduler: any ReminderScheduling

    init(arguments: [String]) {
        self.arguments = arguments
        isUITesting = arguments.contains("-uiTesting")
        usesTestStore = isUITesting || arguments.contains("-onboardingUITest")
        let persistence = usesTestStore
            ? PersistenceController(inMemory: true, cloudSyncEnabled: false)
            : PersistenceController.shared
        let repository = CoreDataLedgerRepository(persistence: persistence)
        let router = AppRouter()

        self.repository = repository
        self.router = router
        reminderScheduler = usesTestStore ? UITestReminderScheduler() : ReminderScheduler.shared
        HourleafAppIntentDependencies.register(repository: repository, router: router)
    }
}

@MainActor
private final class UITestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
