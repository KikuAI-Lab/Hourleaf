import Foundation

/// The typed, pure failure surface for the immutable entry/revision graph.
///
/// The associated UUIDs are diagnostic context for the backup caller. The
/// stable `reason` code is deliberately independent of that context so the
/// live repository can map every failure to one sanitized error.
enum EntryRevisionGraphError: Error, Equatable, Sendable {
    enum Reason: String, Sendable {
        case duplicateEntryID = "duplicate_entry_id"
        case duplicateRevisionRecordID = "duplicate_revision_record_id"
        case duplicateMutationID = "duplicate_mutation_id"
        case revisionMissingEntry = "revision_missing_entry"
        case entryMissingRevision = "entry_missing_revision"
        case nonContiguousRevisions = "non_contiguous_revisions"
        case unknownOperationOrSource = "unknown_operation_or_source"
        case invalidInitialRevision = "invalid_initial_revision"
        case inconsistentCreateTimestamps = "inconsistent_create_timestamps"
        case brokenParent = "broken_parent"
        case createAfterFirstRevision = "create_after_first_revision"
        case invalidUpdateTransition = "invalid_update_transition"
        case invalidDeleteTransition = "invalid_delete_transition"
        case invalidRestoreTransition = "invalid_restore_transition"
        case invalidUndoHeader = "invalid_undo_header"
        case undoCreateInverse = "undo_create_inverse"
        case undoUpdateInverse = "undo_update_inverse"
        case undoDeleteInverse = "undo_delete_inverse"
        case undoRestoreInverse = "undo_restore_inverse"
        case undoUndo = "undo_undo"
        case currentRevisionMismatch = "current_revision_mismatch"
    }

    case duplicateEntryID(UUID)
    case duplicateRevisionRecordID(UUID)
    case duplicateMutationID(UUID)
    case revisionMissingEntry(UUID)
    case entryMissingRevision(UUID)
    case nonContiguousRevisions(UUID)
    case unknownOperationOrSource(UUID)
    case invalidInitialRevision(UUID)
    case inconsistentCreateTimestamps(UUID)
    case brokenParent(UUID)
    case createAfterFirstRevision(UUID)
    case invalidUpdateTransition(UUID)
    case invalidDeleteTransition(UUID)
    case invalidRestoreTransition(UUID)
    case invalidUndoHeader(UUID)
    case undoCreateInverse(UUID)
    case undoUpdateInverse(UUID)
    case undoDeleteInverse(UUID)
    case undoRestoreInverse(UUID)
    case undoUndo(UUID)
    case currentRevisionMismatch(UUID)

    var reasonCode: Reason {
        return switch self {
        case .duplicateEntryID: .duplicateEntryID
        case .duplicateRevisionRecordID: .duplicateRevisionRecordID
        case .duplicateMutationID: .duplicateMutationID
        case .revisionMissingEntry: .revisionMissingEntry
        case .entryMissingRevision: .entryMissingRevision
        case .nonContiguousRevisions: .nonContiguousRevisions
        case .unknownOperationOrSource: .unknownOperationOrSource
        case .invalidInitialRevision: .invalidInitialRevision
        case .inconsistentCreateTimestamps: .inconsistentCreateTimestamps
        case .brokenParent: .brokenParent
        case .createAfterFirstRevision: .createAfterFirstRevision
        case .invalidUpdateTransition: .invalidUpdateTransition
        case .invalidDeleteTransition: .invalidDeleteTransition
        case .invalidRestoreTransition: .invalidRestoreTransition
        case .invalidUndoHeader: .invalidUndoHeader
        case .undoCreateInverse: .undoCreateInverse
        case .undoUpdateInverse: .undoUpdateInverse
        case .undoDeleteInverse: .undoDeleteInverse
        case .undoRestoreInverse: .undoRestoreInverse
        case .undoUndo: .undoUndo
        case .currentRevisionMismatch: .currentRevisionMismatch
        }
    }

    /// A stable machine-readable reason for callers that do not need context.
    var reason: String { reasonCode.rawValue }

