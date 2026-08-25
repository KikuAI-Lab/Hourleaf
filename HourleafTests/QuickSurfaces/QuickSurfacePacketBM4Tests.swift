import Foundation
import XCTest
@testable import Hourleaf

final class QuickSurfacePacketBM4Tests: XCTestCase {
    func testM4UnitTestHostBundleResolvesConfiguredAppGroup() throws {
        let hostBundle = [
            Bundle.main,
            Bundle(identifier: "com.kikuai.hourleaf")
        ]
        .compactMap { $0 }
        .first { bundle in
            bundle.object(forInfoDictionaryKey: HourleafAppGroupIdentifier.infoKey) != nil
        }
        guard let hostBundle else {
            return XCTFail("The hosted Hourleaf app bundle is unavailable.")
        }
        guard let hostBundleIdentifier = hostBundle.bundleIdentifier,
              !hostBundleIdentifier.isEmpty
        else {
            return XCTFail("The hosted Hourleaf app bundle identifier is unavailable.")
        }
        guard let appGroupIdentifier = hostBundle.object(
            forInfoDictionaryKey: HourleafAppGroupIdentifier.infoKey
        ) as? String,
        !appGroupIdentifier.isEmpty
        else {
            return XCTFail("The hosted Hourleaf app group identifier is unavailable.")
        }

        let expectedAppGroupIdentifier = "group.\(hostBundleIdentifier)"
        XCTAssertEqual(appGroupIdentifier, expectedAppGroupIdentifier)

        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-host-bundle")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        var resolvedIdentifier: String?
        let resolution = HourleafQuickSurfaceContainer.resolve(
            bundle: hostBundle,
            containerURL: { identifier in
                resolvedIdentifier = identifier
                return root
            }
        )
        XCTAssertEqual(resolvedIdentifier, expectedAppGroupIdentifier)
        XCTAssertEqual(resolution, .available(root))
    }

    func testM4ContainerResolutionIsTypedAndRedactsIdentifierAndPath() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-container")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let missingBundle = try makeBundle(root: root, values: [:])
        XCTAssertEqual(
            HourleafQuickSurfaceContainer.resolve(
                bundle: missingBundle,
                containerURL: { _ in root }
            ),
            .unavailable(.missingIdentifier)
        )

        let blankBundle = try makeBundle(
            root: root,
            name: "blank.bundle",
            values: [HourleafAppGroupIdentifier.infoKey: " \n"]
        )
        XCTAssertEqual(
            HourleafQuickSurfaceContainer.resolve(
                bundle: blankBundle,
                containerURL: { _ in root }
            ),
            .unavailable(.invalidIdentifier)
        )

        let nonStringBundle = try makeBundle(
            root: root,
            name: "non-string.bundle",
            values: [HourleafAppGroupIdentifier.infoKey: 42]
        )
        XCTAssertEqual(
            HourleafQuickSurfaceContainer.resolve(
                bundle: nonStringBundle,
                containerURL: { _ in root }
            ),
            .unavailable(.invalidIdentifier)
        )

        let identifier = "group.m4.test.redacted"
        let validBundle = try makeBundle(
            root: root,
            name: "valid.bundle",
            values: [HourleafAppGroupIdentifier.infoKey: identifier]
        )
        var receivedIdentifier: String?
        let resolved = HourleafQuickSurfaceContainer.resolve(
            bundle: validBundle,
            containerURL: { value in
                receivedIdentifier = value
                return root
            }
        )
        XCTAssertEqual(resolved, .available(root))
        XCTAssertEqual(receivedIdentifier, identifier)

