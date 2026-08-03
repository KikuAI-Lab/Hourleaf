import Foundation

/// A redacted restore result. The implementation keeps file access, integrity
/// evidence, and restore coordination behind the action seam.
struct DataManagementRestorePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let summary: String

    init(id: UUID = UUID(), summary: String) {
        self.id = id
        self.summary = summary
    }
}

enum DataManagementRestoreAvailability: Equatable, Sendable {
    case available
    case unavailableWhileICloudSyncIsOn

    var isAvailable: Bool { self == .available }
}

/// Pure UI lifecycle state so restore completion and view disappearance cannot
/// race the backend's candidate cleanup.
struct DataManagementRestoreState: Equatable {
    private(set) var preview: DataManagementRestorePreview?
    var isConfirmed = false
    private(set) var isVisible = true

    mutating func appear() {
        isVisible = true
    }

    @discardableResult
    mutating func replacePreview(with preview: DataManagementRestorePreview) -> DataManagementRestorePreview? {
        let previous = self.preview
        self.preview = preview
        isConfirmed = false
        return previous
    }

    mutating func disappear(restoreInFlight: Bool) -> DataManagementRestorePreview? {
        isVisible = false
        isConfirmed = false
        guard !restoreInFlight else { return nil }
        return takePreviewForDiscard()
    }

    /// Success always consumes the candidate. Failure keeps it only while the
    /// view remains visible so the user can explicitly confirm a retry.
    mutating func finishRestore(succeeded: Bool) -> DataManagementRestorePreview? {
        isConfirmed = false
        guard succeeded || !isVisible else { return nil }
        return takePreviewForDiscard()
    }

    mutating func takePreviewForDiscard() -> DataManagementRestorePreview? {
        defer { preview = nil }
        isConfirmed = false
        return preview
    }
}

/// The leaf UI depends only on user-intent actions, so app wiring can own the
/// model, security-scoped file access, and restore coordinator separately.
@MainActor
struct DataManagementActions {
    let restoreAvailability: DataManagementRestoreAvailability
    let createBackup: () async throws -> FileSharePayload
    let previewRestore: (URL) async throws -> DataManagementRestorePreview
    let restore: (DataManagementRestorePreview) async throws -> Void
    let discardRestorePreview: (DataManagementRestorePreview) async -> Void
    let exportCSV: (Bool) async throws -> FileSharePayload
}
