import Foundation
import XCTest
@testable import Hourleaf

@MainActor
final class HourleafBackupExportTests: XCTestCase {
    func testVerifiedExportPublishesCanonicalFileWithReadBackEvidence() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var records = makeValidRecords()
        records.states = [
            HourleafReportStateV1(
                changedAt: nil,
                currentSnapshotID: nil,
                id: fixedUUID(11).uuidString.lowercased(),
                lastStableState: nil,
                monthKey: "2026-01",
                reviewedCalculationFingerprint: nil,
                reviewedPresentationFingerprint: nil,
                state: ReportLifecycleState.draft.rawValue,
                updatedAt: 1
            )
        ]
        records.bibleStudyCounts = [
            HourleafBibleStudyCountV2(count: 2, monthKey: "2026-01")
        ]
        let exportedAt = Date(timeIntervalSinceReferenceDate: 1_234_567)
        let exporter = HourleafBackupExporter(source: FixtureBackupSource(records: records))

        let artifact = try await exporter.createVerifiedBackup(in: directory, exportedAt: exportedAt)
        let data = try Data(contentsOf: artifact.url)
        let verified = try HourleafBackupCodec.decodeAndVerify(data)

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
        XCTAssertEqual(artifact.exportedAt, exportedAt)
        XCTAssertEqual(artifact.byteCount, data.count)
        XCTAssertEqual(artifact.checksum, verified.checksum)
        XCTAssertEqual(artifact.recordCounts, verified.recordCounts)
        XCTAssertEqual(artifact.recordsDigest, verified.recordsDigest)
        XCTAssertEqual(verified.content.records, records)
        XCTAssertEqual(
            verified.content.records.bibleStudyCounts,
            [HourleafBibleStudyCountV2(count: 2, monthKey: "2026-01")]
        )
        XCTAssertFalse(artifact.url.lastPathComponent.hasPrefix("."))
    }

    func testTruncatedReadBackFailsAndLeavesNoPublishedOrPartialArtifact() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = HourleafBackupExporter(
            source: FixtureBackupSource(records: makeValidRecords()),
            readBack: { url in
                let data = try Data(contentsOf: url)
                return Data(data.dropLast())
            }
        )

        do {
            _ = try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 1_234_568)
            )
            XCTFail("A truncated read-back must not produce a successful export.")
        } catch let error as HourleafBackupExportError {
            XCTAssertEqual(error, .verificationFailed)
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testCorruptedPublishedFileIsRemovedWhenVerificationFails() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = HourleafBackupExporter(
            source: FixtureBackupSource(records: makeValidRecords()),
            readBack: { url in
                let data = try Data(contentsOf: url)
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.truncate(atOffset: UInt64(data.count - 1))
                return try Data(contentsOf: url)
            }
        )

        do {
            _ = try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 1_234_568.5)
            )
            XCTFail("A corrupted published file must not produce a successful export.")
        } catch let error as HourleafBackupExportError {
            XCTAssertEqual(error, .verificationFailed)
        }

        // The corruption happened in place after publication. Cleanup must
        // remove the artifact we still own, not only an exact byte match.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testVerificationFailurePreservesAnAtomicallyReplacedFinalFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let replacement = Data("external writer owns this replacement".utf8)
        let exporter = HourleafBackupExporter(
            source: FixtureBackupSource(records: makeValidRecords()),
            readBack: { url in
                // `.atomic` replaces the path with a fresh file. The exporter
                // must not delete this independent writer's publication while
                // cleaning up its failed verification attempt.
                try replacement.write(to: url, options: .atomic)
                return try Data(contentsOf: url)
            }
        )

        do {
            _ = try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 1_234_568.75)
            )
            XCTFail("A replaced final file must not produce a successful export.")
        } catch let error as HourleafBackupExportError {
            XCTAssertEqual(error, .verificationFailed)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(names[0])), replacement)
    }

    func testExistingFinalBackupIsNeverOverwritten() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let date = Date(timeIntervalSinceReferenceDate: 1_234_569)
        let exporter = HourleafBackupExporter(source: FixtureBackupSource(records: makeValidRecords()))
        let first = try await exporter.createVerifiedBackup(in: directory, exportedAt: date)
        let originalData = try Data(contentsOf: first.url)

        do {
            _ = try await exporter.createVerifiedBackup(in: directory, exportedAt: date)
            XCTFail("An existing final backup must not be overwritten.")
        } catch let error as HourleafBackupExportError {
            guard case .destinationAlreadyExists = error else {
                return XCTFail("Expected destinationAlreadyExists, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: first.url), originalData)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [first.url.lastPathComponent])
    }

    func testNoncooperatingWriterInPublicationWindowKeepsItsFinalBytes() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let foreignData = Data("noncooperating writer final bytes".utf8)
        let exporter = HourleafBackupExporter(
            source: FixtureBackupSource(records: makeValidRecords()),
            beforePublication: { finalURL in
                try foreignData.write(to: finalURL, options: [.withoutOverwriting])
            }
        )

        do {
            _ = try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 1_234_569.5)
            )
            XCTFail("A final created in the publication window must win without replacement.")
        } catch let error as HourleafBackupExportError {
            guard case .destinationAlreadyExists = error else {
                return XCTFail("Expected destinationAlreadyExists, got \(error)")
            }
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].hasSuffix(".partial"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(names[0])), foreignData)
    }

    func testSourceFailureCreatesNoBackupArtifact() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exporter = HourleafBackupExporter(source: FailingBackupSource())
        do {
            _ = try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 1_234_570)
            )
            XCTFail("A source failure must not produce a successful export.")
        } catch TestBackupSourceError.failed {
            // Expected: the source error remains distinguishable to the caller.
        }

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testExportSnapshotStaysCoherentWhenSameRepositoryMutatesAfterCapture() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let authorizationTime = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let entryDate = authorizationTime.addingTimeInterval(-60)
        let entryID = fixedUUID(101)
        let createMutationID = fixedUUID(102)
        let updateMutationID = fixedUUID(103)
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let repository = CoreDataLedgerRepository(persistence: persistence, clock: { authorizationTime })
        let day = LocalDay(entryDate, calendar: .hourleaf)

        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = day.monthKey
        try await repository.saveSettings(settings)
        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: createMutationID,
                entryID: entryID,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(kind: .service, day: day, minutes: 45, note: "before export"),
                occurredAt: entryDate,
                source: .appQuickEntry
            )
        )

        let handoff = SnapshotHandoff()
        let exporter = HourleafBackupExporter(
            source: SnapshotHandoffSource(repository: repository, handoff: handoff)
        )
        let exportTask = Task.detached {
            try await exporter.createVerifiedBackup(
                in: directory,
                exportedAt: Date(timeIntervalSinceReferenceDate: 2_000_001)
            )
        }

        await handoff.waitUntilSnapshotTaken()
        let update = try await repository.apply(
            EntryMutationCommand(
                mutationID: updateMutationID,
                entryID: entryID,
                expectedRevision: 1,
                operation: .update,
                values: EntryMutationValues(kind: .service, day: day, minutes: 90, note: "after export"),
                occurredAt: entryDate.addingTimeInterval(1),
                source: .appHistory
            )
        )
        XCTAssertEqual(update.appliedRevision, 2)
        await handoff.releaseExport()

        let artifact = try await exportTask.value
        let backup = try HourleafBackupCodec.decodeAndVerify(Data(contentsOf: artifact.url))
        let exportedEntry = try XCTUnwrap(backup.content.records.entries.first)
        let exportedRevisions = backup.content.records.revisions.filter { $0.entryID == entryID.uuidString.lowercased() }

        // The source snapshot was taken before the actor accepted the update;
        // a valid export must therefore contain the complete before graph, not
        // a hybrid of the two revisions.
        XCTAssertEqual(exportedEntry.revision, 1)
        XCTAssertEqual(exportedEntry.lastMutationID, createMutationID.uuidString.lowercased())
        XCTAssertEqual(exportedEntry.minutes, 45)
        XCTAssertEqual(exportedEntry.note, "before export")
        XCTAssertEqual(exportedRevisions.count, 1)
        XCTAssertEqual(exportedRevisions[0].mutationID, createMutationID.uuidString.lowercased())

        let live = try await repository.portableBackupRecords()
        XCTAssertEqual(live.entries.first?.revision, 2)
        XCTAssertEqual(live.entries.first?.lastMutationID, updateMutationID.uuidString.lowercased())
        XCTAssertEqual(live.revisions.filter { $0.entryID == entryID.uuidString.lowercased() }.count, 2)
    }

    func testConcurrentSameDestinationExportsLeaveOneVerifiedFinalAndNoPartials() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let records = makeValidRecords()
        let source = ConcurrentFixtureBackupSource(records: records, gate: TwoCallGate())
        let exporter = HourleafBackupExporter(source: source)
        let date = Date(timeIntervalSinceReferenceDate: 1_234_571)
        let first = Task.detached { () -> Result<HourleafBackupArtifactV1, Error> in
            do {
                return .success(try await exporter.createVerifiedBackup(in: directory, exportedAt: date))
            } catch {
                return .failure(error)
            }
        }
        let second = Task.detached { () -> Result<HourleafBackupArtifactV1, Error> in
            do {
                return .success(try await exporter.createVerifiedBackup(in: directory, exportedAt: date))
            } catch {
                return .failure(error)
            }
        }

        let results = await [first.value, second.value]
        let artifacts = results.compactMap { try? $0.get() }
        let errors = results.compactMap { result -> Error? in
            guard case let .failure(error) = result else { return nil }
            return error
        }

        XCTAssertEqual(artifacts.count, 1)
        XCTAssertEqual(errors.count, 1)
        guard let collision = errors.first as? HourleafBackupExportError else {
            return XCTFail("The losing concurrent export must return a typed collision error.")
        }
        guard case .destinationAlreadyExists = collision else {
            return XCTFail("Expected destinationAlreadyExists, got \(collision)")
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names.count, 1)
        XCTAssertFalse(names[0].hasSuffix(".partial"))
        let verified = try HourleafBackupCodec.decodeAndVerify(
            Data(contentsOf: directory.appendingPathComponent(names[0]))
        )
        XCTAssertEqual(verified.content.records, records)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafBackupExportTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeValidRecords() -> HourleafBackupRecordsV1 {
        HourleafBackupRecordsV1(
            acknowledgements: [],
            archives: [],
            entries: [],
            policies: [],
            presets: [],
            receipts: [],
            reminders: [],
            revisions: [],
            settings: HourleafSettingsV1(
                baselineServiceYearMinutes: 0,
                baselineServiceYearStart: "2025-09",
                creditLabelEnglish: "Credit hours",
                creditLabelRussian: "Кредит часов",
                creditLabelUkrainian: "Кредит годин",
                dataRevision: 3,
                id: "00000000-0000-0000-0000-000000000010",
                lastPurgeAt: nil,
                ledgerStartMonth: "2026-01",
                onboardingComplete: true,
                openingCreditCarryMinutes: 0,
                openingServiceCarryMinutes: 0,
                planningVisible: false,
                quietGapCheckEnabled: false,
                quietGapDays: 0,
                reportLanguage: ReportLanguage.ukrainian.rawValue,
                syncMode: nil,
                timerVisible: false,
                updatedAt: nil,
                widgetPrivacyMode: nil
            ),
            states: []
        )
    }

    private func fixedUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

