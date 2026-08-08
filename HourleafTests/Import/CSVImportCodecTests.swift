import CryptoKit
import Foundation
import XCTest
@testable import Hourleaf

final class CSVImportCodecTests: XCTestCase {
    func testDecodesExporterShapeWithBOMCRLFAndRFC4180Note() throws {
        let contents = "date,kind,hours,minutes,total_minutes,note\r\n" +
            "2026-07-11,service,1,5,65,plain\r\n" +
            "2026-07-12,credit,0,30,30,\"comma, \"\"quote\"\" 🙂\r\nsecond line\"\r\n"
        let data = Data([0xef, 0xbb, 0xbf]) + Data(contents.utf8)

        let document = try CSVImportCodec.decode(data: data)

        XCTAssertEqual(document.rows.count, 2)
        XCTAssertEqual(document.noteCount, 2)
        XCTAssertEqual(document.rows[0].values.day.key, "2026-07-11")
        XCTAssertEqual(document.rows[0].values.kind, .service)
        XCTAssertEqual(document.rows[0].values.minutes, 65)
        XCTAssertEqual(document.rows[0].values.note, "plain")
        XCTAssertEqual(document.rows[1].values.day.key, "2026-07-12")
        XCTAssertEqual(document.rows[1].values.kind, .credit)
        XCTAssertEqual(document.rows[1].values.minutes, 30)
        XCTAssertEqual(document.rows[1].values.note, "comma, \"quote\" 🙂\r\nsecond line")
        XCTAssertEqual(document.dateRange, LocalDay(year: 2026, month: 7, day: 11)...LocalDay(year: 2026, month: 7, day: 12))
        XCTAssertEqual(document.digest, sha256Hex(data))
    }

    func testDecodesFiveColumnHeaderWithLFAndEmptyDocument() throws {
        let data = Data("date,kind,hours,minutes,total_minutes\n".utf8)
        let document = try CSVImportCodec.decode(data: data)

        XCTAssertTrue(document.rows.isEmpty)
        XCTAssertNil(document.dateRange)
        XCTAssertEqual(document.noteCount, 0)
    }

    func testNormalizesWhitespaceOnlyAndOuterWhitespaceNotes() throws {
        let data = Data((
            "date,kind,hours,minutes,total_minutes,note\n" +
            "2026-07-11,service,1,0,60,  keep me  \n" +
            "2026-07-12,credit,0,1,1,   \n").utf8)

        let rows = try CSVImportCodec.decode(data: data).rows

        XCTAssertEqual(rows[0].values.note, "keep me")
        XCTAssertNil(rows[1].values.note)
    }

    func testReorderingPreservesIdentityAndRepeatedCanonicalRowsRemainDistinct() throws {
        let first = Data((
            "date,kind,hours,minutes,total_minutes,note\n" +
            "2026-07-11,service,1,0,60,same\n" +
            "2026-07-12,credit,0,1,1,other\n" +
            "2026-07-11,service,1,0,60,same\n").utf8)
        let reordered = Data((
            "date,kind,hours,minutes,total_minutes,note\n" +
            "2026-07-11,service,1,0,60,same\n" +
            "2026-07-11,service,1,0,60,same\n" +
            "2026-07-12,credit,0,1,1,other\n").utf8)

        let firstRows = try CSVImportCodec.decode(data: first).rows
        let reorderedRows = try CSVImportCodec.decode(data: reordered).rows

        XCTAssertEqual(firstRows.filter { $0.values.note == "same" }.map { $0.occurrence }, [1, 2])
        XCTAssertEqual(reorderedRows.filter { $0.values.note == "same" }.map { $0.occurrence }, [1, 2])
        XCTAssertEqual(
            firstRows.filter { $0.values.note == "same" }.map { $0.entryID },
            reorderedRows.filter { $0.values.note == "same" }.map { $0.entryID }
        )
        XCTAssertEqual(firstRows[1].entryID, reorderedRows[2].entryID)
        XCTAssertEqual(firstRows[1].mutationID, reorderedRows[2].mutationID)
        XCTAssertNotEqual(firstRows[0].entryID, firstRows[2].entryID)
        XCTAssertNotEqual(firstRows[0].mutationID, firstRows[2].mutationID)
    }

