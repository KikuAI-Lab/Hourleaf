import Foundation

/// Startup recovery deliberately lives beside the confirmation actor instead
/// of adding a second public coordinator. `bootstrap` does its journal-only
/// preflight before either runtime factory is evaluated, then lets this actor
/// serialize every recovery repository and journal operation.
extension HourleafRestoreCoordinator {
    static func bootstrap(
        journalStore: any RestoreJournalStoring,
        reminderScheduler: any ReminderScheduling,
        makeNormalRuntime: @escaping @Sendable () -> RestoreReadyRuntime,
        makeLocalRecoveryRuntime: @escaping @Sendable () -> RestoreReadyRuntime,
        recoveryArtifactsDirectory: URL? = nil,
        protectionReader: any HourleafFileProtectionReading = FoundationFileProtectionReader(),
        faultInjector: @escaping RestoreFaultInjector = { _ in }
    ) async -> RestoreBootstrapResult {
        let disposition: RestoreStartupDisposition
        do {
            disposition = try journalStore.inspectBeforeStoreLoad()
        } catch {
            return .blocked(RedactedRestoreCriticalState(reasonCode: "journal-preflight-failed"))
        }

        switch disposition {
        case .idle:
            do {
                try journalStore.cleanupCompletedTransactions()
                guard case .idle = try journalStore.inspectBeforeStoreLoad() else {
                    return .blocked(RedactedRestoreCriticalState(reasonCode: "completed-cleanup-readback-failed"))
                }
                return .ready(makeNormalRuntime())
            } catch {
                return .blocked(RedactedRestoreCriticalState(reasonCode: "completed-cleanup-failed"))
            }

        case let .critical(state):
            return .blocked(state)

        case let .recover(transaction):
            do {
                // Inspection has already established exactly which partials
                // are trusted. Do not construct a persistence runtime until
                // those only-metadata cleanup operations have succeeded.
                try journalStore.removeTrustedReservedPartials()
                let runtime = makeLocalRecoveryRuntime()
                guard runtime.persistence.mode == .localOnlySQLite else {
                    return .blocked(RedactedRestoreCriticalState(reasonCode: "recovery-runtime-not-local"))
                }

                let stagingRoot = transaction.rootDirectory
                    .deletingLastPathComponent()
                    .appendingPathComponent(Self.stagingDirectoryName, isDirectory: true)
                let coordinator = HourleafRestoreCoordinator(
                    persistence: runtime.persistence,
                    repository: runtime.repository,
                    rootDirectory: stagingRoot,
                    protectionReader: protectionReader,
                    liveStoreMode: { .localOnlySQLite },
                    journalStore: journalStore,
                    reminderScheduler: reminderScheduler,
                    recoveryArtifactsDirectory: recoveryArtifactsDirectory,
                    faultInjector: faultInjector
                )
                try await coordinator.recoverStartup(
                    transaction: transaction,
                    journalStore: journalStore
                )
                return .ready(runtime)
            } catch {
                return .blocked(RedactedRestoreCriticalState(reasonCode: "recovery-blocked"))
            }
        }
    }
}

private extension HourleafRestoreCoordinator {
    enum StartupLiveClassification {
        case exactA(ValidatedReadback)
        case exactB(ValidatedReadback)
        case validOpenable(ValidatedReadback)
        case unreadableOrNeither
    }

    struct RecoveryASource {
        let source: ValidatedTransitionStore
        let rollbackSource: ValidatedTransitionStore?
        let physicalSource: ValidatedTransitionStore?
    }

