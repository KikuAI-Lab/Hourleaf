import SwiftUI

@main
@MainActor
struct HourleafApp: App {
    @StateObject private var launcher = HourleafAppLauncher(
        arguments: ProcessInfo.processInfo.arguments
    )

    var body: some Scene {
        WindowGroup {
            HourleafLaunchView(launcher: launcher)
        }
    }
}

@MainActor
private struct HourleafLaunchView: View {
    @ObservedObject var launcher: HourleafAppLauncher

    var body: some View {
        Group {
            switch launcher.state {
            case .bootstrapping:
                ProgressView("startup.loading")
                    .controlSize(.large)
                    .accessibilityIdentifier("restoreBootstrapIndicator")
            case .blocked:
                ContentUnavailableView {
                    Label("startup.recovery.title", systemImage: "externaldrive.badge.exclamationmark")
                } description: {
                    Text("startup.recovery.message")
                }
                .accessibilityIdentifier("restoreBootstrapBlocked")
            case let .ready(session):
                RootView(dataManagementActions: session.dataManagementActions)
                    .environmentObject(session.model)
                    .environmentObject(session.router)
            }
        }
        .task { await launcher.startIfNeeded() }
    }
}

@MainActor
final class HourleafAppLauncher: ObservableObject {
    enum State {
        case bootstrapping
        case ready(HourleafAppSession)
        case blocked
    }

    private struct PendingRecovery {
        let journalStore: RestoreJournalStoreV1
        let router: AppRouter
        let reminderScheduler: any ReminderScheduling
    }

    @Published private(set) var state: State = .bootstrapping

    private let arguments: [String]
    private let isUITesting: Bool
    private let usesTestStore: Bool
    private var pendingRecovery: PendingRecovery?
    private var didStart = false

    init(arguments: [String]) {
        self.arguments = arguments
        isUITesting = arguments.contains("-uiTesting")
        usesTestStore = isUITesting || arguments.contains("-onboardingUITest")

        if usesTestStore {
            let router = AppRouter()
            let scheduler = UITestReminderScheduler()
            let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
            let repository = CoreDataLedgerRepository(persistence: persistence)
            let journalStore = RestoreJournalStoreV1(
                rootDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                    "Hourleaf-UITest-Restore-\(UUID().uuidString)",
                    isDirectory: true
                )
            )
            state = .ready(makeSession(
                runtime: RestoreReadyRuntime(persistence: persistence, repository: repository),
                journalStore: journalStore,
                router: router,
                reminderScheduler: scheduler
            ))
            return
        }

        let router = AppRouter()
        let scheduler = ReminderScheduler.shared
        // Notification routing touches no ledger data and must be installed in
        // time to retain a cold-launch destination while recovery is checked.
        scheduler.configure(router: router)

