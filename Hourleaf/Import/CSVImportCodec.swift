import Foundation

struct CSVImportCodec: Sendable {
    static let maximumBytes = 8 * 1024 * 1024
    static let maximumDataRows = 25_000

    private static let readChunkSize = 64 * 1024

    private let authorizationDay: LocalDay?
    private let ledgerStartMonth: MonthKey?

    init(
        authorizationDay: LocalDay? = nil,
        ledgerStartMonth: MonthKey? = nil
    ) {
        self.authorizationDay = authorizationDay
        self.ledgerStartMonth = ledgerStartMonth
    }

    func decode(data: Data) throws -> CSVImportDocument {
        try Self.decode(
            data: data,
            authorizationDay: authorizationDay,
            ledgerStartMonth: ledgerStartMonth
        )
    }

    func decode(from url: URL) throws -> CSVImportDocument {
        try Self.decode(
            from: url,
            authorizationDay: authorizationDay,
            ledgerStartMonth: ledgerStartMonth
        )
    }

    static func decode(
        data: Data,
        authorizationDay: LocalDay? = nil,
        ledgerStartMonth: MonthKey? = nil
    ) throws -> CSVImportDocument {
        guard data.count <= maximumBytes else { throw CSVImportCodecError.fileTooLarge }

        var bytes = Array(data)
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) {
            bytes.removeFirst(3)
            guard !bytes.starts(with: [0xef, 0xbb, 0xbf]) else {
                throw CSVImportCodecError.invalidByteOrderMark
            }
        }

        guard String(data: Data(bytes), encoding: .utf8) != nil else {
            throw CSVImportCodecError.invalidUTF8
        }

        let records = try parseRecords(bytes)
        guard let headerRecord = records.first else {
            throw CSVImportCodecError.invalidHeader
        }

        let header = try parseHeader(headerRecord)
        let dataRecords = records.dropFirst()
        guard dataRecords.count <= maximumDataRows else {
            throw CSVImportCodecError.tooManyRows
        }

        var canonicalOccurrences = [CSVImportCanonicalRow: Int]()
        var rows = [CSVImportRow]()
        rows.reserveCapacity(dataRecords.count)

        for record in dataRecords {
            guard record.fields.count == header.fieldCount else {
                throw CSVImportCodecError.invalidRowFieldCount
            }
            let values = try parseValues(
                record,
                header: header,
                authorizationDay: authorizationDay,
                ledgerStartMonth: ledgerStartMonth
            )
            let canonical = CSVImportCanonicalRow(values: values)
            let occurrence = canonicalOccurrences[canonical, default: 0] + 1
            canonicalOccurrences[canonical] = occurrence
            rows.append(CSVImportRow(values: values, occurrence: occurrence))
        }

