import Foundation

enum VerifiedExportEvidenceStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case invalidEvidence
    case invalidDirectory
    case invalidFile
    case writeFailed
    case readFailed
    case publishFailed
}

actor VerifiedExportEvidenceStore {
    typealias ApplicationSupportDirectory = @Sendable () -> URL?
    typealias DataReader = @Sendable (URL) throws -> Data
    typealias DataWriter = @Sendable (Data, URL, Data.WritingOptions) throws -> Void
    typealias UUIDSource = @Sendable () -> UUID

    private static let schemaVersion = 1
    private static let maximumArtifactBytes = 32 * 1_024 * 1_024
    private static let maximumRecordCount = 250_000

    private let fileManager: FileManager
    private let applicationSupportDirectory: ApplicationSupportDirectory
    private let dataReader: DataReader
    private let dataWriter: DataWriter
    private let uuidSource: UUIDSource

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: @escaping ApplicationSupportDirectory = {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        },
        dataReader: @escaping DataReader = { try Data(contentsOf: $0) },
        dataWriter: @escaping DataWriter = { data, url, options in try data.write(to: url, options: options) },
        uuidSource: @escaping UUIDSource = UUID.init
    ) {
        self.fileManager = fileManager
        self.applicationSupportDirectory = applicationSupportDirectory
        self.dataReader = dataReader
        self.dataWriter = dataWriter
        self.uuidSource = uuidSource
    }

    func read() throws -> VerifiedExportEvidenceV1? {
        let finalURL = try evidenceFileURL()
        guard fileManager.fileExists(atPath: finalURL.path) else {
            return nil
        }
        return try decodeValidatedEvidence(at: finalURL)
    }

    func recordVerifiedExport(
        for artifact: HourleafBackupArtifactV1,
        verifiedAt: Date = .now
    ) throws {
        try replace(
            with: VerifiedExportEvidenceV1(
                schemaVersion: Self.schemaVersion,
                exportedAt: artifact.exportedAt,
                verifiedAt: verifiedAt,
                artifactChecksum: artifact.checksum.value,
                recordsDigest: artifact.recordsDigest,
                byteCount: artifact.byteCount,
                totalRecordCount: artifact.recordCounts.total
            )
        )
    }

    func replace(with evidence: VerifiedExportEvidenceV1) throws {
        let canonicalEvidence = try Self.canonicalized(evidence)
        try Self.validate(canonicalEvidence)

        let finalURL = try evidenceFileURL()
        let directory = finalURL.deletingLastPathComponent()
        try ensureDirectoryExists(at: directory)
        let encoded = try Self.encode(canonicalEvidence)

        let partialURL = directory.appendingPathComponent(
            ".last-verified-export-v1.\(uuidSource().uuidString.lowercased()).partial",
            isDirectory: false
        )
        let backupURL = directory.appendingPathComponent(
            ".last-verified-export-v1.\(uuidSource().uuidString.lowercased()).backup",
            isDirectory: false
        )

        var ownsPartial = false
        var ownsFinal = false
        var backupExists = false
        defer {
            if ownsPartial { try? fileManager.removeItem(at: partialURL) }
            if backupExists {
                try? fileManager.removeItem(at: backupURL)
            }
        }

        do {
            try dataWriter(
                encoded,
                partialURL,
                [
                    .withoutOverwriting,
                    .completeFileProtectionUntilFirstUserAuthentication
                ]
            )
            ownsPartial = true
        } catch {
            throw VerifiedExportEvidenceStoreError.writeFailed
        }

        guard try decodeValidatedEvidence(at: partialURL) == canonicalEvidence else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }

        do {
            if fileManager.fileExists(atPath: finalURL.path) {
                if fileManager.fileExists(atPath: backupURL.path) {
                    try fileManager.removeItem(at: backupURL)
                }
                try fileManager.copyItem(at: finalURL, to: backupURL)
                backupExists = true
                _ = try fileManager.replaceItemAt(
                    finalURL,
                    withItemAt: partialURL
                )
            } else {
                try fileManager.moveItem(at: partialURL, to: finalURL)
            }
            ownsPartial = false
            ownsFinal = true
        } catch {
            throw VerifiedExportEvidenceStoreError.publishFailed
        }

        do {
            guard try decodeValidatedEvidence(at: finalURL) == canonicalEvidence else {
                throw VerifiedExportEvidenceStoreError.invalidEvidence
            }
        } catch {
            if backupExists, fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: finalURL)
                try? fileManager.moveItem(at: backupURL, to: finalURL)
                backupExists = false
            } else if ownsFinal {
                try? fileManager.removeItem(at: finalURL)
            }
            throw error
        }

        if backupExists, fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
            backupExists = false
        }
    }

    private func evidenceFileURL() throws -> URL {
        guard let applicationSupport = applicationSupportDirectory()?.standardizedFileURL else {
            throw VerifiedExportEvidenceStoreError.applicationSupportUnavailable
        }
        return applicationSupport
            .appendingPathComponent("Hourleaf", isDirectory: true)
            .appendingPathComponent("BackupEvidence", isDirectory: true)
            .appendingPathComponent("last-verified-export-v1.json", isDirectory: false)
    }

    private func ensureDirectoryExists(at url: URL) throws {
        let applicationRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        let directories = [applicationRoot, url.deletingLastPathComponent(), url]
        for directory in directories {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else {
                    throw VerifiedExportEvidenceStoreError.invalidDirectory
                }
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: false,
                    attributes: [
                        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                    ]
                )
            } catch {
                throw VerifiedExportEvidenceStoreError.writeFailed
            }
        }
    }

    private func decodeValidatedEvidence(at url: URL) throws -> VerifiedExportEvidenceV1 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VerifiedExportEvidenceStoreError.invalidFile
        }

        let data: Data
        do {
            data = try dataReader(url)
        } catch {
            throw VerifiedExportEvidenceStoreError.readFailed
        }

        let evidence: VerifiedExportEvidenceV1
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom(Self.decodeDate)
            evidence = try decoder.decode(VerifiedExportEvidenceV1.self, from: data)
        } catch {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
        try Self.validate(evidence)
        return evidence
    }

    private static func encode(_ evidence: VerifiedExportEvidenceV1) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        do {
            return try encoder.encode(evidence)
        } catch {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
    }

    private static func validate(_ evidence: VerifiedExportEvidenceV1) throws {
        guard evidence.schemaVersion == schemaVersion else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
        let exportedAt = evidence.exportedAt.timeIntervalSinceReferenceDate
        let verifiedAt = evidence.verifiedAt.timeIntervalSinceReferenceDate
        guard exportedAt.isFinite, verifiedAt.isFinite, evidence.exportedAt <= evidence.verifiedAt else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
        guard isLowercaseSHA256(evidence.artifactChecksum), isLowercaseSHA256(evidence.recordsDigest) else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
        guard (1...maximumArtifactBytes).contains(evidence.byteCount) else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
        guard (1...maximumRecordCount).contains(evidence.totalRecordCount) else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.allSatisfy { character in
            switch character {
            case "0"..."9", "a"..."f":
                return true
            default:
                return false
            }
        }
    }

    private static func canonicalized(_ evidence: VerifiedExportEvidenceV1) throws -> VerifiedExportEvidenceV1 {
        VerifiedExportEvidenceV1(
            schemaVersion: evidence.schemaVersion,
            exportedAt: try canonicalizedDate(evidence.exportedAt),
            verifiedAt: try canonicalizedDate(evidence.verifiedAt),
            artifactChecksum: evidence.artifactChecksum,
            recordsDigest: evidence.recordsDigest,
            byteCount: evidence.byteCount,
            totalRecordCount: evidence.totalRecordCount
        )
    }

    private static func canonicalizedDate(_ date: Date) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let encoded = formatter.string(from: date)
        guard let decoded = formatter.date(from: encoded) else {
            throw VerifiedExportEvidenceStoreError.invalidEvidence
        }
        return decoded
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainFormatter = ISO8601DateFormatter()
        plainFormatter.formatOptions = [.withInternetDateTime]
        if let parsed = fractionalFormatter.date(from: value)
            ?? plainFormatter.date(from: value) {
            return parsed
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO8601 date.")
    }
}