    func recoverStartup(
        transaction: VerifiedRestoreTransactionV1,
        journalStore: any RestoreJournalStoring
    ) async throws {
        guard persistence.mode == .localOnlySQLite else {
            throw HourleafRestoreError.recoveryRequired
        }
        try faultInjector(.recoveryBoundary("before-lease"))
        let lease = try await repository.acquireMaintenanceLease()
        let classification = await classifyLive(
            transaction: transaction,
            lease: lease
        )
        try faultInjector(.recoveryBoundary("after-live-proof"))

        switch transaction.journal.content.phase {
        case .prepared:
            switch classification {
            case .exactA, .exactB, .validOpenable:
                try await completeUnstarted(
                    transaction: transaction,
                    lease: lease,
                    journalStore: journalStore
                )
            case .unreadableOrNeither:
                try persistCriticalIfPossible(journalStore)
                throw HourleafRestoreError.criticalRecoveryRequired
            }

        case .maintenanceAcquired:
            let aProof = try originalProof(from: transaction)
            let bProof = candidateProof(from: transaction)
            switch classification {
            case let .exactA(readback):
                try await terminalizeOriginal(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: aProof,
                    journalStore: journalStore
                )
            case .exactB where aProof == bProof:
                // Classification deliberately prefers A for an equal proof,
                // but retain this branch as a fail-closed guard if that order
                // changes in a future repository implementation.
                try await terminalizeOriginal(
                    readback: try await exactReadback(for: lease, proof: aProof),
                    lease: lease,
                    transaction: transaction,
                    proof: aProof,
                    journalStore: journalStore
                )
            case .exactB, .validOpenable, .unreadableOrNeither:
                try persistCriticalIfPossible(journalStore)
                throw HourleafRestoreError.criticalRecoveryRequired
            }

        case .preRestoreBackupVerified:
            try await recoverDirectOriginalPending(
                transaction: transaction,
                sourcePhase: .preRestoreBackupVerified,
                classification: classification,
                lease: lease,
                journalStore: journalStore,
                permitsPhysicalA: false
            )

        case .oldStoreCopyStarted:
            try await recoverDirectOriginalPending(
                transaction: transaction,
                sourcePhase: .oldStoreCopyStarted,
                classification: classification,
                lease: lease,
                journalStore: journalStore,
                permitsPhysicalA: false
            )

        case .oldStoreCopyVerified:
            try await recoverDirectOriginalPending(
                transaction: transaction,
                sourcePhase: .oldStoreCopyVerified,
                classification: classification,
                lease: lease,
                journalStore: journalStore,
                permitsPhysicalA: true
            )

        case .replacementStarted:
            let bProof = candidateProof(from: transaction)
            switch classification {
            case let .exactB(readback):
                try advanceToBPending(journalStore)
                try await terminalizeCandidate(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: bProof,
                    journalStore: journalStore
                )
            case let .exactA(readback):
                let aProof = try originalProof(from: transaction)
                try advanceToOriginalPending(journalStore)
                try await terminalizeOriginal(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: aProof,
                    journalStore: journalStore
                )
            case .validOpenable, .unreadableOrNeither:
                try await restoreOriginal(
                    transaction: transaction,
                    lease: lease,
                    journalStore: journalStore,
                    permitsPhysicalA: true,
                    enterRollbackBeforeReplacement: true
                )
            }

        case .replacementReturned:
            let aProof = try originalProof(from: transaction)
            let bProof = candidateProof(from: transaction)
            switch classification {
            case let .exactB(readback):
                try advanceToBPending(journalStore)
                try await terminalizeCandidate(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: bProof,
                    journalStore: journalStore
                )
            case let .exactA(readback):
                try advanceToOriginalPending(journalStore)
                try await terminalizeOriginal(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: aProof,
                    journalStore: journalStore
                )
            case .validOpenable, .unreadableOrNeither:
                try await restoreOriginal(
                    transaction: transaction,
                    lease: lease,
                    journalStore: journalStore,
                    permitsPhysicalA: true,
                    enterRollbackBeforeReplacement: true
                )
            }

        case .newStoreVerifiedRemindersPending:
            let bProof = candidateProof(from: transaction)
            switch classification {
            case let .exactB(readback):
                try await terminalizeCandidate(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: bProof,
                    journalStore: journalStore
                )
            case .exactA:
                try persistCriticalIfPossible(journalStore)
                throw HourleafRestoreError.criticalRecoveryRequired
            case .validOpenable, .unreadableOrNeither:
                try await restoreOriginal(
                    transaction: transaction,
                    lease: lease,
                    journalStore: journalStore,
                    permitsPhysicalA: true,
                    enterRollbackBeforeReplacement: true
                )
            }

        case .rollbackStarted:
            let aProof = try originalProof(from: transaction)
            switch classification {
            case let .exactA(readback):
                try advanceToOriginalPending(journalStore)
                try await terminalizeOriginal(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: aProof,
                    journalStore: journalStore
                )
            case .exactB, .validOpenable, .unreadableOrNeither:
                try await restoreOriginal(
                    transaction: transaction,
                    lease: lease,
                    journalStore: journalStore,
                    permitsPhysicalA: true,
                    enterRollbackBeforeReplacement: false
                )
            }

        case .oldStoreVerifiedRemindersPending:
            let aProof = try originalProof(from: transaction)
            switch classification {
            case let .exactA(readback):
                try await terminalizeOriginal(
                    readback: readback,
                    lease: lease,
                    transaction: transaction,
                    proof: aProof,
                    journalStore: journalStore
                )
            case .exactB:
                try persistCriticalIfPossible(journalStore)
                throw HourleafRestoreError.criticalRecoveryRequired
            case .validOpenable, .unreadableOrNeither:
                try await restoreOriginal(
                    transaction: transaction,
                    lease: lease,
                    journalStore: journalStore,
                    permitsPhysicalA: true,
                    enterRollbackBeforeReplacement: false
                )
            }

        case .critical:
            throw HourleafRestoreError.criticalRecoveryRequired
        }
    }

