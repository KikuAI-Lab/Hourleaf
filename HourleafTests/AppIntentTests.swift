import AppIntents
@preconcurrency import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class AppIntentTests: XCTestCase {
    func testRecordIntentWritesServiceAndCreditThroughShortcutContract() async throws {
        let repository = try await makeRepository()
        let manager = makeDependencyManager(repository: repository)
        let entryDate = Date.now

        try await RecordTimeIntent(
            kind: .service,
            hours: 1,
            minutes: 15,
            date: entryDate,
            dependencyManager: manager
        ).persist(using: repository)
        try await RecordTimeIntent(
            kind: .credit,
            hours: 0,
            minutes: 45,
            date: entryDate,
            dependencyManager: manager
        ).persist(using: repository)

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.count, 2)
        XCTAssertEqual(snapshot.activeEntries.first(where: { $0.kind == .service })?.minutes, 75)
        XCTAssertEqual(snapshot.activeEntries.first(where: { $0.kind == .credit })?.minutes, 45)
        XCTAssertTrue(snapshot.entryRevisions.allSatisfy { $0.source == EntryMutationSource.shortcut.rawValue })
        XCTAssertTrue(snapshot.entryRevisions.allSatisfy { $0.note == nil })

        let undoCandidate = try await repository.latestUndoCandidate(asOf: .now)
        let undo = try XCTUnwrap(undoCandidate)
        XCTAssertEqual(undo.operation, .create)
        XCTAssertEqual(undo.entry.source, EntryMutationSource.shortcut.rawValue)
        XCTAssertEqual(undo.expiresAt.timeIntervalSince(undo.occurredAt), 10 * 60, accuracy: 0.001)
    }

    func testPromotedRecordTilesLeaveDurationUnresolvedUntilShortcutsCollectsIt() throws {
        guard #available(iOS 18.2, *) else {
            throw XCTSkip("IntentParameter value state is unavailable before iOS 18.2.")
        }

        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false)
        )
        let manager = makeDependencyManager(repository: repository)
        let serviceTile = RecordTimeIntent(kind: .service, dependencyManager: manager)
        let creditTile = RecordTimeIntent(kind: .credit, dependencyManager: manager)

        XCTAssertEqual(serviceTile.kind, .service)
        XCTAssertEqual(creditTile.kind, .credit)
        assertUnset(serviceTile.$hours)
        assertUnset(serviceTile.$minutes)
        assertUnset(creditTile.$hours)
        assertUnset(creditTile.$minutes)
    }

    func testRecordIntentKeepsValidationInTheCommandPath() async throws {
        let repository = try await makeRepository()
        let manager = makeDependencyManager(repository: repository)

        await assertValidationError(.emptyDuration) {
            try await RecordTimeIntent(
                kind: .service,
                hours: 0,
                minutes: 0,
                dependencyManager: manager
            ).persist(using: repository)
        }

        try await RecordTimeIntent(
            kind: .service,
            hours: 99,
            minutes: 59,
            dependencyManager: manager
        ).persist(using: repository)

        await assertValidationError(.durationTooLarge) {
            try await RecordTimeIntent(
                kind: .service,
                hours: 100,
                minutes: 0,
                dependencyManager: manager
            ).persist(using: repository)
        }

        await assertMutationError(.dateInFuture) {
            try await RecordTimeIntent(
                kind: .credit,
                hours: 1,
                minutes: 0,
                date: Date.now.addingTimeInterval(24 * 60 * 60),
                dependencyManager: manager
            ).persist(using: repository)
        }

        let beforeStart = MonthKey(Date.now, calendar: .hourleaf)
            .advanced(by: -1, calendar: .hourleaf)
            .date(calendar: .hourleaf)
        await assertMutationError(.beforeLedgerStart) {
            try await RecordTimeIntent(
                kind: .credit,
                hours: 1,
                minutes: 0,
                date: beforeStart,
                dependencyManager: manager
            ).persist(using: repository)
        }
    }

    func testRecordIntentMarksPreparedClosedMonthAsChangedWithoutRewritingPreparedSnapshot() async throws {
        let repositoryNow = makeDate(year: 2030, month: 1, day: 10, hour: 12, minute: 0)
        let preparedMonth = MonthKey(year: 2029, month: 12)
        let repository = try await makeRepository(
            ledgerStartMonth: MonthKey(year: 2029, month: 9),
            clock: { repositoryNow }
        )
        let manager = makeDependencyManager(repository: repository)
        let initialEntryID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let preparedSnapshotID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                entryID: initialEntryID,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: .service,
                    day: LocalDay(year: 2029, month: 12, day: 3),
                    minutes: 60,
                    note: nil
                ),
                occurredAt: makeDate(year: 2030, month: 1, day: 2, hour: 9, minute: 0),
                source: .appQuickEntry
            )
        )

        let reviewSnapshot = try await repository.ledgerSnapshot()
        let draft = try XCTUnwrap(ReportReadiness.draft(for: preparedMonth, in: reviewSnapshot))
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: preparedMonth,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                reviewedAt: makeDate(year: 2030, month: 1, day: 4, hour: 8, minute: 0)
            )
        )
        let prepared = try await repository.prepareReport(
            PrepareReportRequest(
                month: preparedMonth,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                snapshotID: preparedSnapshotID,
                preparedAt: makeDate(year: 2030, month: 1, day: 5, hour: 8, minute: 0)
            )
        )

        try await RecordTimeIntent(
            kind: .service,
            hours: 0,
            minutes: 30,
            date: makeDate(year: 2029, month: 12, day: 20, hour: 10, minute: 0),
            dependencyManager: manager
        ).persist(using: repository)

        let after = try await repository.ledgerSnapshot()
        let state = try XCTUnwrap(after.reportStates.first(where: { $0.month == preparedMonth }))
        let stableSnapshot = try XCTUnwrap(after.reportSnapshots.first(where: { $0.id == preparedSnapshotID }))
        let shortcutRevision = try XCTUnwrap(
            after.entryRevisions.first(where: {
                $0.source == EntryMutationSource.shortcut.rawValue
                    && $0.entryID != initialEntryID
            })
        )

        XCTAssertEqual(HourleafShortcuts.appShortcuts.count, 3)
        XCTAssertEqual(shortcutRevision.source, EntryMutationSource.shortcut.rawValue)
        XCTAssertEqual(shortcutRevision.localDay, LocalDay(year: 2029, month: 12, day: 20).key)
        XCTAssertEqual(shortcutRevision.minutes, 30)
        XCTAssertEqual(state.state, .changed)
        XCTAssertEqual(state.lastStableState, .prepared)
        XCTAssertEqual(state.currentSnapshotID, preparedSnapshotID)
        XCTAssertEqual(stableSnapshot.id, prepared.snapshot.id)
        XCTAssertEqual(stableSnapshot.version, prepared.snapshot.version)
        XCTAssertEqual(stableSnapshot.supersedesID, prepared.snapshot.supersedesID)
        XCTAssertEqual(stableSnapshot.receipt, prepared.snapshot.receipt)
        XCTAssertEqual(after.reportSnapshots.count, 1)
    }

    func testIntentExecutionPoliciesStaySeparated() {
        XCTAssertFalse(RecordTimeIntent.openAppWhenRun)
        XCTAssertEqual(RecordTimeIntent.authenticationPolicy, .requiresLocalDeviceAuthentication)
        XCTAssertTrue(OpenQuickEntryIntent.openAppWhenRun)
        XCTAssertEqual(OpenQuickEntryIntent.authenticationPolicy, .alwaysAllowed)
    }

    func testOpenQuickEntryQueuesRouteWithoutWriting() async throws {
        let repository = try await makeRepository()
        let router = AppRouter()
        let manager = makeDependencyManager(repository: repository, router: router)
        let before = try await repository.ledgerSnapshot()

        await OpenQuickEntryIntent(dependencyManager: manager).route(using: router)

        let after = try await repository.ledgerSnapshot()
        XCTAssertEqual(after.entries, before.entries)
        XCTAssertEqual(after.entryRevisions, before.entryRevisions)
        XCTAssertEqual(router.pendingRoute, .quickEntry)
    }

    func testForegroundRefreshBringsAnIntentWriteIntoTheLiveModelAndUndo() async throws {
        let repository = try await makeRepository()
        let router = AppRouter()
        let manager = makeDependencyManager(repository: repository, router: router)
        let model = AppModel(repository: repository, reminderScheduler: IntentTestReminderScheduler())
        await model.loadInitialSnapshot()

        try await RecordTimeIntent(
            kind: .service,
            hours: 1,
            minutes: 15,
            dependencyManager: manager
        ).persist(using: repository, notifying: router)
        XCTAssertEqual(router.ledgerChangeGeneration, 1)
        XCTAssertTrue(model.entries.isEmpty)

        await model.refreshAfterForegrounding()

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.minutes, 75)
        XCTAssertEqual(
            model.report(for: MonthKey(Date.now, calendar: .hourleaf)).rawServiceMinutes,
            75
        )
        XCTAssertEqual(model.undoCandidate?.entryID, model.entries.first?.id)
        XCTAssertEqual(model.visibleUndoCandidate?.entryID, model.entries.first?.id)
    }

    func testActiveLedgerSignalRefreshCoalescesWithForegroundRefresh() async throws {
        let repository = try await makeRepository()
        let router = AppRouter()
        let manager = makeDependencyManager(repository: repository, router: router)
        let model = AppModel(repository: repository, reminderScheduler: IntentTestReminderScheduler())
        await model.loadInitialSnapshot()

        try await RecordTimeIntent(
            kind: .credit,
            hours: 0,
            minutes: 45,
            dependencyManager: manager
        ).persist(using: repository, notifying: router)
        XCTAssertEqual(router.ledgerChangeGeneration, 1)

        async let activeRefresh: Void = model.refreshAfterExternalLedgerChange()
        async let foregroundRefresh: Void = model.refreshAfterForegrounding()
        _ = await (activeRefresh, foregroundRefresh)

        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries.first?.kind, .credit)
        XCTAssertEqual(model.entries.first?.minutes, 45)
        XCTAssertEqual(model.undoCandidate?.entryID, model.entries.first?.id)
    }

    func testRecordIntentRefreshesQuickSurfaceProjectionBeforeReturning() async throws {
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            QuickSurfacePreferences(timerVisible: false, privacyMode: .showTotals)
        )
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributeLedger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let publishGate = IntentQuickSurfacePublishGate()
        let store = QuickSurfaceStateStoreV1(
            rootDirectory: root,
            faults: QuickSurfaceStateStoreFaults { point in
                publishGate.interceptFirstPublish(point)
            },
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(
                ledger: attributeLedger
            )
        )
        let entryDate = Date.now
        let quickSurfaceHost = QuickSurfaceHostController(
            repository: repository,
            capability: .available(store),
            calendar: .hourleaf,
            timeZone: .autoupdatingCurrent,
            now: { entryDate }
        )
        let refresher = QuickSurfaceIntentProjectionRefresher(
            repository: repository,
            quickSurfaceHost: quickSurfaceHost
        )
        let router = AppRouter()
        let manager = makeDependencyManager(repository: repository, router: router)

        let persistTask = Task {
            try await RecordTimeIntent(
                kind: .service,
                hours: 1,
                minutes: 15,
                date: entryDate,
                dependencyManager: manager
            ).persist(
                using: repository,
                notifying: router,
                refreshing: refresher
            )
        }

        await fulfillment(of: [publishGate.reachedExpectation], timeout: 2)
        XCTAssertTrue(publishGate.wasIntercepted)
        XCTAssertEqual(router.ledgerChangeGeneration, 0)
        publishGate.release()
        try await persistTask.value

        let state = try store.read()
        XCTAssertEqual(state.projection.privacyMode, .showTotals)
        XCTAssertEqual(state.projection.monthKey, MonthKey(entryDate, calendar: .hourleaf).key)
        XCTAssertEqual(state.projection.serviceMinutes, 75)
        XCTAssertEqual(state.projection.creditMinutes, 0)
        XCTAssertEqual(router.ledgerChangeGeneration, 1)
    }

    func testQuickSurfaceRefreshFailureCannotUndoShortcutWriteOrSuppressSignal() async throws {
        let repository = try await makeRepository()
        try await repository.saveQuickSurfacePreferences(
            QuickSurfacePreferences(timerVisible: false, privacyMode: .showTotals)
        )
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributeLedger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = QuickSurfaceStateStoreV1(
            rootDirectory: root,
            faults: QuickSurfaceStateStoreFaults { point in
                guard case .beforePublish = point else { return }
                throw QuickSurfaceStoreInjectedError.marker
            },
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(
                ledger: attributeLedger
            )
        )
        let entryDate = Date.now
        let quickSurfaceHost = QuickSurfaceHostController(
            repository: repository,
            capability: .available(store),
            calendar: .hourleaf,
            timeZone: .autoupdatingCurrent,
            now: { entryDate }
        )
        let refresher = QuickSurfaceIntentProjectionRefresher(
            repository: repository,
            quickSurfaceHost: quickSurfaceHost
        )
        let router = AppRouter()
        let manager = makeDependencyManager(repository: repository, router: router)

        try await RecordTimeIntent(
            kind: .credit,
            hours: 0,
            minutes: 45,
            date: entryDate,
            dependencyManager: manager
        ).persist(
            using: repository,
            notifying: router,
            refreshing: refresher
        )

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.count, 1)
        XCTAssertEqual(snapshot.activeEntries.first?.kind, .credit)
        XCTAssertEqual(snapshot.activeEntries.first?.minutes, 45)
        XCTAssertEqual(snapshot.entryRevisions.first?.source, EntryMutationSource.shortcut.rawValue)
        XCTAssertEqual(router.ledgerChangeGeneration, 1)
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .missingFile)
        }
    }

    func testEarlyLedgerSignalWaitsUntilInitialStartupIsReady() async throws {
        let repository = try await makeRepository()
        let router = AppRouter()
        let manager = makeDependencyManager(repository: repository, router: router)
        let model = AppModel(repository: repository, reminderScheduler: IntentTestReminderScheduler())
        await model.loadInitialSnapshot(markReady: false)
        XCTAssertEqual(model.startupState, .loading)

        try await RecordTimeIntent(
            kind: .service,
            hours: 0,
            minutes: 30,
            dependencyManager: manager
        ).persist(using: repository, notifying: router)
        XCTAssertEqual(router.ledgerChangeGeneration, 1)

        await model.refreshAfterExternalLedgerChange()
        XCTAssertTrue(model.entries.isEmpty)

        model.finishInitialLoad()
        await model.refreshAfterExternalLedgerChange()
        XCTAssertEqual(model.entries.first?.minutes, 30)
        XCTAssertEqual(model.undoCandidate?.entryID, model.entries.first?.id)
    }

    func testRouterRetainsEarlyRouteAndConsumesItOnce() {
        let router = AppRouter()
        router.route(to: .quickEntry)

        XCTAssertEqual(router.pendingRoute, .quickEntry)
        XCTAssertEqual(router.consumePendingRoute(), .quickEntry)
        XCTAssertNil(router.pendingRoute)
        XCTAssertNil(router.consumePendingRoute())
    }

    func testReminderDestinationRoutesOnlyKnownQuickEntry() {
        let router = AppRouter()

        ReminderNotificationDestination.route(userInfo: [:], using: router)
        ReminderNotificationDestination.route(
            userInfo: ["destination": "future-route"],
            using: router
        )
        ReminderNotificationDestination.route(
            userInfo: ["destination": 1],
            using: router
        )
        XCTAssertNil(router.pendingRoute)

        ReminderNotificationDestination.route(
            userInfo: ["destination": "quick-entry"],
            using: router
        )
        XCTAssertEqual(router.pendingRoute, .quickEntry)
    }

    func testDependencyRegistrationResolvesTheExactRepositoryRepeatedly() async throws {
        let repository = try await makeRepository()
        let router = AppRouter()
        let manager = AppDependencyManager()
        let registration = HourleafAppIntentDependencies.register(
            repository: repository,
            router: router,
            manager: manager
        )
        let first = registration.resolveRepository()
        let second = registration.resolveRepository()
        let model = AppModel(repository: repository, reminderScheduler: IntentTestReminderScheduler())

        XCTAssertTrue(first === repository)
        XCTAssertTrue(second === repository)
        XCTAssertTrue((model.repository as? CoreDataLedgerRepository) === repository)
        XCTAssertTrue(registration.resolveRouter() === router)

        let expectedIdentity = String(ObjectIdentifier(repository).hashValue)
        let resolvedFirst = try await RepositoryIdentityProbeIntent(manager: manager)
            .callAsFunction(donate: false)
        let resolvedSecond = try await RepositoryIdentityProbeIntent(manager: manager)
            .callAsFunction(donate: false)
        XCTAssertEqual(resolvedFirst, expectedIdentity)
        XCTAssertEqual(resolvedSecond, expectedIdentity)
    }

    func testExactlyThreeShortcutsArePromoted() {
        XCTAssertEqual(HourleafShortcuts.appShortcuts.count, 3)
    }

    private func makeRepository() async throws -> CoreDataLedgerRepository {
        try await makeRepository(
            ledgerStartMonth: MonthKey(Date.now, calendar: .hourleaf)
        )
    }

    private func makeRepository(
        ledgerStartMonth: MonthKey,
        clock: @escaping @Sendable () -> Date = { .now }
    ) async throws -> CoreDataLedgerRepository {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: clock
        )
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = ledgerStartMonth
        settings.baselineServiceYearStart = MonthKey(
            year: ledgerStartMonth.month >= 9 ? ledgerStartMonth.year : ledgerStartMonth.year - 1,
            month: 9
        )
        try await repository.saveSettings(settings)
        return repository
    }

    private func makeDependencyManager(
        repository: CoreDataLedgerRepository,
        router: AppRouter = AppRouter()
    ) -> AppDependencyManager {
        let manager = AppDependencyManager()
        HourleafAppIntentDependencies.register(
            repository: repository,
            router: router,
            manager: manager
        )
        return manager
    }

    @available(iOS 18.2, *)
    private func assertUnset(_ parameter: IntentParameter<Int>) {
        if case .unset = parameter.valueState { return }
        XCTFail("Promoted Add tiles must prompt for a duration before writing.")
    }

    private func assertValidationError(
        _ expected: EntryValidationError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected), but the intent succeeded.", file: file, line: line)
        } catch let error as EntryValidationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error).", file: file, line: line)
        }
    }

    private func assertMutationError(
        _ expected: EntryMutationError,
        operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected), but the intent succeeded.", file: file, line: line)
        } catch let error as EntryMutationError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected \(expected), got \(error).", file: file, line: line)
        }
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int
    ) -> Date {
        let components = DateComponents(
            calendar: .hourleaf,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return components.date!
    }
}