private actor FixtureBackupSource: PortableBackupSource {
    let records: HourleafBackupRecordsV1

    init(records: HourleafBackupRecordsV1) {
        self.records = records
    }

    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        records
    }
}

private enum TestBackupSourceError: Error, Sendable {
    case failed
}

private actor FailingBackupSource: PortableBackupSource {
    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        throw TestBackupSourceError.failed
    }
}

private actor SnapshotHandoffSource: PortableBackupSource {
    let repository: CoreDataLedgerRepository
    let handoff: SnapshotHandoff

    init(repository: CoreDataLedgerRepository, handoff: SnapshotHandoff) {
        self.repository = repository
        self.handoff = handoff
    }

    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        let records = try await repository.portableBackupRecords()
        await handoff.markSnapshotTaken()
        await handoff.waitForExportRelease()
        return records
    }
}

private actor SnapshotHandoff {
    private var snapshotTaken = false
    private var released = false
    private var snapshotWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markSnapshotTaken() {
        snapshotTaken = true
        let waiters = snapshotWaiters
        snapshotWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilSnapshotTaken() async {
        guard !snapshotTaken else { return }
        await withCheckedContinuation { continuation in
            snapshotWaiters.append(continuation)
        }
    }

    func waitForExportRelease() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func releaseExport() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor ConcurrentFixtureBackupSource: PortableBackupSource {
    let records: HourleafBackupRecordsV1
    let gate: TwoCallGate

    init(records: HourleafBackupRecordsV1, gate: TwoCallGate) {
        self.records = records
        self.gate = gate
    }

    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        await gate.waitForBothExports()
        return records
    }
}

private actor TwoCallGate {
    private var arrivals = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitForBothExports() async {
        arrivals += 1
        if arrivals == 2 {
            let waiting = waiters
            waiters.removeAll()
            waiting.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
