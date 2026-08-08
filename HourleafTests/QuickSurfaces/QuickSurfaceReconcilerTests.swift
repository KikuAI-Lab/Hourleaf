import Foundation
import XCTest
@testable import Hourleaf

final class QuickSurfaceReconcilerTests: XCTestCase {
    func testBootstrapCreatesRevisionOneWithCurrentMonthActiveTotals() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let now = date(year: 2026, month: 8, day: 3, hour: 10)
        let reconciler = makeReconciler(store: store, now: now)
        let snapshot = makeSnapshot(
            entries: [
                entry(kind: .service, day: .init(year: 2026, month: 8, day: 1), minutes: 75),
                entry(kind: .credit, day: .init(year: 2026, month: 8, day: 2), minutes: 20),
                entry(kind: .service, day: .init(year: 2026, month: 8, day: 2), minutes: 40, deleted: true),
                entry(kind: .service, day: .init(year: 2026, month: 7, day: 31), minutes: 90)
            ],
            preferences: .init(timerVisible: true, privacyMode: .showTotals)
        )

        let state = try reconciler.bootstrap(snapshot: snapshot)

        XCTAssertEqual(state.revision, 1)
        XCTAssertTrue(state.timerEnabled)
        XCTAssertEqual(state.timer, .idle)
        XCTAssertEqual(state.projection.privacyMode, .showTotals)
        XCTAssertEqual(state.projection.monthKey, "2026-08")
        XCTAssertEqual(state.projection.timeZoneIdentifier, timeZone.identifier)
        XCTAssertEqual(state.projection.serviceMinutes, 75)
        XCTAssertEqual(state.projection.creditMinutes, 20)
        XCTAssertEqual(state.projection.generatedAtEpochSeconds, now.timeIntervalSince1970)
    }

    func testBootstrapReconcilesWinningStateHostFieldsAndPreservesTimer() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let existing = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(service: 5, credit: 2, generatedAt: 100),
            timerEnabled: true,
            timer: .running(
                try .init(
                    sessionID: UUID(),
                    startedAtEpochSeconds: 90,
                    startedSystemUptimeSeconds: 10
                )
            )
        )
        _ = try store.createIfAbsent(existing)

        let result = try makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3))
            .bootstrap(
                snapshot: makeSnapshot(
                    entries: [entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 30)],
                    preferences: .init(timerVisible: false, privacyMode: .hideTotals)
                )
            )

        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.projection.privacyMode, .hideTotals)
        XCTAssertNil(result.projection.monthKey)
        XCTAssertNil(result.projection.serviceMinutes)
        XCTAssertNil(result.projection.creditMinutes)
        XCTAssertTrue(result.timerEnabled)
        XCTAssertEqual(result.timer, existing.timer)
        XCTAssertEqual(try store.read(), result)
    }

    func testOrdinaryReconcileNeverElevatesHiddenOrDisabledState() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try hiddenProjection(generatedAt: 100),
            timerEnabled: false,
            timer: .idle
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            entries: [entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 30)],
            preferences: .init(timerVisible: true, privacyMode: .showTotals)
        )
        let reconciler = makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3, hour: 11))

        let ordinary = try reconciler.reconcile(snapshot: snapshot)
        let explicit = try reconciler.reconcile(snapshot: snapshot, permitElevation: true)

        XCTAssertEqual(ordinary, initial)
        XCTAssertEqual(explicit.revision, 2)
        XCTAssertTrue(explicit.timerEnabled)
        XCTAssertEqual(explicit.projection.privacyMode, .showTotals)
        XCTAssertEqual(explicit.projection.serviceMinutes, 30)
    }

    func testOrdinaryReconcileReducesExposureAndPreservesActiveTimer() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let running = try TimerSessionV1.Running(
            sessionID: UUID(),
            startedAtEpochSeconds: 100,
            startedSystemUptimeSeconds: 10
        )
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(service: 5, credit: 2, generatedAt: 100),
            timerEnabled: true,
            timer: .running(running)
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            entries: [entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 30)],
            preferences: .init(timerVisible: false, privacyMode: .hideTotals)
        )

        let result = try makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3, hour: 12))
            .reconcile(snapshot: snapshot)

        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.projection.privacyMode, .hideTotals)
        XCTAssertNil(result.projection.monthKey)
        XCTAssertNil(result.projection.serviceMinutes)
        XCTAssertNil(result.projection.creditMinutes)
        XCTAssertTrue(result.timerEnabled)
        XCTAssertEqual(result.timer, .running(running))
    }

    func testReconcileCanHideExistingTotalsWhenWallClockIsInvalid() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let running = try TimerSessionV1.Running(
            sessionID: UUID(),
            startedAtEpochSeconds: 100,
            startedSystemUptimeSeconds: 10
        )
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(service: 45, credit: 15, generatedAt: 100),
            timerEnabled: true,
            timer: .running(running)
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            preferences: .init(timerVisible: false, privacyMode: .hideTotals)
        )

        let result = try makeReconciler(
            store: store,
            now: Date(timeIntervalSince1970: -1)
        ).reconcile(snapshot: snapshot)

        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.projection.privacyMode, .hideTotals)
        XCTAssertNil(result.projection.monthKey)
        XCTAssertNil(result.projection.timeZoneIdentifier)
        XCTAssertNil(result.projection.serviceMinutes)
        XCTAssertNil(result.projection.creditMinutes)
        XCTAssertEqual(result.projection.generatedAtEpochSeconds, 100)
        XCTAssertTrue(result.timerEnabled)
        XCTAssertEqual(result.timer, .running(running))
        XCTAssertEqual(try store.read(), result)
    }

    func testReconcileStillRejectsShownProjectionWhenWallClockIsInvalid() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(service: 45, credit: 15, generatedAt: 100),
            timerEnabled: true,
            timer: .idle
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            preferences: .init(timerVisible: true, privacyMode: .showTotals)
        )

        XCTAssertThrowsError(
            try makeReconciler(
                store: store,
                now: Date(timeIntervalSince1970: -1)
            ).reconcile(snapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? QuickSurfaceReconcilerError, .invalidGeneratedAt)
        }
        XCTAssertEqual(try store.read(), initial)
    }

    func testReconcileDoesNotChurnRevisionForSameProjectionContent() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(service: 30, credit: 0, generatedAt: 100),
            timerEnabled: true,
            timer: .idle
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            entries: [entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 30)],
            preferences: .init(timerVisible: true, privacyMode: .showTotals)
        )

        let result = try makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3, hour: 12))
            .reconcile(snapshot: snapshot)

        XCTAssertEqual(result, initial)
    }

    func testReconcileReplacesFutureGeneratedAtRatherThanKeepingItForever() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let now = date(year: 2026, month: 8, day: 3, hour: 12)
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(
                service: 30,
                credit: 0,
                generatedAt: now.timeIntervalSince1970 + 60
            ),
            timerEnabled: true,
            timer: .idle
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            entries: [entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 30)],
            preferences: .init(timerVisible: true, privacyMode: .showTotals)
        )

        let result = try makeReconciler(store: store, now: now).reconcile(snapshot: snapshot)

        XCTAssertEqual(result.revision, 2)
        XCTAssertEqual(result.projection.generatedAtEpochSeconds, now.timeIntervalSince1970)
    }

    func testProjectionOverflowFailsClosedWithNewHiddenState() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let snapshot = makeSnapshot(
            entries: [
                entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: Int(Int32.max)),
                entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 1)
            ],
            preferences: .init(timerVisible: false, privacyMode: .showTotals)
        )

        XCTAssertThrowsError(
            try makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3))
                .reconcile(snapshot: snapshot, permitElevation: true)
        ) { error in
            XCTAssertEqual(error as? QuickSurfaceReconcilerError, .projectionTotalsUnavailable)
        }
        let state = try store.read()
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.projection.privacyMode, .hideTotals)
        XCTAssertNil(state.projection.monthKey)
        XCTAssertNil(state.projection.serviceMinutes)
        XCTAssertNil(state.projection.creditMinutes)
        XCTAssertFalse(state.timerEnabled)
        XCTAssertEqual(state.timer, .idle)
    }

    func testProjectionOverflowRedactsExistingShownStateAndPreservesTimer() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let store = makeStore(root: root)
        let running = try TimerSessionV1.Running(
            sessionID: UUID(),
            startedAtEpochSeconds: 100,
            startedSystemUptimeSeconds: 10
        )
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: try shownProjection(service: 30, credit: 0, generatedAt: 100),
            timerEnabled: true,
            timer: .running(running)
        )
        _ = try store.createIfAbsent(initial)
        let snapshot = makeSnapshot(
            entries: [
                entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: Int(Int32.max)),
                entry(kind: .service, day: .init(year: 2026, month: 8, day: 3), minutes: 1)
            ],
            preferences: .init(timerVisible: true, privacyMode: .showTotals)
        )

        XCTAssertThrowsError(
            try makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3))
                .reconcile(snapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? QuickSurfaceReconcilerError, .projectionTotalsUnavailable)
        }

        let state = try store.read()
        XCTAssertEqual(state.revision, 2)
        XCTAssertEqual(state.projection.privacyMode, .hideTotals)
        XCTAssertNil(state.projection.monthKey)
        XCTAssertNil(state.projection.timeZoneIdentifier)
        XCTAssertNil(state.projection.serviceMinutes)
        XCTAssertNil(state.projection.creditMinutes)
        XCTAssertTrue(state.timerEnabled)
        XCTAssertEqual(state.timer, .running(running))
    }

    func testCorruptStateFailsClosedWithoutReplacingBytes() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = QuickSurfaceStateStoreV1(
            rootDirectory: root,
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
        )
        let fileURL = QuickSurfaceStoreTestSupport.stateFileURL(root: root)
        let corrupt = Data("not quick-surface json".utf8)
        try QuickSurfaceStoreTestSupport.writeData(corrupt, to: fileURL)
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: attributes)
        let snapshot = makeSnapshot(preferences: .init(timerVisible: false, privacyMode: .hideTotals))

        XCTAssertThrowsError(
            try makeReconciler(store: store, now: date(year: 2026, month: 8, day: 3))
                .reconcile(snapshot: snapshot)
        ) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .corrupt)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupt)
    }

    private let timeZone = TimeZone(identifier: "Europe/Uzhgorod")!

    private func makeStore(root: URL) -> QuickSurfaceStateStoreV1 {
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        return QuickSurfaceStateStoreV1(
            rootDirectory: root,
            attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: attributes)
        )
    }

    private func makeReconciler(
        store: QuickSurfaceStateStoreV1,
        now: Date
    ) -> QuickSurfaceReconciler {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return QuickSurfaceReconciler(
            stateStore: store,
            calendar: calendar,
            timeZone: timeZone,
            clock: { now }
        )
    }

    private func makeSnapshot(
        entries: [LedgerEntryRecord] = [],
        preferences: QuickSurfacePreferences = .init()
    ) -> LedgerSnapshot {
        LedgerSnapshot(
            entries: entries,
            settings: .init(),
            settingsMetadata: .init(
                id: UUID(),
                dataRevision: 2,
                planningVisible: false,
                quietGapCheckEnabled: false,
                quietGapDays: 7,
                timerVisible: preferences.timerVisible,
                syncMode: "local",
                widgetPrivacyMode: preferences.privacyMode.rawValue,
                lastPurgeAt: nil
            ),
            policies: [],
            reminders: [],
            reportSnapshots: [],
            reportStates: [],
            entryRevisions: [],
            presets: [],
            dayAcknowledgements: [],
            serviceYearArchives: []
        )
    }

    private func entry(
        kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        deleted: Bool = false
    ) -> LedgerEntryRecord {
        LedgerEntryRecord(
            entry: TimeEntry(
                kind: kind,
                day: day,
                minutes: minutes,
                note: "private note sentinel",
                createdAt: date(year: 2026, month: 1, day: 1),
                updatedAt: date(year: 2026, month: 1, day: 1)
            ),
            deletedAt: deleted ? date(year: 2026, month: 8, day: 3) : nil,
            source: EntryMutationSource.appQuickEntry.rawValue,
            revision: 1,
            lastMutationID: UUID()
        )
    }

    private func hiddenProjection(generatedAt: Double) throws -> QuickSurfaceProjectionV1 {
        try .init(
            privacyMode: .hideTotals,
            monthKey: nil,
            timeZoneIdentifier: nil,
            serviceMinutes: nil,
            creditMinutes: nil,
            generatedAtEpochSeconds: generatedAt
        )
    }

    private func shownProjection(
        service: Int,
        credit: Int,
        generatedAt: Double
    ) throws -> QuickSurfaceProjectionV1 {
        try .init(
            privacyMode: .showTotals,
            monthKey: "2026-08",
            timeZoneIdentifier: timeZone.identifier,
            serviceMinutes: service,
            creditMinutes: credit,
            generatedAtEpochSeconds: generatedAt
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
