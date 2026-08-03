import Foundation

struct VerifiedExportEvidenceV1: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let exportedAt: Date
    let verifiedAt: Date
    let artifactChecksum: String
    let recordsDigest: String
    let byteCount: Int
    let totalRecordCount: Int
}

enum BackupConfidenceState: Equatable, Sendable {
    case noVerifiedExport
    case matches(verifiedAt: Date)
    case recordsChanged(verifiedAt: Date)
    case unavailable
}

extension BackupConfidenceState {
    var localizedStatusText: String {
        switch self {
        case .noVerifiedExport:
            return String(localized: "backup_status.none")
        case let .matches(verifiedAt):
            return String(
                format: String(localized: "backup_status.matches_format"),
                locale: .current,
                verifiedAt.formatted(date: .abbreviated, time: .shortened)
            )
        case let .recordsChanged(verifiedAt):
            return String(
                format: String(localized: "backup_status.changed_format"),
                locale: .current,
                verifiedAt.formatted(date: .abbreviated, time: .shortened)
            )
        case .unavailable:
            return String(localized: "backup_status.unavailable")
        }
    }
}
