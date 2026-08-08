import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class LocalBundleMigrationTests: XCTestCase {
    func testIndependentLocalStoresMigrateExactGraphAfterDestinationRelaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let source = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("source.sqlite")
        )
        defer { source.close() }
        let destination = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("destination.sqlite")
        )
        defer { destination.close() }

        XCTAssertNotEqual(source.persistence.descriptor.url, destination.persistence.descriptor.url)

        let sourceRecords = RestoreFixture.records()
        try source.seed(sourceRecords)
        let sourceBefore = try await source.repository.portableBackupRecords()
        let sourceDigest = try HourleafBackupCodec.storeDigest(sourceBefore)
        XCTAssertEqual(sourceBefore.counts, sourceRecords.counts)

        let backupDirectory = sandbox.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let artifact = try await HourleafBackupExporter(source: source.repository)
            .createVerifiedBackup(
                in: backupDirectory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 123)
            )
        XCTAssertEqual(artifact.recordsDigest, sourceDigest)
        XCTAssertEqual(artifact.recordCounts, sourceBefore.counts)
        XCTAssertEqual(
            try HourleafBackupCodec.decodeAndVerify(Data(contentsOf: artifact.url)).recordsDigest,
            sourceDigest
        )

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("destination-journal", isDirectory: true),
            protectionReader: protection
        )
        let scheduler = RestoreTestReminderScheduler()
        let coordinator = HourleafRestoreCoordinator(
            persistence: destination.persistence,
            repository: destination.repository,
            rootDirectory: sandbox.appendingPathComponent("destination-staging", isDirectory: true),
            protectionReader: protection,
            journalStore: journal,
            reminderScheduler: scheduler,
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "destination-recovery-artifacts",
                isDirectory: true
            )
        )

        let preview = try await coordinator.prepare(from: artifact.url)
        let stagedDigest = await coordinator.stagedRecordsDigest(for: preview.candidateID)
        XCTAssertEqual(stagedDigest, sourceDigest)

        let result = try await coordinator.confirm(preview.candidateID)
        XCTAssertEqual(result.selectedTarget, .candidate)
        XCTAssertEqual(result.recordsDigest, sourceDigest)
        XCTAssertEqual(result.recordCounts, sourceBefore.counts)
        XCTAssertEqual(scheduler.rescheduled.count, 1)

        _ = try destination.persistence.closePersistentStoreForTransition()
        XCTAssertNil(destination.persistence.reopenFreshContainerAfterTransition())
        let reopenedRepository = CoreDataLedgerRepository(persistence: destination.persistence)
        let destinationAfter = try await reopenedRepository.portableBackupRecords()

        XCTAssertEqual(try HourleafBackupCodec.storeDigest(destinationAfter), sourceDigest)
        XCTAssertEqual(destinationAfter.counts, sourceBefore.counts)

        let sourceAfter = try await source.repository.portableBackupRecords()
        XCTAssertEqual(try HourleafBackupCodec.storeDigest(sourceAfter), sourceDigest)
        XCTAssertEqual(sourceAfter.counts, sourceBefore.counts)
    }

    func testCorruptMigrationInputCannotWriteToFreshDestination() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let destination = RestoreTestRuntime(
            storeURL: sandbox.appendingPathComponent("destination.sqlite")
        )
        defer { destination.close() }

        let protection = RestoreTestProtectionReader()
        let journal = RestoreJournalStoreV1(
            rootDirectory: sandbox.appendingPathComponent("destination-journal", isDirectory: true),
            protectionReader: protection
        )
        let coordinator = HourleafRestoreCoordinator(
            persistence: destination.persistence,
            repository: destination.repository,
            rootDirectory: sandbox.appendingPathComponent("destination-staging", isDirectory: true),
            protectionReader: protection,
            journalStore: journal,
            reminderScheduler: RestoreTestReminderScheduler(),
            recoveryArtifactsDirectory: sandbox.appendingPathComponent(
                "destination-recovery-artifacts",
                isDirectory: true
            )
        )

        let before = try await destination.repository.portableBackupRecords()
        let beforeDigest = try HourleafBackupCodec.storeDigest(before)
        let beforeCounts = before.counts

        var corruptData = try RestoreFixture.backupData()
        corruptData[corruptData.count - 1] ^= 0x01
        let corruptURL = sandbox.appendingPathComponent("corrupt.hourleafbackup")
        try corruptData.write(to: corruptURL)

        do {
            _ = try await coordinator.prepare(from: corruptURL)
            XCTFail("A wrong-checksum backup must not produce a restore preview.")
        } catch let error as HourleafRestoreError {
            XCTAssertEqual(error, .preparationFailed)
        }

        let after = try await destination.repository.portableBackupRecords()
        XCTAssertEqual(try HourleafBackupCodec.storeDigest(after), beforeDigest)
        XCTAssertEqual(after.counts, beforeCounts)
        XCTAssertEqual(try contentsOf(sandbox.appendingPathComponent("destination-staging")), [])
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HourleafLocalBundleMigrationTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private func contentsOf(_ directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }
}