    func classifyLive(
        transaction: VerifiedRestoreTransactionV1,
        lease: LedgerMaintenanceLease
    ) async -> StartupLiveClassification {
        guard persistence.startupError == nil else {
            return .unreadableOrNeither
        }
        do {
            let readback = try await repository.validatedReadback(for: lease)
            if let aProof = try? originalProof(from: transaction), matches(readback, proof: aProof) {
                return .exactA(readback)
            }
            let bProof = candidateProof(from: transaction)
            if matches(readback, proof: bProof) {
                return .exactB(readback)
            }
            return .validOpenable(readback)
        } catch {
            return .unreadableOrNeither
        }
    }

    func originalProof(
        from transaction: VerifiedRestoreTransactionV1
    ) throws -> RestoreLogicalProof {
        guard let digest = transaction.journal.content.aRecordsDigest,
              let counts = transaction.journal.content.aRecordCounts else {
            throw HourleafRestoreError.recoveryRequired
        }
        return RestoreLogicalProof(recordsDigest: digest, recordCounts: counts.backupCounts)
    }

    func candidateProof(
        from transaction: VerifiedRestoreTransactionV1
    ) -> RestoreLogicalProof {
        RestoreLogicalProof(
            recordsDigest: transaction.journal.content.candidateRecordsDigest,
            recordCounts: transaction.journal.content.candidateRecordCounts.backupCounts
        )
    }

    func exactReadback(
        for lease: LedgerMaintenanceLease,
        proof: RestoreLogicalProof
    ) async throws -> ValidatedReadback {
        let readback = try await repository.validatedReadback(for: lease)
        guard matches(readback, proof: proof) else {
            throw HourleafRestoreError.recoveryRequired
        }
        return readback
    }

    /// The M3a direct exact-A edge is intentionally restricted to the three
    /// A-evidence phases before replacement. It never writes a replacement or
    /// rollback phase: first prove A, then publish the one allowed A-pending
    /// transition for this exact source phase.
    func recoverDirectOriginalPending(
        transaction: VerifiedRestoreTransactionV1,
        sourcePhase: RestoreJournalPhase,
        classification: StartupLiveClassification,
        lease: LedgerMaintenanceLease,
        journalStore: any RestoreJournalStoring,
        permitsPhysicalA: Bool
    ) async throws {
        let aProof = try originalProof(from: transaction)
        switch classification {
        case let .exactA(readback):
            try advanceDirectOriginalPending(from: sourcePhase, journalStore)
            try await terminalizeOriginal(
                readback: readback,
                lease: lease,
                transaction: transaction,
                proof: aProof,
                journalStore: journalStore
            )
        case .exactB:
            try persistCriticalIfPossible(journalStore)
            throw HourleafRestoreError.criticalRecoveryRequired
        case .validOpenable, .unreadableOrNeither:
            try await restoreOriginal(
                transaction: transaction,
                lease: lease,
                journalStore: journalStore,
                permitsPhysicalA: permitsPhysicalA,
                enterRollbackBeforeReplacement: false,
                directPendingFrom: sourcePhase
            )
        }
    }

