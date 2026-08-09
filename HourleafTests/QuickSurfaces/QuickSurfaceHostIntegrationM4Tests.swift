import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class QuickSurfaceHostIntegrationM4Tests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_785_837_600)
    private static let timeZone = TimeZone(identifier: "Europe/Uzhgorod")!

    func testExpectedReconcileAndAcceptedTimerStateEachReloadOnce() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-reload-ready")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let counter = M4ReloadCounter()
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: M4ReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .available(store)),
            quickSurfaceSystemReloader: QuickSurfaceSystemReloader {
                counter.increment()
            },
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()
        XCTAssertEqual(counter.value, 1, "The first authoritative reconcile must reload once.")

        await model.updateQuickSurfaceTimerVisibility(true)
        XCTAssertTrue(model.quickSurfaceTimerWasRequested)
        counter.reset()

        await model.startQuickSurfaceTimer()
        XCTAssertEqual(counter.value, 1, "An accepted timer state must reload once after readback.")
        guard let timer = model.quickSurfaceState?.timer,
              case .running = timer
        else {
            return XCTFail("The accepted timer state must remain running.")
        }
    }

    func testDisabledReloaderAndNonExpectedCapabilityRemainQuiet() async throws {
        let repository = try await makeRepository()
        let counter = M4ReloadCounter()
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: M4ReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .notExpected),
            quickSurfaceSystemReloader: QuickSurfaceSystemReloader {
                counter.increment()
            },
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()

        XCTAssertEqual(counter.value, 0)
        XCTAssertEqual(model.quickSurfaceAvailability, .unavailable)
    }

    func testExpectedButUnavailableCapabilityReloadsToRetireCachedContent() async throws {
        let repository = try await makeRepository()
        let counter = M4ReloadCounter()
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: M4ReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .expectedButUnavailable),
            quickSurfaceSystemReloader: QuickSurfaceSystemReloader {
                counter.increment()
            },
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(model.quickSurfaceAvailability, .unavailable)
    }

    func testRestoreTerminalReloadsOnceAfterVerifiedProjection() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-reload-restore")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let counter = M4ReloadCounter()
        let fixedNow = Self.now
        let model = AppModel(
            repository: repository,
            reminderScheduler: M4ReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .available(store)),
            quickSurfaceSystemReloader: QuickSurfaceSystemReloader {
                counter.increment()
            },
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()
        counter.reset()

        try await model.performWholeStoreRestore {
            RestoreCommitResult(
                selectedTarget: .candidate,
                recordsDigest: String(repeating: "a", count: 64),
                recordCounts: HourleafBackupRecordCountsV1(
                    acknowledgements: 0,
                    archives: 0,
                    entries: 0,
                    policies: 0,
                    presets: 0,
                    receipts: 0,
                    reminders: 0,
                    revisions: 0,
                    states: 0
                )
            )
        }

        XCTAssertEqual(counter.value, 1)
        XCTAssertEqual(model.startupState, .ready)
    }

    func testIntentProjectionRefreshReloadsOnceAfterHostReconcile() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-reload-intent")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let host = makeHost(repository: repository, capability: .available(store))
        let counter = M4ReloadCounter()
        let refresher = QuickSurfaceIntentProjectionRefresher(
            repository: repository,
            quickSurfaceHost: host,
            systemReloader: QuickSurfaceSystemReloader {
                counter.increment()
            }
        )

        await refresher.refreshAfterMutation()

        XCTAssertEqual(counter.value, 1)
    }

    private func makeRepository() async throws -> CoreDataLedgerRepository {
        let fixedNow = Self.now
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: { fixedNow }
        )
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(year: 2026, month: 8)
        try await repository.saveSettings(settings)
        return repository
    }

    private func makeHost(
        repository: any LedgerRepository,
        capability: QuickSurfaceHostCapability
    ) -> QuickSurfaceHostController {
        let fixedNow = Self.now
        let fixedTimeZone = Self.timeZone
        return QuickSurfaceHostController(
            repository: repository,
            capability: capability,
            calendar: calendar(),
            timeZone: fixedTimeZone,
            now: { fixedNow },
            systemUptime: { 1_000 }
        )
    }

    private func makeStore(
        root: URL,
        attributes: QuickSurfaceStoreAttributeLedger
    ) -> QuickSurfaceStateStoreV1 {
        QuickSurfaceStateStoreV1(
            rootDirectory: root,
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
        )
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = Self.timeZone
        return calendar
    }
}

private final class M4ReloadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var countStorage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return countStorage
    }

    func increment() {
        lock.lock()
        countStorage += 1
        lock.unlock()
    }

    func reset() {
        lock.lock()
        countStorage = 0
        lock.unlock()
    }
}

@MainActor
private struct M4ReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
    func reconcile(_ request: ReminderReconciliationRequest) async throws {}
    func notificationAuthorizationStatus() async -> ReminderAuthorizationStatus { .authorized }
}
