import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class QuickSurfaceAppModelTests: XCTestCase {
    private static let timeZone = TimeZone(identifier: "Europe/Uzhgorod")!
    private static let now = Date(timeIntervalSince1970: 1_785_837_600)

    func testCoreOnlyCapabilityKeepsQuickSurfaceUIUnavailableWhileRestoreRemainsAllowed() async throws {
        let fixedNow = Self.now
        let repository = try await makeRepository()
        let model = AppModel(
            repository: repository,
            reminderScheduler: QuickSurfaceAppModelTestReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .notExpected),
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()

        XCTAssertEqual(model.startupState, .ready)
        XCTAssertEqual(model.quickSurfaceAvailability, .unavailable)
        XCTAssertNil(model.quickSurfaceState)
        XCTAssertEqual(model.quickSurfacePreferences, .init())
        try await model.requireQuickSurfaceIdleForRestore()
    }

    func testProjectionFollowsAppModelAddUpdateDeleteUndoAndPreservesRunningTimer() async throws {
        let fixedNow = Self.now
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let model = AppModel(
            repository: repository,
            reminderScheduler: QuickSurfaceAppModelTestReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .available(store)),
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()
        await model.updateQuickSurfacePrivacyMode(.showTotals)
        await model.updateQuickSurfaceTimerVisibility(true)
        await model.startQuickSurfaceTimer()

        let runningTimer = try XCTUnwrap(model.quickSurfaceState?.timer)
        guard case .running = runningTimer else {
            return XCTFail("Explicit enable must leave the timer Idle until Start is requested.")
        }
        XCTAssertTrue(model.quickSurfaceTimerWasRequested)
        XCTAssertNil(model.errorMessage)

        let added = await model.addEntry(
            kind: .service,
            date: Self.now,
            hours: 1,
            minutes: 15,
            note: "private note sentinel"
        )
        XCTAssertTrue(added)
        try assertProjection(
            model.quickSurfaceState,
            serviceMinutes: 75,
            creditMinutes: 0,
            timer: runningTimer
        )

        let record = try XCTUnwrap(model.entryRecords.first)
        let updated = await model.updateEntry(
            record,
            kind: .credit,
            date: Self.now,
            hours: 2,
            minutes: 0,
            note: "still private"
        )
        XCTAssertTrue(updated)
        try assertProjection(
            model.quickSurfaceState,
            serviceMinutes: 0,
            creditMinutes: 120,
            timer: runningTimer
        )

        let current = try XCTUnwrap(model.entryRecords.first)
        let deleted = await model.deleteEntry(current)
        XCTAssertTrue(deleted)
        try assertProjection(
            model.quickSurfaceState,
            serviceMinutes: 0,
            creditMinutes: 0,
            timer: runningTimer
        )

        await model.undoLatestMutation()
        try assertProjection(
            model.quickSurfaceState,
            serviceMinutes: 0,
            creditMinutes: 120,
            timer: runningTimer
        )
        XCTAssertEqual(model.entryRecords.count, 1)
        XCTAssertEqual(model.entryRecords.first?.entry.kind, .credit)
    }

    func testProjectionFaultDoesNotRollBackCommittedLedgerMutation() async throws {
        let fixedNow = Self.now
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            .init(timerVisible: false, privacyMode: .showTotals)
        )
        let initialSnapshot = try await repository.ledgerSnapshot()
        let bootstrapStore = makeStore(root: root, attributes: attributes)
        let initialState = try makeReconciler(store: bootstrapStore).bootstrap(snapshot: initialSnapshot)
        let faultingStore = QuickSurfaceStateStoreV1(
            rootDirectory: root,
            faults: .init { point in
                if case .beforePublish = point {
                    throw QuickSurfaceAppModelTestFault.publish
                }
            },
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
        )
        let model = AppModel(
            repository: repository,
            reminderScheduler: QuickSurfaceAppModelTestReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .available(faultingStore)),
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()
        XCTAssertEqual(model.quickSurfaceState, initialState)

        let added = await model.addEntry(
            kind: .service,
            date: Self.now,
            hours: 0,
            minutes: 30,
            note: nil
        )
        let ledger = try await repository.ledgerSnapshot()

        XCTAssertTrue(added)
        XCTAssertEqual(ledger.activeEntries.count, 1)
        XCTAssertEqual(ledger.activeEntries.first?.minutes, 30)
        XCTAssertEqual(model.entryRecords.count, 1)
        XCTAssertEqual(model.quickSurfaceAvailability, .stale)
        XCTAssertEqual(try faultingStore.read(), initialState)
    }

    func testResetCorruptSidecarThroughAppModelPreservesLedgerAndBuildsIdleState() async throws {
        let fixedNow = Self.now
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        let repository = try await makeRepository()
        let receipt = try await AddTimeEntryCommand(repository: repository).execute(
            kind: .credit,
            date: Self.now,
            hours: 0,
            minutes: 45,
            note: "ledger note survives reset",
            occurredAt: Self.now
        )
        try QuickSurfaceStoreTestSupport.writeData(
            Data("corrupt quick surface state".utf8),
            to: QuickSurfaceStoreTestSupport.stateFileURL(root: root)
        )
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
        let model = AppModel(
            repository: repository,
            reminderScheduler: QuickSurfaceAppModelTestReminderScheduler(),
            quickSurfaceHost: makeHost(repository: repository, capability: .available(store)),
            now: { fixedNow }
        )

        await model.loadInitialSnapshot()
        XCTAssertEqual(model.quickSurfaceAvailability, .resetRequired)

        let reset = await model.resetQuickSurfaceState()
        XCTAssertTrue(reset)
        let state = try XCTUnwrap(model.quickSurfaceState)
        let ledger = try await repository.ledgerSnapshot()

        XCTAssertEqual(model.quickSurfaceAvailability, .ready)
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.timer, .idle)
        XCTAssertEqual(ledger.activeEntries.map(\.id), [receipt.entry.id])
        XCTAssertEqual(ledger.activeEntries.first?.note, "ledger note survives reset")
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
        return QuickSurfaceHostController(
            repository: repository,
            capability: capability,
            calendar: calendar(),
            timeZone: Self.timeZone,
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

    private func makeReconciler(store: QuickSurfaceStateStoreV1) -> QuickSurfaceReconciler {
        let fixedNow = Self.now
        return QuickSurfaceReconciler(
            stateStore: store,
            calendar: calendar(),
            timeZone: Self.timeZone,
            clock: { fixedNow }
        )
    }

    private func assertProjection(
        _ state: QuickSurfaceStateV1?,
        serviceMinutes: Int,
        creditMinutes: Int,
        timer: TimerSessionV1,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let state = try XCTUnwrap(state, file: file, line: line)
        XCTAssertEqual(state.projection.privacyMode, .showTotals, file: file, line: line)
        XCTAssertEqual(state.projection.serviceMinutes, Optional(serviceMinutes), file: file, line: line)
        XCTAssertEqual(state.projection.creditMinutes, Optional(creditMinutes), file: file, line: line)
        XCTAssertEqual(state.timer, timer, file: file, line: line)
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.timeZone
        return calendar
    }
}

@MainActor
private final class QuickSurfaceAppModelTestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}

private enum QuickSurfaceAppModelTestFault: Error, Sendable {
    case publish
}