        let unavailable = HourleafQuickSurfaceContainer.resolve(
            bundle: validBundle,
            containerURL: { _ in nil }
        )
        XCTAssertEqual(unavailable, .unavailable(.unavailable))
        XCTAssertEqual(
            HourleafQuickSurfaceContainer.resolve(
                bundle: validBundle,
                containerURL: { _ in URL(string: "https://example.invalid") }
            ),
            .unavailable(.unavailable)
        )
    }

    func testM4DisplayReducerRedactsHiddenTotalsAndMapsTimerPhases() throws {
        let hidden = QuickSurfaceStateV1(
            revision: 1,
            projection: try hiddenProjection(),
            timerEnabled: true,
            timer: .idle
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: hidden),
            QuickSurfaceDisplayStateV1(
                availability: .ready,
                totals: .absent,
                timer: .idle
            )
        )

        let shown = QuickSurfaceStateV1(
            revision: 2,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .showTotals,
                monthKey: "2026-08",
                timeZoneIdentifier: "Europe/Uzhgorod",
                serviceMinutes: 125,
                creditMinutes: 7,
                generatedAtEpochSeconds: 100
            ),
            timerEnabled: true,
            timer: .running(
                try .init(
                    sessionID: UUID(),
                    startedAtEpochSeconds: 90,
                    startedSystemUptimeSeconds: 10
                )
            )
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: shown),
            QuickSurfaceDisplayStateV1(
                availability: .ready,
                totals: .shown(
                    monthKey: "2026-08",
                    serviceMinutes: 125,
                    creditMinutes: 7,
                    bibleStudyCount: nil,
                    serviceYearMinutes: nil,
                    serviceYearTargetMinutes: nil
                ),
                timer: .running(startedAtEpochSeconds: 90)
            )
        )

        let review = QuickSurfaceStateV1(
            revision: 3,
            projection: try hiddenProjection(),
            timerEnabled: true,
            timer: try TimerSessionCommandV1.stop(
                state: shown,
                clock: .init(wallNowEpochSeconds: 200, uptimeNowSeconds: 110),
                mutationID: UUID(),
                entryID: UUID()
            ).timer
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: review).timer,
            .reviewPending
        )
        let disabled = QuickSurfaceStateV1(
            revision: 4,
            projection: try hiddenProjection(),
            timerEnabled: false,
            timer: review.timer
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: disabled).timer,
            .disabled
        )
        guard case let .reviewPending(reviewPayload) = review.timer else {
            return XCTFail("Expected review pending state")
        }
        let finalizing = try TimerSessionCommandV1.authorizeReview(
            state: review,
            expectedSessionID: reviewPayload.sessionID,
            expectedMutationID: reviewPayload.mutationID,
            expectedEntryID: reviewPayload.entryID,
            kind: .service,
            day: "2026-08-09",
            minutes: 5,
            authorizedAtEpochSeconds: 300
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(state: finalizing).timer,
            .finalizing
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(
                readResult: .failure(.protectedBeforeFirstUnlock)
            ).availability,
            .protected
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(
                readResult: .failure(.accessBusy)
            ),
            .fallback(.unavailable)
        )
        XCTAssertEqual(
            QuickSurfaceDisplayReducerV1.reduce(
                readResult: .failure(.corrupt)
            ),
            .fallback(.needsReset)
        )
    }

    func testM4ControlTransactionStartsStopsAndIsIdempotent() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-control")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        _ = try store.createIfAbsent(
            QuickSurfaceStateV1(
                revision: 1,
                projection: try hiddenProjection(),
                timerEnabled: true,
                timer: .idle
            )
        )

        let sessionID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let mutationID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let entryID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        var ids = [sessionID, mutationID, entryID]
        let transaction = QuickSurfaceTimerControlTransactionV1(
            clock: { .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20) },
            uuid: { ids.removeFirst() }
        )

        let idle = try store.read()
        XCTAssertEqual(
            transaction.perform(request: .stop, stateStore: store),
            .unchanged
        )
        XCTAssertEqual(try store.read(), idle)
        XCTAssertEqual(
            transaction.perform(request: .start, stateStore: store),
            .committed
        )
        let running = try store.read()
        XCTAssertEqual(running.revision, 2)
        XCTAssertEqual(
            transaction.perform(request: .start, stateStore: store),
            .unchanged
        )
        XCTAssertEqual(try store.read(), running)

        XCTAssertEqual(
            transaction.perform(request: .stop, stateStore: store),
            .committed
        )
        let review = try store.read()
        guard case let .reviewPending(payload) = review.timer else {
            return XCTFail("Expected review pending state")
        }
        XCTAssertEqual(payload.mutationID, mutationID)
        XCTAssertEqual(payload.entryID, entryID)
        XCTAssertEqual(
            transaction.perform(request: .stop, stateStore: store),
            .reviewRequired
        )
        XCTAssertEqual(
            transaction.perform(request: .start, stateStore: store),
            .reviewRequired
        )
        XCTAssertEqual(try store.read(), review)

        let finalizing = try TimerSessionCommandV1.authorizeReview(
            state: review,
            expectedSessionID: payload.sessionID,
            expectedMutationID: payload.mutationID,
            expectedEntryID: payload.entryID,
            kind: .service,
            day: "2026-08-09",
            minutes: 5,
            authorizedAtEpochSeconds: 300
        )
        _ = try store.replace { _ in finalizing }
        XCTAssertEqual(
            transaction.perform(request: .stop, stateStore: store),
            .reviewRequired
        )
        XCTAssertEqual(try store.read(), finalizing)
    }

    func testM4ControlTransactionFailsPrivateForDisabledClockBusyAndCorrupt() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-control-errors")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let attributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, attributes: attributes)
        _ = try store.createIfAbsent(
            QuickSurfaceStateV1(
                revision: 1,
                projection: try hiddenProjection(),
                timerEnabled: false,
                timer: .idle
            )
        )
        let disabled = QuickSurfaceTimerControlTransactionV1(
            clock: { .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20) }
        )
        XCTAssertEqual(
            disabled.perform(request: .start, stateStore: store),
            .failed(.disabled)
        )

        let runningStore = makeStore(root: root, attributes: attributes)
        _ = try runningStore.replace { current in
            guard let current else { throw QuickSurfaceStateStoreError.missingFile }
            return QuickSurfaceStateV1(
                revision: try current.nextRevision(),
                projection: current.projection,
                timerEnabled: true,
                timer: try TimerSessionCommandV1.start(
                    state: QuickSurfaceStateV1(
                        revision: current.revision,
                        projection: current.projection,
                        timerEnabled: true,
                        timer: .idle
                    ),
                    clock: .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20),
                    sessionID: UUID()
                ).timer
            )
        }
        let invalidClock = QuickSurfaceTimerControlTransactionV1(
            clock: { .init(wallNowEpochSeconds: -.infinity, uptimeNowSeconds: 20) }
        )
        let beforeInvalidClock = try runningStore.read()
        XCTAssertEqual(
            invalidClock.perform(request: .stop, stateStore: runningStore),
            .failed(.invalidClock)
        )
        XCTAssertEqual(try runningStore.read(), beforeInvalidClock)

        let lease = try runningStore.acquireExclusiveRestoreLease()
        defer { try? lease.release() }
        XCTAssertEqual(
            invalidClock.perform(request: .stop, stateStore: runningStore),
            .failed(.busy)
        )

        let corruptRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-corrupt")
        defer { QuickSurfaceStoreTestSupport.cleanup(corruptRoot) }
        let corruptAttributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let corruptStore = makeStore(root: corruptRoot, attributes: corruptAttributes)
        try QuickSurfaceStoreTestSupport.writeData(
            Data("not-json".utf8),
            to: QuickSurfaceStoreTestSupport.stateFileURL(root: corruptRoot)
        )
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: corruptRoot, ledger: corruptAttributes)
        XCTAssertEqual(
            disabled.perform(request: .start, stateStore: corruptStore),
            .failed(.corrupt)
        )

        let maxRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-revision")
        defer { QuickSurfaceStoreTestSupport.cleanup(maxRoot) }
        let maxAttributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let maxStore = makeStore(root: maxRoot, attributes: maxAttributes)
        let maxState = QuickSurfaceStateV1(
            revision: .max,
            projection: try hiddenProjection(),
            timerEnabled: true,
            timer: .idle
        )
        try QuickSurfaceStoreTestSupport.writeStateFile(maxState, root: maxRoot)
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: maxRoot, ledger: maxAttributes)
        XCTAssertEqual(
            transactionForTest().perform(request: .start, stateStore: maxStore),
            .failed(.revisionExhausted)
        )
        XCTAssertEqual(try maxStore.read(), maxState)

        let missingRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "m4-missing")
        defer { QuickSurfaceStoreTestSupport.cleanup(missingRoot) }
        let missingAttributes = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let missingStore = makeStore(root: missingRoot, attributes: missingAttributes)
        XCTAssertEqual(
            transactionForTest().perform(request: .start, stateStore: missingStore),
            .failed(.unavailable)
        )
    }

    private func transactionForTest() -> QuickSurfaceTimerControlTransactionV1 {
        QuickSurfaceTimerControlTransactionV1(
            clock: { .init(wallNowEpochSeconds: 100, uptimeNowSeconds: 20) },
            uuid: { UUID() }
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

    private func hiddenProjection() throws -> QuickSurfaceProjectionV1 {
        try QuickSurfaceProjectionV1(
            privacyMode: .hideTotals,
            monthKey: nil,
            timeZoneIdentifier: nil,
            serviceMinutes: nil,
            creditMinutes: nil,
            generatedAtEpochSeconds: 0
        )
    }

    private func makeBundle(
        root: URL,
        name: String = "empty.bundle",
        values: [String: Any]
    ) throws -> Bundle {
        let bundleURL = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let plistURL = bundleURL.appendingPathComponent("Info.plist")
        try (values as NSDictionary).write(to: plistURL)
        guard let bundle = Bundle(url: bundleURL) else {
            throw NSError(domain: "QuickSurfacePacketBM4Tests", code: 1)
        }
        return bundle
    }
}
