import Foundation

/// The stable identifiers for the first portable Hourleaf backup format.
enum HourleafBackupV1 {
    static let format = "com.kikuai.hourleaf.backup"
    static let version = 1
    static let checksumAlgorithm = "sha256"
}

/// Encodes optionals as an explicit JSON `null` and requires their key on
/// decode. Core Data attributes are optional at the storage boundary, so an
/// omitted key would otherwise be indistinguishable from a stored nil.
@propertyWrapper
struct HourleafBackupOptional<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

struct HourleafBackupEnvelopeV1: Codable, Equatable, Sendable {
    var content: HourleafBackupContentV1
    var checksum: HourleafBackupChecksumV1
}

struct HourleafBackupContentV1: Codable, Equatable, Sendable {
    var format: String
    var version: Int
    var exportedAt: Double
    var records: HourleafBackupRecordsV1

    init(
        format: String = HourleafBackupV1.format,
        version: Int = HourleafBackupV1.version,
        exportedAt: Double,
        records: HourleafBackupRecordsV1
    ) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.records = records
    }
}

struct HourleafBackupChecksumV1: Codable, Equatable, Sendable {
    var algorithm: String
    var value: String

    init(algorithm: String = HourleafBackupV1.checksumAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

/// Raw Core Data storage values. This is deliberately not `LedgerSnapshot`:
/// normalization/defaulting would lose whether an optional was actually nil.
struct HourleafBackupRecordsV1: Codable, Equatable, Sendable {
    var acknowledgements: [HourleafDayAcknowledgementV1]
    var archives: [HourleafServiceYearArchiveV1]
    var entries: [HourleafEntryV1]
    var policies: [HourleafPolicyRevisionV1]
    var presets: [HourleafPresetV1]
    var receipts: [HourleafReportReceiptV1]
    var reminders: [HourleafReminderV1]
    var revisions: [HourleafEntryRevisionV1]
    var settings: HourleafSettingsV1
    var states: [HourleafReportStateV1]

    var counts: HourleafBackupRecordCountsV1 {
        HourleafBackupRecordCountsV1(
            acknowledgements: acknowledgements.count,
            archives: archives.count,
            entries: entries.count,
            policies: policies.count,
            presets: presets.count,
            receipts: receipts.count,
            reminders: reminders.count,
            revisions: revisions.count,
            states: states.count
        )
    }
}

struct HourleafBackupRecordCountsV1: Equatable, Sendable {
    let acknowledgements: Int
    let archives: Int
    let entries: Int
    let policies: Int
    let presets: Int
    let receipts: Int
    let reminders: Int
    let revisions: Int
    let states: Int

    var total: Int {
        acknowledgements + archives + entries + policies + presets + receipts + reminders + revisions + states + 1
    }
}

// MARK: - Raw entity DTOs

struct HourleafDayAcknowledgementV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var createdAt: Double?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var localDay: String?
    @HourleafBackupOptional var source: String?
    @HourleafBackupOptional var status: String?
    @HourleafBackupOptional var updatedAt: Double?
}

struct HourleafEntryV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var createdAt: Double?
    @HourleafBackupOptional var deletedAt: Double?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var kind: String?
    @HourleafBackupOptional var lastMutationID: String?
    @HourleafBackupOptional var localDay: String?
    var minutes: Int32
    @HourleafBackupOptional var note: String?
    var revision: Int64
    @HourleafBackupOptional var source: String?
    @HourleafBackupOptional var updatedAt: Double?
}

struct HourleafEntryRevisionV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var entryCreatedAt: Double?
    @HourleafBackupOptional var entryDeletedAt: Double?
    @HourleafBackupOptional var entryID: String?
    @HourleafBackupOptional var entryUpdatedAt: Double?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var kind: String?
    @HourleafBackupOptional var localDay: String?
    var minutes: Int32
    @HourleafBackupOptional var mutationID: String?
    @HourleafBackupOptional var note: String?
    @HourleafBackupOptional var occurredAt: Double?
    @HourleafBackupOptional var operation: String?
    @HourleafBackupOptional var parentMutationID: String?
    @HourleafBackupOptional var revertedMutationID: String?
    var revision: Int64
    @HourleafBackupOptional var source: String?
}

