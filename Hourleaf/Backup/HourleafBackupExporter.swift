import Foundation

enum HourleafBackupExportError: LocalizedError, Equatable, Sendable {
    case destinationUnavailable(String)
    case destinationAlreadyExists(String)
    case diskWriteFailed(String)
    case readBackFailed(String)
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case let .destinationUnavailable(path):
            "The backup destination is unavailable: \(path)"
        case let .destinationAlreadyExists(path):
            "A backup already exists at \(path)"
        case let .diskWriteFailed(reason):
            "Hourleaf could not write the backup: \(reason)"
        case let .readBackFailed(reason):
            "Hourleaf could not read back the backup: \(reason)"
        case .verificationFailed:
            "Hourleaf could not verify the written backup."
        }
    }
}

struct HourleafBackupArtifactV1: Equatable, Sendable {
    let url: URL
    let exportedAt: Date
    let byteCount: Int
    let checksum: HourleafBackupChecksumV1
    let recordCounts: HourleafBackupRecordCountsV1
    let recordsDigest: String
}

struct HourleafBackupExporter: Sendable {
    typealias ReadBack = @Sendable (URL) throws -> Data
    typealias BeforePublication = @Sendable (URL) throws -> Void

    private let source: any PortableBackupSource
    private let readBack: ReadBack
    private let beforePublication: BeforePublication

    init(
        source: any PortableBackupSource,
        readBack: @escaping ReadBack = { try Data(contentsOf: $0) },
        beforePublication: @escaping BeforePublication = { _ in }
    ) {
        self.source = source
        self.readBack = readBack
        self.beforePublication = beforePublication
    }

    /// Creates a single canonical export from one actor-isolated raw snapshot.
    /// A file is returned only after atomic same-directory publication and a
    /// complete disk reread/decode/hash/semantic comparison.
    func createVerifiedBackup(
        in directory: URL,
        exportedAt: Date = .now
    ) async throws -> HourleafBackupArtifactV1 {
        let values = try await source.portableBackupRecords()
        let content = HourleafBackupContentV1(
            exportedAt: exportedAt.timeIntervalSinceReferenceDate,
            records: values
        )
        let expected = try HourleafBackupCodec.encode(content: content)
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw HourleafBackupExportError.destinationUnavailable(directory.path)
        }

        let filename = Self.filename(for: exportedAt, checksum: expected.checksum.value)
        let finalURL = directory.appendingPathComponent(filename, isDirectory: false)
        guard !fileManager.fileExists(atPath: finalURL.path) else {
            throw HourleafBackupExportError.destinationAlreadyExists(finalURL.path)
        }

        let partialURL = directory.appendingPathComponent(
            ".Hourleaf-Backup-\(UUID().uuidString.lowercased()).partial",
            isDirectory: false
        )
        var ownsPartial = false
        var ownsFinal = false
        var publishedFileNumber: NSNumber?
        var succeeded = false
        defer {
            if !succeeded {
                if ownsPartial { try? fileManager.removeItem(at: partialURL) }
                // Remove a damaged file that is still the inode we published.
                // An external writer that atomically replaced the path gets a
                // different file number, so its file is never deleted merely
                // because this export failed verification.
                if ownsFinal,
                   let publishedFileNumber,
                   let currentFileNumber = try? Self.fileNumber(at: finalURL, using: fileManager),
                   currentFileNumber == publishedFileNumber {
                    try? fileManager.removeItem(at: finalURL)
                }
            }
        }

        do {
            // File protection is selected when the partial is created, so no
            // unprotected bytes exist between writing and publication.
            try expected.data.write(
                to: partialURL,
                options: [
                    .withoutOverwriting,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
            ownsPartial = true
            // Test seam for the exact non-cooperating-writer window between
            // the early existence check and the exclusive publication link.
            try beforePublication(finalURL)
        } catch {
            throw HourleafBackupExportError.diskWriteFailed(error.localizedDescription)
        }

        do {
            // The random partial is task-owned and shares the final's volume.
            // POSIX link creation fails with EEXIST instead of replacing a
            // destination, closing the TOCTOU window left by `moveItem`.
            publishedFileNumber = try Self.fileNumber(at: partialURL, using: fileManager)
            try fileManager.linkItem(at: partialURL, to: finalURL)
            ownsFinal = true
            try fileManager.removeItem(at: partialURL)
            ownsPartial = false
        } catch {
            // A non-cooperating writer or another export can win after the
            // initial existence check. `linkItem` never overwrites that final.
            if !ownsFinal, fileManager.fileExists(atPath: finalURL.path) {
                throw HourleafBackupExportError.destinationAlreadyExists(finalURL.path)
            }
            throw HourleafBackupExportError.diskWriteFailed(error.localizedDescription)
        }

        let rereadData: Data
        do {
            rereadData = try readBack(finalURL)
        } catch {
            throw HourleafBackupExportError.readBackFailed(error.localizedDescription)
        }

        let reread: VerifiedHourleafBackupV1
        do {
            reread = try HourleafBackupCodec.decodeAndVerify(rereadData)
        } catch {
            throw HourleafBackupExportError.verificationFailed
        }
        guard reread.data == expected.data else {
            throw HourleafBackupExportError.verificationFailed
        }

        succeeded = true
        return HourleafBackupArtifactV1(
            url: finalURL,
            exportedAt: exportedAt,
            byteCount: expected.byteCount,
            checksum: expected.checksum,
            recordCounts: expected.recordCounts,
            recordsDigest: expected.recordsDigest
        )
    }

    private static func filename(for date: Date, checksum: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return "Hourleaf-Backup-\(formatter.string(from: date))-\(checksum.prefix(8)).hourleafbackup"
    }

    private static func fileNumber(at url: URL, using fileManager: FileManager) throws -> NSNumber {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let number = attributes[.systemFileNumber] as? NSNumber else {
            throw HourleafBackupExportError.diskWriteFailed(
                "Hourleaf could not establish ownership of the published backup."
            )
        }
        return number
    }
}
