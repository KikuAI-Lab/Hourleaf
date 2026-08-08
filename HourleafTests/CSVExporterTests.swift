import Foundation
import XCTest
@testable import Hourleaf

final class CSVExporterTests: XCTestCase {
    func testByteGoldenUsesSortedRFC4180RowsWithBOMAndCRLF() {
        let records = [
            record(
                id: "00000000-0000-0000-0000-000000000003",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 12),
                minutes: 120
            ),
            record(
                id: "00000000-0000-0000-0000-000000000002",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 11),
                minutes: 65,
                note: "plain"
            ),
            record(
                id: "00000000-0000-0000-0000-000000000001",
                kind: .credit,
                day: LocalDay(year: 2026, month: 7, day: 11),
                minutes: 30,
                note: "comma, \"quote\" 🙂\r\nsecond line"
            )
        ]

        let actual = CSVExporter.data(for: records, includeNotes: true)
        let expectedContents = "date,kind,hours,minutes,total_minutes,note\r\n" +
            "2026-07-11,credit,0,30,30,\"comma, \"\"quote\"\" 🙂\r\nsecond line\"\r\n" +
            "2026-07-11,service,1,5,65,plain\r\n" +
            "2026-07-12,service,2,0,120,\r\n"
        let expected = Data([0xEF, 0xBB, 0xBF]) + Data(expectedContents.utf8)

        XCTAssertEqual(actual, expected)
    }

    func testSameDayAndKindUseLowercaseUUIDAsTheFinalSortKey() {
        let records = [
            record(
                id: "00000000-0000-0000-0000-00000000000B",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 11),
                minutes: 20
            ),
            record(
                id: "00000000-0000-0000-0000-00000000000A",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 11),
                minutes: 10
            )
        ]

        let actual = String(decoding: CSVExporter.data(for: records, includeNotes: false).dropFirst(3), as: UTF8.self)

        XCTAssertEqual(
            actual,
            "date,kind,hours,minutes,total_minutes\r\n" +
                "2026-07-11,service,0,10,10\r\n" +
                "2026-07-11,service,0,20,20\r\n"
        )
    }

    func testNotesOffExcludesTheColumnAndItsContents() {
        let records = [
            record(
                id: "00000000-0000-0000-0000-000000000001",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 11),
                minutes: 65,
                note: "private note, with \"quotes\""
            )
        ]

        let actual = String(decoding: CSVExporter.data(for: records, includeNotes: false).dropFirst(3), as: UTF8.self)

        XCTAssertEqual(
            actual,
            "date,kind,hours,minutes,total_minutes\r\n2026-07-11,service,1,5,65\r\n"
        )
        XCTAssertFalse(actual.contains("private note"))
    }

    func testDeletedRecordsAreExcluded() {
        let active = record(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 11),
            minutes: 15
        )
        let deleted = record(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .credit,
            day: LocalDay(year: 2026, month: 7, day: 12),
            minutes: 999,
            deleted: true
        )

        let actual = String(decoding: CSVExporter.data(for: [deleted, active], includeNotes: false).dropFirst(3), as: UTF8.self)

        XCTAssertEqual(actual, "date,kind,hours,minutes,total_minutes\r\n2026-07-11,service,0,15,15\r\n")
        XCTAssertFalse(actual.contains("999"))
    }

    func testExportUsesExclusiveProtectedWriteAndReportsInjectedProtection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = CapturingWriter()
        let exportedAt = fixedExportDate()
        let exporter = CSVExporter(
            clock: { exportedAt },
            fileProtectionReader: { _ in .protected },
            writeFile: writer.write
        )

        let artifact = try exporter.export(
            records: [sampleRecord()],
            includeNotes: false,
            in: directory
        )

        XCTAssertEqual(artifact.url.lastPathComponent, CSVExporter.filename(for: exportedAt))
        XCTAssertEqual(artifact.protectionStatus, .protected)
        XCTAssertTrue(writer.options?.contains(.withoutOverwriting) == true)
        XCTAssertTrue(writer.options?.contains(.completeFileProtectionUntilFirstUserAuthentication) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    func testExistingFileIsNeverOverwritten() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exportedAt = fixedExportDate()
        let outputURL = directory.appendingPathComponent(CSVExporter.filename(for: exportedAt))
        let existing = Data("keep these bytes".utf8)
        try existing.write(to: outputURL)

        let exporter = CSVExporter(clock: { exportedAt }, fileProtectionReader: { _ in .protected })

        XCTAssertThrowsError(
            try exporter.export(records: [sampleRecord()], includeNotes: false, in: directory)
        ) { error in
            XCTAssertEqual(error as? CSVExportError, .destinationAlreadyExists)
        }
        XCTAssertEqual(try Data(contentsOf: outputURL), existing)
    }

    func testWriteFailureReturnsSanitizedErrorAndCreatesNoFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exportedAt = fixedExportDate()
        let exporter = CSVExporter(
            clock: { exportedAt },
            fileProtectionReader: { _ in .protected },
            writeFile: { _, _, _ in throw CSVExporterTestError.failed }
        )

        XCTAssertThrowsError(
            try exporter.export(records: [sampleRecord()], includeNotes: false, in: directory)
        ) { error in
            XCTAssertEqual(error as? CSVExportError, .writeFailed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testProtectionVerificationFailureDeletesTheExport() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exportedAt = fixedExportDate()
        let exporter = CSVExporter(
            clock: { exportedAt },
            fileProtectionReader: { _ in throw CSVExporterTestError.failed }
        )

        XCTAssertThrowsError(
            try exporter.export(records: [sampleRecord()], includeNotes: false, in: directory)
        ) { error in
            XCTAssertEqual(error as? CSVExportError, .fileProtectionVerificationFailed)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(CSVExporter.filename(for: exportedAt)).path
            )
        )
    }

    func testProtectionFailurePreservesAnAtomicallyReplacedFinalFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exportedAt = fixedExportDate()
        let replacement = Data("external writer owns this CSV".utf8)
        let exporter = CSVExporter(
            clock: { exportedAt },
            fileProtectionReader: { url in
                try replacement.write(to: url, options: .atomic)
                throw CSVExporterTestError.failed
            }
        )

        XCTAssertThrowsError(
            try exporter.export(records: [sampleRecord()], includeNotes: false, in: directory)
        ) { error in
            XCTAssertEqual(error as? CSVExportError, .fileProtectionVerificationFailed)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, [CSVExporter.filename(for: exportedAt)])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(names[0])), replacement)
    }

    #if targetEnvironment(simulator)
    func testDefaultReaderDoesNotClaimDeviceProtectionOnSimulator() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let exportedAt = fixedExportDate()
        let artifact = try CSVExporter(clock: { exportedAt }).export(
            records: [sampleRecord()],
            includeNotes: false,
            in: directory
        )

        XCTAssertEqual(artifact.protectionStatus, .notVerifiedOnSimulator)
    }
    #endif

    @MainActor
    func testFileShareCleanupIsIdempotentAcrossCancelAndDismiss() {
        var cleanupCount = 0
        var completions: [Bool] = []
        let payload = FileSharePayload(
            url: URL(fileURLWithPath: "/tmp/hourleaf-share-fixture.csv"),
            cleanup: { cleanupCount += 1 }
        )
        let coordinator = FileActivityView.Coordinator(
            payload: payload,
            completion: { completions.append($0) }
        )

        coordinator.finish(completed: false)
        coordinator.finish(completed: true)
        coordinator.dismantle()
        payload.cleanup()

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(completions, [false])
    }

    func testRestoreDisappearanceDefersDiscardUntilInFlightFailure() {
        let preview = DataManagementRestorePreview(summary: "Fixture")
        var state = DataManagementRestoreState()
        state.replacePreview(with: preview)
        state.isConfirmed = true

        XCTAssertNil(state.disappear(restoreInFlight: true))
        XCTAssertEqual(state.preview, preview)
        XCTAssertFalse(state.isConfirmed)

        XCTAssertEqual(state.finishRestore(succeeded: false), preview)
        XCTAssertNil(state.preview)
    }

    func testVisibleRestoreFailurePreservesCandidateForExplicitRetry() {
        let preview = DataManagementRestorePreview(summary: "Fixture")
        var state = DataManagementRestoreState()
        state.replacePreview(with: preview)
        state.isConfirmed = true

        XCTAssertNil(state.finishRestore(succeeded: false))
        XCTAssertEqual(state.preview, preview)
        XCTAssertFalse(state.isConfirmed)
    }

    func testRestoreSuccessConsumesVisibleCandidate() {
        let preview = DataManagementRestorePreview(summary: "Fixture")
        var state = DataManagementRestoreState()
        state.replacePreview(with: preview)

        XCTAssertEqual(state.finishRestore(succeeded: true), preview)
        XCTAssertNil(state.preview)
    }

    func testCSVImportVisibleFailureKeepsCandidateForRetry() {
        let preview = csvImportPreview()
        var state = DataManagementCSVImportState()
        state.replacePreview(with: preview)

        XCTAssertNil(state.finishImportFailure())
        XCTAssertEqual(state.preview, preview)
    }

    func testCSVImportSuccessConsumesCandidateAndStoresUndoToken() {
        let preview = csvImportPreview()
        let token = CSVImportUndoToken(
            members: [],
            importedAt: Date(timeIntervalSinceReferenceDate: 10),
            expiresAt: Date(timeIntervalSinceReferenceDate: 610)
        )
        let result = CSVImportResult(
            importedCount: 2,
            previouslyImportedCount: 1,
            skippedPossibleMatchCount: 3,
            undoToken: token
        )
        var state = DataManagementCSVImportState()
        state.replacePreview(with: preview)

        state.finishImport(with: result)

        XCTAssertNil(state.preview)
        XCTAssertEqual(state.result, result)
        XCTAssertEqual(state.undoToken, token)
    }

    func testCSVImportDisappearanceDiscardsUnconfirmedCandidate() {
        let preview = csvImportPreview()
        var state = DataManagementCSVImportState()
        state.replacePreview(with: preview)

        XCTAssertEqual(state.disappear(importInFlight: false), preview)
        XCTAssertNil(state.preview)
        XCTAssertFalse(state.isVisible)
    }

    func testCSVImportUndoResultClearsTokenAndUpdatesResult() {
        let preview = csvImportPreview()
        let token = CSVImportUndoToken(
            members: [],
            importedAt: Date(timeIntervalSinceReferenceDate: 10),
            expiresAt: Date(timeIntervalSinceReferenceDate: 610)
        )
        var state = DataManagementCSVImportState()
        state.replacePreview(with: preview)
        state.finishImport(with: CSVImportResult(
            importedCount: 1,
            previouslyImportedCount: 0,
            skippedPossibleMatchCount: 0,
            undoToken: token
        ))

        let undoResult = CSVImportUndoResult(deletedCount: 1)
        state.finishUndo(with: undoResult)

        XCTAssertNil(state.undoToken)
        XCTAssertEqual(state.undoResult, undoResult)
        XCTAssertEqual(state.result?.importedCount, 1)
    }

    private func csvImportPreview() -> DataManagementCSVImportPreview {
        let day = LocalDay(year: 2026, month: 7, day: 11)
        return DataManagementCSVImportPreview(
            totalRows: 5,
            noteCount: 1,
            dateRange: day...day,
            previouslyImportedCount: 2,
            possibleMatchCount: 1,
            importableWhenSkippingMatches: 2,
            importableWhenIncludingMatches: 3
        )
    }

    private func record(
        id: String,
        kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        note: String? = nil,
        deleted: Bool = false
    ) -> LedgerEntryRecord {
        let timestamp = Date(timeIntervalSinceReferenceDate: 1_000)
        return LedgerEntryRecord(
            entry: TimeEntry(
                id: UUID(uuidString: id)!,
                kind: kind,
                day: day,
                minutes: minutes,
                note: note,
                createdAt: timestamp,
                updatedAt: timestamp
            ),
            deletedAt: deleted ? timestamp : nil,
            source: nil,
            revision: 1,
            lastMutationID: nil
        )
    }

    private func sampleRecord() -> LedgerEntryRecord {
        record(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 11),
            minutes: 65
        )
    }

    private func fixedExportDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 8))!
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CSVExporterTests-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class CapturingWriter {
    private(set) var options: Data.WritingOptions?

    func write(_ data: Data, to url: URL, options: Data.WritingOptions) throws {
        self.options = options
        try data.write(to: url, options: options)
    }
}

private enum CSVExporterTestError: Error {
    case failed
}
