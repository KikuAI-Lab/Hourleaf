import Foundation

enum CSVExportError: LocalizedError, Equatable, Sendable {
    case destinationUnavailable
    case destinationAlreadyExists
    case writeFailed
    case fileProtectionVerificationFailed

    var errorDescription: String? {
        switch self {
        case .destinationUnavailable:
            "Hourleaf could not access the export destination."
        case .destinationAlreadyExists:
            "A CSV export with this name already exists."
        case .writeFailed:
            "Hourleaf could not write the CSV export."
        case .fileProtectionVerificationFailed:
            "Hourleaf could not verify protection for the CSV export."
        }
    }
}

enum CSVFileProtectionStatus: Equatable, Sendable {
    case protected
    case notVerifiedOnSimulator
}

struct CSVExportArtifact: Equatable, Sendable {
    let url: URL
    let protectionStatus: CSVFileProtectionStatus
}

/// Exports only the active ledger entries into a spreadsheet-only CSV file.
/// This format intentionally has no decoder and is not a backup format.
struct CSVExporter {
    typealias Clock = () -> Date
    typealias FileProtectionReader = (URL) throws -> CSVFileProtectionStatus
    typealias FileWriter = (Data, URL, Data.WritingOptions) throws -> Void

    private let clock: Clock
    private let fileProtectionReader: FileProtectionReader
    private let writeFile: FileWriter

    init(
        clock: @escaping Clock = { .now },
        fileProtectionReader: @escaping FileProtectionReader = { try CSVExporter.systemFileProtectionStatus(at: $0) },
        writeFile: @escaping FileWriter = { data, url, options in try data.write(to: url, options: options) }
    ) {
        self.clock = clock
        self.fileProtectionReader = fileProtectionReader
        self.writeFile = writeFile
    }

    func export(
        records: [LedgerEntryRecord],
        includeNotes: Bool,
        in directory: URL
    ) throws -> CSVExportArtifact {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CSVExportError.destinationUnavailable
        }

        let outputURL = directory.appendingPathComponent(Self.filename(for: clock()), isDirectory: false)
        guard !fileManager.fileExists(atPath: outputURL.path) else {
            throw CSVExportError.destinationAlreadyExists
        }

        let partialURL = directory.appendingPathComponent(
            ".Hourleaf-CSV-\(UUID().uuidString.lowercased()).partial",
            isDirectory: false
        )
        var ownsPartial = false
        var ownsFinal = false
        var publishedFileNumber: NSNumber?
        var shouldKeepFile = false
        defer {
            if !shouldKeepFile {
                if ownsPartial { try? fileManager.removeItem(at: partialURL) }
                // Remove only the inode published by this export. An external
                // writer may atomically replace the final path before a later
                // protection check fails.
                if ownsFinal,
                   let publishedFileNumber,
                   let currentFileNumber = try? Self.fileNumber(at: outputURL, using: fileManager),
                   currentFileNumber == publishedFileNumber {
                    try? fileManager.removeItem(at: outputURL)
                }
            }
        }

        let data = Self.data(for: records, includeNotes: includeNotes)
        let options: Data.WritingOptions = [
            .withoutOverwriting,
            .completeFileProtectionUntilFirstUserAuthentication
        ]

        do {
            // The partial receives the protection class before its first byte
            // is written. `linkItem` publishes those protected bytes without
            // replacing a file another export may have created meanwhile.
            try writeFile(data, partialURL, options)
            ownsPartial = true
        } catch {
            throw CSVExportError.writeFailed
        }

        do {
            publishedFileNumber = try Self.fileNumber(at: partialURL, using: fileManager)
            try fileManager.linkItem(at: partialURL, to: outputURL)
            ownsFinal = true
            try fileManager.removeItem(at: partialURL)
            ownsPartial = false
        } catch {
            if !ownsFinal, fileManager.fileExists(atPath: outputURL.path) {
                throw CSVExportError.destinationAlreadyExists
            }
            throw CSVExportError.writeFailed
        }

        let protectionStatus: CSVFileProtectionStatus
        do {
            protectionStatus = try fileProtectionReader(outputURL)
        } catch {
            throw CSVExportError.fileProtectionVerificationFailed
        }

        shouldKeepFile = true
        return CSVExportArtifact(url: outputURL, protectionStatus: protectionStatus)
    }

    static func data(for records: [LedgerEntryRecord], includeNotes: Bool) -> Data {
        let activeEntries = records
            .lazy
            .filter { !$0.isDeleted }
            .map(\.entry)
            .sorted(by: entryOrder)

        var rows = [includeNotes
            ? "date,kind,hours,minutes,total_minutes,note"
            : "date,kind,hours,minutes,total_minutes"
        ]
        rows.reserveCapacity(activeEntries.count + 1)

        for entry in activeEntries {
            var fields = [
                entry.day.key,
                entry.kind.rawValue,
                String(entry.minutes / 60),
                String(entry.minutes % 60),
                String(entry.minutes)
            ]
            if includeNotes {
                fields.append(entry.note ?? "")
            }
            rows.append(fields.map(escapedField).joined(separator: ","))
        }

        let contents = rows.joined(separator: "\r\n") + "\r\n"
        return Data([0xEF, 0xBB, 0xBF]) + Data(contents.utf8)
    }

    static func filename(for date: Date) -> String {
        "Hourleaf-entries-\(LocalDay(date, calendar: .hourleaf).key).csv"
    }

    private static func entryOrder(_ lhs: TimeEntry, _ rhs: TimeEntry) -> Bool {
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private static func escapedField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func systemFileProtectionStatus(at url: URL) throws -> CSVFileProtectionStatus {
        #if targetEnvironment(simulator)
        // Simulator file systems do not provide device data-protection evidence.
        return .notVerifiedOnSimulator
        #else
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication else {
            throw CSVExportError.fileProtectionVerificationFailed
        }
        return .protected
        #endif
    }

    private static func fileNumber(at url: URL, using fileManager: FileManager) throws -> NSNumber {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw CSVExportError.writeFailed
        }
        return number
    }
}