    /// A diagnostic description that retains the existing backup validator's
    /// wording where the old rule carried an entry identifier.
    var diagnosticDescription: String {
        let entryID: UUID? = switch self {
        case let .duplicateEntryID(id),
             let .duplicateRevisionRecordID(id),
             let .duplicateMutationID(id),
             let .revisionMissingEntry(id),
             let .entryMissingRevision(id),
             let .nonContiguousRevisions(id),
             let .unknownOperationOrSource(id),
             let .invalidInitialRevision(id),
             let .inconsistentCreateTimestamps(id),
             let .brokenParent(id),
             let .createAfterFirstRevision(id),
             let .invalidUpdateTransition(id),
             let .invalidDeleteTransition(id),
             let .invalidRestoreTransition(id),
             let .invalidUndoHeader(id),
             let .undoCreateInverse(id),
             let .undoUpdateInverse(id),
             let .undoDeleteInverse(id),
             let .undoRestoreInverse(id),
             let .undoUndo(id),
             let .currentRevisionMismatch(id):
            id
        }
        let id = entryID?.uuidString.lowercased()

        return switch self {
        case .duplicateEntryID:
            "duplicate entry id"
        case .duplicateRevisionRecordID:
            "duplicate revision record id"
        case .duplicateMutationID:
            "duplicate mutation id"
        case .revisionMissingEntry:
            "revision references a missing entry"
        case .entryMissingRevision:
            "entry \(id!) has no revisions"
        case .nonContiguousRevisions:
            "entry \(id!) revision numbers are not contiguous"
        case .unknownOperationOrSource:
            "entry \(id!) has an unknown mutation operation or source"
        case .invalidInitialRevision:
            "entry \(id!) must begin with an active create revision"
        case .inconsistentCreateTimestamps:
            "entry \(id!) create timestamps are inconsistent"
        case .brokenParent:
            "entry \(id!) has a broken revision parent or creation date"
        case .createAfterFirstRevision:
            "entry \(id!) cannot create after revision one"
        case .invalidUpdateTransition:
            "entry \(id!) has an invalid update transition"
        case .invalidDeleteTransition:
            "entry \(id!) has an invalid delete transition"
        case .invalidRestoreTransition:
            "entry \(id!) has an invalid restore transition"
        case .invalidUndoHeader:
            "entry \(id!) has an invalid undo header"
        case .undoCreateInverse:
            "entry \(id!) undo does not invert create"
        case .undoUpdateInverse:
            "entry \(id!) undo does not restore update parent"
        case .undoDeleteInverse:
            "entry \(id!) undo does not invert delete"
        case .undoRestoreInverse:
            "entry \(id!) undo does not restore deleted state"
        case .undoUndo:
            "entry \(id!) cannot undo an undo"
        case .currentRevisionMismatch:
            "entry \(id!) does not match its current revision"
        }
    }
}