@MainActor
private final class IntentTestReminderScheduler: ReminderScheduling {
    func requestAuthorization() async throws -> Bool { true }
    func reschedule(_ reminders: [ReminderSchedule]) async throws {}
}

private final class IntentQuickSurfacePublishGate: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation = DispatchSemaphore(value: 0)
    private var didIntercept = false
    let reachedExpectation = XCTestExpectation(
        description: "Quick-surface projection reached its coordinated publish"
    )

    var wasIntercepted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didIntercept
    }

    func interceptFirstPublish(_ point: QuickSurfaceStateStoreFaultPoint) {
        guard case .beforePublish = point else { return }
        lock.lock()
        let shouldIntercept = !didIntercept
        didIntercept = true
        lock.unlock()
        guard shouldIntercept else { return }
        reachedExpectation.fulfill()
        continuation.wait()
    }

    func release() {
        continuation.signal()
    }
}

/// A test-target-only AppIntent exercises the framework's actual dependency
/// resolution context. It is not part of the app target or promoted shortcuts.
private struct RepositoryIdentityProbeIntent: AppIntent {
    typealias PerformResult = IntentResultContainer<String, Never, Never, Never>

    static var title: LocalizedStringResource { "Repository identity probe" }
    static var isDiscoverable: Bool { false }

    @AppDependency private var repository: CoreDataLedgerRepository

    init() {
        _repository = AppDependency()
    }

    init(manager: AppDependencyManager) {
        _repository = AppDependency(manager: manager)
    }

    func perform() async throws -> PerformResult {
        .result(value: String(ObjectIdentifier(repository).hashValue))
    }
}