    func completeUnstarted(
        transaction: VerifiedRestoreTransactionV1,
        lease: LedgerMaintenanceLease,
        journalStore: any RestoreJournalStoring
    ) async throws {
        let current = try trustedTransaction(from: journalStore)
        guard current.journal.content.phase == .prepared else {
            throw HourleafRestoreError.recoveryRequired
        }
        try cleanupSelectedArtifacts(
            candidateSource: nil,
            rollbackSource: nil,
            physicalSource: nil,
            transaction: current,
            journalStore: journalStore,
            selectedTarget: .b,
            selectedProof: candidateProof(from: transaction)
        )
        let identifier = try transactionIdentifier(from: current)
        try journalStore.complete(
            RestoreTerminalDecisionV1(
                transactionID: identifier,
                sourcePhase: .prepared,
                target: .unstarted
            )
        )
        try verifyTerminalJournalReadback(journalStore)
        try await repository.releaseMaintenanceLease(lease)
    }

    func terminalizeOriginal(
        readback: ValidatedReadback,
        lease: LedgerMaintenanceLease,
        transaction: VerifiedRestoreTransactionV1,
        proof: RestoreLogicalProof,
        journalStore: any RestoreJournalStoring,
        rollbackSource: ValidatedTransitionStore? = nil,
        physicalSource: ValidatedTransitionStore? = nil
    ) async throws {
        guard matches(readback, proof: proof) else {
            throw HourleafRestoreError.recoveryRequired
        }
        let current = try trustedTransaction(from: journalStore)
        guard current.journal.content.phase == .oldStoreVerifiedRemindersPending else {
            throw HourleafRestoreError.recoveryRequired
        }
        let scheduler = await resolvedReminderScheduler()
        try await scheduler.reschedule(readback.reminderSchedules)
        let refreshed = try trustedTransaction(from: journalStore)
        guard refreshed.journal.content.phase == .oldStoreVerifiedRemindersPending else {
            throw HourleafRestoreError.recoveryRequired
        }
        try cleanupSelectedArtifacts(
            candidateSource: nil,
            rollbackSource: rollbackSource,
            physicalSource: physicalSource,
            transaction: refreshed,
            journalStore: journalStore,
            selectedTarget: .a,
            selectedProof: proof
        )
        try journalStore.complete(
            terminalDecision(transaction: refreshed, target: .a, proof: proof)
        )
        try verifyTerminalJournalReadback(journalStore)
        try await repository.releaseMaintenanceLease(lease)
    }

    func terminalizeCandidate(
        readback: ValidatedReadback,
        lease: LedgerMaintenanceLease,
        transaction: VerifiedRestoreTransactionV1,
        proof: RestoreLogicalProof,
        journalStore: any RestoreJournalStoring
    ) async throws {
        guard matches(readback, proof: proof) else {
            throw HourleafRestoreError.recoveryRequired
        }
        let current = try trustedTransaction(from: journalStore)
        guard current.journal.content.phase == .newStoreVerifiedRemindersPending else {
            throw HourleafRestoreError.recoveryRequired
        }
        let scheduler = await resolvedReminderScheduler()
        try await scheduler.reschedule(readback.reminderSchedules)
        let refreshed = try trustedTransaction(from: journalStore)
        try cleanupSelectedArtifacts(
            candidateSource: nil,
            rollbackSource: nil,
            physicalSource: nil,
            transaction: refreshed,
            journalStore: journalStore,
            selectedTarget: .b,
            selectedProof: proof
        )
        try journalStore.complete(
            terminalDecision(transaction: refreshed, target: .b, proof: proof)
        )
        try verifyTerminalJournalReadback(journalStore)
        try await repository.releaseMaintenanceLease(lease)
    }