/// Pure validation for the immutable entry/revision history.
///
/// This type deliberately receives already-decoded domain records. It does
/// not normalize notes, dates, ordering, or Core Data state; callers own raw
/// syntax validation and public error mapping at their respective boundaries.
enum EntryRevisionGraphValidator {
    static func validate(
        entries: [LedgerEntryRecord],
        revisions: [EntryRevisionRecord]
    ) throws {
        var entriesByID = [UUID: LedgerEntryRecord](minimumCapacity: entries.count)
        var recordIDs = Set<UUID>(minimumCapacity: entries.count + revisions.count)

        for entry in entries {
            guard recordIDs.insert(entry.id).inserted else {
                throw EntryRevisionGraphError.duplicateEntryID(entry.id)
            }
            guard entriesByID.updateValue(entry, forKey: entry.id) == nil else {
                throw EntryRevisionGraphError.duplicateEntryID(entry.id)
            }
        }

        var revisionsByEntry = [UUID: [EntryRevisionRecord]]()
        var mutationIDs = Set<UUID>(minimumCapacity: revisions.count)
        for revision in revisions {
            guard recordIDs.insert(revision.id).inserted else {
                throw EntryRevisionGraphError.duplicateRevisionRecordID(revision.id)
            }
            guard mutationIDs.insert(revision.mutationID).inserted else {
                throw EntryRevisionGraphError.duplicateMutationID(revision.mutationID)
            }
            guard entriesByID[revision.entryID] != nil else {
                throw EntryRevisionGraphError.revisionMissingEntry(revision.entryID)
            }
            revisionsByEntry[revision.entryID, default: []].append(revision)
        }

        for entryID in entriesByID.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let entry = entriesByID[entryID] else { continue }
            guard let revisions = revisionsByEntry[entryID], !revisions.isEmpty else {
                throw EntryRevisionGraphError.entryMissingRevision(entryID)
            }
            let ordered = revisions.sorted {
                ($0.revision, $0.id.uuidString) < ($1.revision, $1.id.uuidString)
            }
            try validateRevisionHistory(ordered, entryID: entryID)

            guard
                let current = ordered.last,
                entry.revision == current.revision,
                entry.lastMutationID == current.mutationID,
                entry.entry.kind.rawValue == current.kind,
                entry.entry.day.key == current.localDay,
                entry.entry.minutes == current.minutes,
                entry.entry.note == current.note,
                entry.entry.createdAt == current.entryCreatedAt,
                entry.entry.updatedAt == current.entryUpdatedAt,
                entry.deletedAt == current.entryDeletedAt,
                entry.source == current.source
            else {
                throw EntryRevisionGraphError.currentRevisionMismatch(entryID)
            }
        }
    }

    private static func validateRevisionHistory(
        _ revisions: [EntryRevisionRecord],
        entryID: UUID
    ) throws {
        var prior: EntryRevisionRecord?
        var priorToPrior: EntryRevisionRecord?

        for (offset, revision) in revisions.enumerated() {
            let expectedRevision = Int64(offset + 1)
            guard revision.revision == expectedRevision else {
                throw EntryRevisionGraphError.nonContiguousRevisions(entryID)
            }
            guard
                let operation = EntryMutationOperation(rawValue: revision.operation),
                let source = EntryMutationSource(rawValue: revision.source)
            else {
                throw EntryRevisionGraphError.unknownOperationOrSource(entryID)
            }

            if let prior {
                guard
                    operation != .create,
                    revision.parentMutationID == prior.mutationID,
                    revision.entryCreatedAt == prior.entryCreatedAt
                else {
                    throw EntryRevisionGraphError.brokenParent(entryID)
                }
            } else {
                guard
                    operation == .create,
                    revision.parentMutationID == nil,
                    revision.revertedMutationID == nil,
                    revision.entryDeletedAt == nil,
                    isValidCreateSource(source)
                else {
                    throw EntryRevisionGraphError.invalidInitialRevision(entryID)
                }
                if source != .migration {
                    guard
                        revision.entryCreatedAt == revision.occurredAt,
                        revision.entryUpdatedAt == revision.occurredAt
                    else {
                        throw EntryRevisionGraphError.inconsistentCreateTimestamps(entryID)
                    }
                }
                prior = revision
                continue
            }

            guard let parent = prior else {
                throw EntryRevisionGraphError.brokenParent(entryID)
            }
            switch operation {
            case .create:
                throw EntryRevisionGraphError.createAfterFirstRevision(entryID)
            case .update:
                guard
                    source == .appHistory,
                    revision.revertedMutationID == nil,
                    parent.entryDeletedAt == nil,
                    revision.entryDeletedAt == nil,
                    revision.entryUpdatedAt == revision.occurredAt
                else {
                    throw EntryRevisionGraphError.invalidUpdateTransition(entryID)
                }
            case .delete:
                guard
                    source == .appHistory,
                    revision.revertedMutationID == nil,
                    parent.entryDeletedAt == nil,
                    sameEntryValues(revision, parent),
                    revision.entryDeletedAt == revision.occurredAt,
                    revision.entryUpdatedAt == revision.occurredAt
                else {
                    throw EntryRevisionGraphError.invalidDeleteTransition(entryID)
                }
            case .restore:
                guard
                    source == .restore,
                    revision.revertedMutationID == nil,
                    parent.entryDeletedAt != nil,
                    sameEntryValues(revision, parent),
                    revision.entryDeletedAt == nil,
                    revision.entryUpdatedAt == revision.occurredAt
                else {
                    throw EntryRevisionGraphError.invalidRestoreTransition(entryID)
                }
            case .undo:
                try validateUndoTransition(
                    revision,
                    target: parent,
                    targetParent: priorToPrior,
                    entryID: entryID
                )
            }

            priorToPrior = prior
            prior = revision
        }
    }

    private static func validateUndoTransition(
        _ revision: EntryRevisionRecord,
        target: EntryRevisionRecord,
        targetParent: EntryRevisionRecord?,
        entryID: UUID
    ) throws {
        guard
            revision.source == EntryMutationSource.undo.rawValue,
            revision.revertedMutationID == target.mutationID,
            revision.parentMutationID == target.mutationID,
            revision.entryUpdatedAt == revision.occurredAt,
            target.source != EntryMutationSource.migration.rawValue,
            let targetOperation = EntryMutationOperation(rawValue: target.operation),
            targetOperation != .undo
        else {
            throw EntryRevisionGraphError.invalidUndoHeader(entryID)
        }

        switch targetOperation {
        case .create:
            guard
                target.entryDeletedAt == nil,
                sameEntryValues(revision, target),
                revision.entryDeletedAt == revision.occurredAt
            else {
                throw EntryRevisionGraphError.undoCreateInverse(entryID)
            }
        case .update:
            guard
                let targetParent,
                target.entryDeletedAt == nil,
                targetParent.entryDeletedAt == nil,
                sameEntryValues(revision, targetParent),
                revision.entryDeletedAt == nil
            else {
                throw EntryRevisionGraphError.undoUpdateInverse(entryID)
            }
        case .delete:
            guard
                let targetParent,
                target.entryDeletedAt != nil,
                targetParent.entryDeletedAt == nil,
                sameEntryValues(revision, target),
                revision.entryDeletedAt == nil
            else {
                throw EntryRevisionGraphError.undoDeleteInverse(entryID)
            }
        case .restore:
            guard
                let targetParent,
                let deletedAt = targetParent.entryDeletedAt,
                target.entryDeletedAt == nil,
                sameEntryValues(revision, target),
                revision.entryDeletedAt == deletedAt
            else {
                throw EntryRevisionGraphError.undoRestoreInverse(entryID)
            }
        case .undo:
            throw EntryRevisionGraphError.undoUndo(entryID)
        }
    }

    private static func isValidCreateSource(_ source: EntryMutationSource) -> Bool {
        switch source {
        case .appQuickEntry, .appOneTap, .shortcut, .widget, .watch, .timer, .csvImport, .migration:
            true
        case .appHistory, .restore, .undo:
            false
        }
    }

    private static func sameEntryValues(
        _ lhs: EntryRevisionRecord,
        _ rhs: EntryRevisionRecord
    ) -> Bool {
        lhs.entryCreatedAt == rhs.entryCreatedAt
            && lhs.kind == rhs.kind
            && lhs.localDay == rhs.localDay
            && lhs.minutes == rhs.minutes
            && lhs.note == rhs.note
    }
}
