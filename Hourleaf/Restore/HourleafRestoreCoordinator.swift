@preconcurrency import CoreData
import Foundation

/// Narrow local-only restore coordinator. Preparation is completely isolated
/// from the live container: input becomes an app-owned protected file, then a
/// separately opened CloudKit-off SQLite store that must survive raw/domain/raw
/// validation before a preview is exposed.
actor HourleafRestoreCoordinator {
    private struct Candidate: Sendable {
        let id: RestoreCandidateID
        let preview: RestorePreview
        let backupFileURL: URL
        let storeCleanup: PersistentStoreCleanupCapability
        let recordsDigest: String
    }

    private enum PendingStoreCleanup: Sendable {
        case relinquished(PersistentStoreCleanupCapability)
        case owned(PersistenceController, PersistentStoreArtifact)
    }

    private static let protectionClass = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    private static let stagingDirectoryName = "RestoreStaging"
    private static let stagedBackupFilename = "candidate.hourleafbackup"
    private static let stagedStoreFilename = "candidate.sqlite"

    private let persistence: PersistenceController
    private let repository: CoreDataLedgerRepository
    private let liveStoreMode: @Sendable () -> PersistentStoreMode
    private let rootDirectory: URL
    private let protectionReader: any HourleafFileProtectionReading
    private let faultInjector: RestoreFaultInjector
    private var candidate: Candidate?
    private var pendingStoreCleanup: [PendingStoreCleanup] = []
    private var pendingBackupCleanup: [URL] = []
    private var didReclaimInitialSlot = false

    init(
        persistence: PersistenceController,
        repository: CoreDataLedgerRepository,
        rootDirectory: URL? = nil,
        protectionReader: any HourleafFileProtectionReading = FoundationFileProtectionReader(),
        liveStoreMode: (@Sendable () -> PersistentStoreMode)? = nil,
        faultInjector: @escaping RestoreFaultInjector = { _ in }
    ) {
        self.persistence = persistence
        self.repository = repository
        self.liveStoreMode = liveStoreMode ?? { persistence.mode }
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.protectionReader = protectionReader
        self.faultInjector = faultInjector
    }

    /// Stage and validate one file. A private-cloud live store is rejected
    /// before scope access, coordination, or any app-owned staging file exists.
    func prepare(from sourceURL: URL) async throws -> RestorePreview {
        switch liveStoreMode() {
        case .localOnlySQLite:
            break
        case .privateCloudSQLite:
            throw HourleafRestoreError.cloudStoreUnsupported
        case .inMemory:
            throw HourleafRestoreError.preparationFailed
        }
        guard sourceURL.pathExtension == "hourleafbackup" else {
            throw HourleafRestoreError.invalidFileSelection
        }

        do {
            try retryPendingCleanup()
            try discardCurrentCandidateIfNeeded()
            try ensureProtectedDirectory(rootDirectory)
            try reclaimInitialSlotIfNeeded()
            let candidateID = RestoreCandidateID()
            let backupFileURL = rootDirectory.appendingPathComponent(
                Self.stagedBackupFilename,
                isDirectory: false
            )
            let streamedBytes = try Self.copyCoordinatedBoundedBackup(
                from: sourceURL,
                to: backupFileURL
            )
            let verified: VerifiedHourleafBackupV1
            do {
                try verifyProtection(of: backupFileURL)
                let bytes = try Self.readBoundedAppOwnedFile(at: backupFileURL)
                guard bytes == streamedBytes else {
                    throw HourleafRestoreError.preparationFailed
                }
                verified = try HourleafBackupCodec.decodeAndVerify(bytes)
            } catch {
                cleanupFailedBackup(at: backupFileURL)
                throw error
            }
            let stagedStore: PersistentStoreArtifact
            do {
                stagedStore = try PersistentStoreArtifact.make(
                    in: rootDirectory,
                    named: Self.stagedStoreFilename,
                    purpose: .staging
                )
            } catch {
                cleanupFailedBackup(at: backupFileURL)
                throw error
            }
            let storeCleanup: PersistentStoreCleanupCapability
            do {
                storeCleanup = try await stageAndValidate(
                    verified,
                    in: stagedStore
                )
            } catch {
                cleanupFailedBackup(at: backupFileURL)
                throw error
            }
            let preview = Self.preview(for: verified.content, candidateID: candidateID)
            candidate = Candidate(
                id: candidateID,
                preview: preview,
                backupFileURL: backupFileURL,
                storeCleanup: storeCleanup,
                recordsDigest: verified.recordsDigest
            )
            return preview
        } catch let error as HourleafRestoreError {
            throw error
        } catch {
            throw HourleafRestoreError.preparationFailed
        }
    }

    func preview(for candidateID: RestoreCandidateID) -> RestorePreview? {
        guard candidate?.id == candidateID else { return nil }
        return candidate?.preview
    }

    func stagedRecordsDigest(for candidateID: RestoreCandidateID) -> String? {
        guard candidate?.id == candidateID else { return nil }
        return candidate?.recordsDigest
    }

    func discardCandidate(_ candidateID: RestoreCandidateID? = nil) throws {
        guard let candidate else { return }
        guard candidateID == nil || candidateID == candidate.id else {
            throw HourleafRestoreError.candidateMismatch
        }
        try discard(candidate)
        self.candidate = nil
    }

    private func discardCurrentCandidateIfNeeded() throws {
        guard let candidate else { return }
        try discard(candidate)
        self.candidate = nil
    }

    private func discard(_ candidate: Candidate) throws {
        // The staged SQLite file is always removed through Core Data, never
        // through raw SQLite/WAL/SHM file operations.
        var firstFailure: Error?
        do {
            try faultInjector(.candidateStoreCleanup)
            try PersistenceController.destroyRelinquishedTransitionStore(
                candidate.storeCleanup,
                afterDestroy: {
                    try self.faultInjector(.candidateStoreDestroyedBeforeProof)
                }
            )
        } catch {
            firstFailure = error
        }
        do {
            try faultInjector(.candidateBackupCleanup)
            try removeBackupIfPresent(at: candidate.backupFileURL)
        } catch {
            if firstFailure == nil { firstFailure = error }
        }
        if let firstFailure { throw firstFailure }
    }

    private func stageAndValidate(
        _ verified: VerifiedHourleafBackupV1,
        in stagedStore: PersistentStoreArtifact
    ) async throws -> PersistentStoreCleanupCapability {
        let staged = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            transitionArtifact: stagedStore
        )
        do {
            guard staged.startupError == nil else {
                throw HourleafRestoreError.preparationFailed
            }
            try importRecords(verified.content.records, into: staged)
            let initialRecords = try Self.rawRecords(from: staged)
            guard try HourleafBackupCodec.storeDigest(initialRecords) == verified.recordsDigest else {
                throw HourleafRestoreError.importVerificationFailed
            }

            _ = try staged.closePersistentStoreForTransition()
            guard staged.reopenFreshContainerAfterTransition() == nil else {
                throw HourleafRestoreError.importVerificationFailed
            }
            let reopenedRecords = try Self.rawRecords(from: staged)
            guard try HourleafBackupCodec.storeDigest(reopenedRecords) == verified.recordsDigest else {
                throw HourleafRestoreError.importVerificationFailed
            }

            let stagedRepository = CoreDataLedgerRepository(persistence: staged)
            let lease = try await stagedRepository.acquireMaintenanceLease()
            do {
                try await stagedRepository.resetAfterPersistentStoreTransition(for: lease)
                let readback = try await stagedRepository.validatedReadback(for: lease)
                guard
                    readback.recordsDigest == verified.recordsDigest,
                    readback.rawBeforeNormalizationDigest == verified.recordsDigest,
                    readback.rawAfterNormalizationDigest == verified.recordsDigest
                else {
                    throw HourleafRestoreError.importVerificationFailed
                }
                try await stagedRepository.releaseMaintenanceLease(lease)
            } catch {
                try? await stagedRepository.releaseMaintenanceLease(lease)
                throw error
            }

            _ = try staged.closePersistentStoreForTransition()
            let stagedFiles = try staged.existingOwnedTransitionStoreFiles(stagedStore)
            for stagedFile in stagedFiles {
                try verifyProtection(of: stagedFile)
            }
            return try staged.relinquishOwnedTransitionStore(stagedStore)
        } catch {
            // A partially imported staging SQLite database is task-owned; the
            // coordinator removes it only after its container has been closed.
            if let closed = try? staged.closePersistentStoreForTransition() {
                _ = closed
            }
            cleanupFailedStore(staged, artifact: stagedStore)
            throw error
        }
    }

    private func ensureProtectedDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw HourleafRestoreError.preparationFailed }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw HourleafRestoreError.preparationFailed
        }
        try fileManager.setAttributes([.protectionKey: Self.protectionClass], ofItemAtPath: directory.path)
        try verifyProtection(of: directory)
    }

    /// A process may terminate after creating the deterministic staging slot.
    /// Reclaim it exactly once before this coordinator stages a candidate. The
    /// SQLite family is never unlinked directly; Core Data proves its former
    /// identity and records are gone before the slot can be reused.
    private func reclaimInitialSlotIfNeeded() throws {
        guard !didReclaimInitialSlot else { return }

        let stagedStore = try PersistentStoreArtifact.make(
            in: rootDirectory,
            named: Self.stagedStoreFilename,
            purpose: .staging
        )
        let storeFiles = try PersistenceController.existingOrphanedTransitionStoreFiles(
            stagedStore,
            in: rootDirectory,
            named: Self.stagedStoreFilename
        )
        let backupURL = rootDirectory.appendingPathComponent(
            Self.stagedBackupFilename,
            isDirectory: false
        )
        var firstFailure: Error?

        if !storeFiles.isEmpty {
            do {
                for storeFile in storeFiles {
                    try verifyProtection(of: storeFile)
                }
                let capability = try PersistenceController.orphanedTransitionStoreCleanupCapability(
                    stagedStore,
                    in: rootDirectory,
                    named: Self.stagedStoreFilename
                )
                do {
                    try PersistenceController.destroyRelinquishedTransitionStore(
                        capability,
                        afterDestroy: {
                            try self.faultInjector(.candidateStoreDestroyedBeforeProof)
                        }
                    )
                } catch {
                    pendingStoreCleanup.append(.relinquished(capability))
                    throw error
                }
            } catch {
                firstFailure = error
            }
        }

        if FileManager.default.fileExists(atPath: backupURL.path) {
            var backupIsSafeToRemove = false
            do {
                let values = try backupURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw HourleafRestoreError.preparationFailed
                }
                try verifyProtection(of: backupURL)
                backupIsSafeToRemove = true
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
            if backupIsSafeToRemove {
                do {
                    try removeBackupIfPresent(at: backupURL)
                } catch {
                    if !pendingBackupCleanup.contains(backupURL) {
                        pendingBackupCleanup.append(backupURL)
                    }
                    if firstFailure == nil { firstFailure = error }
                }
            }
        }

        if let firstFailure { throw firstFailure }
        didReclaimInitialSlot = true
    }

    private func verifyProtection(of url: URL) throws {
        guard let observed = try protectionReader.protectionClass(at: url) else {
            #if targetEnvironment(simulator)
            // Simulator frequently reports no data-protection class. This is
            // inconclusive and must never be reported as a physical-device pass.
            return
            #else
            throw HourleafRestoreError.preparationFailed
            #endif
        }
        guard observed == Self.protectionClass else {
            throw HourleafRestoreError.preparationFailed
        }
    }

    private static func rawRecords(from persistence: PersistenceController) throws -> HourleafBackupRecordsV1 {
        try autoreleasepool {
            let context = persistence.container.newBackgroundContext()
            context.undoManager = nil
            defer {
                context.performAndWait { context.reset() }
            }
            return try context.performAndWait {
                try HourleafBackupRecordsV1.rawRecords(in: context)
            }
        }
    }

    /// Keep the import context out of this actor method's async frame. Core
    /// Data contexts retain their coordinator; the staging store cannot be
    /// destroyed until this short-lived context has been deallocated.
    private func importRecords(
        _ records: HourleafBackupRecordsV1,
        into persistence: PersistenceController
    ) throws {
        let faultInjector = faultInjector
        try autoreleasepool {
            let context = persistence.container.newBackgroundContext()
            context.undoManager = nil
            defer {
                context.performAndWait { context.reset() }
            }
            try context.performAndWait {
                try RawBackupStore.insert(records, into: context) { _, batchIndex in
                    try faultInjector(.stagedImportBatch(batchIndex))
                }
            }
        }
    }

    private static func readBoundedAppOwnedFile(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = HourleafBackupLimitsV1.maximumFileBytes
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw HourleafBackupError.fileTooLarge(actual: data.count, limit: limit)
        }
        return data
    }

    private static func preview(
        for content: HourleafBackupContentV1,
        candidateID: RestoreCandidateID
    ) -> RestorePreview {
        let records = content.records
        let activeEntries = records.entries.filter { $0.deletedAt == nil }
        let days = activeEntries.compactMap(\.localDay).sorted()
        let dateRange = days.first.flatMap { first in
            days.last.map { RestoreDateRange(firstLocalDay: first, lastLocalDay: $0) }
        }
        return RestorePreview(
            candidateID: candidateID,
            exportedAt: Date(timeIntervalSinceReferenceDate: content.exportedAt),
            formatVersion: content.version,
            activeEntryCount: activeEntries.count,
            deletedEntryCount: records.entries.count - activeEntries.count,
            entryDateRange: dateRange,
            noteCount: activeEntries.reduce(into: 0) { count, entry in
                if let note = entry.note, !note.isEmpty { count += 1 }
            },
            reminderCount: records.reminders.count,
            receiptCount: records.receipts.count,
            archiveCount: records.archives.count
        )
    }

    private static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent(stagingDirectoryName, isDirectory: true)
    }

    private static func copyCoordinatedBoundedBackup(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> Data {
        let accessedSecurityScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScope { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let sourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw HourleafRestoreError.invalidFileSelection
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            result = Result {
                try streamBoundedBackup(from: coordinatedURL, to: destinationURL)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw HourleafRestoreError.preparationFailed }
        return try result.get()
    }

    /// Creates the app-owned destination with its protection class before the
    /// first byte is streamed. At most `limit + 1` input bytes are retained.
    private static func streamBoundedBackup(
        from sourceURL: URL,
        to destinationURL: URL
    ) throws -> Data {
        let fileManager = FileManager.default
        let sourceValues = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues.isRegularFile == true, sourceValues.isSymbolicLink != true else {
            throw HourleafRestoreError.invalidFileSelection
        }
        var succeeded = false
        defer {
            if !succeeded { try? fileManager.removeItem(at: destinationURL) }
        }

        try Data().write(
            to: destinationURL,
            options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let input = try FileHandle(forReadingFrom: sourceURL)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer {
            try? input.close()
            try? output.close()
        }

        let limit = HourleafBackupLimitsV1.maximumFileBytes
        var result = Data()
        while result.count <= limit {
            let remaining = limit + 1 - result.count
            let chunk = try input.read(upToCount: min(64 * 1_024, remaining)) ?? Data()
            guard !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            result.append(chunk)
        }
        guard result.count <= limit else {
            throw HourleafBackupError.fileTooLarge(actual: result.count, limit: limit)
        }
        try output.synchronize()
        succeeded = true
        return result
    }

    private func cleanupFailedBackup(at url: URL) {
        do {
            try removeBackupIfPresent(at: url)
        } catch {
            if !pendingBackupCleanup.contains(url) {
                pendingBackupCleanup.append(url)
            }
        }
    }

    private func cleanupFailedStore(
        _ persistence: PersistenceController,
        artifact: PersistentStoreArtifact
    ) {
        do {
            let capability = try persistence.relinquishOwnedTransitionStore(artifact)
            do {
                try PersistenceController.destroyRelinquishedTransitionStore(capability)
            } catch {
                pendingStoreCleanup.append(.relinquished(capability))
            }
        } catch {
            pendingStoreCleanup.append(.owned(persistence, artifact))
        }
    }

    private func removeBackupIfPresent(at url: URL) throws {
        let expectedURL = rootDirectory.appendingPathComponent(
            Self.stagedBackupFilename,
            isDirectory: false
        ).standardizedFileURL
        guard url.standardizedFileURL == expectedURL else {
            throw HourleafRestoreError.preparationFailed
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HourleafRestoreError.preparationFailed
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Cleanup is retryable and attempts every artifact even when one fails.
    /// A new candidate is not staged while an older task-owned artifact remains
    /// unaccounted for.
    private func retryPendingCleanup() throws {
        var remainingStores: [PendingStoreCleanup] = []
        for item in pendingStoreCleanup {
            do {
                switch item {
                case let .relinquished(capability):
                    try PersistenceController.destroyRelinquishedTransitionStore(capability)
                case let .owned(persistence, artifact):
                    try persistence.destroyOwnedTransitionStore(artifact)
                }
            } catch {
                remainingStores.append(item)
            }
        }
        pendingStoreCleanup = remainingStores

        var remainingBackups: [URL] = []
        for url in pendingBackupCleanup {
            do {
                try removeBackupIfPresent(at: url)
            } catch {
                remainingBackups.append(url)
            }
        }
        pendingBackupCleanup = remainingBackups
        guard pendingStoreCleanup.isEmpty, pendingBackupCleanup.isEmpty else {
            throw HourleafRestoreError.preparationFailed
        }
    }
}