    func advanceToBPending(_ journalStore: any RestoreJournalStoring) throws {
        var current = try trustedTransaction(from: journalStore)
        if current.journal.content.phase == .replacementStarted {
            try advance(journalStore, to: .replacementReturned) { _ in }
            current = try trustedTransaction(from: journalStore)
        }
        if current.journal.content.phase == .replacementReturned {
            try advance(journalStore, to: .newStoreVerifiedRemindersPending) { _ in }
            current = try trustedTransaction(from: journalStore)
        }
        guard current.journal.content.phase == .newStoreVerifiedRemindersPending else {
            throw HourleafRestoreError.recoveryRequired
        }
    }

    func advanceToOriginalPending(_ journalStore: any RestoreJournalStoring) throws {
        var current = try trustedTransaction(from: journalStore)
        switch current.journal.content.phase {
        case .replacementStarted, .replacementReturned, .newStoreVerifiedRemindersPending:
            try advance(journalStore, to: .rollbackStarted) { _ in }
            current = try trustedTransaction(from: journalStore)
        case .rollbackStarted, .oldStoreVerifiedRemindersPending:
            break
        default:
            throw HourleafRestoreError.recoveryRequired
        }
        if current.journal.content.phase == .rollbackStarted {
            try advance(journalStore, to: .oldStoreVerifiedRemindersPending) { _ in }
            current = try trustedTransaction(from: journalStore)
        }
        guard current.journal.content.phase == .oldStoreVerifiedRemindersPending else {
            throw HourleafRestoreError.recoveryRequired
        }
    }

    func advanceDirectOriginalPending(
        from sourcePhase: RestoreJournalPhase,
        _ journalStore: any RestoreJournalStoring
    ) throws {
        let current = try trustedTransaction(from: journalStore)
        guard current.journal.content.phase == sourcePhase else {
            throw HourleafRestoreError.recoveryRequired
        }
        switch sourcePhase {
        case .preRestoreBackupVerified, .oldStoreCopyStarted, .oldStoreCopyVerified:
            try advance(journalStore, to: .oldStoreVerifiedRemindersPending) { _ in }
        default:
            throw HourleafRestoreError.recoveryRequired
        }
        let pending = try trustedTransaction(from: journalStore)
        guard pending.journal.content.phase == .oldStoreVerifiedRemindersPending else {
            throw HourleafRestoreError.recoveryRequired
        }
    }

    func restoreOriginal(
        transaction: VerifiedRestoreTransactionV1,
        lease: LedgerMaintenanceLease,
        journalStore: any RestoreJournalStoring,
        permitsPhysicalA: Bool,
        enterRollbackBeforeReplacement: Bool,
        directPendingFrom: RestoreJournalPhase? = nil
    ) async throws {
        let aProof = try originalProof(from: transaction)
        if let directPendingFrom {
            let current = try trustedTransaction(from: journalStore)
            guard current.journal.content.phase == directPendingFrom else {
                throw HourleafRestoreError.recoveryRequired
            }
        } else if enterRollbackBeforeReplacement {
            try advanceToRollbackOnly(journalStore)
        }

        let artifactsDirectory: URL
        let source: RecoveryASource
        do {
            artifactsDirectory = try resolvedRecoveryArtifactsDirectory(for: transaction)
            source = try await recoveryASource(
                transaction: transaction,
                proof: aProof,
                artifactsDirectory: artifactsDirectory,
                permitsPhysicalA: permitsPhysicalA
            )
        } catch {
            try persistCriticalIfPossible(journalStore)
            throw HourleafRestoreError.criticalRecoveryRequired
        }

        let closed: ClosedPersistentStoreDescriptor
        do {
            try faultInjector(.recoveryBoundary("before-live-close"))
            closed = try persistence.closePersistentStoreForRecovery(authorizedBy: transaction)
        } catch is PersistentStoreTransitionError {
            throw HourleafRestoreError.recoveryRequired
        } catch {
            throw HourleafRestoreError.recoveryRequired
        }

        let readback: ValidatedReadback
        do {
            try faultInjector(.recoveryBoundary("before-a-replacement"))
            try persistence.replaceClosedStore(closed, with: source.source)
            guard persistence.reopenFreshContainerAfterTransition() == nil else {
                throw HourleafRestoreError.recoveryRequired
            }
            try await repository.resetAfterPersistentStoreTransition(for: lease)
            readback = try await repository.validatedReadback(for: lease)
            guard matches(readback, proof: aProof) else {
                throw HourleafRestoreError.recoveryRequired
            }
            try faultInjector(.recoveryBoundary("after-a-proof"))
        } catch {
            try persistCriticalIfPossible(journalStore)
            throw HourleafRestoreError.criticalRecoveryRequired
        }

        let current = try trustedTransaction(from: journalStore)
        if let directPendingFrom {
            guard current.journal.content.phase == directPendingFrom else {
                throw HourleafRestoreError.recoveryRequired
            }
            try advanceDirectOriginalPending(from: directPendingFrom, journalStore)
        } else if current.journal.content.phase == .rollbackStarted {
            try advance(journalStore, to: .oldStoreVerifiedRemindersPending) { _ in }
        }
        try await terminalizeOriginal(
            readback: readback,
            lease: lease,
            transaction: transaction,
            proof: aProof,
            journalStore: journalStore,
            rollbackSource: source.rollbackSource,
            physicalSource: source.physicalSource
        )
    }