        do {
            let root = try RestoreJournalStoreV1.defaultRecoveryRoot()
            let journalStore = RestoreJournalStoreV1(rootDirectory: root)
            switch try journalStore.inspectBeforeStoreLoad() {
            case .idle:
                try journalStore.cleanupCompletedTransactions()
                guard case .idle = try journalStore.inspectBeforeStoreLoad() else {
                    state = .blocked
                    return
                }
                let runtime = Self.makeLocalRuntime()
                state = .ready(makeSession(
                    runtime: runtime,
                    journalStore: journalStore,
                    router: router,
                    reminderScheduler: scheduler
                ))
            case .recover:
                pendingRecovery = PendingRecovery(
                    journalStore: journalStore,
                    router: router,
                    reminderScheduler: scheduler
                )
            case .critical:
                state = .blocked
            }
        } catch {
            state = .blocked
        }
    }

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true

        if case let .ready(session) = state {
            await initialize(session)
            return
        }

        guard let pendingRecovery else { return }
        let result = await HourleafRestoreCoordinator.bootstrap(
            journalStore: pendingRecovery.journalStore,
            reminderScheduler: pendingRecovery.reminderScheduler,
            makeNormalRuntime: Self.makeLocalRuntime,
            makeLocalRecoveryRuntime: Self.makeLocalRuntime
        )
        self.pendingRecovery = nil

        switch result {
        case let .ready(runtime):
            let session = makeSession(
                runtime: runtime,
                journalStore: pendingRecovery.journalStore,
                router: pendingRecovery.router,
                reminderScheduler: pendingRecovery.reminderScheduler
            )
            await initialize(session)
            state = .ready(session)
        case .blocked:
            state = .blocked
        }
    }

    nonisolated private static func makeLocalRuntime() -> RestoreReadyRuntime {
        let persistence = PersistenceController(cloudSyncEnabled: false)
        return RestoreReadyRuntime(
            persistence: persistence,
            repository: CoreDataLedgerRepository(persistence: persistence)
        )
    }

    private func makeSession(
        runtime: RestoreReadyRuntime,
        journalStore: RestoreJournalStoreV1,
        router: AppRouter,
        reminderScheduler: any ReminderScheduling
    ) -> HourleafAppSession {
        let model = AppModel(
            repository: runtime.repository,
            reminderScheduler: reminderScheduler
        )
        let restoreCoordinator = HourleafRestoreCoordinator(
            persistence: runtime.persistence,
            repository: runtime.repository,
            journalStore: journalStore,
            reminderScheduler: reminderScheduler
        )
        let actions = DataManagementActions.live(
            repository: runtime.repository,
            restoreCoordinator: restoreCoordinator,
            appModel: model
        )

        HourleafAppIntentDependencies.register(
            repository: runtime.repository,
            router: router
        )
        HourleafShortcuts.updateAppShortcutParameters()

        return HourleafAppSession(
            persistence: runtime.persistence,
            repository: runtime.repository,
            model: model,
            router: router,
            dataManagementActions: actions
        )
    }

    private func initialize(_ session: HourleafAppSession) async {
        let model = session.model
        if arguments.contains("-coldQuickEntryRouteUITest") {
            model.selectedTab = .history
            session.router.route(to: .quickEntry)
        }

        await model.loadInitialSnapshot(markReady: !isUITesting)
        guard model.startupState != .failed else { return }

        if isUITesting {
            var settings = model.settings
            settings.onboardingComplete = true
            if arguments.contains("-seedUITestData") || arguments.contains("-pastDateUITest") {
                let previous = MonthKey(Date(), calendar: .hourleaf).advanced(by: -1, calendar: .hourleaf)
                settings.ledgerStartMonth = previous
                await model.saveSettings(settings)
                if arguments.contains("-seedUITestData") {
                    let seedDate = LocalDay(year: previous.year, month: previous.month, day: 15)
                        .date(calendar: .hourleaf)
                    _ = await model.addEntry(
                        kind: .service,
                        date: seedDate,
                        hours: 52,
                        minutes: 0,
                        note: nil
                    )
                    _ = await model.addEntry(
                        kind: .credit,
                        date: seedDate,
                        hours: 7,
                        minutes: 0,
                        note: nil
                    )
                }
            } else {
                await model.saveSettings(settings)
            }
            model.finishInitialLoad()
        }

        if !usesTestStore {
            await model.rescheduleReminders()
        }
    }
}

@MainActor
final class HourleafAppSession {
    let persistence: PersistenceController
    let repository: CoreDataLedgerRepository
    let model: AppModel
    let router: AppRouter
    let dataManagementActions: DataManagementActions

    init(
        persistence: PersistenceController,
        repository: CoreDataLedgerRepository,
        model: AppModel,
        router: AppRouter,
        dataManagementActions: DataManagementActions
    ) {
        self.persistence = persistence
        self.repository = repository
        self.model = model
        self.router = router
        self.dataManagementActions = dataManagementActions
    }
}

@MainActor
private final class UITestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}
