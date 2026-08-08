import CryptoKit
import Foundation

/// The two CSV headers emitted by `CSVExporter`.
enum CSVImportHeader: Equatable, Sendable {
    case withoutNotes
    case withNotes

    var fields: [String] {
        switch self {
        case .withoutNotes:
            ["date", "kind", "hours", "minutes", "total_minutes"]
        case .withNotes:
            ["date", "kind", "hours", "minutes", "total_minutes", "note"]
        }
    }

    var fieldCount: Int { fields.count }
    var includesNotes: Bool { self == .withNotes }
}

/// Errors intentionally contain no source path, row text, or note content.
/// The coordinator can therefore present a sanitized failure without having to
/// scrub parser details first.
enum CSVImportCodecError: Error, Equatable, Sendable {
    case invalidFileExtension
    case fileNotRegular
    case fileReadFailed
    case fileTooLarge
    case invalidUTF8
    case invalidByteOrderMark
    case malformedCSV
    case invalidHeader
    case tooManyRows
    case invalidRowFieldCount
    case invalidDate
    case dateInFuture
    case beforeLedgerStart
    case invalidKind
    case invalidNumber
    case invalidDuration
    case noteTooLong
}

extension CSVImportCodecError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidFileExtension,
             .fileNotRegular,
             .fileReadFailed,
             .fileTooLarge,
             .invalidUTF8,
             .invalidByteOrderMark,
             .malformedCSV,
             .invalidHeader,
             .tooManyRows,
             .invalidRowFieldCount,
             .invalidDate,
             .dateInFuture,
             .beforeLedgerStart,
             .invalidKind,
             .invalidNumber,
             .invalidDuration,
             .noteTooLong:
            "The CSV file could not be imported."
        }
    }
}

struct CSVImportCanonicalRow: Hashable, Equatable, Sendable {
    let localDay: LocalDay
    let kind: EntryKind
    let totalMinutes: Int
    let note: String?

    init(values: EntryMutationValues) {
        self.localDay = values.day
        self.kind = values.kind
        self.totalMinutes = values.minutes
        self.note = values.note
    }

    /// The canonical row is framed as four UTF-8 fields. An empty note is
    /// impossible after `EntryMutationValues` normalization, so a zero-length
    /// field unambiguously represents the nil note case.
    var lengthPrefixedData: Data {
        CSVImportIdentity.frame(fields: [
            localDay.key,
            kind.rawValue,
            String(totalMinutes),
            note ?? ""
        ])
    }
}

struct CSVImportRow: Equatable, Sendable {
    let entryID: UUID
    let mutationID: UUID
    let values: EntryMutationValues
    let occurrence: Int

    init(values: EntryMutationValues, occurrence: Int) {
        precondition(occurrence > 0, "CSV import occurrences are one-based")
        self.values = values
        self.occurrence = occurrence
        self.entryID = CSVImportIdentity.uuid(
            purpose: "entry",
            values: values,
            occurrence: occurrence
        )
        self.mutationID = CSVImportIdentity.uuid(
            purpose: "mutation",
            values: values,
            occurrence: occurrence
        )
    }

    var canonical: CSVImportCanonicalRow { CSVImportCanonicalRow(values: values) }

    static func entryID(for values: EntryMutationValues, occurrence: Int) -> UUID {
        CSVImportIdentity.uuid(purpose: "entry", values: values, occurrence: occurrence)
    }

    static func mutationID(for values: EntryMutationValues, occurrence: Int) -> UUID {
        CSVImportIdentity.uuid(purpose: "mutation", values: values, occurrence: occurrence)
    }
}

struct CSVImportDocument: Equatable, Sendable {
    /// SHA-256 of the exact source bytes, represented as lowercase hex.
    /// Row identities are canonical and remain stable when these bytes are
    /// reordered or line-ending-normalized.
    let digest: String
    let rows: [CSVImportRow]

    var noteCount: Int { rows.lazy.filter { $0.values.note != nil }.count }

    var dateRange: ClosedRange<LocalDay>? {
        guard let first = rows.map(\.values.day).min(),
              let last = rows.map(\.values.day).max()
        else { return nil }
        return first...last
    }
}

enum CSVImportDuplicatePolicy: Equatable, Sendable {
    case skipPossibleMatches
    case includePossibleMatches
}

struct CSVImportPreview: Equatable, Sendable {
    let candidateID: UUID
    let totalRows: Int
    let noteCount: Int
    let dateRange: ClosedRange<LocalDay>?
    let previouslyImportedCount: Int
    let possibleMatchCount: Int
    let importableWhenSkippingMatches: Int
    let importableWhenIncludingMatches: Int
}

struct CSVImportUndoMember: Equatable, Sendable {
    let entryID: UUID
    let importMutationID: UUID
    let expectedRevision: Int64
    let undoMutationID: UUID
}

struct CSVImportUndoToken: Equatable, Sendable {
    let id: UUID
    let members: [CSVImportUndoMember]
    let importedAt: Date
    let expiresAt: Date

    init(
        id: UUID = UUID(),
        members: [CSVImportUndoMember],
        importedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.members = members
        self.importedAt = importedAt
        self.expiresAt = expiresAt
    }
}

struct CSVImportUndoResult: Equatable, Sendable {
    let deletedCount: Int
}

struct CSVImportResult: Equatable, Sendable {
    let importedCount: Int
    let previouslyImportedCount: Int
    let skippedPossibleMatchCount: Int
    let undoToken: CSVImportUndoToken?
}

/// Small, explicit identity helper kept private to the import domain. Each
/// field receives an unsigned big-endian byte length, avoiding delimiter
/// collisions while keeping the seed deterministic across platforms.
enum CSVImportIdentity {
    static let namespace = "hourleaf.csv-import.v1"

    static func frame(fields: [String]) -> Data {
        frame(fields: fields.map { Data($0.utf8) })
    }

    static func frame(fields: [Data]) -> Data {
        var result = Data()
        result.reserveCapacity(fields.reduce(0) { $0 + 8 + $1.count })
        for field in fields {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }

    static func uuid(
        purpose: String,
        values: EntryMutationValues,
        occurrence: Int
    ) -> UUID {
        let canonical = CSVImportCanonicalRow(values: values)
        let seed = frame(fields: [
            Data(namespace.utf8),
            Data(purpose.utf8),
            canonical.lengthPrefixedData,
            Data(String(occurrence).utf8)
        ])
        let digest = SHA256.hash(data: seed)
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUID version 8.
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC 4122 variant 10.
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