    func advanceToRollbackOnly(_ journalStore: any RestoreJournalStoring) throws {
        let current = try trustedTransaction(from: journalStore)
        switch current.journal.content.phase {
        case .replacementStarted, .replacementReturned, .newStoreVerifiedRemindersPending:
            try advance(journalStore, to: .rollbackStarted) { _ in }
        case .rollbackStarted:
            break
        default:
            throw HourleafRestoreError.recoveryRequired
        }
    }

    func recoveryASource(
        transaction: VerifiedRestoreTransactionV1,
        proof: RestoreLogicalProof,
        artifactsDirectory: URL,
        permitsPhysicalA: Bool
    ) async throws -> RecoveryASource {
        if permitsPhysicalA {
            do {
                if let physical = try await validatedPhysicalASource(
                    transaction: transaction,
                    proof: proof,
                    artifactsDirectory: artifactsDirectory
                ) {
                    return RecoveryASource(
                        source: physical,
                        rollbackSource: nil,
                        physicalSource: physical
                    )
                }
            } catch {
                // The evidence slot is only one recovery source. A malformed,
                // inaccessible, or protection-mismatched physical copy must
                // not prevent the journal-bound portable A fallback.
            }
        }

        let rebuilt = try await rebuildPortableASource(
            transaction: transaction,
            proof: proof,
            artifactsDirectory: artifactsDirectory
        )
        return RecoveryASource(
            source: rebuilt,
            rollbackSource: rebuilt,
            physicalSource: nil
        )
    }

    func validatedPhysicalASource(
        transaction: VerifiedRestoreTransactionV1,
        proof: RestoreLogicalProof,
        artifactsDirectory: URL
    ) async throws -> ValidatedTransitionStore? {
        guard FileManager.default.fileExists(atPath: artifactsDirectory.path) else {
            return nil
        }
        let directoryValues = try artifactsDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else {
            return nil
        }
        try verifyProtection(of: artifactsDirectory)
        let artifact = try PersistentStoreArtifact.make(
            in: artifactsDirectory,
            named: RestoreJournalV1.physicalAStoreBasename,
            purpose: .evidence
        )
        let files = try PersistenceController.existingOrphanedTransitionStoreFiles(
            artifact,
            in: artifactsDirectory,
            named: RestoreJournalV1.physicalAStoreBasename
        )
        guard !files.isEmpty else { return nil }
        for file in files {
            try verifyProtection(of: file)
        }
        do {
            let validated = try await validateTransitionArtifact(artifact, proof: proof).source
            guard validated.storeUUID == transaction.journal.content.physicalAStoreUUID else {
                return nil
            }
            return validated
        } catch {
            // A valid journal can coexist with damaged physical evidence. The
            // portable source remains the durable fallback, so preserve this
            // slot untouched until the selected live target is proved.
            return nil
        }
    }

    func transactionIdentifier(
        from transaction: VerifiedRestoreTransactionV1
    ) throws -> UUID {
        guard let identifier = UUID(uuidString: transaction.journal.content.transactionID) else {
            throw HourleafRestoreError.recoveryRequired
        }
        return identifier
    }
}
