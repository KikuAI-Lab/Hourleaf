import CryptoKit
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
        let backupByteCount: Int
        let backupChecksum: String
        let recordsDigest: String
        let recordCounts: HourleafBackupRecordCountsV1
        let transitionSource: ValidatedTransitionStore
        let transactionID: UUID?
    }

    private enum PendingStoreCleanup: Sendable {
        case validated(ValidatedTransitionStore)
        case relinquished(PersistentStoreCleanupCapability)
        case owned(PersistenceController, PersistentStoreArtifact)
    }

    private static let protectionClass = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    static let stagingDirectoryName = "RestoreStaging"
    private static let stagedBackupFilename = "candidate.hourleafbackup"
    private static let stagedStoreFilename = "candidate.sqlite"

    let persistence: PersistenceController
    let repository: CoreDataLedgerRepository
    private let liveStoreMode: @Sendable () -> PersistentStoreMode
    let rootDirectory: URL
    let protectionReader: any HourleafFileProtectionReading
    let faultInjector: RestoreFaultInjector
    private let journalStore: (any RestoreJournalStoring)?
    private let reminderScheduler: (any ReminderScheduling)?
    let recoveryArtifactsDirectory: URL?
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
        journalStore: (any RestoreJournalStoring)? = nil,
        reminderScheduler: (any ReminderScheduling)? = nil,
        recoveryArtifactsDirectory: URL? = nil,
        faultInjector: @escaping RestoreFaultInjector = { _ in }
    ) {
        self.persistence = persistence
        self.repository = repository
        self.liveStoreMode = liveStoreMode ?? { persistence.mode }
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.protectionReader = protectionReader
        self.journalStore = journalStore
        self.reminderScheduler = reminderScheduler
        self.recoveryArtifactsDirectory = recoveryArtifactsDirectory
        self.faultInjector = faultInjector
    }

    /// Stage and validate one file while the caller holds any picker-granted
    /// security scope. A private-cloud live store is rejected before file
    /// coordination or any app-owned staging file exists.
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
            let transitionSource: ValidatedTransitionStore
            do {
                transitionSource = try await stageAndValidate(
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
                backupByteCount: verified.byteCount,
                backupChecksum: verified.checksum.value,
                recordsDigest: verified.recordsDigest,
                recordCounts: verified.recordCounts,
                transitionSource: transitionSource,
                transactionID: nil
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
        guard candidate.transactionID == nil else {
            throw HourleafRestoreError.recoveryRequired
        }
        try discard(candidate)
        self.candidate = nil
    }

    private func discardCurrentCandidateIfNeeded() throws {
        guard let candidate else { return }
        guard candidate.transactionID == nil else {
            throw HourleafRestoreError.recoveryRequired
        }
        try discard(candidate)
        self.candidate = nil
    }

    private func discard(_ candidate: Candidate) throws {
        // The staged SQLite file is always removed through Core Data, never
        // through raw SQLite/WAL/SHM file operations.
        var firstFailure: Error?
        do {
            try faultInjector(.candidateStoreCleanup)
            try PersistenceController.destroyValidatedTransitionStore(
                candidate.transitionSource,
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
    ) async throws -> ValidatedTransitionStore {
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
            guard
                try HourleafBackupCodec.storeDigest(initialRecords) == verified.recordsDigest,
                initialRecords.counts == verified.recordCounts
            else {
                throw HourleafRestoreError.importVerificationFailed
            }

            _ = try staged.closePersistentStoreForTransition { context in
                try CoreDataLedgerRepository.validateExactRawDomainRaw(
                    in: context,
                    expectedRecordsDigest: verified.recordsDigest,
                    expectedRecordCounts: verified.recordCounts
                )
            }
            guard staged.reopenFreshContainerAfterTransition() == nil else {
                throw HourleafRestoreError.importVerificationFailed
            }
            let reopenedRecords = try Self.rawRecords(from: staged)
            guard
                try HourleafBackupCodec.storeDigest(reopenedRecords) == verified.recordsDigest,
                reopenedRecords.counts == verified.recordCounts
            else {
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
                    readback.rawAfterNormalizationDigest == verified.recordsDigest,
                    readback.recordCounts == verified.recordCounts
                else {
                    throw HourleafRestoreError.importVerificationFailed
                }
                let source = try staged.closeAndRelinquishOwnedTransitionStore(
                    stagedStore,
                    expectedRecordsDigest: verified.recordsDigest,
                    expectedRecordCounts: verified.recordCounts
                )
                let stagedFiles = try staged.existingOwnedTransitionStoreFiles(stagedStore)
                for stagedFile in stagedFiles {
                    try verifyProtection(of: stagedFile)
                }
                try await stagedRepository.releaseMaintenanceLease(lease)
                return source
            } catch {
                try? await stagedRepository.releaseMaintenanceLease(lease)
                throw error
            }
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

    func ensureProtectedDirectory(_ directory: URL) throws {
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

    func verifyProtection(of url: URL) throws {
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
        try verifyProtection(of: url)
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
                case let .validated(source):
                    try PersistenceController.destroyValidatedTransitionStore(source)
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

    // MARK: - M3b confirmation

    /// Confirmation is actor-serialized from the candidate re-read through
    /// every journal writer. Once `arm` returns the candidate becomes
    /// transaction-owned; this actor never creates a second transaction or
    /// treats a later retry as another replace attempt.
    func confirm(_ candidateID: RestoreCandidateID) async throws -> RestoreCommitResult {
        guard liveStoreMode() == .localOnlySQLite else {
            switch liveStoreMode() {
            case .privateCloudSQLite:
                throw HourleafRestoreError.cloudStoreUnsupported
            case .inMemory, .localOnlySQLite:
                throw HourleafRestoreError.preparationFailed
            }
        }
        guard var candidate, candidate.id == candidateID else {
            throw HourleafRestoreError.candidateUnavailable
        }
        guard candidate.transactionID == nil else {
            throw HourleafRestoreError.recoveryRequired
        }

        // C0 performs every untrusted candidate operation before journal arm
        // and before any live maintenance lease exists.
        do {
            try retryPendingCleanup()
            candidate = try await reverify(candidate)
            self.candidate = candidate
        } catch let error as HourleafRestoreError {
            throw error
        } catch {
            throw HourleafRestoreError.importVerificationFailed
        }

        let journal: any RestoreJournalStoring
        let prepared: RestoreJournalContentV1
        do {
            journal = try resolvedJournalStore()
            prepared = try makePreparedJournal(for: candidate)
            try journal.arm(prepared)
        } catch {
            // Before the active rename succeeds, M3a owns any inert arming
            // residue and the current candidate remains retryable.
            throw HourleafRestoreError.preparationFailed
        }

        candidate = Candidate(
            id: candidate.id,
            preview: candidate.preview,
            backupFileURL: candidate.backupFileURL,
            backupByteCount: candidate.backupByteCount,
            backupChecksum: candidate.backupChecksum,
            recordsDigest: candidate.recordsDigest,
            recordCounts: candidate.recordCounts,
            transitionSource: candidate.transitionSource,
            transactionID: UUID(uuidString: prepared.transactionID)
        )
        self.candidate = candidate

        do {
            return try await confirmArmed(candidate: candidate, journalStore: journal)
        } catch let error as HourleafRestoreError {
            throw error
        } catch {
            throw HourleafRestoreError.recoveryRequired
        }
    }

    private func confirmArmed(
        candidate: Candidate,
        journalStore: any RestoreJournalStoring
    ) async throws -> RestoreCommitResult {
        let transaction = try trustedTransaction(from: journalStore)
        guard transaction.journal.content.transactionID == candidate.transactionID?.uuidString.lowercased() else {
            throw HourleafRestoreError.criticalRecoveryRequired
        }

        let lease: LedgerMaintenanceLease
        do {
            lease = try await repository.acquireMaintenanceLease()
        } catch {
            throw HourleafRestoreError.recoveryRequired
        }

        let capture: LedgerMaintenanceCapture
        do {
            capture = try await repository.maintenanceCapture(for: lease)
            try advance(journalStore, to: .maintenanceAcquired) { content in
                content.aRecordsDigest = capture.recordsDigest
                content.aRecordCounts = RestoreRecordCountsV1(capture.recordCounts)
            }
        } catch {
            // Once a journal is armed, normal writers stay fenced until a
            // recovery process reaches a terminal journal readback. The
            // durable prepared/maintenance phase is the only safe handoff.
            throw HourleafRestoreError.recoveryRequired
        }

        let aProof = RestoreLogicalProof(
            recordsDigest: capture.recordsDigest,
            recordCounts: capture.recordCounts
        )
        let bProof = RestoreLogicalProof(
            recordsDigest: candidate.recordsDigest,
            recordCounts: candidate.recordCounts
        )
        if aProof == bProof {
            do {
                let fresh = try await repository.validatedReadback(for: lease)
                guard matches(fresh, proof: aProof) else {
                    throw HourleafRestoreError.recoveryRequired
                }
                let scheduler = await resolvedReminderScheduler()
                try await scheduler.reschedule(fresh.reminderSchedules)
                let current = try trustedTransaction(from: journalStore)
                guard current.journal.content.phase == .maintenanceAcquired else {
                    throw HourleafRestoreError.recoveryRequired
                }
                try cleanupSelectedArtifacts(
                    candidateSource: candidate.transitionSource,
                    rollbackSource: nil,
                    physicalSource: nil,
                    transaction: current,
                    journalStore: journalStore,
                    selectedTarget: .a,
                    selectedProof: aProof
                )
                let decision = terminalDecision(
                    transaction: current,
                    target: .a,
                    proof: aProof
                )
                try journalStore.complete(decision)
                try verifyTerminalJournalReadback(journalStore)
                try await repository.releaseMaintenanceLease(lease)
                self.candidate = nil
                return RestoreCommitResult(
                    selectedTarget: .original,
                    recordsDigest: aProof.recordsDigest,
                    recordCounts: aProof.recordCounts
                )
            } catch {
                throw HourleafRestoreError.recoveryRequired
            }
        }

        let portableA: VerifiedHourleafBackupV1
        do {
            let current = try trustedTransaction(from: journalStore)
            let artifact = try await HourleafBackupExporter(
                source: CapturedMaintenanceBackupSource(capture: capture)
            ).createVerifiedBackup(in: current.activeDirectory)
            try RestoreJournalCodecV1.validatePortableABasename(artifact.url.lastPathComponent)
            portableA = try verifiedRegularBackup(at: artifact.url)
            guard
                portableA.byteCount == artifact.byteCount,
                portableA.checksum.value == artifact.checksum.value,
                portableA.recordsDigest == aProof.recordsDigest,
                portableA.recordCounts == aProof.recordCounts
            else {
                throw HourleafRestoreError.recoveryRequired
            }
            try advance(journalStore, to: .preRestoreBackupVerified) { content in
                content.portableABasename = artifact.url.lastPathComponent
                content.portableAByteCount = portableA.byteCount
                content.portableAChecksum = portableA.checksum.value
                content.portableARecordsDigest = portableA.recordsDigest
            }
        } catch {
            // Live A is still open. A future bootstrap can prove it and uses
            // M3a's proof-bound provisional-artifact cleanup if publication
            // won the crash window.
            throw HourleafRestoreError.recoveryRequired
        }

        let artifactsDirectory: URL
        let evidenceArtifact: PersistentStoreArtifact
        do {
            let current = try trustedTransaction(from: journalStore)
            artifactsDirectory = try resolvedRecoveryArtifactsDirectory(for: current)
            try ensureProtectedDirectory(artifactsDirectory)
            evidenceArtifact = try PersistentStoreArtifact.make(
                in: artifactsDirectory,
                named: RestoreJournalV1.physicalAStoreBasename,
                purpose: .evidence
            )
            try reclaimReusableSlot(
                evidenceArtifact,
                in: artifactsDirectory,
                named: RestoreJournalV1.physicalAStoreBasename
            )
            try advance(journalStore, to: .oldStoreCopyStarted) { _ in }
        } catch {
            throw HourleafRestoreError.recoveryRequired
        }

        let closed: ClosedPersistentStoreDescriptor
        do {
            closed = try await repository.validateCaptureAndCloseStore(capture, for: lease)
        } catch let error as PersistentStoreTransitionError {
            switch error {
            case .validationFailedBeforeClose:
                break // retain writer gate for exact-A startup recovery
            case .coordinatorOutcomeUnknown:
                break // retain the live lease and block this process
            default:
                break // journal is armed; recovery owns the terminal release
            }
            throw HourleafRestoreError.recoveryRequired
        } catch {
            throw HourleafRestoreError.recoveryRequired
        }

        let physicalA: ValidatedTransitionStore
        do {
            try persistence.copyClosedStore(closed, to: evidenceArtifact)
            let validation = try await validateTransitionArtifact(
                evidenceArtifact,
                proof: aProof
            )
            physicalA = validation.source
            guard physicalA.storeUUID == physicalA.storeUUID.lowercased() else {
                throw HourleafRestoreError.recoveryRequired
            }
            try advance(journalStore, to: .oldStoreCopyVerified) { content in
                content.physicalAStoreUUID = physicalA.storeUUID.lowercased()
                content.physicalARecordsDigest = aProof.recordsDigest
            }
        } catch {
            // The live store is known closed. Do not release the lease or use
            // the unjournaled evidence slot; startup falls back to portable A.
            throw HourleafRestoreError.recoveryRequired
        }

        do {
            try advance(journalStore, to: .replacementStarted) { _ in }
            try persistence.replaceClosedStore(closed, with: candidate.transitionSource)
            try advance(journalStore, to: .replacementReturned) { _ in }
        } catch {
            return try await rollbackAfterCandidateFailure(
                journalStore: journalStore,
                lease: lease,
                originalProof: aProof,
                candidate: candidate,
                physicalA: physicalA,
                artifactsDirectory: artifactsDirectory
            )
        }

        let bReadback: ValidatedReadback
        do {
            try faultInjector(.confirmationBoundary("before-b-reopen"))
            guard persistence.reopenFreshContainerAfterTransition() == nil else {
                throw HourleafRestoreError.recoveryRequired
            }
            try faultInjector(.confirmationBoundary("after-b-reopen"))
            try await repository.resetAfterPersistentStoreTransition(for: lease)
            let readback = try await repository.validatedReadback(for: lease)
            guard matches(readback, proof: bProof) else {
                throw HourleafRestoreError.recoveryRequired
            }
            try faultInjector(.confirmationBoundary("after-b-proof"))
            try advance(journalStore, to: .newStoreVerifiedRemindersPending) { _ in }
            bReadback = readback
        } catch {
            return try await rollbackAfterCandidateFailure(
                journalStore: journalStore,
                lease: lease,
                originalProof: aProof,
                candidate: candidate,
                physicalA: physicalA,
                artifactsDirectory: artifactsDirectory
            )
        }

        do {
            let scheduler = await resolvedReminderScheduler()
            try await scheduler.reschedule(bReadback.reminderSchedules)
            let current = try trustedTransaction(from: journalStore)
            guard current.journal.content.phase == .newStoreVerifiedRemindersPending else {
                throw HourleafRestoreError.recoveryRequired
            }
            try cleanupSelectedArtifacts(
                candidateSource: candidate.transitionSource,
                rollbackSource: nil,
                physicalSource: physicalA,
                transaction: current,
                journalStore: journalStore,
                selectedTarget: .b,
                selectedProof: bProof
            )
            let decision = terminalDecision(transaction: current, target: .b, proof: bProof)
            try journalStore.complete(decision)
            try verifyTerminalJournalReadback(journalStore)
            try await repository.releaseMaintenanceLease(lease)
            self.candidate = nil
            return RestoreCommitResult(
                selectedTarget: .candidate,
                recordsDigest: bProof.recordsDigest,
                recordCounts: bProof.recordCounts
            )
        } catch {
            // The B-pending phase is durable before any reminder effect. A
            // scheduler or cleanup failure deliberately leaves all evidence
            // and never repeats replacement on a retry.
            throw HourleafRestoreError.recoveryRequired
        }
    }

    struct TransitionValidation: Sendable {
        let source: ValidatedTransitionStore
        let readback: ValidatedReadback
    }

    private func reverify(_ candidate: Candidate) async throws -> Candidate {
        let expectedBackupURL = rootDirectory.appendingPathComponent(
            Self.stagedBackupFilename,
            isDirectory: false
        ).standardizedFileURL
        guard candidate.backupFileURL.standardizedFileURL == expectedBackupURL else {
            throw HourleafRestoreError.candidateUnavailable
        }
        let backup = try verifiedRegularBackup(at: candidate.backupFileURL)
        guard
            backup.byteCount == candidate.backupByteCount,
            backup.checksum.value == candidate.backupChecksum,
            backup.recordsDigest == candidate.recordsDigest,
            backup.recordCounts == candidate.recordCounts
        else {
            throw HourleafRestoreError.candidateMismatch
        }
        let validation = try await validateTransitionArtifact(
            candidate.transitionSource.artifact,
            proof: RestoreLogicalProof(
                recordsDigest: candidate.recordsDigest,
                recordCounts: candidate.recordCounts
            )
        )
        return Candidate(
            id: candidate.id,
            preview: candidate.preview,
            backupFileURL: candidate.backupFileURL,
            backupByteCount: candidate.backupByteCount,
            backupChecksum: candidate.backupChecksum,
            recordsDigest: candidate.recordsDigest,
            recordCounts: candidate.recordCounts,
            transitionSource: validation.source,
            transactionID: candidate.transactionID
        )
    }

    func validateTransitionArtifact(
        _ artifact: PersistentStoreArtifact,
        proof: RestoreLogicalProof
    ) async throws -> TransitionValidation {
        let transition = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            transitionArtifact: artifact
        )
        guard transition.startupError == nil else {
            throw HourleafRestoreError.importVerificationFailed
        }
        let transitionRepository = CoreDataLedgerRepository(persistence: transition)
        let lease = try await transitionRepository.acquireMaintenanceLease()
        do {
            try await transitionRepository.resetAfterPersistentStoreTransition(for: lease)
            let readback = try await transitionRepository.validatedReadback(for: lease)
            guard matches(readback, proof: proof) else {
                throw HourleafRestoreError.importVerificationFailed
            }
            let source = try transition.closeAndRelinquishOwnedTransitionStore(
                artifact,
                expectedRecordsDigest: proof.recordsDigest,
                expectedRecordCounts: proof.recordCounts
            )
            let files = try transition.existingOwnedTransitionStoreFiles(artifact)
            for file in files {
                try verifyProtection(of: file)
            }
            try await transitionRepository.releaseMaintenanceLease(lease)
            return TransitionValidation(source: source, readback: readback)
        } catch {
            try? await transitionRepository.releaseMaintenanceLease(lease)
            throw error
        }
    }

    private func resolvedJournalStore() throws -> any RestoreJournalStoring {
        if let journalStore { return journalStore }
        let injectedFault = faultInjector
        return RestoreJournalStoreV1(
            rootDirectory: try RestoreJournalStoreV1.defaultRecoveryRoot(),
            protectionReader: protectionReader,
            faultInjector: { point in
                try injectedFault(.journalPhase(String(describing: point)))
            }
        )
    }

    func resolvedReminderScheduler() async -> any ReminderScheduling {
        if let reminderScheduler { return reminderScheduler }
        return await MainActor.run { ReminderScheduler.shared }
    }

    private func makePreparedJournal(for candidate: Candidate) throws -> RestoreJournalContentV1 {
        let transactionID = UUID().uuidString.lowercased()
        let nonceSeed = "\(UUID().uuidString.lowercased())-\(UUID().uuidString.lowercased())"
        let nonce = SHA256.hash(data: Data(nonceSeed.utf8)).map { String(format: "%02x", $0) }.joined()
        let milliseconds = Int64((Date.now.timeIntervalSince1970 * 1_000).rounded(.down))
        return RestoreJournalContentV1(
            transactionID: transactionID,
            transactionNonce: nonce,
            createdAtMilliseconds: milliseconds,
            candidateBackupByteCount: candidate.backupByteCount,
            candidateBackupChecksum: candidate.backupChecksum,
            candidateRecordsDigest: candidate.recordsDigest,
            candidateRecordCounts: RestoreRecordCountsV1(candidate.recordCounts)
        )
    }

    func trustedTransaction(
        from journalStore: any RestoreJournalStoring
    ) throws -> VerifiedRestoreTransactionV1 {
        switch try journalStore.inspectBeforeStoreLoad() {
        case let .recover(transaction):
            return transaction
        case .idle:
            throw HourleafRestoreError.recoveryRequired
        case .critical:
            throw HourleafRestoreError.criticalRecoveryRequired
        }
    }

    func advance(
        _ journalStore: any RestoreJournalStoring,
        to phase: RestoreJournalPhase,
        mutate: (inout RestoreJournalContentV1) throws -> Void
    ) throws {
        try journalStore.advance(to: phase, mutate: mutate)
        try faultInjector(.journalPhase(phase.rawValue))
    }

    func matches(
        _ readback: ValidatedReadback,
        proof: RestoreLogicalProof
    ) -> Bool {
        readback.rawBeforeNormalizationDigest == proof.recordsDigest
            && readback.recordsDigest == proof.recordsDigest
            && readback.rawAfterNormalizationDigest == proof.recordsDigest
            && readback.recordCounts == proof.recordCounts
    }

    func verifiedRegularBackup(at url: URL) throws -> VerifiedHourleafBackupV1 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw HourleafRestoreError.importVerificationFailed
        }
        try verifyProtection(of: url)
        let data = try Self.readBoundedAppOwnedFile(at: url)
        let verified = try HourleafBackupCodec.decodeAndVerify(data)
        guard verified.data == data else {
            throw HourleafRestoreError.importVerificationFailed
        }
        return verified
    }

    func resolvedRecoveryArtifactsDirectory(
        for transaction: VerifiedRestoreTransactionV1
    ) throws -> URL {
        if let recoveryArtifactsDirectory {
            return recoveryArtifactsDirectory.standardizedFileURL
        }
        let support = transaction.rootDirectory.deletingLastPathComponent()
        return support.appendingPathComponent(
            RestoreJournalV1.artifactDirectoryName,
            isDirectory: true
        ).standardizedFileURL
    }

    func reclaimReusableSlot(
        _ artifact: PersistentStoreArtifact,
        in directory: URL,
        named filename: String
    ) throws {
        let files = try PersistenceController.existingOrphanedTransitionStoreFiles(
            artifact,
            in: directory,
            named: filename
        )
        guard !files.isEmpty else { return }
        for file in files {
            try verifyProtection(of: file)
        }
        let capability = try PersistenceController.orphanedTransitionStoreCleanupCapability(
            artifact,
            in: directory,
            named: filename
        )
        try PersistenceController.destroyRelinquishedTransitionStore(capability)
    }

    func terminalDecision(
        transaction: VerifiedRestoreTransactionV1,
        target: RestoreTerminalTargetV1,
        proof: RestoreLogicalProof
    ) -> RestoreTerminalDecisionV1 {
        RestoreTerminalDecisionV1(
            transactionID: UUID(uuidString: transaction.journal.content.transactionID)!,
            sourcePhase: transaction.journal.content.phase,
            target: target,
            recordsDigest: proof.recordsDigest,
            recordCounts: RestoreRecordCountsV1(proof.recordCounts)
        )
    }

    /// Completion is not the point at which normal runtime access becomes
    /// safe. Read the terminal state, remove its completed metadata, and read
    /// it once more before the maintenance writer gate is released.
    func verifyTerminalJournalReadback(
        _ journalStore: any RestoreJournalStoring
    ) throws {
        guard case .idle = try journalStore.inspectBeforeStoreLoad() else {
            throw HourleafRestoreError.recoveryRequired
        }
        try journalStore.cleanupCompletedTransactions()
        guard case .idle = try journalStore.inspectBeforeStoreLoad() else {
            throw HourleafRestoreError.recoveryRequired
        }
    }

    /// Typed cleanup is deliberately separate from target selection. It runs
    /// only after the caller has a fresh exact target and (for pending phases)
    /// a successful reminder reconciliation. A restarted process supplies no
    /// process-local source and therefore mints only exact fixed-slot orphan
    /// cleanup capabilities.
    func cleanupSelectedArtifacts(
        candidateSource: ValidatedTransitionStore?,
        rollbackSource: ValidatedTransitionStore?,
        physicalSource: ValidatedTransitionStore?,
        transaction: VerifiedRestoreTransactionV1,
        journalStore: any RestoreJournalStoring,
        selectedTarget: RestoreTerminalTargetV1,
        selectedProof: RestoreLogicalProof
    ) throws {
        if let candidateSource {
            try PersistenceController.destroyValidatedTransitionStore(candidateSource)
        } else {
            let artifact = try PersistentStoreArtifact.make(
                in: rootDirectory,
                named: RestoreJournalV1.candidateStoreBasename,
                purpose: .staging
            )
            try destroyExactSlotIfPresent(
                artifact,
                in: rootDirectory,
                named: RestoreJournalV1.candidateStoreBasename
            )
        }

        let artifactsDirectory = try resolvedRecoveryArtifactsDirectory(for: transaction)
        if FileManager.default.fileExists(atPath: artifactsDirectory.path) {
            let directoryValues = try artifactsDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
                throw HourleafRestoreError.recoveryRequired
            }
            try verifyProtection(of: artifactsDirectory)

            let rollbackArtifact = try PersistentStoreArtifact.make(
                in: artifactsDirectory,
                named: RestoreJournalV1.rollbackAStoreBasename,
                purpose: .staging
            )
            if let rollbackSource {
                try PersistenceController.destroyValidatedTransitionStore(rollbackSource)
            } else {
                try destroyExactSlotIfPresent(
                    rollbackArtifact,
                    in: artifactsDirectory,
                    named: RestoreJournalV1.rollbackAStoreBasename
                )
            }

            let evidenceArtifact = try PersistentStoreArtifact.make(
                in: artifactsDirectory,
                named: RestoreJournalV1.physicalAStoreBasename,
                purpose: .evidence
            )
            if let physicalSource {
                try PersistenceController.destroyValidatedTransitionStore(physicalSource)
            } else {
                try destroyExactSlotIfPresent(
                    evidenceArtifact,
                    in: artifactsDirectory,
                    named: RestoreJournalV1.physicalAStoreBasename
                )
            }
        } else if rollbackSource != nil || physicalSource != nil {
            // A process-local source can only have been minted beneath this
            // directory. If it vanished before target cleanup, a fresh startup
            // proof is required rather than a raw-path cleanup guess.
            throw HourleafRestoreError.recoveryRequired
        }

        try removeBackupIfPresent(
            at: rootDirectory.appendingPathComponent(
                RestoreJournalV1.candidateBackupBasename,
                isDirectory: false
            )
        )

        // The maintenance crash window has a typed provisional A name rather
        // than journal-bound portable evidence. M3a verifies the fresh A
        // terminal decision before removing it.
        if transaction.journal.content.phase == .maintenanceAcquired,
           selectedTarget == .a {
            try journalStore.discardProvisionalPortableAArtifacts(
                afterProvingLiveA: terminalDecision(
                    transaction: transaction,
                    target: .a,
                    proof: selectedProof
                )
            )
        }

        try removeVerifiedPortableALastIfPresent(transaction)
        try journalStore.removeTrustedReservedPartials()
    }

    private func destroyExactSlotIfPresent(
        _ artifact: PersistentStoreArtifact,
        in directory: URL,
        named filename: String
    ) throws {
        let files = try PersistenceController.existingOrphanedTransitionStoreFiles(
            artifact,
            in: directory,
            named: filename
        )
        guard !files.isEmpty else { return }
        for file in files {
            try verifyProtection(of: file)
        }
        let capability = try PersistenceController.orphanedTransitionStoreCleanupCapability(
            artifact,
            in: directory,
            named: filename
        )
        try PersistenceController.destroyRelinquishedTransitionStore(capability)
    }

    private func removeVerifiedPortableALastIfPresent(
        _ transaction: VerifiedRestoreTransactionV1
    ) throws {
        let content = transaction.journal.content
        guard let basename = content.portableABasename else { return }
        try RestoreJournalCodecV1.validatePortableABasename(basename)
        let activeDirectory = transaction.activeDirectory.standardizedFileURL
        let url = activeDirectory.appendingPathComponent(basename, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == activeDirectory else {
            throw HourleafRestoreError.recoveryRequired
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // M3a permits an already-cleaned portable file only in the two
            // target-pending phases. Earlier phases fail closed in inspection.
            guard [
                RestoreJournalPhase.newStoreVerifiedRemindersPending,
                .oldStoreVerifiedRemindersPending
            ].contains(content.phase) else {
                throw HourleafRestoreError.recoveryRequired
            }
            return
        }
        let backup = try verifiedRegularBackup(at: url)
        guard
            backup.byteCount == content.portableAByteCount,
            backup.checksum.value == content.portableAChecksum,
            backup.recordsDigest == content.portableARecordsDigest,
            RestoreRecordCountsV1(backup.recordCounts) == content.aRecordCounts,
            backup.recordsDigest == content.aRecordsDigest
        else {
            throw HourleafRestoreError.recoveryRequired
        }
        try FileManager.default.removeItem(at: url)
    }

    private func rollbackAfterCandidateFailure(
        journalStore: any RestoreJournalStoring,
        lease: LedgerMaintenanceLease,
        originalProof: RestoreLogicalProof,
        candidate: Candidate,
        physicalA: ValidatedTransitionStore,
        artifactsDirectory: URL
    ) async throws -> RestoreCommitResult {
        let sources: (
            replacement: ValidatedTransitionStore,
            rollback: ValidatedTransitionStore?,
            physical: ValidatedTransitionStore?
        )
        let readback: ValidatedReadback

        do {
            var transaction = try trustedTransaction(from: journalStore)
            if transaction.journal.content.phase != .rollbackStarted {
                try advance(journalStore, to: .rollbackStarted) { _ in }
                transaction = try trustedTransaction(from: journalStore)
            }

            do {
                try faultInjector(.confirmationBoundary("before-physical-a-rollback-proof"))
                let validated = try await validateTransitionArtifact(
                    physicalA.artifact,
                    proof: originalProof
                ).source
                guard validated.storeUUID == transaction.journal.content.physicalAStoreUUID else {
                    throw HourleafRestoreError.recoveryRequired
                }
                sources = (replacement: validated, rollback: nil, physical: validated)
            } catch {
                let rebuilt = try await rebuildPortableASource(
                    transaction: transaction,
                    proof: originalProof,
                    artifactsDirectory: artifactsDirectory
                )
                sources = (replacement: rebuilt, rollback: rebuilt, physical: nil)
            }

            let closed = try persistence.closePersistentStoreForRecovery(
                authorizedBy: transaction
            )
            try persistence.replaceClosedStore(closed, with: sources.replacement)
            guard persistence.reopenFreshContainerAfterTransition() == nil else {
                throw HourleafRestoreError.recoveryRequired
            }
            try await repository.resetAfterPersistentStoreTransition(for: lease)
            readback = try await repository.validatedReadback(for: lease)
            guard matches(readback, proof: originalProof) else {
                throw HourleafRestoreError.recoveryRequired
            }
            try advance(journalStore, to: .oldStoreVerifiedRemindersPending) { _ in }
        } catch let error as HourleafRestoreError {
            if error == .recoveryRequired {
                try persistCriticalIfPossible(journalStore)
                throw HourleafRestoreError.criticalRecoveryRequired
            }
            throw error
        } catch {
            try persistCriticalIfPossible(journalStore)
            throw HourleafRestoreError.criticalRecoveryRequired
        }

        do {
            let scheduler = await resolvedReminderScheduler()
            try await scheduler.reschedule(readback.reminderSchedules)
            let current = try trustedTransaction(from: journalStore)
            guard current.journal.content.phase == .oldStoreVerifiedRemindersPending else {
                throw HourleafRestoreError.recoveryRequired
            }
            try cleanupSelectedArtifacts(
                candidateSource: candidate.transitionSource,
                rollbackSource: sources.rollback,
                physicalSource: sources.physical,
                transaction: current,
                journalStore: journalStore,
                selectedTarget: .a,
                selectedProof: originalProof
            )
            let decision = terminalDecision(transaction: current, target: .a, proof: originalProof)
            try journalStore.complete(decision)
            try verifyTerminalJournalReadback(journalStore)
            try await repository.releaseMaintenanceLease(lease)
            self.candidate = nil
            return RestoreCommitResult(
                selectedTarget: .original,
                recordsDigest: originalProof.recordsDigest,
                recordCounts: originalProof.recordCounts
            )
        } catch {
            // The A-pending phase is durable before any reminder side effect.
            // A scheduler or cleanup failure must remain restartable and never
            // repeat either replacement.
            throw HourleafRestoreError.recoveryRequired
        }
    }

    func rebuildPortableASource(
        transaction: VerifiedRestoreTransactionV1,
        proof: RestoreLogicalProof,
        artifactsDirectory: URL
    ) async throws -> ValidatedTransitionStore {
        let content = transaction.journal.content
        guard let basename = content.portableABasename else {
            throw HourleafRestoreError.recoveryRequired
        }
        try RestoreJournalCodecV1.validatePortableABasename(basename)
        let portableURL = transaction.activeDirectory.appendingPathComponent(
            basename,
            isDirectory: false
        ).standardizedFileURL
        guard portableURL.deletingLastPathComponent() == transaction.activeDirectory.standardizedFileURL else {
            throw HourleafRestoreError.recoveryRequired
        }
        let backup = try verifiedRegularBackup(at: portableURL)
        guard
            backup.byteCount == content.portableAByteCount,
            backup.checksum.value == content.portableAChecksum,
            backup.recordsDigest == proof.recordsDigest,
            backup.recordCounts == proof.recordCounts
        else {
            throw HourleafRestoreError.recoveryRequired
        }

        try ensureProtectedDirectory(artifactsDirectory)
        let artifact = try PersistentStoreArtifact.make(
            in: artifactsDirectory,
            named: RestoreJournalV1.rollbackAStoreBasename,
            purpose: .staging
        )
        try reclaimReusableSlot(
            artifact,
            in: artifactsDirectory,
            named: RestoreJournalV1.rollbackAStoreBasename
        )
        let transition = PersistenceController(
            inMemory: false,
            cloudSyncEnabled: false,
            transitionArtifact: artifact
        )
        guard transition.startupError == nil else {
            throw HourleafRestoreError.recoveryRequired
        }
        try importRecords(backup.content.records, into: transition)
        let transitionRepository = CoreDataLedgerRepository(persistence: transition)
        let lease = try await transitionRepository.acquireMaintenanceLease()
        do {
            try await transitionRepository.resetAfterPersistentStoreTransition(for: lease)
            let readback = try await transitionRepository.validatedReadback(for: lease)
            guard matches(readback, proof: proof) else {
                throw HourleafRestoreError.recoveryRequired
            }
            let source = try transition.closeAndRelinquishOwnedTransitionStore(
                artifact,
                expectedRecordsDigest: proof.recordsDigest,
                expectedRecordCounts: proof.recordCounts
            )
            let files = try transition.existingOwnedTransitionStoreFiles(artifact)
            for file in files {
                try verifyProtection(of: file)
            }
            try await transitionRepository.releaseMaintenanceLease(lease)
            return source
        } catch {
            try? await transitionRepository.releaseMaintenanceLease(lease)
            throw error
        }
    }

    func persistCriticalIfPossible(_ journalStore: any RestoreJournalStoring) throws {
        guard let transaction = try? trustedTransaction(from: journalStore),
              transaction.journal.content.phase != .critical else {
            return
        }
        do {
            try advance(journalStore, to: .critical) { content in
                content.criticalFromPhase = content.phase
                content.criticalReasonCode = "a-recovery-unproved"
            }
        } catch {
            // Failure to persist critical never authorizes cleanup or normal
            // loading. The next startup re-inspects the prior trusted phase.
        }
    }
}