    func testDeterministicIDsAreUUIDv8AndSeparateEntryAndMutationNamespaces() throws {
        let data = Data("date,kind,hours,minutes,total_minutes\n2026-07-11,service,1,0,60\n".utf8)
        let row = try XCTUnwrap(CSVImportCodec.decode(data: data).rows.first)

        XCTAssertEqual(String(row.entryID.uuidString.lowercased().dropFirst(14).prefix(1)), "8")
        let variant = row.entryID.uuidString.lowercased()[row.entryID.uuidString.lowercased().index(row.entryID.uuidString.lowercased().startIndex, offsetBy: 19)]
        XCTAssertTrue("89ab".contains(variant))
        XCTAssertEqual(row.entryID.uuidString.lowercased(), "bf435c9b-60a5-8c09-9a7b-3669240598f8")
        XCTAssertEqual(row.mutationID.uuidString.lowercased(), "7470e620-0089-8ac0-b8f8-1f7081ffe04d")
        XCTAssertNotEqual(row.entryID, row.mutationID)
        XCTAssertEqual(row.entryID, CSVImportRow.entryID(for: row.values, occurrence: 1))
        XCTAssertEqual(row.mutationID, CSVImportRow.mutationID(for: row.values, occurrence: 1))
    }

    func testRejectsMalformedHeadersAndQuotedHeaderFields() {
        let invalidHeaders = [
            "date,kind,hours,minutes\n",
            "date,kind,hours,total_minutes,minutes\n",
            "Date,kind,hours,minutes,total_minutes\n",
            "date,date,hours,minutes,total_minutes\n",
            "\"date\",kind,hours,minutes,total_minutes\n",
            "date,kind,hours,minutes,total_minutes,extra\n"
        ]

        for header in invalidHeaders {
            XCTAssertThrowsError(try CSVImportCodec.decode(data: Data(header.utf8))) { error in
                XCTAssertEqual(error as? CSVImportCodecError, .invalidHeader)
            }
        }
    }

    func testRejectsCSVGrammarViolations() {
        let invalidRows = [
            "date,kind,hours,minutes,total_minutes\n2026-07-11,service,1,0,60,extra\n",
            "date,kind,hours,minutes,total_minutes,note\n2026-07-11,service,1,0,60,\"not closed\n",
            "date,kind,hours,minutes,total_minutes,note\n2026-07-11,service,1,0,60,\"closed\"junk\n",
            "date,kind,hours,minutes,total_minutes,note\n2026-07-11,service,1,0,60,bare\"quote\n",
            "date,kind,hours,minutes,total_minutes,note\n\n"
        ]

        for source in invalidRows {
            XCTAssertThrowsError(try CSVImportCodec.decode(data: Data(source.utf8))) { error in
                XCTAssertTrue(
                    (error as? CSVImportCodecError) == .malformedCSV ||
                    (error as? CSVImportCodecError) == .invalidRowFieldCount ||
                    (error as? CSVImportCodecError) == .invalidDate
                )
            }
        }
    }

