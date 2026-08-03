import CryptoKit
@preconcurrency import CoreData
import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class HourleafRestorePreparationTests: XCTestCase {
    func testPrepareImportsAllTenEntitiesAndReturnsOnlyAggregatePreview() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("fixture.hourleafbackup")
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let exportedAt = Date(timeIntervalSinceReferenceDate: 99)
        let sourceData = try RestoreFixture.backupData(exportedAt: exportedAt)
        try sourceData.write(to: source)

        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let liveBefore = try await repository.portableBackupRecords()
        let protection = RecordingProtectionReader(value: expectedProtectionClass)
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: protection
        )

        let preview = try await coordinator.prepare(from: source)
        XCTAssertEqual(preview.exportedAt, exportedAt)
        XCTAssertEqual(preview.formatVersion, 1)
        XCTAssertEqual(preview.activeEntryCount, 2)
        XCTAssertEqual(preview.deletedEntryCount, 1)
        XCTAssertEqual(
            preview.entryDateRange,
            RestoreDateRange(firstLocalDay: "2026-07-12", lastLocalDay: "2026-07-14")
        )
        XCTAssertEqual(preview.noteCount, 1, "Deleted-entry notes must not appear in the current-note count.")
        XCTAssertEqual(preview.reminderCount, 1)
        XCTAssertEqual(preview.receiptCount, 2)
        XCTAssertEqual(preview.archiveCount, 2)

        let expectedRecords = RestoreFixture.records()
        let expectedDigest = try HourleafBackupCodec.storeDigest(expectedRecords)
        let stagedDigest = await coordinator.stagedRecordsDigest(for: preview.candidateID)
        XCTAssertEqual(stagedDigest, expectedDigest)
        XCTAssertTrue(protection.inspectedNames().contains(where: { $0.hasSuffix(".hourleafbackup") }))
        XCTAssertTrue(protection.inspectedNames().contains(where: { $0.hasSuffix(".sqlite") }))

        let liveAfter = try await repository.portableBackupRecords()
        XCTAssertEqual(
            try HourleafBackupCodec.storeDigest(liveAfter),
            try HourleafBackupCodec.storeDigest(liveBefore),
            "Preview preparation must not touch the live store."
        )

        try await coordinator.discardCandidate(preview.candidateID)
        try assertOnlyDestroyedStoreSlot(in: root)
    }

    func testCloudAndInMemoryModesRejectBeforeCreatingStagingDirectory() async throws {
        for mode in [PersistentStoreMode.privateCloudSQLite, .inMemory] {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent("restore", isDirectory: true)
            let source = sandbox.appendingPathComponent("missing.hourleafbackup")
            let liveStore = try await makeLiveStore(in: sandbox)
            defer { liveStore.close() }
            let (persistence, repository) = liveStore.dependencies
            let coordinator = HourleafRestoreCoordinator(
                persistence: persistence,
                repository: repository,
                rootDirectory: root,
                protectionReader: RecordingProtectionReader(value: expectedProtectionClass),
                liveStoreMode: { mode }
            )

            do {
                _ = try await coordinator.prepare(from: source)
                XCTFail("Non-local live mode must reject before staging.")
            } catch let error as HourleafRestoreError {
                if mode == .privateCloudSQLite {
                    XCTAssertEqual(error, .cloudStoreUnsupported)
                } else {
                    XCTAssertEqual(error, .preparationFailed)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        }
    }

    func testWrongExtensionDirectoryAndSymlinkNeverPreview() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass)
        )

        let wrongExtension = sandbox.appendingPathComponent("fixture.json")
        try RestoreFixture.backupData().write(to: wrongExtension)
        await assertPreparationFails(coordinator, source: wrongExtension, expected: .invalidFileSelection)

        let directory = sandbox.appendingPathComponent("directory.hourleafbackup", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        await assertPreparationFails(coordinator, source: directory, expected: .invalidFileSelection)

        let target = sandbox.appendingPathComponent("target.hourleafbackup")
        try RestoreFixture.backupData().write(to: target)
        let symlink = sandbox.appendingPathComponent("symlink.hourleafbackup")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        await assertPreparationFails(coordinator, source: symlink, expected: .invalidFileSelection)
        XCTAssertEqual(try contentsIfPresent(root), [])
    }

    func testSymlinkStagingRootIsRejectedBeforeProtectionOrStagingMutation() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("fixture.hourleafbackup")
        try RestoreFixture.backupData().write(to: source)
        let actualDirectory = sandbox.appendingPathComponent("actual-root", isDirectory: true)
        try FileManager.default.createDirectory(at: actualDirectory, withIntermediateDirectories: false)
        let sentinel = actualDirectory.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        let symlinkRoot = sandbox.appendingPathComponent("restore-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: actualDirectory
        )
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let protection = RecordingProtectionReader(value: expectedProtectionClass)
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: symlinkRoot,
            protectionReader: protection
        )

        await assertPreparationFails(coordinator, source: source, expected: .preparationFailed)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
        XCTAssertEqual(try contentsIfPresent(actualDirectory), ["sentinel"])
        XCTAssertEqual(protection.inspectedNames(), [])
    }

    func testCorruptNoncanonicalVersionChecksumAndGraphInputsNeverPreview() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass)
        )
        let valid = try RestoreFixture.backupData()
        var graphRecords = RestoreFixture.records()
        graphRecords.revisions.removeLast()
        let invalidGraphContent = HourleafBackupContentV1(exportedAt: 99, records: graphRecords)
        let wrongVersionContent = HourleafBackupContentV1(
            format: HourleafBackupV1.format,
            version: 99,
            exportedAt: 99,
            records: RestoreFixture.records()
        )

        let cases: [(String, Data)] = [
            ("corrupt", Data("not-json".utf8)),
            ("noncanonical", Data([0x20]) + valid),
            ("version", try uncheckedEnvelopeData(content: wrongVersionContent)),
            ("checksum", try checksumMismatchData(from: valid)),
            ("graph", try uncheckedEnvelopeData(content: invalidGraphContent))
        ]
        for (name, data) in cases {
            let source = sandbox.appendingPathComponent("\(name).hourleafbackup")
            try data.write(to: source)
            await assertPreparationFails(coordinator, source: source, expected: .preparationFailed)
            XCTAssertEqual(try contentsIfPresent(root), [], "\(name) left a staged artifact")
        }
    }

    func testBoundedReaderRejectsExactlyLimitPlusOneAndCleansPartial() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("oversized.hourleafbackup")
        try Data(
            repeating: 0x61,
            count: HourleafBackupLimitsV1.maximumFileBytes + 1
        ).write(to: source)
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass)
        )

        await assertPreparationFails(coordinator, source: source, expected: .preparationFailed)
        XCTAssertEqual(try contentsIfPresent(root), [])
    }

    func testEveryBoundedImportBatchCanFailWithoutLeavingCandidateOrSQLite() async throws {
        let data = try RestoreFixture.backupData(acknowledgementCount: 520)
        for failingBatch in 1...3 {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let source = sandbox.appendingPathComponent("fixture.hourleafbackup")
            try data.write(to: source)
            let root = sandbox.appendingPathComponent("restore", isDirectory: true)
            let liveStore = try await makeLiveStore(in: sandbox)
            defer { liveStore.close() }
            let (persistence, repository) = liveStore.dependencies
            let coordinator = HourleafRestoreCoordinator(
                persistence: persistence,
                repository: repository,
                rootDirectory: root,
                protectionReader: RecordingProtectionReader(value: expectedProtectionClass),
                faultInjector: { point in
                    if point == .stagedImportBatch(failingBatch) {
                        throw InjectedRestoreFailure.failed
                    }
                }
            )

            await assertPreparationFails(coordinator, source: source, expected: .preparationFailed)
            try assertOnlyDestroyedStoreSlot(in: root)
        }
    }

    func testProtectionMismatchRejectsBeforeSensitiveFileAndNilReaderIsSimulatorOnlySeam() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("fixture.hourleafbackup")
        try RestoreFixture.backupData().write(to: source)
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let mismatched = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: "NSFileProtectionNone")
        )
        await assertPreparationFails(mismatched, source: source, expected: .preparationFailed)
        XCTAssertEqual(try contentsIfPresent(root), [])

        let simulatorRoot = sandbox.appendingPathComponent("simulator-restore", isDirectory: true)
        let simulatorCoordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: simulatorRoot,
            protectionReader: RecordingProtectionReader(value: nil)
        )
        #if targetEnvironment(simulator)
        let preview = try await simulatorCoordinator.prepare(from: source)
        try await simulatorCoordinator.discardCandidate(preview.candidateID)
        #else
        await assertPreparationFails(simulatorCoordinator, source: source, expected: .preparationFailed)
        #endif
    }

    func testCandidateReplacementAndOneCleanupFailureAreRetryable() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let source = sandbox.appendingPathComponent("fixture.hourleafbackup")
        try RestoreFixture.backupData().write(to: source)
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let oneShot = OneShotFault(point: .candidateBackupCleanup)
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass),
            faultInjector: oneShot.inject
        )
        let first = try await coordinator.prepare(from: source)

        do {
            try await coordinator.discardCandidate(first.candidateID)
            XCTFail("The injected first cleanup must be reported.")
        } catch {
            // The consumed store capability remains a no-op while backup
            // cleanup is retried.
        }
        try await coordinator.discardCandidate(first.candidateID)
        try await coordinator.discardCandidate(first.candidateID)
        try assertOnlyDestroyedStoreSlot(in: root)

        let second = try await coordinator.prepare(from: source)
        let third = try await coordinator.prepare(from: source)
        XCTAssertNotEqual(second.candidateID, third.candidateID)
        let discardedPreview = await coordinator.preview(for: second.candidateID)
        let currentPreview = await coordinator.preview(for: third.candidateID)
        XCTAssertNil(discardedPreview)
        XCTAssertEqual(currentPreview, third)
        try await coordinator.discardCandidate(third.candidateID)
    }

    func testDestroyChangesStoreIdentityClearsEveryModelEntityAndReusesSlotForB() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceA = sandbox.appendingPathComponent("a.hourleafbackup")
        let sourceB = sandbox.appendingPathComponent("b.hourleafbackup")
        try RestoreFixture.backupData(acknowledgementCount: 1).write(to: sourceA)
        try RestoreFixture.backupData(
            exportedAt: Date(timeIntervalSinceReferenceDate: 199),
            acknowledgementCount: 2
        ).write(to: sourceB)
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let storeURL = root.appendingPathComponent("candidate.sqlite")
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies
        let coordinator = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass)
        )

        let previewA = try await coordinator.prepare(from: sourceA)
        let storeUUIDA = try storeUUID(at: storeURL)
        let digestA = await coordinator.stagedRecordsDigest(for: previewA.candidateID)
        XCTAssertEqual(
            digestA,
            try HourleafBackupCodec.storeDigest(RestoreFixture.records(acknowledgementCount: 1))
        )

        try await coordinator.discardCandidate(previewA.candidateID)
        let destroyedStoreUUID = try storeUUID(at: storeURL)
        XCTAssertNotEqual(destroyedStoreUUID, storeUUIDA)
        try assertEveryCurrentModelEntityIsEmpty(at: storeURL)

        let previewB = try await coordinator.prepare(from: sourceB)
        let digestB = await coordinator.stagedRecordsDigest(for: previewB.candidateID)
        XCTAssertEqual(
            digestB,
            try HourleafBackupCodec.storeDigest(RestoreFixture.records(acknowledgementCount: 2))
        )
        XCTAssertNotEqual(digestA, digestB)
        XCTAssertNotEqual(try storeUUID(at: storeURL), storeUUIDA)
        try await coordinator.discardCandidate(previewB.candidateID)
        try assertOnlyDestroyedStoreSlot(in: root)
    }

    func testRestartReclaimsOrphanAndRetriesFaultAfterDestroyBeforeProof() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sourceA = sandbox.appendingPathComponent("a.hourleafbackup")
        let sourceB = sandbox.appendingPathComponent("b.hourleafbackup")
        try RestoreFixture.backupData(acknowledgementCount: 1).write(to: sourceA)
        try RestoreFixture.backupData(
            exportedAt: Date(timeIntervalSinceReferenceDate: 299),
            acknowledgementCount: 3
        ).write(to: sourceB)
        let root = sandbox.appendingPathComponent("restore", isDirectory: true)
        let storeURL = root.appendingPathComponent("candidate.sqlite")
        let liveStore = try await makeLiveStore(in: sandbox)
        defer { liveStore.close() }
        let (persistence, repository) = liveStore.dependencies

        var firstCoordinator: HourleafRestoreCoordinator? = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass)
        )
        let previewA = try await firstCoordinator!.prepare(from: sourceA)
        let orphanUUID = try storeUUID(at: storeURL)
        let orphanDigest = await firstCoordinator!.stagedRecordsDigest(for: previewA.candidateID)
        XCTAssertNotNil(orphanDigest)
        firstCoordinator = nil

        let fault = OneShotFault(point: .candidateStoreDestroyedBeforeProof)
        let restarted = HourleafRestoreCoordinator(
            persistence: persistence,
            repository: repository,
            rootDirectory: root,
            protectionReader: RecordingProtectionReader(value: expectedProtectionClass),
            faultInjector: fault.inject
        )
        await assertPreparationFails(restarted, source: sourceB, expected: .preparationFailed)

        let previewB = try await restarted.prepare(from: sourceB)
        XCTAssertNotEqual(try storeUUID(at: storeURL), orphanUUID)
        let restartedDigest = await restarted.stagedRecordsDigest(for: previewB.candidateID)
        XCTAssertEqual(
            restartedDigest,
            try HourleafBackupCodec.storeDigest(RestoreFixture.records(acknowledgementCount: 3))
        )
        try await restarted.discardCandidate(previewB.candidateID)
        try assertOnlyDestroyedStoreSlot(in: root)
    }

    private var expectedProtectionClass: String {
        FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    }

    private func makeLiveStore(
        in sandbox: URL
    ) async throws -> TestLiveStore {
        let liveStore = TestLiveStore(
            storeURL: sandbox.appendingPathComponent("live-\(UUID().uuidString).sqlite")
        )
        do {
            _ = try await liveStore.repository.loadSettings()
            return liveStore
        } catch {
            try liveStore.closePersistentStore()
            throw error
        }
    }

    private func makeSandbox() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafRestorePreparationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func contentsIfPresent(_ directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func assertOnlyDestroyedStoreSlot(
        in directory: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let allowed = Set([
            "candidate.sqlite",
            "candidate.sqlite-wal",
            "candidate.sqlite-shm"
        ])
        let observed = Set(try contentsIfPresent(directory))
        XCTAssertTrue(
            observed.isSubset(of: allowed),
            "Unexpected staging artifacts: \(observed.sorted())",
            file: file,
            line: line
        )
    }

    private func storeUUID(at url: URL) throws -> String {
        let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(
            type: .sqlite,
            at: url,
            options: testSQLiteOptions
        )
        return try XCTUnwrap(metadata[NSStoreUUIDKey] as? String)
    }

    private func assertEveryCurrentModelEntityIsEmpty(at url: URL) throws {
        try autoreleasepool {
            let modelContainer = NSPersistentCloudKitContainer(name: "HourleafModel")
            let model = modelContainer.managedObjectModel
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let store = try coordinator.addPersistentStore(
                type: .sqlite,
                configuration: nil,
                at: url,
                options: testSQLiteOptions
            )
            defer { try? coordinator.remove(store) }
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            try context.performAndWait {
                defer { context.reset() }
                for entity in model.entities where !entity.isAbstract {
                    let entityName = try XCTUnwrap(entity.name)
                    let request = NSFetchRequest<NSFetchRequestResult>(entityName: entityName)
                    request.includesSubentities = false
                    XCTAssertEqual(
                        try context.count(for: request),
                        0,
                        "Destroyed slot retained \(entityName) records."
                    )
                }
            }
        }
    }

    private var testSQLiteOptions: [AnyHashable: Any] {
        [
            NSMigratePersistentStoresAutomaticallyOption: true as NSNumber,
            NSInferMappingModelAutomaticallyOption: true as NSNumber,
            NSPersistentHistoryTrackingKey: true as NSNumber,
            NSPersistentStoreRemoteChangeNotificationPostOptionKey: true as NSNumber,
            NSPersistentStoreFileProtectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        ]
    }

    private func assertPreparationFails(
        _ coordinator: HourleafRestoreCoordinator,
        source: URL,
        expected: HourleafRestoreError
    ) async {
        do {
            _ = try await coordinator.prepare(from: source)
            XCTFail("Preparation unexpectedly produced a preview.")
        } catch let error as HourleafRestoreError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func uncheckedEnvelopeData(content: HourleafBackupContentV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let contentData = try encoder.encode(content)
        let checksum = SHA256.hash(data: contentData).map { String(format: "%02x", $0) }.joined()
        return try encoder.encode(HourleafBackupEnvelopeV1(
            content: content,
            checksum: HourleafBackupChecksumV1(value: checksum)
        ))
    }

    private func checksumMismatchData(from valid: Data) throws -> Data {
        let decoder = JSONDecoder()
        var envelope = try decoder.decode(HourleafBackupEnvelopeV1.self, from: valid)
        envelope.checksum.value = String(repeating: "0", count: 64)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }
}

@MainActor
private final class TestLiveStore {
    let persistence: PersistenceController
    let repository: CoreDataLedgerRepository
    private var isClosed = false

    init(storeURL: URL) {
        let persistence = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            storeURL: storeURL
        )
        self.persistence = persistence
        repository = CoreDataLedgerRepository(persistence: persistence)
    }

    var dependencies: (PersistenceController, CoreDataLedgerRepository) {
        (persistence, repository)
    }

    func close(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            try closePersistentStore()
        } catch {
            XCTFail("Failed to close test live store: \(error)", file: file, line: line)
        }
    }

    func closePersistentStore() throws {
        guard !isClosed else { return }
        _ = try persistence.closePersistentStoreForTransition()
        isClosed = true
    }
}

private enum InjectedRestoreFailure: Error {
    case failed
}

private final class RecordingProtectionReader: HourleafFileProtectionReading, @unchecked Sendable {
    private let lock = NSLock()
    private let value: String?
    private var names: [String] = []

    init(value: String?) {
        self.value = value
    }

    func protectionClass(at url: URL) throws -> String? {
        lock.withLock { names.append(url.lastPathComponent) }
        return value
    }

    func inspectedNames() -> [String] {
        lock.withLock { names }
    }
}

private final class OneShotFault: @unchecked Sendable {
    private let lock = NSLock()
    private let point: RestoreFaultPoint
    private var hasFailed = false

    init(point: RestoreFaultPoint) {
        self.point = point
    }

    func inject(_ observed: RestoreFaultPoint) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard observed == point, !hasFailed else { return false }
            hasFailed = true
            return true
        }
        if shouldFail { throw InjectedRestoreFailure.failed }
    }
}
