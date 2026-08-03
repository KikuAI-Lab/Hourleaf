import Foundation

/// Opaque handle for the single staged candidate. Its UUID is not a backup
/// record ID and cannot be used to derive a file or database path.
struct RestoreCandidateID: Hashable, Sendable {
    fileprivate let value: UUID

    init() {
        value = UUID()
    }
}

struct RestoreDateRange: Equatable, Sendable {
    let firstLocalDay: String
    let lastLocalDay: String
}

/// Deliberately contains only preview-safe aggregate values. Notes, record
/// identifiers, raw dates, paths, and journal details remain inside the actor.
struct RestorePreview: Equatable, Sendable {
    let candidateID: RestoreCandidateID
    let exportedAt: Date
    let formatVersion: Int
    let activeEntryCount: Int
    let deletedEntryCount: Int
    let entryDateRange: RestoreDateRange?
    let noteCount: Int
    let reminderCount: Int
    let receiptCount: Int
    let archiveCount: Int
}

/// The complete logical identity used to decide whether a freshly opened
/// store is the original ledger (A) or the prepared candidate (B). A digest
/// alone is deliberately insufficient: the count vector makes every terminal
/// decision bind the full backup-shaped record set.
struct RestoreLogicalProof: Equatable, Sendable {
    let recordsDigest: String
    let recordCounts: HourleafBackupRecordCountsV1
}

enum RestoreSelectedTarget: Equatable, Sendable {
    case original
    case candidate
}

struct RestoreCommitResult: Equatable, Sendable {
    let selectedTarget: RestoreSelectedTarget
    let recordsDigest: String
    let recordCounts: HourleafBackupRecordCountsV1
}

/// The runtime is intentionally returned only after bootstrap has completed
/// journal preflight and, when necessary, exact recovery proof.
struct RestoreReadyRuntime: Sendable {
    let persistence: PersistenceController
    let repository: CoreDataLedgerRepository
}

enum RestoreBootstrapResult: Sendable {
    case ready(RestoreReadyRuntime)
    case blocked(RedactedRestoreCriticalState)
}

enum HourleafRestoreError: LocalizedError, Equatable, Sendable {
    case cloudStoreUnsupported
    case invalidFileSelection
    case candidateUnavailable
    case candidateMismatch
    case preparationFailed
    case importVerificationFailed
    case replacementFailed
    case recoveryRequired
    case criticalRecoveryRequired

    var errorDescription: String? {
        switch self {
        case .cloudStoreUnsupported:
            "Hourleaf cannot restore while private cloud data is active. Your data is unchanged."
        case .invalidFileSelection:
            "Choose a regular .hourleafbackup file."
        case .candidateUnavailable:
            "This restore preview is no longer available. Choose the backup again."
        case .candidateMismatch:
            "Hourleaf refused a restore confirmation for a different preview."
        case .preparationFailed:
            "Hourleaf could not prepare that backup for restore."
        case .importVerificationFailed:
            "Hourleaf could not verify the staged backup."
        case .replacementFailed:
            "Hourleaf could not safely replace local data."
        case .recoveryRequired:
            "Hourleaf must recover local data before it can open normally."
        case .criticalRecoveryRequired:
            "Hourleaf kept recovery evidence because local data needs manual recovery."
        }
    }
}

enum RestoreFaultPoint: Equatable, Sendable {
    case stagedImportBatch(Int)
    case candidateStoreCleanup
    case candidateStoreDestroyedBeforeProof
    case candidateBackupCleanup
    case journalPhase(String)
    case confirmationBoundary(String)
    case recoveryBoundary(String)
}

/// Tests may inject a deterministic failure after any bounded staging batch or
/// journal phase. Production uses the empty injector.
typealias RestoreFaultInjector = @Sendable (RestoreFaultPoint) throws -> Void

/// iOS Simulator cannot prove device data-protection state. The production
/// reader reports a value only when Foundation exposes one; tests inject a
/// reader to exercise success and mismatch paths without claiming a device
/// protection pass.
protocol HourleafFileProtectionReading: Sendable {
    func protectionClass(at url: URL) throws -> String?
}

struct FoundationFileProtectionReader: HourleafFileProtectionReading {
    func protectionClass(at url: URL) throws -> String? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let value = attributes[.protectionKey] as? FileProtectionType {
            return value.rawValue
        }
        if let value = attributes[.protectionKey] as? String {
            return value
        }
        return nil
    }
}
