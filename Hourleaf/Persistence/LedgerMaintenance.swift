import Foundation

/// An actor-issued, process-local capability. Its token is intentionally not
/// serializable or user-facing; it exists only to distinguish restore work from
/// ordinary app reads and writes while a whole-store transition is underway.
struct LedgerMaintenanceLease: Equatable, Sendable {
    fileprivate let token: UUID

    init(token: UUID) {
        self.token = token
    }
}

/// Privacy-safe evidence captured from the live store before replacement. The
/// raw records stay actor-internal and are only handed to the frozen backup
/// exporter through `MaintenanceBackupSource`.
struct LedgerMaintenanceCapture: Equatable, Sendable {
    /// Module-internal transaction state. It never crosses into the UI; the
    /// pre-restore exporter must encode these exact captured bytes/records,
    /// rather than opening a second raw read after the maintenance boundary.
    let records: HourleafBackupRecordsV1
    let recordsDigest: String
    let recordCounts: HourleafBackupRecordCountsV1
}

/// Privacy-safe evidence from a post-transition readback. UI can report that
/// validation succeeded without receiving entries, notes, database paths, or
/// journal details.
struct ValidatedReadback: Equatable, Sendable {
    /// Internal forensic evidence for the restore transaction. `recordsDigest`
    /// is the safe value exposed to callers; these digests prove normalization
    /// did not alter raw storage on either side of a fresh-container readback.
    let rawBeforeNormalizationDigest: String
    let rawAfterNormalizationDigest: String
    let recordsDigest: String
    let recordCounts: HourleafBackupRecordCountsV1
}

enum LedgerMaintenanceError: LocalizedError, Equatable, Sendable {
    case alreadyInProgress
    case invalidLease

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "Hourleaf is already maintaining local data."
        case .invalidLease:
            "Hourleaf could not verify the maintenance operation."
        }
    }
}

/// Bridges the frozen Slice 4 exporter to the exact capture that acquired the
/// maintenance boundary. Re-reading the repository here would allow another
/// Core Data writer to make the pre-backup differ from A.
struct CapturedMaintenanceBackupSource: PortableBackupSource {
    let capture: LedgerMaintenanceCapture

    func portableBackupRecords() async throws -> HourleafBackupRecordsV1 {
        capture.records
    }
}
