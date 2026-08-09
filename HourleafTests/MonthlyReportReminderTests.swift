import XCTest
@testable import Hourleaf

@MainActor
final class MonthlyReportReminderTests: XCTestCase {
    func testMissingLocalPreferenceDefaultsOnWithoutRequestingAuthorization() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let repository = makeRepository()
        let scheduler = MonthlyReportReminderTestScheduler()
        let now = monthlyReportTestDate(year: 2026, month: 10, day: 2)
        let model = AppModel(
            repository: repository,
            reminderScheduler: scheduler,
            now: { now },
            monthlyReportReminderDefaults: defaults
        )

        await model.loadInitialSnapshot()
        await model.rescheduleReminders()

        XCTAssertTrue(model.monthlyReportReminderEnabled)
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 0)
        XCTAssertTrue(scheduler.reconcileRequests.last?.monthlyReportReminderEnabled == true)
    }

    func testExplicitDisableRemovesMonthlyScheduleAndReenableMayRequestPermission() async throws {
        let defaults = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
        let repository = makeRepository()
        let scheduler = MonthlyReportReminderTestScheduler()
        let now = monthlyReportTestDate(year: 2026, month: 10, day: 2)
        let model = AppModel(
            repository: repository,
            reminderScheduler: scheduler,
            now: { now },
            monthlyReportReminderDefaults: defaults
        )
        await model.loadInitialSnapshot()

        await model.setMonthlyReportReminderEnabled(false)
        XCTAssertFalse(model.monthlyReportReminderEnabled)
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 0)
        XCTAssertFalse(scheduler.reconcileRequests.last?.monthlyReportReminderEnabled ?? true)

        await model.setMonthlyReportReminderEnabled(true)
        XCTAssertTrue(model.monthlyReportReminderEnabled)
        XCTAssertEqual(scheduler.requestAuthorizationCallCount, 1)
        XCTAssertTrue(scheduler.reconcileRequests.last?.monthlyReportReminderEnabled == true)
        XCTAssertTrue(MonthlyReportReminderPreference.load(from: defaults).isEnabled)
    }

    private let defaultsSuiteName = "MonthlyReportReminderTests.\(UUID().uuidString)"

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    private func makeRepository() -> CoreDataLedgerRepository {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        return CoreDataLedgerRepository(persistence: persistence)
    }

}

private func monthlyReportTestDate(year: Int, month: Int, day: Int) -> Date {
    var calendar = Calendar.hourleaf
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

@MainActor
private final class MonthlyReportReminderTestScheduler: ReminderScheduling {
    var authorizationStatus: ReminderAuthorizationStatus = .notDetermined
    var requestAuthorizationCallCount = 0
    private(set) var reconcileRequests: [ReminderReconciliationRequest] = []

    func requestAuthorization() async throws -> Bool {
        requestAuthorizationCallCount += 1
        authorizationStatus = .authorized
        return true
    }

    func notificationAuthorizationStatus() async -> ReminderAuthorizationStatus {
        authorizationStatus
    }

    func reschedule(_ reminders: [ReminderSchedule]) async throws {}

    func reconcile(_ request: ReminderReconciliationRequest) async throws {
        reconcileRequests.append(request)
    }
}
