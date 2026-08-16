import CryptoKit
import Foundation

enum HourleafBackupLimitsV1 {
    static let maximumFileBytes = 32 * 1_024 * 1_024
    static let maximumRecords = 250_000
    static let maximumEntries = 100_000
    static let maximumRevisions = 200_000
    static let maximumPolicies = 10_000
    static let maximumReminders = 512
    static let maximumReceipts = 50_000
    static let maximumStates = 10_000
    static let maximumPresets = 1_000
    static let maximumAcknowledgements = 100_000
    static let maximumArchives = 10_000
    static let maximumBibleStudyCounts = maximumStates
    // App settings and report copy currently have no smaller byte limits.
    // The outer UTF-8 file cap is therefore the compatible string bound; do
    // not make a healthy locally-created ledger unexportable with a new,
    // backup-only truncation rule.
    static let maximumStringBytes = maximumFileBytes
    static let maximumStructuredStringBytes = maximumFileBytes
    static let maximumNoteCharacters = 280
    static let maximumNoteBytes = maximumFileBytes
    static let maximumReportTextBytes = maximumFileBytes

    /// The maximum report total derivable from the bounded entry collection.
    /// This keeps later `Int` conversion and carry arithmetic comfortably
    /// inside range even for hostile but re-checksummed input.
    static let maximumAggregateMinutes = Int64(maximumEntries) * 5_999
    static let maximumReportHours = maximumAggregateMinutes / 60 + 1

    /// `TimeWheelPicker(maximumDirectHours: 24 * 366)` also permits its
    /// selected minute component, so this is the exact largest baseline the
    /// app can create. A future configurable target uses the same direct-time
    /// safety bound rather than an accidental physical-calendar cap.
    static let maximumBaselineMinutes = Int64(24 * 366 * 60 + 59)
    static let maximumServiceYearTargetMinutes = maximumBaselineMinutes

    /// Archives may record a valid baseline plus every bounded service entry;
    /// entries are not constrained to non-overlapping wall-clock minutes.
    /// This remains far below `Int.max`, preserving later progress arithmetic.
    static let maximumArchiveActualMinutes = maximumBaselineMinutes + maximumAggregateMinutes
}

enum HourleafBackupError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(actual: Int, limit: Int)
    case invalidJSON(String)
    case nonCanonicalJSON
    case wrongFormat(String)
    case unsupportedVersion(Int)
    case unsupportedChecksumAlgorithm(String)
    case checksumMismatch
    case invalidRecord(String)
    case invalidGraph(String)

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(actual, limit):
            "The backup is \(actual) bytes, above the \(limit)-byte limit."
        case let .invalidJSON(reason):
            "The backup is not valid JSON: \(reason)"
        case .nonCanonicalJSON:
            "The backup is not in Hourleaf canonical JSON form."
        case let .wrongFormat(format):
            "The backup format \(format) is not an Hourleaf backup."
        case let .unsupportedVersion(version):
            "Backup version \(version) is not supported."
        case let .unsupportedChecksumAlgorithm(algorithm):
            "Checksum algorithm \(algorithm) is not supported."
        case .checksumMismatch:
            "The backup checksum does not match its content."
        case let .invalidRecord(reason):
            "The backup has an invalid record: \(reason)"
        case let .invalidGraph(reason):
            "The backup record graph is invalid: \(reason)"
        }
    }
}

struct VerifiedHourleafBackupV1: Equatable, Sendable {
    let data: Data
    let content: HourleafBackupContentV1
    let checksum: HourleafBackupChecksumV1
    let recordsDigest: String

    var byteCount: Int { data.count }
    var recordCounts: HourleafBackupRecordCountsV1 { content.records.counts }
}

/// The exact version-1 encoding omitted the additive Bible-study collection.
/// These projections keep its checksum and canonical-byte contract intact
/// while the in-memory representation supplies an empty collection.
private struct LegacyHourleafBackupRecordsV1: Encodable {
    let acknowledgements: [HourleafDayAcknowledgementV1]
    let archives: [HourleafServiceYearArchiveV1]
    let entries: [HourleafEntryV1]
    let policies: [HourleafPolicyRevisionV1]
    let presets: [HourleafPresetV1]
    let receipts: [HourleafReportReceiptV1]
    let reminders: [HourleafReminderV1]
    let revisions: [HourleafEntryRevisionV1]
    let settings: HourleafSettingsV1
    let states: [HourleafReportStateV1]

    init(_ records: HourleafBackupRecordsV1) {
        acknowledgements = records.acknowledgements
        archives = records.archives
        entries = records.entries
        policies = records.policies
        presets = records.presets
        receipts = records.receipts
        reminders = records.reminders
        revisions = records.revisions
        settings = records.settings
        states = records.states
    }
}

private struct LegacyHourleafBackupContentV1: Encodable {
    let format: String
    let version: Int
    let exportedAt: Double
    let records: LegacyHourleafBackupRecordsV1

    init(_ content: HourleafBackupContentV1) {
        format = content.format
        version = content.version
        exportedAt = content.exportedAt
        records = LegacyHourleafBackupRecordsV1(content.records)
    }
}

private struct LegacyHourleafBackupEnvelopeV1: Encodable {
    let content: LegacyHourleafBackupContentV1
    let checksum: HourleafBackupChecksumV1
}