        return CSVImportDocument(
            digest: CSVImportIdentity.sha256Hex(data),
            rows: rows
        )
    }

    static func decode(
        from url: URL,
        authorizationDay: LocalDay? = nil,
        ledgerStartMonth: MonthKey? = nil
    ) throws -> CSVImportDocument {
        guard url.pathExtension == "csv" else {
            throw CSVImportCodecError.invalidFileExtension
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CSVImportCodecError.fileNotRegular
        }

        do {
            let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard resourceValues.isRegularFile == true, resourceValues.isSymbolicLink != true else {
                throw CSVImportCodecError.fileNotRegular
            }
        } catch let error as CSVImportCodecError {
            throw error
        } catch {
            throw CSVImportCodecError.fileReadFailed
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                throw CSVImportCodecError.fileNotRegular
            }
            if let size = attributes[.size] as? NSNumber,
               size.uint64Value > UInt64(maximumBytes) {
                throw CSVImportCodecError.fileTooLarge
            }
        } catch let error as CSVImportCodecError {
            throw error
        } catch {
            throw CSVImportCodecError.fileReadFailed
        }

        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var bounded = Data()
            bounded.reserveCapacity(min(maximumBytes, 256 * 1024))
            while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
                guard bounded.count <= maximumBytes - chunk.count else {
                    throw CSVImportCodecError.fileTooLarge
                }
                bounded.append(chunk)
            }
            data = bounded
        } catch let error as CSVImportCodecError {
            throw error
        } catch {
            throw CSVImportCodecError.fileReadFailed
        }

        return try decode(
            data: data,
            authorizationDay: authorizationDay,
            ledgerStartMonth: ledgerStartMonth
        )
    }

    private struct ParsedField: Equatable {
        let bytes: [UInt8]
        let wasQuoted: Bool
    }

    private struct ParsedRecord: Equatable {
        let fields: [ParsedField]
        let hadContent: Bool
    }

    private static func parseRecords(_ bytes: [UInt8]) throws -> [ParsedRecord] {
        var records = [ParsedRecord]()
        var fields = [ParsedField]()
        var fieldBytes = [UInt8]()
        var fieldWasQuoted = false
        var inQuotes = false
        var afterClosingQuote = false
        var fieldHasContent = false
        var recordHasContent = false
        var index = 0

        func finishField() {
            fields.append(ParsedField(bytes: fieldBytes, wasQuoted: fieldWasQuoted))
            fieldBytes.removeAll(keepingCapacity: true)
            fieldWasQuoted = false
            fieldHasContent = false
        }

        func finishRecord() throws {
            guard recordHasContent else { throw CSVImportCodecError.malformedCSV }
            finishField()
            records.append(ParsedRecord(fields: fields, hadContent: true))
            fields.removeAll(keepingCapacity: true)
            recordHasContent = false
        }

        while index < bytes.count {
            let byte = bytes[index]

            if inQuotes {
                if byte == 0x22 { // quote
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        fieldBytes.append(0x22)
                        fieldHasContent = true
                        recordHasContent = true
                        index += 2
                    } else {
                        inQuotes = false
                        afterClosingQuote = true
                        index += 1
                    }
                } else {
                    fieldBytes.append(byte)
                    fieldHasContent = true
                    recordHasContent = true
                    index += 1
                }
                continue
            }

            if afterClosingQuote {
                switch byte {
                case 0x2c: // comma
                    finishField()
                    afterClosingQuote = false
                    recordHasContent = true
                    index += 1
                case 0x0a: // LF
                    try finishRecord()
                    afterClosingQuote = false
                    index += 1
                case 0x0d: // CRLF only
                    guard index + 1 < bytes.count, bytes[index + 1] == 0x0a else {
                        throw CSVImportCodecError.malformedCSV
                    }
                    try finishRecord()
                    afterClosingQuote = false
                    index += 2
                default:
                    throw CSVImportCodecError.malformedCSV
                }
                continue
            }

            switch byte {
            case 0x22: // quote
                guard !fieldHasContent else { throw CSVImportCodecError.malformedCSV }
                inQuotes = true
                fieldWasQuoted = true
                fieldHasContent = true
                recordHasContent = true
                index += 1
            case 0x2c: // comma
                finishField()
                recordHasContent = true
                index += 1
            case 0x0a: // LF
                try finishRecord()
                index += 1
            case 0x0d: // CRLF only
                guard index + 1 < bytes.count, bytes[index + 1] == 0x0a else {
                    throw CSVImportCodecError.malformedCSV
                }
                try finishRecord()
                index += 2
            default:
                fieldBytes.append(byte)
                fieldHasContent = true
                recordHasContent = true
                index += 1
            }
        }

        guard !inQuotes else { throw CSVImportCodecError.malformedCSV }
        guard !afterClosingQuote else {
            try finishRecord()
            return records
        }
        if recordHasContent || !fields.isEmpty || !fieldBytes.isEmpty {
            try finishRecord()
        }
        return records
    }

    private static func parseHeader(_ record: ParsedRecord) throws -> CSVImportHeader {
        guard record.fields.allSatisfy({ !$0.wasQuoted }) else {
            throw CSVImportCodecError.invalidHeader
        }
        let fields = record.fields.map { String(decoding: $0.bytes, as: UTF8.self) }
        if fields == CSVImportHeader.withoutNotes.fields {
            return .withoutNotes
        }
        if fields == CSVImportHeader.withNotes.fields {
            return .withNotes
        }
        throw CSVImportCodecError.invalidHeader
    }

    private static func parseValues(
        _ record: ParsedRecord,
        header: CSVImportHeader,
        authorizationDay: LocalDay?,
        ledgerStartMonth: MonthKey?
    ) throws -> EntryMutationValues {
        let strings = record.fields.map { String(decoding: $0.bytes, as: UTF8.self) }
        guard let day = parseDay(strings[0]) else { throw CSVImportCodecError.invalidDate }
        if let authorizationDay, day > authorizationDay {
            throw CSVImportCodecError.dateInFuture
        }
        if let ledgerStartMonth, day.monthKey < ledgerStartMonth {
            throw CSVImportCodecError.beforeLedgerStart
        }

        guard let kind = EntryKind(rawValue: strings[1]) else {
            throw CSVImportCodecError.invalidKind
        }
        let hours = try parseDecimal(strings[2], maximum: 99)
        let minutes = try parseDecimal(strings[3], maximum: 59)
        let total = try parseDecimal(strings[4], maximum: 5_999)
        guard total > 0, total == hours * 60 + minutes else {
            throw CSVImportCodecError.invalidDuration
        }

        var note: String?
        if header.includesNotes {
            let normalized = strings[5].trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalized.count <= 280 else { throw CSVImportCodecError.noteTooLong }
            note = normalized.isEmpty ? nil : normalized
        }

        return EntryMutationValues(kind: kind, day: day, minutes: total, note: note)
    }

    private static func parseDay(_ value: String) -> LocalDay? {
        guard value.utf8.count == 10,
              value.utf8.allSatisfy({ $0 == 0x2d || (0x30...0x39).contains($0) })
        else { return nil }
        return LocalDay(key: value)
    }

    private static func parseDecimal(_ value: String, maximum: Int) throws -> Int {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) })
        else { throw CSVImportCodecError.invalidNumber }
        var result = 0
        for byte in value.utf8 {
            let digit = Int(byte - 0x30)
            guard result <= (maximum - digit) / 10 else {
                throw CSVImportCodecError.invalidNumber
            }
            result = result * 10 + digit
        }
        guard result <= maximum else { throw CSVImportCodecError.invalidNumber }
        return result
    }
}
