import XCTest
import Darwin
@testable import Hourleaf

final class QuickSurfaceStateStoreTests: XCTestCase {
    func testStateFileUsesExactFixedRelativePath() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let fileURL = QuickSurfaceStoreTestSupport.stateFileURL(root: root)
        XCTAssertEqual(
            Array(fileURL.pathComponents.suffix(QuickSurfaceStateStoreV1.relativePathComponents.count)),
            QuickSurfaceStateStoreV1.relativePathComponents
        )
    }

    func testReadMissingFileCreatesNothing() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let store = makeStore(root: root).store
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .missingFile)
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: QuickSurfaceStateStoreV1.lockFileURL(root: root).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: QuickSurfaceStoreTestSupport.stateFileURL(root: root).path
        ))
    }

    func testCreateReadAndUpdateRoundTripWithRequiredAttributes() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let context = makeStore(root: root)
        let store = context.store
        let initial = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        try store.write(initial)
        XCTAssertEqual(try store.read(), initial)

        let updated = try store.replace { current in
            let current = try XCTUnwrap(current)
            return try QuickSurfaceStoreTestSupport.makeShownState(
                revision: current.revision + 1,
                serviceMinutes: 180,
                creditMinutes: 10
            )
        }

        XCTAssertEqual(updated.revision, 2)
        XCTAssertEqual(try store.read(), updated)

        let fileURL = QuickSurfaceStoreTestSupport.stateFileURL(root: root)
        let directoryURL = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: root)
        let lockURL = QuickSurfaceStateStoreV1.lockFileURL(root: root)
        XCTAssertTrue(context.ledger.isBackupExcluded(fileURL))
        XCTAssertTrue(context.ledger.isBackupExcluded(directoryURL))
        XCTAssertTrue(context.ledger.isBackupExcluded(lockURL))
        XCTAssertTrue(context.ledger.isProtected(fileURL))
        XCTAssertTrue(context.ledger.isProtected(directoryURL))
        XCTAssertTrue(context.ledger.isProtected(lockURL))
        XCTAssertEqual(try Data(contentsOf: lockURL), Data())
        let lockAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let permissions = try XCTUnwrap(lockAttributes[.posixPermissions] as? NSNumber).uint16Value
        XCTAssertEqual(permissions & 0o777, 0o600)
        XCTAssertEqual(
            try XCTUnwrap(lockAttributes[.ownerAccountID] as? NSNumber).uint64Value,
            UInt64(geteuid())
        )
    }

    func testConcurrentCreateRacePublishesOnlyRevisionOneState() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let state = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let stores = [
            makeStore(root: root, ledger: ledger).store,
            makeStore(root: root, ledger: ledger).store
        ]

        let results = try await withThrowingTaskGroup(of: QuickSurfaceStateV1.self) { group in
            for store in stores {
                group.addTask {
                    try store.replace { current in
                        current ?? state
                    }
                }
            }

            var collected: [QuickSurfaceStateV1] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        XCTAssertEqual(results, [state, state])
        XCTAssertEqual(try makeStore(root: root, ledger: ledger).store.read(), state)
    }

    func testConcurrentDifferentCreatesReturnThePublishedWinner() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let hidden = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let shown = try QuickSurfaceStoreTestSupport.makeShownState(revision: 1)
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let stores = [
            makeStore(root: root, ledger: ledger).store,
            makeStore(root: root, ledger: ledger).store
        ]
        let candidates = [hidden, shown]

        let results = try await withThrowingTaskGroup(of: QuickSurfaceStateV1.self) { group in
            for (store, candidate) in zip(stores, candidates) {
                group.addTask {
                    try store.createIfAbsent(candidate)
                }
            }

            var collected: [QuickSurfaceStateV1] = []
            for try await value in group {
                collected.append(value)
            }
            return collected
        }

        let final = try makeStore(root: root, ledger: ledger).store.read()
        XCTAssertTrue(final == hidden || final == shown)
        XCTAssertTrue(results.allSatisfy { $0 == final })
    }

    func testConcurrentIncrementOperationsSerializeWithoutLostUpdates() async throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, ledger: ledger).store
        try store.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for iteration in 0..<12 {
                group.addTask {
                    let workerStore = QuickSurfaceStateStoreV1(
                        rootDirectory: root,
                        attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(ledger: ledger)
                    )
                    _ = try workerStore.replace { current in
                        let current = try XCTUnwrap(current)
                        return try QuickSurfaceStoreTestSupport.makeShownState(
                            revision: current.revision + 1,
                            serviceMinutes: 125 + iteration,
                            creditMinutes: 7 + iteration
                        )
                    }
                }
            }

            for try await _ in group {}
        }

        let final = try store.read()
        XCTAssertEqual(final.revision, 13)
    }

    func testSemanticNoOpReturnsCurrentWithoutChangingBytes() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let store = makeStore(root: root).store
        let initial = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        try store.write(initial)
        let before = try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))

        let returned = try store.replace { current in
            try XCTUnwrap(current)
        }

        let after = try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))
        XCTAssertEqual(returned, initial)
        XCTAssertEqual(before, after)
    }

    func testStrictWriteRejectsDifferentRevisionOneWinnerWithoutMutation() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let store = makeStore(root: root).store
        let winner = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let competing = try QuickSurfaceStoreTestSupport.makeShownState(revision: 1)
        try store.write(winner)
        let before = try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))

        XCTAssertThrowsError(try store.write(competing)) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .currentStateMismatch)
        }

        XCTAssertEqual(try store.read(), winner)
        XCTAssertEqual(
            try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root)),
            before
        )
    }

    func testTransformErrorIsPreservedWithoutCreatingState() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let store = makeStore(root: root).store
        XCTAssertThrowsError(try store.replace { _ in
            throw QuickSurfaceStoreInjectedError.marker
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStoreInjectedError, .marker)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: QuickSurfaceStoreTestSupport.stateFileURL(root: root).path
        ))
    }

    func testRevisionRulesRejectInvalidTransitions() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let store = makeStore(root: root).store
        XCTAssertThrowsError(try store.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 2))) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .invalidInitialRevision)
        }

        try store.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))
        XCTAssertThrowsError(try store.replace { _ in
            try QuickSurfaceStoreTestSupport.makeShownState(revision: 7)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .invalidRevisionTransition)
        }

        let maxRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "max-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(maxRoot) }
        let maxLedger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        try QuickSurfaceStoreTestSupport.writeStateFile(
            QuickSurfaceStateV1(
                revision: .max,
                projection: try QuickSurfaceProjectionV1(
                    privacyMode: .hideTotals,
                    monthKey: nil,
                    timeZoneIdentifier: nil,
                    serviceMinutes: nil,
                    creditMinutes: nil,
                    generatedAtEpochSeconds: 10
                ),
                timerEnabled: false,
                timer: .idle
            ),
            root: maxRoot
        )
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: maxRoot, ledger: maxLedger)
        let maxStore = makeStore(root: maxRoot, ledger: maxLedger).store
        XCTAssertThrowsError(try maxStore.replace { current in
            let current = try XCTUnwrap(current)
            return try QuickSurfaceStoreTestSupport.makeShownState(revision: current.revision)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .revisionUnavailable)
        }
    }

    func testCorruptUnsupportedAndOversizedFilesAreRejectedWithoutMutation() throws {
        let corruptRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "corrupt-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(corruptRoot) }
        let corruptFile = QuickSurfaceStoreTestSupport.stateFileURL(root: corruptRoot)
        let corruptBytes = Data("raw-marker-corrupt".utf8)
        try QuickSurfaceStoreTestSupport.writeData(corruptBytes, to: corruptFile)
        let corruptLedger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: corruptRoot, ledger: corruptLedger)
        let corruptStore = makeStore(root: corruptRoot, ledger: corruptLedger).store

        XCTAssertThrowsError(try corruptStore.replace { _ in
            try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .corrupt)
        }
        XCTAssertEqual(try Data(contentsOf: corruptFile), corruptBytes)

        let unsupportedRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "unsupported-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(unsupportedRoot) }
        let unsupportedState = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let unsupportedText = try XCTUnwrap(
            String(data: QuickSurfaceStateV1.encodeCanonical(unsupportedState), encoding: .utf8)
        ).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
        let unsupportedBytes = Data(unsupportedText.utf8)
        let unsupportedFile = QuickSurfaceStoreTestSupport.stateFileURL(root: unsupportedRoot)
        try QuickSurfaceStoreTestSupport.writeData(unsupportedBytes, to: unsupportedFile)
        let unsupportedLedger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: unsupportedRoot, ledger: unsupportedLedger)
        let unsupportedStore = makeStore(root: unsupportedRoot, ledger: unsupportedLedger).store

        XCTAssertThrowsError(try unsupportedStore.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .unsupportedVersion)
        }
        XCTAssertEqual(try Data(contentsOf: unsupportedFile), unsupportedBytes)

        let oversizedRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "oversized-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(oversizedRoot) }
        let oversizedFile = QuickSurfaceStoreTestSupport.stateFileURL(root: oversizedRoot)
        try QuickSurfaceStoreTestSupport.writeData(
            Data(repeating: 0x41, count: QuickSurfaceStateStoreV1.maximumFileBytes + 1),
            to: oversizedFile
        )
        let oversizedLedger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: oversizedRoot, ledger: oversizedLedger)
        let oversizedStore = makeStore(root: oversizedRoot, ledger: oversizedLedger).store
        XCTAssertThrowsError(try oversizedStore.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .corrupt)
        }
        XCTAssertEqual(
            try Data(contentsOf: oversizedFile),
            Data(repeating: 0x41, count: QuickSurfaceStateStoreV1.maximumFileBytes + 1)
        )
    }

    func testSymlinkedRootAncestorAndFileAreRejected() throws {
        let sandbox = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "symlink-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(sandbox) }

        let actualRoot = sandbox.appendingPathComponent("actual-root", isDirectory: true)
        try FileManager.default.createDirectory(at: actualRoot, withIntermediateDirectories: true)
        let rootLink = sandbox.appendingPathComponent("root-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: actualRoot)
        XCTAssertThrowsError(try makeStore(root: rootLink).store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .symlinkDetected)
        }

        let ancestorRoot = sandbox.appendingPathComponent("ancestor-root", isDirectory: true)
        let escapedDirectory = sandbox.appendingPathComponent("ancestor-root-escape", isDirectory: true)
        try FileManager.default.createDirectory(at: escapedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ancestorRoot, withIntermediateDirectories: true)
        let libraryLink = ancestorRoot.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: libraryLink, withDestinationURL: escapedDirectory)
        XCTAssertThrowsError(try makeStore(root: ancestorRoot).store.write(
            try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        )) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .symlinkDetected)
        }

        let fileRoot = sandbox.appendingPathComponent("file-root", isDirectory: true)
        let fileDirectory = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: fileRoot)
        let outsideFile = sandbox.appendingPathComponent("outside.json", isDirectory: false)
        try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
        try QuickSurfaceStoreTestSupport.writeData(Data("{}".utf8), to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: QuickSurfaceStoreTestSupport.stateFileURL(root: fileRoot),
            withDestinationURL: outsideFile
        )
        XCTAssertThrowsError(try makeStore(root: fileRoot).store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .symlinkDetected)
        }

        let danglingRoot = sandbox.appendingPathComponent("dangling-root", isDirectory: true)
        let danglingDirectory = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: danglingRoot)
        try FileManager.default.createDirectory(at: danglingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: QuickSurfaceStoreTestSupport.stateFileURL(root: danglingRoot),
            withDestinationURL: sandbox.appendingPathComponent("missing-target.json")
        )
        XCTAssertThrowsError(try makeStore(root: danglingRoot).store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .symlinkDetected)
        }
    }

    func testDirectoryAndFileAttributeFailuresUseInjectedSeams() throws {
        let directoryRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "dir-attr-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(directoryRoot) }
        let directoryURL = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: directoryRoot)
        let failingDirectoryStore = makeStore(
            root: directoryRoot,
            failSetBackupExclusion: { $0 == directoryURL }
        ).store
        XCTAssertThrowsError(try failingDirectoryStore.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .attributeApplyFailed)
        }

        let fileRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "file-attr-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(fileRoot) }
        let fileURL = QuickSurfaceStoreTestSupport.stateFileURL(root: fileRoot)
        let failingFileStore = makeStore(
            root: fileRoot,
            failSetProtection: { $0 == fileURL }
        ).store
        XCTAssertThrowsError(try failingFileStore.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .attributeApplyFailed)
        }
    }

    func testDirectoryAndFileAttributeReadbackFailuresAreTyped() throws {
        let directoryRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "dir-readback-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(directoryRoot) }
        let directoryURL = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: directoryRoot)
        let failingDirectoryStore = makeStore(
            root: directoryRoot,
            failReadBackupExclusion: { $0 == directoryURL }
        ).store
        XCTAssertThrowsError(try failingDirectoryStore.write(
            QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        )) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .backupExclusionReadbackFailed)
        }

        let fileRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "file-readback-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(fileRoot) }
        let fileURL = QuickSurfaceStoreTestSupport.stateFileURL(root: fileRoot)
        let failingFileStore = makeStore(
            root: fileRoot,
            failReadProtection: { $0 == fileURL }
        ).store
        XCTAssertThrowsError(try failingFileStore.write(
            QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        )) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .protectionReadbackFailed)
        }
    }

    func testBeforePublishFailureLeavesOldBytesIntact() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let initial = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        try makeStore(root: root, ledger: ledger).store.write(initial)
        let oldBytes = try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))

        let store = makeStore(
            root: root,
            ledger: ledger,
            faults: QuickSurfaceStateStoreFaults { point in
                if case .beforePublish = point {
                    throw QuickSurfaceStoreInjectedError.marker
                }
            }
        ).store

        XCTAssertThrowsError(try store.replace { current in
            let current = try XCTUnwrap(current)
            return try QuickSurfaceStoreTestSupport.makeShownState(revision: current.revision + 1)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStoreInjectedError, .marker)
        }

        XCTAssertEqual(try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root)), oldBytes)
    }

    func testAfterPublishFailureLeavesOldOrNewValidBytes() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let initial = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let updated = try QuickSurfaceStoreTestSupport.makeShownState(revision: 2)
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        try makeStore(root: root, ledger: ledger).store.write(initial)
        let oldBytes = try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))
        let newBytes = try QuickSurfaceStateV1.encodeCanonical(updated)

        let store = makeStore(
            root: root,
            ledger: ledger,
            faults: QuickSurfaceStateStoreFaults { point in
                if case .afterPublishBeforeReadback = point {
                    throw QuickSurfaceStoreInjectedError.marker
                }
            }
        ).store

        XCTAssertThrowsError(try store.replace { current in
            let current = try XCTUnwrap(current)
            return try QuickSurfaceStoreTestSupport.makeShownState(revision: current.revision + 1)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStoreInjectedError, .marker)
        }

        let finalBytes = try Data(contentsOf: QuickSurfaceStoreTestSupport.stateFileURL(root: root))
        XCTAssertTrue(finalBytes == oldBytes || finalBytes == newBytes)
        if finalBytes == newBytes {
            XCTAssertEqual(try makeStore(root: root, ledger: ledger).store.read(), updated)
        }
    }

    func testReadbackMismatchIsReportedWhenPublishedBytesChange() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot()
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }

        let initial = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        try makeStore(root: root, ledger: ledger).store.write(initial)
        let alternate = try QuickSurfaceStoreTestSupport.makeShownState(revision: 3, serviceMinutes: 333, creditMinutes: 44)

        let store = makeStore(
            root: root,
            ledger: ledger,
            faults: QuickSurfaceStateStoreFaults { point in
                if case let .afterPublishBeforeReadback(targetURL) = point {
                    try QuickSurfaceStoreTestSupport.writeData(
                        QuickSurfaceStateV1.encodeCanonical(alternate),
                        to: targetURL
                    )
                }
            }
        ).store

        XCTAssertThrowsError(try store.replace { current in
            let current = try XCTUnwrap(current)
            return try QuickSurfaceStoreTestSupport.makeShownState(revision: current.revision + 1)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .readbackMismatch)
        }
    }

    func testErrorDescriptionsAreSanitized() throws {
        let marker = "USER_MARKER_DO_NOT_LEAK"
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: marker)
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        try QuickSurfaceStoreTestSupport.writeData(
            Data(marker.utf8),
            to: QuickSurfaceStoreTestSupport.stateFileURL(root: root)
        )

        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        QuickSurfaceStoreTestSupport.primeRequiredAttributes(root: root, ledger: ledger)
        let store = makeStore(root: root, ledger: ledger).store
        XCTAssertThrowsError(try store.read()) { error in
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(marker))
            XCTAssertFalse(description.contains(NSHomeDirectory()))
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .corrupt)
        }
    }

    func testSharedLeasesCanCoexistAndConflictWithExclusiveLeases() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-shared-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let directory = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = QuickSurfaceStateStoreV1.lockFileURL(root: root)

        let firstShared = try QuickSurfaceStateStoreLease.acquire(
            mode: .shared,
            rootURL: root,
            lockURL: lockURL
        )
        let secondShared = try QuickSurfaceStateStoreLease.acquire(
            mode: .shared,
            rootURL: root,
            lockURL: lockURL
        )
        XCTAssertThrowsError(try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: root,
            lockURL: lockURL
        )) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }

        try firstShared.release()
        try secondShared.release()
        let exclusive = try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: root,
            lockURL: lockURL
        )
        XCTAssertThrowsError(try QuickSurfaceStateStoreLease.acquire(
            mode: .shared,
            rootURL: root,
            lockURL: lockURL
        )) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        XCTAssertThrowsError(try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: root,
            lockURL: lockURL
        )) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        try exclusive.release()
    }

    func testDifferentRootsDoNotContend() throws {
        let firstRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-root-a-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(firstRoot) }
        let secondRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-root-b-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(secondRoot) }
        for root in [firstRoot, secondRoot] {
            try FileManager.default.createDirectory(
                at: QuickSurfaceStoreTestSupport.stateDirectoryURL(root: root),
                withIntermediateDirectories: true
            )
        }

        let first = try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: firstRoot,
            lockURL: QuickSurfaceStateStoreV1.lockFileURL(root: firstRoot)
        )
        let second = try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: secondRoot,
            lockURL: QuickSurfaceStateStoreV1.lockFileURL(root: secondRoot)
        )
        try first.release()
        try second.release()
    }

    func testOrdinaryStoreOperationsFailClosedDuringExclusiveLease() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-ordinary-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let first = makeStore(root: root, ledger: ledger).store
        let second = makeStore(root: root, ledger: ledger).store
        try first.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))
        let lease = try first.acquireExclusiveRestoreLease()
        defer { try? lease.release() }

        XCTAssertThrowsError(try second.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        XCTAssertThrowsError(try second.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        XCTAssertThrowsError(try second.createIfAbsent(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        XCTAssertThrowsError(try second.replace { _ in
            XCTFail("A transform must not run while the exclusive lease is held")
            return try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 2)
        }) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        XCTAssertThrowsError(try second.removeStateFile()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }

        try lease.release()
        let expected = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        XCTAssertEqual(try second.read(), expected)
    }

    func testLeasedViewSkipsRecursiveSharedAcquisition() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-view-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, ledger: ledger).store
        try store.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))

        let lease = try store.acquireExclusiveRestoreLease()
        let view = try store.leasedView(using: lease)
        let expected = try QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1)
        XCTAssertEqual(try view.read(), expected)
        let updated = try view.replace { current in
            let current = try XCTUnwrap(current)
            return try QuickSurfaceStoreTestSupport.makeHiddenState(revision: current.revision + 1)
        }
        XCTAssertEqual(updated.revision, 2)
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .accessBusy)
        }
        try lease.release()
        XCTAssertEqual(try store.read(), updated)
    }

    func testLeasedViewRejectsReleasedAndMismatchedLeases() throws {
        let firstRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-mismatch-a-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(firstRoot) }
        let secondRoot = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-mismatch-b-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(secondRoot) }
        let first = makeStore(root: firstRoot).store
        let second = makeStore(root: secondRoot).store
        try first.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))
        try second.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))

        let firstLease = try first.acquireExclusiveRestoreLease()
        XCTAssertThrowsError(try second.leasedView(using: firstLease)) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .leaseRootMismatch)
        }
        try firstLease.release()
        XCTAssertThrowsError(try first.leasedView(using: firstLease)) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .leaseReleased)
        }
    }

    func testExistingLockSymlinkDirectoryAndUnsafePermissionsFailClosed() throws {
        let sandbox = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-lock-shapes-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(sandbox) }

        let symlinkRoot = sandbox.appendingPathComponent("symlink", isDirectory: true)
        let symlinkDirectory = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: symlinkRoot)
        try FileManager.default.createDirectory(at: symlinkDirectory, withIntermediateDirectories: true)
        let symlinkTarget = sandbox.appendingPathComponent("outside.lock", isDirectory: false)
        try Data().write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(
            at: QuickSurfaceStateStoreV1.lockFileURL(root: symlinkRoot),
            withDestinationURL: symlinkTarget
        )
        XCTAssertThrowsError(try makeStore(root: symlinkRoot).store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .symlinkDetected)
        }

        let directoryRoot = sandbox.appendingPathComponent("directory", isDirectory: true)
        let lockDirectory = QuickSurfaceStateStoreV1.lockFileURL(root: directoryRoot)
        try FileManager.default.createDirectory(at: lockDirectory, withIntermediateDirectories: true)
        XCTAssertThrowsError(try makeStore(root: directoryRoot).store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .lockFileInvalid)
        }

        let unsafeRoot = sandbox.appendingPathComponent("unsafe", isDirectory: true)
        let unsafeDirectory = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: unsafeRoot)
        try FileManager.default.createDirectory(at: unsafeDirectory, withIntermediateDirectories: true)
        let unsafeLock = QuickSurfaceStateStoreV1.lockFileURL(root: unsafeRoot)
        try Data().write(to: unsafeLock)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unsafeLock.path)
        XCTAssertThrowsError(try makeStore(root: unsafeRoot).store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .lockFileInvalid)
        }
    }

    func testResetLeavesPersistentLockInodeIntact() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-reset-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, ledger: ledger).store
        try store.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))
        let lockURL = QuickSurfaceStateStoreV1.lockFileURL(root: root)
        let before = try QuickSurfaceStoreTestSupport.fileIdentity(at: lockURL)

        try store.removeStateFile()
        XCTAssertFalse(FileManager.default.fileExists(atPath: QuickSurfaceStoreTestSupport.stateFileURL(root: root).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
        XCTAssertEqual(try QuickSurfaceStoreTestSupport.fileIdentity(at: lockURL), before)
        XCTAssertThrowsError(try store.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .missingFile)
        }
    }

    func testLeasedViewRejectsLockInodeReplacement() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-inode-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let ledger = QuickSurfaceStoreTestSupport.makeAttributeLedger()
        let store = makeStore(root: root, ledger: ledger).store
        try store.write(QuickSurfaceStoreTestSupport.makeHiddenState(revision: 1))
        let lease = try store.acquireExclusiveRestoreLease()
        let view = try store.leasedView(using: lease)
        let lockURL = QuickSurfaceStateStoreV1.lockFileURL(root: root)
        let replacement = lockURL.deletingLastPathComponent().appendingPathComponent("replacement.lock")
        try Data().write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.moveItem(at: replacement, to: lockURL)

        XCTAssertThrowsError(try view.read()) { error in
            XCTAssertEqual(error as? QuickSurfaceStateStoreError, .leaseIdentityMismatch)
        }
        try lease.release()
    }

    func testLeaseDeinitReleasesAdvisoryLock() throws {
        let root = try QuickSurfaceStoreTestSupport.makeSandboxRoot(name: "lease-deinit-\(UUID().uuidString)")
        defer { QuickSurfaceStoreTestSupport.cleanup(root) }
        let directory = QuickSurfaceStoreTestSupport.stateDirectoryURL(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockURL = QuickSurfaceStateStoreV1.lockFileURL(root: root)
        var lease: QuickSurfaceStateStoreLease? = try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: root,
            lockURL: lockURL
        )
        XCTAssertNotNil(lease)
        lease = nil
        let next = try QuickSurfaceStateStoreLease.acquire(
            mode: .exclusive,
            rootURL: root,
            lockURL: lockURL
        )
        try next.release()
    }

    private func makeStore(
        root: URL,
        ledger: QuickSurfaceStoreAttributeLedger? = nil,
        faults: QuickSurfaceStateStoreFaults = .init(),
        failSetBackupExclusion: (@Sendable (URL) -> Bool)? = nil,
        failSetProtection: (@Sendable (URL) -> Bool)? = nil,
        failReadBackupExclusion: (@Sendable (URL) -> Bool)? = nil,
        failReadProtection: (@Sendable (URL) -> Bool)? = nil
    ) -> (store: QuickSurfaceStateStoreV1, ledger: QuickSurfaceStoreAttributeLedger) {
        let ledger = ledger ?? QuickSurfaceStoreTestSupport.makeAttributeLedger()
        return (
            QuickSurfaceStateStoreV1(
                rootDirectory: root,
                faults: faults,
                attributeIO: QuickSurfaceStoreTestSupport.simulatedAttributeIO(
                    ledger: ledger,
                    failSetBackupExclusion: failSetBackupExclusion,
                    failSetProtection: failSetProtection,
                    failReadBackupExclusion: failReadBackupExclusion,
                    failReadProtection: failReadProtection
                )
            ),
            ledger
        )
    }
}

private extension QuickSurfaceStoreTestSupport {
    static func fileIdentity(at url: URL) throws -> QuickSurfaceStateStoreFileIdentity {
        var metadata = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &metadata)
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return QuickSurfaceStateStoreFileIdentity(metadata)
    }
}