enum HourleafBackupCodec {
    static func encode(content: HourleafBackupContentV1) throws -> VerifiedHourleafBackupV1 {
        try validate(content: content)
        let canonicalContent = try canonicalized(content)
        let contentData = try canonicalContentData(canonicalContent)
        let checksum = HourleafBackupChecksumV1(value: sha256(contentData))
        let data = try canonicalEnvelopeData(content: canonicalContent, checksum: checksum)
        guard data.count <= HourleafBackupLimitsV1.maximumFileBytes else {
            throw HourleafBackupError.fileTooLarge(
                actual: data.count,
                limit: HourleafBackupLimitsV1.maximumFileBytes
            )
        }
        return VerifiedHourleafBackupV1(
            data: data,
            content: canonicalContent,
            checksum: checksum,
            recordsDigest: try storeDigest(canonicalContent.records)
        )
    }

    static func decodeAndVerify(_ data: Data) throws -> VerifiedHourleafBackupV1 {
        guard data.count <= HourleafBackupLimitsV1.maximumFileBytes else {
            throw HourleafBackupError.fileTooLarge(
                actual: data.count,
                limit: HourleafBackupLimitsV1.maximumFileBytes
            )
        }
        let envelope: HourleafBackupEnvelopeV1
        do {
            envelope = try JSONDecoder().decode(HourleafBackupEnvelopeV1.self, from: data)
        } catch {
            throw HourleafBackupError.invalidJSON(error.localizedDescription)
        }

        try validate(content: envelope.content)
        guard envelope.checksum.algorithm == HourleafBackupV1.checksumAlgorithm else {
            throw HourleafBackupError.unsupportedChecksumAlgorithm(envelope.checksum.algorithm)
        }
        guard isLowercaseSHA256(envelope.checksum.value) else {
            throw HourleafBackupError.checksumMismatch
        }

        let canonicalContent = try canonicalized(envelope.content)
        let canonicalContentData = try canonicalContentData(canonicalContent)
        let digest = sha256(canonicalContentData)
        guard digest == envelope.checksum.value else {
            throw HourleafBackupError.checksumMismatch
        }

        guard try canonicalEnvelopeData(
            content: canonicalContent,
            checksum: envelope.checksum
        ) == data else {
            throw HourleafBackupError.nonCanonicalJSON
        }

        return VerifiedHourleafBackupV1(
            data: data,
            content: canonicalContent,
            checksum: envelope.checksum,
            recordsDigest: try storeDigest(canonicalContent.records)
        )
    }