struct HourleafPolicyRevisionV1: Codable, Equatable, Sendable {
    var carryAcrossServiceYear: Bool
    @HourleafBackupOptional var createdAt: Double?
    @HourleafBackupOptional var effectiveMonth: String?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var mode: String?
}

struct HourleafPresetV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var createdAt: Double?
    @HourleafBackupOptional var deletedAt: Double?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var kind: String?
    var minutes: Int32
    var position: Int16
    @HourleafBackupOptional var updatedAt: Double?
}

struct HourleafReminderV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var createdAt: Double?
    var hour: Int16
    @HourleafBackupOptional var id: String?
    var isEnabled: Bool
    var minute: Int16
    @HourleafBackupOptional var updatedAt: Double?
    var weekday: Int16
}

struct HourleafReportReceiptV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var calculationFingerprint: String?
    @HourleafBackupOptional var confirmedSentAt: Double?
    @HourleafBackupOptional var createdBySource: String?
    var creditCarryIn: Int32
    var creditCarryOut: Int32
    var creditHours: Int32
    @HourleafBackupOptional var creditLabel: String?
    @HourleafBackupOptional var id: String?
    var legacyCalculationUnavailable: Bool
    @HourleafBackupOptional var monthKey: String?
    @HourleafBackupOptional var presentationFingerprint: String?
    @HourleafBackupOptional var preparedAt: Double?
    var rawCreditMinutes: Int64
    var rawServiceMinutes: Int64
    @HourleafBackupOptional var reportLanguage: String?
    @HourleafBackupOptional var reportText: String?
    @HourleafBackupOptional var reportingMode: String?
    var schemaVersion: Int16
    var serviceCarryIn: Int32
    var serviceCarryOut: Int32
    var serviceHours: Int32
    @HourleafBackupOptional var supersedesID: String?
    @HourleafBackupOptional var templateID: String?
    var version: Int32
}

struct HourleafReportStateV1: Codable, Equatable, Sendable {
    @HourleafBackupOptional var changedAt: Double?
    @HourleafBackupOptional var currentSnapshotID: String?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var lastStableState: String?
    @HourleafBackupOptional var monthKey: String?
    @HourleafBackupOptional var reviewedCalculationFingerprint: String?
    @HourleafBackupOptional var reviewedPresentationFingerprint: String?
    @HourleafBackupOptional var state: String?
    @HourleafBackupOptional var updatedAt: Double?
}

struct HourleafServiceYearArchiveV1: Codable, Equatable, Sendable {
    var actualServiceMinutes: Int64
    var baselineServiceMinutes: Int64
    @HourleafBackupOptional var calculationFingerprint: String?
    @HourleafBackupOptional var createdAt: Double?
    @HourleafBackupOptional var endMonthKey: String?
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var startMonthKey: String?
    @HourleafBackupOptional var supersedesID: String?
    var targetMinutes: Int64
    var version: Int32
}

struct HourleafSettingsV1: Codable, Equatable, Sendable {
    var baselineServiceYearMinutes: Int64
    @HourleafBackupOptional var baselineServiceYearStart: String?
    @HourleafBackupOptional var creditLabelEnglish: String?
    @HourleafBackupOptional var creditLabelRussian: String?
    @HourleafBackupOptional var creditLabelUkrainian: String?
    var dataRevision: Int16
    @HourleafBackupOptional var id: String?
    @HourleafBackupOptional var lastPurgeAt: Double?
    @HourleafBackupOptional var ledgerStartMonth: String?
    var onboardingComplete: Bool
    var openingCreditCarryMinutes: Int32
    var openingServiceCarryMinutes: Int32
    var planningVisible: Bool
    var quietGapCheckEnabled: Bool
    var quietGapDays: Int16
    @HourleafBackupOptional var reportLanguage: String?
    @HourleafBackupOptional var syncMode: String?
    var timerVisible: Bool
    @HourleafBackupOptional var updatedAt: Double?
    @HourleafBackupOptional var widgetPrivacyMode: String?
}
