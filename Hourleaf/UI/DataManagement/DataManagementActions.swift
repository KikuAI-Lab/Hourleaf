import Foundation

/// A redacted restore result. The implementation keeps file access, integrity
/// evidence, and restore coordination behind the action seam.
struct DataManagementRestorePreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let summary: String
    fileprivate let candidateID: RestoreCandidateID?

    init(id: UUID = UUID(), summary: String) {
        self.id = id
        self.summary = summary
        candidateID = nil
    }

    fileprivate init(candidateID: RestoreCandidateID, summary: String) {
        id = UUID()
        self.summary = summary
        self.candidateID = candidateID
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
    let backupStatus: BackupConfidenceStatusModel
    let createBackup: () async throws -> FileSharePayload
    let previewRestore: (URL) async throws -> DataManagementRestorePreview
    let restore: (DataManagementRestorePreview) async throws -> Void
    let discardRestorePreview: (DataManagementRestorePreview) async -> Void
    let exportCSV: (Bool) async throws -> FileSharePayload

    static func live(
        repository: CoreDataLedgerRepository,
        restoreCoordinator: HourleafRestoreCoordinator,
        appModel: AppModel,
        backupEvidenceStore: VerifiedExportEvidenceStore = VerifiedExportEvidenceStore()
    ) -> Self {
        let backupStatus = BackupConfidenceStatusModel(
            evaluator: BackupConfidenceEvaluator(
                evidenceStore: backupEvidenceStore,
                snapshot: { try await repository.portableBackupRecords() }
            )
        )
        return Self(
            restoreAvailability: .available,
            backupStatus: backupStatus,
            createBackup: {
                let directory = try makeShareDirectory()
                do {
                    let artifact = try await HourleafBackupExporter(source: repository)
                        .createVerifiedBackup(in: directory)
                    try await backupEvidenceStore.recordVerifiedExport(for: artifact)
                    backupStatus.requestRefresh()
                    return sharePayload(for: artifact.url, cleaning: directory)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            },
            previewRestore: { url in
                let preview = try await restoreCoordinator.prepare(from: url)
                return DataManagementRestorePreview(
                    candidateID: preview.candidateID,
                    summary: restoreSummary(preview)
                )
            },
            restore: { preview in
                guard let candidateID = preview.candidateID else {
                    throw HourleafRestoreError.candidateUnavailable
                }
                await appModel.prepareForWholeStoreRestore()
                _ = try await restoreCoordinator.confirm(candidateID)
                backupStatus.requestRefresh()
                do {
                    try await appModel.refreshAfterRestore()
                } catch {
                    // The store replacement is already durable. AppModel marks
                    // itself failed so RootView blocks instead of presenting a
                    // retry that could no longer refer to this candidate.
                }
            },
            discardRestorePreview: { preview in
                guard let candidateID = preview.candidateID else { return }
                try? await restoreCoordinator.discardCandidate(candidateID)
            },
            exportCSV: { includeNotes in
                let directory = try makeShareDirectory()
                do {
                    let records = try await repository.fetchAllEntries()
                    let artifact = try CSVExporter().export(
                        records: records,
                        includeNotes: includeNotes,
                        in: directory
                    )
                    return sharePayload(for: artifact.url, cleaning: directory)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw error
                }
            }
        )
    }

    private static func makeShareDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Hourleaf-Share-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        return directory
    }

    private static func sharePayload(for url: URL, cleaning directory: URL) -> FileSharePayload {
        FileSharePayload(url: url) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func restoreSummary(_ preview: RestorePreview) -> String {
        var lines = [String(
            format: String(localized: "data_management.restore.preview_exported"),
            locale: .current,
            preview.exportedAt.formatted(date: .abbreviated, time: .shortened)
        )]
        lines.append(String(
            format: String(localized: "data_management.restore.preview_entries"),
            locale: .current,
            Int64(preview.activeEntryCount),
            Int64(preview.deletedEntryCount)
        ))
        if let range = preview.entryDateRange {
            lines.append(String(
                format: String(localized: "data_management.restore.preview_period"),
                locale: .current,
                range.firstLocalDay,
                range.lastLocalDay
            ))
        }
        lines.append(String(
            format: String(localized: "data_management.restore.preview_details"),
            locale: .current,
            Int64(preview.noteCount),
            Int64(preview.reminderCount),
            Int64(preview.receiptCount),
            Int64(preview.archiveCount)
        ))
        return lines.joined(separator: "\n")
    }
}