    static func storeDigest(_ records: HourleafBackupRecordsV1) throws -> String {
        try validate(records: records)
        return sha256(try canonicalData(canonicalized(records)))
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func canonicalContentData(_ content: HourleafBackupContentV1) throws -> Data {
        if content.version == HourleafBackupV1.legacyVersion {
            return try canonicalData(LegacyHourleafBackupContentV1(content))
        }
        return try canonicalData(content)
    }

    private static func canonicalEnvelopeData(
        content: HourleafBackupContentV1,
        checksum: HourleafBackupChecksumV1
    ) throws -> Data {
        if content.version == HourleafBackupV1.legacyVersion {
            return try canonicalData(LegacyHourleafBackupEnvelopeV1(
                content: LegacyHourleafBackupContentV1(content),
                checksum: checksum
            ))
        }
        return try canonicalData(HourleafBackupEnvelopeV1(content: content, checksum: checksum))
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func canonicalized(_ content: HourleafBackupContentV1) throws -> HourleafBackupContentV1 {
        HourleafBackupContentV1(
            format: content.format,
            version: content.version,
            exportedAt: content.exportedAt,
            records: canonicalized(content.records)
        )
    }

    private static func canonicalized(_ records: HourleafBackupRecordsV1) -> HourleafBackupRecordsV1 {
        HourleafBackupRecordsV1(
            acknowledgements: records.acknowledgements.sorted { ($0.id ?? "") < ($1.id ?? "") },
            archives: records.archives.sorted { ($0.id ?? "") < ($1.id ?? "") },
            bibleStudyCounts: records.bibleStudyCounts.sorted { ($0.monthKey ?? "") < ($1.monthKey ?? "") },
            entries: records.entries.sorted { ($0.id ?? "") < ($1.id ?? "") },
            policies: records.policies.sorted { ($0.id ?? "") < ($1.id ?? "") },
            presets: records.presets.sorted { ($0.id ?? "") < ($1.id ?? "") },
            receipts: records.receipts.sorted { ($0.id ?? "") < ($1.id ?? "") },
            reminders: records.reminders.sorted { ($0.id ?? "") < ($1.id ?? "") },
            revisions: records.revisions.sorted { ($0.id ?? "") < ($1.id ?? "") },
            settings: records.settings,
            states: records.states.sorted { ($0.id ?? "") < ($1.id ?? "") }
        )
    }

    private static func validate(content: HourleafBackupContentV1) throws {
        guard content.format == HourleafBackupV1.format else {
            throw HourleafBackupError.wrongFormat(content.format)
        }
        guard HourleafBackupV1.supportedVersions.contains(content.version) else {
            throw HourleafBackupError.unsupportedVersion(content.version)
        }
        guard content.version != HourleafBackupV1.legacyVersion || content.records.bibleStudyCounts.isEmpty else {
            throw HourleafBackupError.invalidRecord(
                "version 1 cannot contain monthly Bible-study counts"
            )
        }
        try validateDate(content.exportedAt, path: "content.exportedAt")
        try validate(records: content.records)
    }

    private static func validate(records: HourleafBackupRecordsV1) throws {
        let counts = records.counts
        guard counts.total <= HourleafBackupLimitsV1.maximumRecords - records.bibleStudyCounts.count else {
            throw HourleafBackupError.invalidRecord("total record count exceeds the limit")
        }
        try validateCount(counts.entries, maximum: HourleafBackupLimitsV1.maximumEntries, path: "entries")
        try validateCount(counts.revisions, maximum: HourleafBackupLimitsV1.maximumRevisions, path: "revisions")
        try validateCount(counts.policies, maximum: HourleafBackupLimitsV1.maximumPolicies, path: "policies")
        try validateCount(counts.reminders, maximum: HourleafBackupLimitsV1.maximumReminders, path: "reminders")
        try validateCount(counts.receipts, maximum: HourleafBackupLimitsV1.maximumReceipts, path: "receipts")
        try validateCount(counts.states, maximum: HourleafBackupLimitsV1.maximumStates, path: "states")
        try validateCount(counts.presets, maximum: HourleafBackupLimitsV1.maximumPresets, path: "presets")
        try validateCount(counts.acknowledgements, maximum: HourleafBackupLimitsV1.maximumAcknowledgements, path: "acknowledgements")
        try validateCount(counts.archives, maximum: HourleafBackupLimitsV1.maximumArchives, path: "archives")
        try validateCount(
            records.bibleStudyCounts.count,
            maximum: HourleafBackupLimitsV1.maximumBibleStudyCounts,
            path: "bibleStudyCounts"
        )

        var allRecordIDs = Set<String>()
        func registerRecordID(_ id: String, path: String) throws {
            guard allRecordIDs.insert(id).inserted else {
                throw HourleafBackupError.invalidGraph("duplicate record id at \(path)")
            }
        }

        var entriesByID = [String: HourleafEntryV1]()
        for (index, entry) in records.entries.enumerated() {
            let path = "entries[\(index)]"
            let id = try validate(entry: entry, path: path)
            try registerRecordID(id, path: path)
            guard entriesByID.updateValue(entry, forKey: id) == nil else {
                throw HourleafBackupError.invalidGraph("duplicate entry id at \(path)")
            }
        }

        var mutationIDs = Set<String>()
        for (index, revision) in records.revisions.enumerated() {
            let path = "revisions[\(index)]"
            let ids = try validate(revision: revision, path: path)
            try registerRecordID(ids.id, path: path)
            guard mutationIDs.insert(ids.mutationID).inserted else {
                throw HourleafBackupError.invalidGraph("duplicate mutation id at \(path)")
            }
            guard entriesByID[ids.entryID] != nil else {
                throw HourleafBackupError.invalidGraph("revision at \(path) references a missing entry")
            }
        }

        do {
            try EntryRevisionGraphValidator.validate(
                entries: records.entries.map(Self.graphEntryRecord),
                revisions: records.revisions.map(Self.graphRevisionRecord)
            )
        } catch let error as EntryRevisionGraphError {
            throw HourleafBackupError.invalidGraph(error.diagnosticDescription)
        }

        for (index, policy) in records.policies.enumerated() {
            let id = try validate(policy: policy, path: "policies[\(index)]")
            try registerRecordID(id, path: "policies[\(index)]")
        }

        var activePresetPositions = Set<Int16>()
        for (index, preset) in records.presets.enumerated() {
            let id = try validate(preset: preset, path: "presets[\(index)]")
            try registerRecordID(id, path: "presets[\(index)]")
            if preset.deletedAt == nil, !activePresetPositions.insert(preset.position).inserted {
                throw HourleafBackupError.invalidGraph("active presets reuse position \(preset.position)")
            }
        }

        for (index, reminder) in records.reminders.enumerated() {
            let id = try validate(reminder: reminder, path: "reminders[\(index)]")
            try registerRecordID(id, path: "reminders[\(index)]")
        }

        var receiptsByID = [String: HourleafReportReceiptV1]()
        var receiptsByMonth = [String: [HourleafReportReceiptV1]]()
        for (index, receipt) in records.receipts.enumerated() {
            let id = try validate(receipt: receipt, path: "receipts[\(index)]")
            try registerRecordID(id, path: "receipts[\(index)]")
            guard receiptsByID.updateValue(receipt, forKey: id) == nil else {
                throw HourleafBackupError.invalidGraph("duplicate receipt id at receipts[\(index)]")
            }
            receiptsByMonth[receipt.monthKey!, default: []].append(receipt)
        }

        let newestReceiptIDs = try validateReceiptSeries(receiptsByMonth)
        var statesByMonth = [String: HourleafReportStateV1]()
        for (index, state) in records.states.enumerated() {
            let id = try validate(state: state, path: "states[\(index)]")
            try registerRecordID(id, path: "states[\(index)]")
            let month = state.monthKey!
            guard statesByMonth.updateValue(state, forKey: month) == nil else {
                throw HourleafBackupError.invalidGraph("duplicate report state for \(month)")
            }
            if let currentSnapshotID = state.currentSnapshotID {
                guard let receipt = receiptsByID[currentSnapshotID], receipt.monthKey == month else {
                    throw HourleafBackupError.invalidGraph("state \(id) references a missing or wrong-month receipt")
                }
                if state.state == "sent", receipt.confirmedSentAt == nil {
                    throw HourleafBackupError.invalidGraph("sent state \(id) lacks a sent receipt")
                }
                if state.state == "prepared", receipt.confirmedSentAt != nil {
                    throw HourleafBackupError.invalidGraph("prepared state \(id) references a sent receipt")
                }
            } else if state.state == "prepared" || state.state == "sent" {
                throw HourleafBackupError.invalidGraph("\(state.state!) state \(id) has no current receipt")
            }
        }
        for (month, newestReceiptID) in newestReceiptIDs {
            guard statesByMonth[month]?.currentSnapshotID == newestReceiptID else {
                throw HourleafBackupError.invalidGraph(
                    "report state for \(month) does not point to its newest receipt"
                )
            }
        }


        var bibleStudyMonths = Set<String>()
        for (index, value) in records.bibleStudyCounts.enumerated() {
            let path = "bibleStudyCounts[\(index)]"
            let month = try validate(bibleStudyCount: value, path: path)
            guard bibleStudyMonths.insert(month).inserted else {
                throw HourleafBackupError.invalidGraph("duplicate Bible-study count for \(month)")
            }
            guard statesByMonth[month] != nil else {
                throw HourleafBackupError.invalidGraph(
                    "Bible-study count for \(month) has no report state"
                )
            }
        }

        var archivesBySeries = [String: [HourleafServiceYearArchiveV1]]()
        for (index, archive) in records.archives.enumerated() {
            let id = try validate(archive: archive, path: "archives[\(index)]")
            try registerRecordID(id, path: "archives[\(index)]")
            let series = "\(archive.startMonthKey!)|\(archive.endMonthKey!)"
            archivesBySeries[series, default: []].append(archive)
        }
        try validateArchiveSeries(archivesBySeries)

        for (index, acknowledgement) in records.acknowledgements.enumerated() {
            let id = try validate(acknowledgement: acknowledgement, path: "acknowledgements[\(index)]")
            try registerRecordID(id, path: "acknowledgements[\(index)]")
        }

        let settingsID = try validate(settings: records.settings, path: "settings")
        try registerRecordID(settingsID, path: "settings")
    }

    private static func validateCount(_ count: Int, maximum: Int, path: String) throws {
        guard count <= maximum else {
            throw HourleafBackupError.invalidRecord("\(path) count exceeds \(maximum)")
        }
    }

    /// Convert raw rows only after their boundary syntax has been checked.
    /// Assigning the note after `TimeEntry` construction is intentional:
    /// `TimeEntry.init` normalizes user input, while backup graph validation
    /// must compare the stored note exactly.
    private static func graphEntryRecord(_ raw: HourleafEntryV1) throws -> LedgerEntryRecord {
        guard
            let idValue = raw.id,
            let id = UUID(uuidString: idValue),
            let kindValue = raw.kind,
            let kind = EntryKind(rawValue: kindValue),
            let localDayValue = raw.localDay,
            let day = LocalDay(key: localDayValue),
            let lastMutationValue = raw.lastMutationID,
            let lastMutationID = UUID(uuidString: lastMutationValue),
            let createdAtValue = raw.createdAt,
            let updatedAtValue = raw.updatedAt,
            let source = raw.source
        else {
            throw HourleafBackupError.invalidRecord("entry graph conversion failed")
        }

        var entry = TimeEntry(
            id: id,
            kind: kind,
            day: day,
            minutes: Int(raw.minutes),
            note: raw.note,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAtValue),
            updatedAt: Date(timeIntervalSinceReferenceDate: updatedAtValue)
        )
        entry.note = raw.note
        return LedgerEntryRecord(
            entry: entry,
            deletedAt: raw.deletedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            source: source,
            revision: raw.revision,
            lastMutationID: lastMutationID
        )
    }

    private static func graphRevisionRecord(_ raw: HourleafEntryRevisionV1) throws -> EntryRevisionRecord {
        guard
            let idValue = raw.id,
            let id = UUID(uuidString: idValue),
            let entryIDValue = raw.entryID,
            let entryID = UUID(uuidString: entryIDValue),
            let mutationIDValue = raw.mutationID,
            let mutationID = UUID(uuidString: mutationIDValue),
            let operation = raw.operation,
            let kind = raw.kind,
            let localDay = raw.localDay,
            let entryCreatedAtValue = raw.entryCreatedAt,
            let entryUpdatedAtValue = raw.entryUpdatedAt,
            let source = raw.source,
            let occurredAtValue = raw.occurredAt
        else {
            throw HourleafBackupError.invalidRecord("revision graph conversion failed")
        }

        return EntryRevisionRecord(
            id: id,
            entryID: entryID,
            mutationID: mutationID,
            parentMutationID: raw.parentMutationID.flatMap(UUID.init(uuidString:)),
            revertedMutationID: raw.revertedMutationID.flatMap(UUID.init(uuidString:)),
            revision: raw.revision,
            operation: operation,
            kind: kind,
            localDay: localDay,
            minutes: Int(raw.minutes),
            note: raw.note,
            entryCreatedAt: Date(timeIntervalSinceReferenceDate: entryCreatedAtValue),
            entryUpdatedAt: Date(timeIntervalSinceReferenceDate: entryUpdatedAtValue),
            entryDeletedAt: raw.entryDeletedAt.map(Date.init(timeIntervalSinceReferenceDate:)),
            source: source,
            occurredAt: Date(timeIntervalSinceReferenceDate: occurredAtValue)
        )
    }

    private static func validate(entry: HourleafEntryV1, path: String) throws -> String {
        let id = try requiredUUID(entry.id, path: "\(path).id")
        _ = try requiredUUID(entry.lastMutationID, path: "\(path).lastMutationID")
        _ = try requireEnum(entry.kind, EntryKind.self, path: "\(path).kind")
        _ = try requireLocalDay(entry.localDay, path: "\(path).localDay")
        try validateInteger(Int64(entry.minutes), range: 1...5_999, path: "\(path).minutes")
        guard entry.revision >= 1 else {
            throw HourleafBackupError.invalidRecord("\(path).revision must be positive")
        }
        try requireMutationSource(entry.source, path: "\(path).source")
        try validateDate(entry.createdAt, path: "\(path).createdAt", required: true)
        try validateDate(entry.updatedAt, path: "\(path).updatedAt", required: true)
        try validateDate(entry.deletedAt, path: "\(path).deletedAt")
        try validateNote(entry.note, path: "\(path).note")
        return id
    }

    private static func validate(revision: HourleafEntryRevisionV1, path: String) throws -> (id: String, entryID: String, mutationID: String) {
        let id = try requiredUUID(revision.id, path: "\(path).id")
        let entryID = try requiredUUID(revision.entryID, path: "\(path).entryID")
        let mutationID = try requiredUUID(revision.mutationID, path: "\(path).mutationID")
        if let parentMutationID = revision.parentMutationID {
            _ = try requiredUUID(parentMutationID, path: "\(path).parentMutationID")
        }
        if let revertedMutationID = revision.revertedMutationID {
            _ = try requiredUUID(revertedMutationID, path: "\(path).revertedMutationID")
        }
        guard revision.revision >= 1 else {
            throw HourleafBackupError.invalidRecord("\(path).revision must be positive")
        }
        _ = try requireEnum(revision.operation, EntryMutationOperation.self, path: "\(path).operation")
        _ = try requireEnum(revision.kind, EntryKind.self, path: "\(path).kind")
        _ = try requireLocalDay(revision.localDay, path: "\(path).localDay")
        try validateInteger(Int64(revision.minutes), range: 1...5_999, path: "\(path).minutes")
        try requireMutationSource(revision.source, path: "\(path).source")
        try validateDate(revision.entryCreatedAt, path: "\(path).entryCreatedAt", required: true)
        try validateDate(revision.entryUpdatedAt, path: "\(path).entryUpdatedAt", required: true)
        try validateDate(revision.entryDeletedAt, path: "\(path).entryDeletedAt")
        try validateDate(revision.occurredAt, path: "\(path).occurredAt", required: true)
        try validateNote(revision.note, path: "\(path).note")
        return (id, entryID, mutationID)
    }

    private static func validate(policy: HourleafPolicyRevisionV1, path: String) throws -> String {
        let id = try requiredUUID(policy.id, path: "\(path).id")
        _ = try requireMonth(policy.effectiveMonth, path: "\(path).effectiveMonth")
        _ = try requireEnum(policy.mode, RemainderMode.self, path: "\(path).mode")
        try validateDate(policy.createdAt, path: "\(path).createdAt", required: true)
        return id
    }

    private static func validate(preset: HourleafPresetV1, path: String) throws -> String {
        let id = try requiredUUID(preset.id, path: "\(path).id")
        _ = try requireEnum(preset.kind, EntryKind.self, path: "\(path).kind")
        try validateInteger(Int64(preset.minutes), range: 1...5_999, path: "\(path).minutes")
        try validateInteger(Int64(preset.position), range: 0...2, path: "\(path).position")
        try validateDate(preset.createdAt, path: "\(path).createdAt", required: true)
        try validateDate(preset.updatedAt, path: "\(path).updatedAt", required: true)
        try validateDate(preset.deletedAt, path: "\(path).deletedAt")
        return id
    }

    private static func validate(reminder: HourleafReminderV1, path: String) throws -> String {
        let id = try requiredUUID(reminder.id, path: "\(path).id")
        try validateInteger(Int64(reminder.weekday), range: 1...7, path: "\(path).weekday")
        try validateInteger(Int64(reminder.hour), range: 0...23, path: "\(path).hour")
        try validateInteger(Int64(reminder.minute), range: 0...59, path: "\(path).minute")
        try validateDate(reminder.createdAt, path: "\(path).createdAt")
        try validateDate(reminder.updatedAt, path: "\(path).updatedAt")
        return id
    }

    private static func validate(
        bibleStudyCount: HourleafBibleStudyCountV2,
        path: String
    ) throws -> String {
        let month = try requireMonth(bibleStudyCount.monthKey, path: "\(path).monthKey")
        try validateInteger(
            Int64(bibleStudyCount.count),
            range: 1...Int64(MonthlyBibleStudyCount.allowedRange.upperBound),
            path: "\(path).count"
        )
        return month.key
    }

    private static func validate(receipt: HourleafReportReceiptV1, path: String) throws -> String {
        let id = try requiredUUID(receipt.id, path: "\(path).id")
        _ = try requireMonth(receipt.monthKey, path: "\(path).monthKey")
        _ = try requireString(receipt.reportText, maximum: HourleafBackupLimitsV1.maximumReportTextBytes, path: "\(path).reportText")
        try validateDate(receipt.preparedAt, path: "\(path).preparedAt", required: true)
        try validateDate(receipt.confirmedSentAt, path: "\(path).confirmedSentAt")
        guard receipt.schemaVersion >= 1, receipt.version >= 1 else {
            throw HourleafBackupError.invalidRecord("\(path) has an invalid schema or version")
        }
        // `nextReceiptVersion` must add one when a fresh snapshot is saved.
        // Refuse the exhausted raw value here instead of emitting a portable
        // backup which would later make that live arithmetic overflow.
        guard receipt.version < Int32.max else {
            throw HourleafBackupError.invalidRecord("\(path).version is exhausted")
        }
        try validateInteger(
            receipt.rawServiceMinutes,
            range: 0...HourleafBackupLimitsV1.maximumAggregateMinutes,
            path: "\(path).rawServiceMinutes"
        )
        try validateInteger(
            receipt.rawCreditMinutes,
            range: 0...HourleafBackupLimitsV1.maximumAggregateMinutes,
            path: "\(path).rawCreditMinutes"
        )
        try validateInteger(
            Int64(receipt.serviceHours),
            range: 0...HourleafBackupLimitsV1.maximumReportHours,
            path: "\(path).serviceHours"
        )
        try validateInteger(
            Int64(receipt.creditHours),
            range: 0...HourleafBackupLimitsV1.maximumReportHours,
            path: "\(path).creditHours"
        )
        try validateInteger(Int64(receipt.serviceCarryIn), range: 0...59, path: "\(path).serviceCarryIn")
        try validateInteger(Int64(receipt.creditCarryIn), range: 0...59, path: "\(path).creditCarryIn")
        try validateInteger(Int64(receipt.serviceCarryOut), range: 0...59, path: "\(path).serviceCarryOut")
        try validateInteger(Int64(receipt.creditCarryOut), range: 0...59, path: "\(path).creditCarryOut")
        if let supersedesID = receipt.supersedesID {
            _ = try requiredUUID(supersedesID, path: "\(path).supersedesID")
        }
        try validateStructuredString(receipt.reportingMode, path: "\(path).reportingMode")
        try validateStructuredString(receipt.reportLanguage, path: "\(path).reportLanguage")
        try validateString(receipt.creditLabel, path: "\(path).creditLabel")
        try validateStructuredString(receipt.templateID, path: "\(path).templateID")
        try validateStructuredString(receipt.calculationFingerprint, path: "\(path).calculationFingerprint")
        try validateStructuredString(receipt.presentationFingerprint, path: "\(path).presentationFingerprint")
        try validateStructuredString(receipt.createdBySource, path: "\(path).createdBySource")

        if receipt.legacyCalculationUnavailable {
            if let source = receipt.createdBySource {
                _ = try requireNonEmptyString(
                    source,
                    maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes,
                    path: "\(path).createdBySource"
                )
            }
            if let mode = receipt.reportingMode {
                _ = try requireEnum(mode, RemainderMode.self, path: "\(path).reportingMode")
            }
            if let language = receipt.reportLanguage {
                _ = try requireEnum(language, ReportLanguage.self, path: "\(path).reportLanguage")
            }
        } else {
            let mode = try requireEnum(receipt.reportingMode, RemainderMode.self, path: "\(path).reportingMode")
            _ = try requireEnum(receipt.reportLanguage, ReportLanguage.self, path: "\(path).reportLanguage")
            let creditLabel = try requireString(receipt.creditLabel, path: "\(path).creditLabel")
            let templateID = try requireString(receipt.templateID, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: "\(path).templateID")
            let calculationFingerprint = try requireString(receipt.calculationFingerprint, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: "\(path).calculationFingerprint")
            let presentationFingerprint = try requireString(receipt.presentationFingerprint, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: "\(path).presentationFingerprint")
            _ = try requireNonEmptyString(
                receipt.createdBySource,
                maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes,
                path: "\(path).createdBySource"
            )
            guard !templateID.isEmpty, !calculationFingerprint.isEmpty else {
                throw HourleafBackupError.invalidRecord("\(path) has empty current report metadata")
            }
            let report = MonthlyReport(
                month: MonthKey(key: receipt.monthKey!)!,
                rawServiceMinutes: Int(receipt.rawServiceMinutes),
                rawCreditMinutes: Int(receipt.rawCreditMinutes),
                serviceCarryIn: Int(receipt.serviceCarryIn),
                creditCarryIn: Int(receipt.creditCarryIn),
                serviceHours: Int(receipt.serviceHours),
                creditHours: Int(receipt.creditHours),
                serviceCarryOut: Int(receipt.serviceCarryOut),
                creditCarryOut: Int(receipt.creditCarryOut)
            )
            guard
                ReportCalculator.isConsistent(report, mode: mode),
                presentationFingerprint == ReportFingerprint.presentation(
                    calculationFingerprint: calculationFingerprint,
                    language: ReportLanguage(rawValue: receipt.reportLanguage!)!,
                    creditLabel: creditLabel,
                    templateID: templateID,
                    text: receipt.reportText!
                )
            else {
                throw HourleafBackupError.invalidRecord("\(path) report metadata does not match its raw values")
            }
        }
        return id
    }

    private static func validate(state: HourleafReportStateV1, path: String) throws -> String {
        let id = try requiredUUID(state.id, path: "\(path).id")
        _ = try requireMonth(state.monthKey, path: "\(path).monthKey")
        let stateValue = try requireReportState(state.state, path: "\(path).state")
        if let stable = state.lastStableState {
            _ = try requireReportState(stable, path: "\(path).lastStableState")
        }
        if let snapshotID = state.currentSnapshotID {
            _ = try requiredUUID(snapshotID, path: "\(path).currentSnapshotID")
        }
        try validateStructuredString(state.reviewedCalculationFingerprint, path: "\(path).reviewedCalculationFingerprint")
        try validateStructuredString(state.reviewedPresentationFingerprint, path: "\(path).reviewedPresentationFingerprint")
        try validateDate(state.updatedAt, path: "\(path).updatedAt", required: true)
        try validateDate(state.changedAt, path: "\(path).changedAt")
        guard !stateValue.isEmpty else {
            throw HourleafBackupError.invalidRecord("\(path).state is empty")
        }
        return id
    }

    private static func validate(archive: HourleafServiceYearArchiveV1, path: String) throws -> String {
        let id = try requiredUUID(archive.id, path: "\(path).id")
        let start = try requireMonth(archive.startMonthKey, path: "\(path).startMonthKey")
        let end = try requireMonth(archive.endMonthKey, path: "\(path).endMonthKey")
        guard end >= start else {
            throw HourleafBackupError.invalidRecord("\(path) ends before it starts")
        }
        try validateInteger(
            archive.actualServiceMinutes,
            range: 0...HourleafBackupLimitsV1.maximumArchiveActualMinutes,
            path: "\(path).actualServiceMinutes"
        )
        try validateInteger(
            archive.baselineServiceMinutes,
            range: 0...HourleafBackupLimitsV1.maximumBaselineMinutes,
            path: "\(path).baselineServiceMinutes"
        )
        try validateInteger(
            archive.targetMinutes,
            range: 1...HourleafBackupLimitsV1.maximumServiceYearTargetMinutes,
            path: "\(path).targetMinutes"
        )
        guard archive.version >= 1 else {
            throw HourleafBackupError.invalidRecord("\(path).version must be positive")
        }
        let fingerprint = try requireString(
            archive.calculationFingerprint,
            maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes,
            path: "\(path).calculationFingerprint"
        )
        guard !fingerprint.isEmpty else {
            throw HourleafBackupError.invalidRecord("\(path).calculationFingerprint is empty")
        }
        if let supersedesID = archive.supersedesID {
            _ = try requiredUUID(supersedesID, path: "\(path).supersedesID")
        }
        try validateDate(archive.createdAt, path: "\(path).createdAt", required: true)
        return id
    }

    private static func validate(acknowledgement: HourleafDayAcknowledgementV1, path: String) throws -> String {
        let id = try requiredUUID(acknowledgement.id, path: "\(path).id")
        _ = try requireLocalDay(acknowledgement.localDay, path: "\(path).localDay")
        let status = try requireString(
            acknowledgement.status,
            maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes,
            path: "\(path).status"
        )
        guard status == "nothingToday" else {
            throw HourleafBackupError.invalidRecord("\(path).status is unsupported")
        }
        _ = try requireNonEmptyString(
            acknowledgement.source,
            maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes,
            path: "\(path).source"
        )
        try validateDate(acknowledgement.createdAt, path: "\(path).createdAt", required: true)
        try validateDate(acknowledgement.updatedAt, path: "\(path).updatedAt", required: true)
        return id
    }

    private static func validate(settings: HourleafSettingsV1, path: String) throws -> String {
        let id = try requiredUUID(settings.id, path: "\(path).id")
        // This is raw storage metadata, not the portable format version.
        // Repository normalization may advance it while Backup V1 remains
        // structurally compatible, so preserve any positive revision.
        guard settings.dataRevision > 0 else {
            throw HourleafBackupError.invalidRecord("\(path).dataRevision must be positive")
        }
        _ = try requireEnum(settings.reportLanguage, ReportLanguage.self, path: "\(path).reportLanguage")
        _ = try requireString(settings.creditLabelEnglish, path: "\(path).creditLabelEnglish")
        _ = try requireString(settings.creditLabelRussian, path: "\(path).creditLabelRussian")
        _ = try requireString(settings.creditLabelUkrainian, path: "\(path).creditLabelUkrainian")
        _ = try requireMonth(settings.ledgerStartMonth, path: "\(path).ledgerStartMonth")
        _ = try requireMonth(settings.baselineServiceYearStart, path: "\(path).baselineServiceYearStart")
        try validateInteger(
            settings.baselineServiceYearMinutes,
            range: 0...HourleafBackupLimitsV1.maximumBaselineMinutes,
            path: "\(path).baselineServiceYearMinutes"
        )
        try validateInteger(Int64(settings.openingServiceCarryMinutes), range: 0...59, path: "\(path).openingServiceCarryMinutes")
        try validateInteger(Int64(settings.openingCreditCarryMinutes), range: 0...59, path: "\(path).openingCreditCarryMinutes")
        guard settings.quietGapDays >= 0 else {
            throw HourleafBackupError.invalidRecord("\(path).quietGapDays is negative")
        }
        try validateString(settings.syncMode, path: "\(path).syncMode")
        try validateString(settings.widgetPrivacyMode, path: "\(path).widgetPrivacyMode")
        try validateDate(settings.lastPurgeAt, path: "\(path).lastPurgeAt")
        try validateDate(settings.updatedAt, path: "\(path).updatedAt")
        return id
    }

    /// Returns the receipt selected by the live repository's `receiptOrder`
    /// for each month. Versions are intentionally separate from that ordering:
    /// a repaired/imported timestamp may sort differently, but it must not
    /// leave a stale report-state pointer behind.
    private static func validateReceiptSeries(
        _ receiptsByMonth: [String: [HourleafReportReceiptV1]]
    ) throws -> [String: String] {
        var newestIDs = [String: String]()

        for (month, receipts) in receiptsByMonth {
            let ordered = receipts.sorted { lhs, rhs in
                (lhs.version, lhs.id ?? "") < (rhs.version, rhs.id ?? "")
            }
            try validateVersionSeries(
                ordered,
                seriesDescription: "receipt month \(month)",
                id: \.id,
                version: \.version,
                supersedesID: \.supersedesID
            )

            guard let newest = receipts.max(by: receiptOrder), let newestID = newest.id else {
                throw HourleafBackupError.invalidGraph("receipt month \(month) has no newest receipt")
            }
            newestIDs[month] = newestID
        }
        return newestIDs
    }

    private static func validateArchiveSeries(
        _ archivesBySeries: [String: [HourleafServiceYearArchiveV1]]
    ) throws {
        for (series, archives) in archivesBySeries {
            let ordered = archives.sorted { lhs, rhs in
                (lhs.version, lhs.id ?? "") < (rhs.version, rhs.id ?? "")
            }
            try validateVersionSeries(
                ordered,
                seriesDescription: "archive series \(series)",
                id: \.id,
                version: \.version,
                supersedesID: \.supersedesID
            )
        }
    }

    /// Existing installed ledgers can contain a fully legacy all-nil
    /// supersedes column. Preserve that valid history. Once a series records
    /// any edge, all later versions must form the exact immediate chain, which
    /// rejects forked, skipped, cross-series, and cyclic histories in O(n).
    private static func validateVersionSeries<Record>(
        _ ordered: [Record],
        seriesDescription: String,
        id: (Record) -> String?,
        version: (Record) -> Int32,
        supersedesID: (Record) -> String?
    ) throws {
        var priorID: String?
        let hasSupersedesEdges = ordered.contains { supersedesID($0) != nil }

        for (offset, record) in ordered.enumerated() {
            let expected = Int32(offset + 1)
            guard version(record) == expected else {
                throw HourleafBackupError.invalidGraph("\(seriesDescription) versions are not contiguous")
            }

            if hasSupersedesEdges {
                guard supersedesID(record) == priorID else {
                    throw HourleafBackupError.invalidGraph(
                        "\(seriesDescription) does not supersede its immediate prior version"
                    )
                }
            }
            priorID = id(record)
        }
    }

    private static func receiptOrder(
        _ lhs: HourleafReportReceiptV1,
        _ rhs: HourleafReportReceiptV1
    ) -> Bool {
        let lhsKey = (lhs.preparedAt ?? -Double.greatestFiniteMagnitude, lhs.id ?? "")
        let rhsKey = (rhs.preparedAt ?? -Double.greatestFiniteMagnitude, rhs.id ?? "")
        return lhsKey < rhsKey
    }

    private static func requiredUUID(_ value: String?, path: String) throws -> String {
        guard
            let value,
            value.utf8.count <= HourleafBackupLimitsV1.maximumStructuredStringBytes,
            let uuid = UUID(uuidString: value),
            uuid.uuidString.lowercased() == value
        else {
            throw HourleafBackupError.invalidRecord("\(path) is not a lowercase UUID")
        }
        return value
    }

    private static func requireLocalDay(_ value: String?, path: String) throws -> LocalDay {
        let value = try requireString(value, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: path)
        guard let day = LocalDay(key: value) else {
            throw HourleafBackupError.invalidRecord("\(path) is not a valid local day")
        }
        return day
    }

    private static func requireMonth(_ value: String?, path: String) throws -> MonthKey {
        let value = try requireString(value, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: path)
        guard let month = MonthKey(key: value) else {
            throw HourleafBackupError.invalidRecord("\(path) is not a valid month")
        }
        return month
    }

    private static func requireMutationSource(_ value: String?, path: String) throws {
        _ = try requireEnum(value, EntryMutationSource.self, path: path)
    }

    private static func requireReportState(_ value: String?, path: String) throws -> String {
        let value = try requireString(value, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: path)
        guard ["draft", "ready", "reviewed", "prepared", "sent", "changed"].contains(value) else {
            throw HourleafBackupError.invalidRecord("\(path) is not a supported report state")
        }
        return value
    }

    private static func requireEnum<Value: RawRepresentable>(
        _ value: String?,
        _ type: Value.Type,
        path: String
    ) throws -> Value where Value.RawValue == String {
        let value = try requireString(value, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: path)
        guard let result = Value(rawValue: value) else {
            throw HourleafBackupError.invalidRecord("\(path) has an unsupported value")
        }
        return result
    }

    private static func requireString(
        _ value: String?,
        maximum: Int = HourleafBackupLimitsV1.maximumStringBytes,
        path: String
    ) throws -> String {
        guard let value else {
            throw HourleafBackupError.invalidRecord("\(path) is missing")
        }
        try validateString(value, maximum: maximum, path: path)
        return value
    }

    private static func requireNonEmptyString(
        _ value: String?,
        maximum: Int = HourleafBackupLimitsV1.maximumStringBytes,
        path: String
    ) throws -> String {
        let value = try requireString(value, maximum: maximum, path: path)
        guard !value.isEmpty else {
            throw HourleafBackupError.invalidRecord("\(path) is empty")
        }
        return value
    }

    private static func validateString(
        _ value: String?,
        maximum: Int = HourleafBackupLimitsV1.maximumStringBytes,
        path: String
    ) throws {
        guard let value else { return }
        guard value.utf8.count <= maximum else {
            throw HourleafBackupError.invalidRecord("\(path) exceeds \(maximum) UTF-8 bytes")
        }
    }

    private static func validateStructuredString(_ value: String?, path: String) throws {
        try validateString(value, maximum: HourleafBackupLimitsV1.maximumStructuredStringBytes, path: path)
    }

    private static func validateNote(_ value: String?, path: String) throws {
        guard let value else { return }
        guard
            value.count <= HourleafBackupLimitsV1.maximumNoteCharacters,
            value.utf8.count <= HourleafBackupLimitsV1.maximumNoteBytes
        else {
            throw HourleafBackupError.invalidRecord("\(path) exceeds the note limit")
        }
    }

    private static func validateDate(_ value: Double?, path: String, required: Bool = false) throws {
        guard let value else {
            if required {
                throw HourleafBackupError.invalidRecord("\(path) is missing")
            }
            return
        }
        guard value.isFinite else {
            throw HourleafBackupError.invalidRecord("\(path) is not finite")
        }
    }

    private static func validateDate(_ value: Double, path: String) throws {
        guard value.isFinite else {
            throw HourleafBackupError.invalidRecord("\(path) is not finite")
        }
    }

    private static func validateInteger(_ value: Int64, range: ClosedRange<Int64>, path: String) throws {
        guard range.contains(value) else {
            throw HourleafBackupError.invalidRecord("\(path) is out of range")
        }
    }
}