    func testRejectsInvalidRowsAndAppliesDateGateWhenConfigured() {
        let cases: [(String, CSVImportCodecError)] = [
            ("2026-02-30,service,1,0,60", .invalidDate),
            ("2026-07-11,other,1,0,60", .invalidKind),
            ("2026-07-11,service,+1,0,60", .invalidNumber),
            ("2026-07-11,service, 1,0,60", .invalidNumber),
            ("2026-07-11,service,1 ,0,60", .invalidNumber),
            ("2026-07-11,service,1.5,0,90", .invalidNumber),
            ("2026-07-11,service,-1,0,60", .invalidNumber),
            ("2026-07-11,service,1,60,120", .invalidNumber),
            ("2026-07-11,service,1,0,61", .invalidDuration),
            ("2026-07-11,service,0,0,0", .invalidDuration),
            ("2026-07-11,service,100,0,6000", .invalidNumber)
        ]

        for (row, expected) in cases {
            let source = "date,kind,hours,minutes,total_minutes\n\(row)\n"
            XCTAssertThrowsError(try CSVImportCodec.decode(data: Data(source.utf8))) { error in
                XCTAssertEqual(error as? CSVImportCodecError, expected)
            }
        }

        let future = "date,kind,hours,minutes,total_minutes\n2026-07-12,service,1,0,60\n"
        XCTAssertThrowsError(
            try CSVImportCodec(
                authorizationDay: LocalDay(year: 2026, month: 7, day: 11)
            ).decode(data: Data(future.utf8))
        ) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .dateInFuture)
        }

        let beforeStart = "date,kind,hours,minutes,total_minutes\n2026-06-30,service,1,0,60\n"
        XCTAssertThrowsError(
            try CSVImportCodec(
                ledgerStartMonth: MonthKey(year: 2026, month: 7)
            ).decode(data: Data(beforeStart.utf8))
        ) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .beforeLedgerStart)
        }
    }

    func testRowLimitAllowsExactlyTwentyFiveThousandRowsAndRejectsTheNext() throws {
        let header = "date,kind,hours,minutes,total_minutes\n"
        let row = "2026-07-11,service,1,0,60\n"
        let valid = Data((header + String(repeating: row, count: 25_000)).utf8)
        XCTAssertLessThanOrEqual(valid.count, CSVImportCodec.maximumBytes)
        XCTAssertEqual(try CSVImportCodec.decode(data: valid).rows.count, 25_000)

        let overLimit = Data((header + String(repeating: row, count: 25_001)).utf8)
        XCTAssertLessThanOrEqual(overLimit.count, CSVImportCodec.maximumBytes)
        XCTAssertThrowsError(try CSVImportCodec.decode(data: overLimit)) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .tooManyRows)
        }
    }

    func testFormulaAndURLLikeNoteRemainsLiteralData() throws {
        let source = "date,kind,hours,minutes,total_minutes,note\n" +
            "2026-07-11,service,1,0,60,\"=HYPERLINK(\"\"https://example.com\"\",\"\"Open\"\")\"\n"

        let row = try XCTUnwrap(CSVImportCodec.decode(data: Data(source.utf8)).rows.first)

        XCTAssertEqual(row.values.note, "=HYPERLINK(\"https://example.com\",\"Open\")")
    }

    func testRejectsOverlongNoteInvalidUTF8SecondBOMAndOversizedData() {
        let overlongNote = String(repeating: "x", count: 281)
        let source = "date,kind,hours,minutes,total_minutes,note\n2026-07-11,service,1,0,60,\(overlongNote)\n"
        XCTAssertThrowsError(try CSVImportCodec.decode(data: Data(source.utf8))) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .noteTooLong)
        }

        XCTAssertThrowsError(try CSVImportCodec.decode(data: Data([0xff, 0xfe]))) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .invalidUTF8)
        }

        let doubleBOM = Data([0xef, 0xbb, 0xbf, 0xef, 0xbb, 0xbf]) + Data("date,kind,hours,minutes,total_minutes\n".utf8)
        XCTAssertThrowsError(try CSVImportCodec.decode(data: doubleBOM)) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .invalidByteOrderMark)
        }

        let oversized = Data(repeating: 0x20, count: CSVImportCodec.maximumBytes + 1)
        XCTAssertThrowsError(try CSVImportCodec.decode(data: oversized)) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .fileTooLarge)
        }
    }

    func testFileDecoderRequiresCSVRegularFileAndReadsBoundedBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HourleafCSVImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let csvURL = directory.appendingPathComponent("entries.csv")
        let bytes = Data("date,kind,hours,minutes,total_minutes\n".utf8)
        try bytes.write(to: csvURL)
        XCTAssertEqual(try CSVImportCodec.decode(from: csvURL).rows.count, 0)

        let wrongExtension = directory.appendingPathComponent("entries.txt")
        try bytes.write(to: wrongExtension)
        XCTAssertThrowsError(try CSVImportCodec.decode(from: wrongExtension)) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .invalidFileExtension)
        }

        let directoryURL = directory.appendingPathComponent("directory.csv", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try CSVImportCodec.decode(from: directoryURL)) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .fileNotRegular)
        }

        let symlinkURL = directory.appendingPathComponent("link.csv")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: csvURL)
        XCTAssertThrowsError(try CSVImportCodec.decode(from: symlinkURL)) { error in
            XCTAssertEqual(error as? CSVImportCodecError, .fileNotRegular)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
