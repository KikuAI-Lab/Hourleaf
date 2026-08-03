import CryptoKit
import Darwin
import Foundation

/// Restore-local optional encoding. Unlike a synthesized `Optional`, this
/// wrapper makes a missing key invalid and always writes an explicit JSON
/// `null` for a nil value.
@propertyWrapper
struct RestoreJournalOptional<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
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

enum RestoreJournalV1 {
    static let format = "com.kikuai.hourleaf.restore-journal"
    static let armedFormat = "com.kikuai.hourleaf.restore-armed"
    static let version = 1
    static let checksumAlgorithm = "sha256"

    static let recoveryDirectoryName = "RestoreRecovery"
    static let artifactDirectoryName = "RestoreRecoveryArtifacts"
    static let activeDirectoryName = "active"
    static let journalBasename = "journal-v1.json"
    static let armedBasename = "armed-v1.json"
    static let candidateBackupBasename = "candidate.hourleafbackup"
    static let candidateStoreBasename = "candidate.sqlite"
    static let physicalAStoreBasename = "physical-a.sqlite"
    static let rollbackAStoreBasename = "rollback-a.sqlite"

    static let requiredProtectionClass = FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    static let maximumJournalBytes = 64 * 1_024
    static let maximumMarkerBytes = 16 * 1_024
}

enum RestoreJournalPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case prepared
    case maintenanceAcquired
    case preRestoreBackupVerified
    case oldStoreCopyStarted
    case oldStoreCopyVerified
    case replacementStarted
    case replacementReturned
    case newStoreVerifiedRemindersPending
    case rollbackStarted
    case oldStoreVerifiedRemindersPending
    case critical
}

/// The only post-restart facts that may terminalize a transaction. `a` and
/// `b` deliberately carry the independently revalidated logical evidence;
/// `unstarted` is allowed only before any maintenance mutation can begin.
enum RestoreTerminalTargetV1: String, Codable, Equatable, Sendable {
    case unstarted
    case a
    case b
}

/// A caller cannot terminalize from a transaction ID alone. It must bind the
/// selected live ledger to the durable source phase and exact logical evidence
/// that the journal already committed.
struct RestoreTerminalDecisionV1: Equatable, Sendable {
    let transactionID: UUID
    let sourcePhase: RestoreJournalPhase
    let target: RestoreTerminalTargetV1
    let recordsDigest: String?
    let recordCounts: RestoreRecordCountsV1?

    init(
        transactionID: UUID,
        sourcePhase: RestoreJournalPhase,
        target: RestoreTerminalTargetV1,
        recordsDigest: String? = nil,
        recordCounts: RestoreRecordCountsV1? = nil
    ) {
        self.transactionID = transactionID
        self.sourcePhase = sourcePhase
        self.target = target
        self.recordsDigest = recordsDigest
        self.recordCounts = recordCounts
    }
}

/// Typed names are deliberately not arbitrary URLs. They represent only the
/// two exporter publication states that can be observed before portable A is
/// bound into the journal.
enum RestoreProvisionalPortableAArtifactNameV1: Equatable, Sendable {
    case final(String)
    case partial(String)

    var basename: String {
        switch self {
        case let .final(basename), let .partial(basename): basename
        }
    }
}

enum RestoreProvisionalPortableAArtifactsV1: Equatable, Sendable {
    case none
    case single(RestoreProvisionalPortableAArtifactNameV1)
    case publishedPair(
        final: RestoreProvisionalPortableAArtifactNameV1,
        partial: RestoreProvisionalPortableAArtifactNameV1
    )
}

/// Record counts are duplicated in the journal instead of serializing a
/// backup DTO. That keeps the journal wire stable if the backup's storage DTO
/// grows in a later format.
struct RestoreRecordCountsV1: Codable, Equatable, Sendable {
    var acknowledgements: Int
    var archives: Int
    var entries: Int
    var policies: Int
    var presets: Int
    var receipts: Int
    var reminders: Int
    var revisions: Int
    var states: Int

    init(
        acknowledgements: Int,
        archives: Int,
        entries: Int,
        policies: Int,
        presets: Int,
        receipts: Int,
        reminders: Int,
        revisions: Int,
        states: Int
    ) {
        self.acknowledgements = acknowledgements
        self.archives = archives
        self.entries = entries
        self.policies = policies
        self.presets = presets
        self.receipts = receipts
        self.reminders = reminders
        self.revisions = revisions
        self.states = states
    }

    init(_ backupCounts: HourleafBackupRecordCountsV1) {
        self.init(
            acknowledgements: backupCounts.acknowledgements,
            archives: backupCounts.archives,
            entries: backupCounts.entries,
            policies: backupCounts.policies,
            presets: backupCounts.presets,
            receipts: backupCounts.receipts,
            reminders: backupCounts.reminders,
            revisions: backupCounts.revisions,
            states: backupCounts.states
        )
    }

    var backupCounts: HourleafBackupRecordCountsV1 {
        HourleafBackupRecordCountsV1(
            acknowledgements: acknowledgements,
            archives: archives,
            entries: entries,
            policies: policies,
            presets: presets,
            receipts: receipts,
            reminders: reminders,
            revisions: revisions,
            states: states
        )
    }
}

struct RestoreJournalIntegrityV1: Codable, Equatable, Sendable {
    var algorithm: String
    var value: String

    init(algorithm: String = RestoreJournalV1.checksumAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = value
    }
}

struct RestoreJournalEnvelopeV1: Codable, Equatable, Sendable {
    var content: RestoreJournalContentV1
    var checksum: RestoreJournalIntegrityV1
}

struct RestoreArmedEnvelopeV1: Codable, Equatable, Sendable {
    var content: RestoreArmedContentV1
    var checksum: RestoreJournalIntegrityV1
}

struct RestoreJournalContentV1: Codable, Equatable, Sendable {
    var format: String
    var version: Int
    var transactionID: String
    var transactionNonce: String
    var sequence: Int64
    var phase: RestoreJournalPhase
    var createdAtMilliseconds: Int64
    var updatedAtMilliseconds: Int64
    var candidateBackupBasename: String
    var candidateStoreBasename: String
    var physicalAStoreBasename: String
    var rollbackAStoreBasename: String
    var candidateBackupByteCount: Int
    var candidateBackupChecksum: String
    var candidateRecordsDigest: String
    var candidateRecordCounts: RestoreRecordCountsV1
    @RestoreJournalOptional var aRecordsDigest: String?
    @RestoreJournalOptional var aRecordCounts: RestoreRecordCountsV1?
    @RestoreJournalOptional var portableABasename: String?
    @RestoreJournalOptional var portableAByteCount: Int?
    @RestoreJournalOptional var portableAChecksum: String?
    @RestoreJournalOptional var portableARecordsDigest: String?
    @RestoreJournalOptional var physicalAStoreUUID: String?
    @RestoreJournalOptional var physicalARecordsDigest: String?
    @RestoreJournalOptional var criticalFromPhase: RestoreJournalPhase?
    @RestoreJournalOptional var criticalReasonCode: String?

    init(
        format: String = RestoreJournalV1.format,
        version: Int = RestoreJournalV1.version,
        transactionID: String,
        transactionNonce: String,
        sequence: Int64 = 0,
        phase: RestoreJournalPhase = .prepared,
        createdAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64? = nil,
        candidateBackupBasename: String = RestoreJournalV1.candidateBackupBasename,
        candidateStoreBasename: String = RestoreJournalV1.candidateStoreBasename,
        physicalAStoreBasename: String = RestoreJournalV1.physicalAStoreBasename,
        rollbackAStoreBasename: String = RestoreJournalV1.rollbackAStoreBasename,
        candidateBackupByteCount: Int,
        candidateBackupChecksum: String,
        candidateRecordsDigest: String,
        candidateRecordCounts: RestoreRecordCountsV1,
        aRecordsDigest: String? = nil,
        aRecordCounts: RestoreRecordCountsV1? = nil,
        portableABasename: String? = nil,
        portableAByteCount: Int? = nil,
        portableAChecksum: String? = nil,
        portableARecordsDigest: String? = nil,
        physicalAStoreUUID: String? = nil,
        physicalARecordsDigest: String? = nil,
        criticalFromPhase: RestoreJournalPhase? = nil,
        criticalReasonCode: String? = nil
    ) {
        self.format = format
        self.version = version
        self.transactionID = transactionID
        self.transactionNonce = transactionNonce
        self.sequence = sequence
        self.phase = phase
        self.createdAtMilliseconds = createdAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds ?? createdAtMilliseconds
        self.candidateBackupBasename = candidateBackupBasename
        self.candidateStoreBasename = candidateStoreBasename
        self.physicalAStoreBasename = physicalAStoreBasename
        self.rollbackAStoreBasename = rollbackAStoreBasename
        self.candidateBackupByteCount = candidateBackupByteCount
        self.candidateBackupChecksum = candidateBackupChecksum
        self.candidateRecordsDigest = candidateRecordsDigest
        self.candidateRecordCounts = candidateRecordCounts
        _aRecordsDigest = RestoreJournalOptional(wrappedValue: aRecordsDigest)
        _aRecordCounts = RestoreJournalOptional(wrappedValue: aRecordCounts)
        _portableABasename = RestoreJournalOptional(wrappedValue: portableABasename)
        _portableAByteCount = RestoreJournalOptional(wrappedValue: portableAByteCount)
        _portableAChecksum = RestoreJournalOptional(wrappedValue: portableAChecksum)
        _portableARecordsDigest = RestoreJournalOptional(wrappedValue: portableARecordsDigest)
        _physicalAStoreUUID = RestoreJournalOptional(wrappedValue: physicalAStoreUUID)
        _physicalARecordsDigest = RestoreJournalOptional(wrappedValue: physicalARecordsDigest)
        _criticalFromPhase = RestoreJournalOptional(wrappedValue: criticalFromPhase)
        _criticalReasonCode = RestoreJournalOptional(wrappedValue: criticalReasonCode)
    }
}

struct RestoreArmedContentV1: Codable, Equatable, Sendable {
    var format: String
    var version: Int
    var transactionID: String
    var transactionNonce: String
    var journalBasename: String
    var journalIdentityDigest: String
    var createdAtMilliseconds: Int64

    init(
        format: String = RestoreJournalV1.armedFormat,
        version: Int = RestoreJournalV1.version,
        transactionID: String,
        transactionNonce: String,
        journalBasename: String = RestoreJournalV1.journalBasename,
        journalIdentityDigest: String,
        createdAtMilliseconds: Int64
    ) {
        self.format = format
        self.version = version
        self.transactionID = transactionID
        self.transactionNonce = transactionNonce
        self.journalBasename = journalBasename
        self.journalIdentityDigest = journalIdentityDigest
        self.createdAtMilliseconds = createdAtMilliseconds
    }
}

struct VerifiedRestoreJournalV1: Equatable, Sendable {
    let data: Data
    let content: RestoreJournalContentV1
    let checksum: RestoreJournalIntegrityV1
    let identityDigest: String

    var byteCount: Int { data.count }
}

struct VerifiedRestoreArmedMarkerV1: Equatable, Sendable {
    let data: Data
    let content: RestoreArmedContentV1
    let checksum: RestoreJournalIntegrityV1

    var byteCount: Int { data.count }
}

enum RestoreJournalError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(actual: Int, limit: Int)
    case invalidJSON
    case nonCanonicalJSON
    case wrongFormat(String)
    case unsupportedVersion(Int)
    case unsupportedChecksumAlgorithm(String)
    case checksumMismatch
    case invalidContent(String)
    case invalidMarker(String)
    case invalidBasename(String)
    case invalidTransition
    case invalidTerminalDecision
    case activeTransactionExists
    case transactionUnavailable
    case protectionMismatch
    case applicationSupportUnavailable
    case fileSystem(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge:
            "Hourleaf recovery metadata is too large."
        case .invalidJSON:
            "Hourleaf recovery metadata is not valid JSON."
        case .nonCanonicalJSON:
            "Hourleaf recovery metadata is not canonical."
        case .wrongFormat:
            "Hourleaf recovery metadata has an unexpected format."
        case .unsupportedVersion:
            "Hourleaf recovery metadata has an unsupported version."
        case .unsupportedChecksumAlgorithm:
            "Hourleaf recovery metadata has an unsupported checksum."
        case .checksumMismatch:
            "Hourleaf recovery metadata did not verify."
        case .invalidContent, .invalidMarker, .invalidBasename, .invalidTransition,
             .invalidTerminalDecision:
            "Hourleaf recovery metadata is invalid."
        case .activeTransactionExists:
            "Hourleaf already has a restore transaction to recover."
        case .transactionUnavailable:
            "Hourleaf could not find a trusted restore transaction."
        case .protectionMismatch:
            "Hourleaf recovery metadata does not have the required protection."
        case .applicationSupportUnavailable:
            "Hourleaf could not resolve Application Support for recovery metadata."
        case .fileSystem:
            "Hourleaf could not durably write recovery metadata."
        }
    }
}

enum RestoreJournalCodecV1 {
    static func encode(content: RestoreJournalContentV1) throws -> VerifiedRestoreJournalV1 {
        try validate(content: content)
        let contentData = try canonicalData(content)
        let checksum = RestoreJournalIntegrityV1(value: sha256(contentData))
        let envelope = RestoreJournalEnvelopeV1(content: content, checksum: checksum)
        let data = try canonicalData(envelope)
        guard data.count <= RestoreJournalV1.maximumJournalBytes else {
            throw RestoreJournalError.fileTooLarge(
                actual: data.count,
                limit: RestoreJournalV1.maximumJournalBytes
            )
        }
        return VerifiedRestoreJournalV1(
            data: data,
            content: content,
            checksum: checksum,
            identityDigest: try journalIdentityDigest(content)
        )
    }

    static func decodeAndVerify(_ data: Data) throws -> VerifiedRestoreJournalV1 {
        guard data.count <= RestoreJournalV1.maximumJournalBytes else {
            throw RestoreJournalError.fileTooLarge(
                actual: data.count,
                limit: RestoreJournalV1.maximumJournalBytes
            )
        }
        let envelope: RestoreJournalEnvelopeV1
        do {
            envelope = try JSONDecoder().decode(RestoreJournalEnvelopeV1.self, from: data)
        } catch {
            throw RestoreJournalError.invalidJSON
        }
        try validate(content: envelope.content)
        try validate(checksum: envelope.checksum)
        let contentData = try canonicalData(envelope.content)
        guard sha256(contentData) == envelope.checksum.value else {
            throw RestoreJournalError.checksumMismatch
        }
        guard try canonicalData(envelope) == data else {
            throw RestoreJournalError.nonCanonicalJSON
        }
        return VerifiedRestoreJournalV1(
            data: data,
            content: envelope.content,
            checksum: envelope.checksum,
            identityDigest: try journalIdentityDigest(envelope.content)
        )
    }

    static func encode(marker: RestoreArmedContentV1) throws -> VerifiedRestoreArmedMarkerV1 {
        try validate(marker: marker)
        let contentData = try canonicalData(marker)
        let checksum = RestoreJournalIntegrityV1(value: sha256(contentData))
        let envelope = RestoreArmedEnvelopeV1(content: marker, checksum: checksum)
        let data = try canonicalData(envelope)
        guard data.count <= RestoreJournalV1.maximumMarkerBytes else {
            throw RestoreJournalError.fileTooLarge(
                actual: data.count,
                limit: RestoreJournalV1.maximumMarkerBytes
            )
        }
        return VerifiedRestoreArmedMarkerV1(data: data, content: marker, checksum: checksum)
    }

    static func decodeAndVerifyMarker(_ data: Data) throws -> VerifiedRestoreArmedMarkerV1 {
        guard data.count <= RestoreJournalV1.maximumMarkerBytes else {
            throw RestoreJournalError.fileTooLarge(
                actual: data.count,
                limit: RestoreJournalV1.maximumMarkerBytes
            )
        }
        let envelope: RestoreArmedEnvelopeV1
        do {
            envelope = try JSONDecoder().decode(RestoreArmedEnvelopeV1.self, from: data)
        } catch {
            throw RestoreJournalError.invalidJSON
        }
        try validate(marker: envelope.content)
        try validate(checksum: envelope.checksum)
        let contentData = try canonicalData(envelope.content)
        guard sha256(contentData) == envelope.checksum.value else {
            throw RestoreJournalError.checksumMismatch
        }
        guard try canonicalData(envelope) == data else {
            throw RestoreJournalError.nonCanonicalJSON
        }
        return VerifiedRestoreArmedMarkerV1(
            data: data,
            content: envelope.content,
            checksum: envelope.checksum
        )
    }

    static func marker(for journal: RestoreJournalContentV1) throws -> RestoreArmedContentV1 {
        try validate(content: journal)
        return RestoreArmedContentV1(
            transactionID: journal.transactionID,
            transactionNonce: journal.transactionNonce,
            journalIdentityDigest: try journalIdentityDigest(journal),
            createdAtMilliseconds: journal.createdAtMilliseconds
        )
    }

    static func journalIdentityDigest(_ content: RestoreJournalContentV1) throws -> String {
        try validateImmutableIdentity(content)
        return sha256(try canonicalData(RestoreJournalIdentityV1(content)))
    }

    static func canTransition(
        from current: RestoreJournalPhase,
        to next: RestoreJournalPhase
    ) -> Bool {
        switch (current, next) {
        case (.prepared, .maintenanceAcquired),
             (.maintenanceAcquired, .preRestoreBackupVerified),
             (.preRestoreBackupVerified, .oldStoreCopyStarted),
             (.oldStoreCopyStarted, .oldStoreCopyVerified),
             (.oldStoreCopyVerified, .replacementStarted),
             (.replacementStarted, .replacementReturned),
             (.replacementReturned, .newStoreVerifiedRemindersPending),
             (.replacementStarted, .rollbackStarted),
             (.replacementReturned, .rollbackStarted),
             (.newStoreVerifiedRemindersPending, .rollbackStarted),
             (.rollbackStarted, .oldStoreVerifiedRemindersPending):
            true
        case (_, .critical) where current != .critical:
            true
        default:
            false
        }
    }

    static func validateTransition(
        from current: RestoreJournalContentV1,
        to next: RestoreJournalContentV1
    ) throws {
        try validate(content: current)
        try validate(content: next)
        guard canTransition(from: current.phase, to: next.phase) else {
            throw RestoreJournalError.invalidTransition
        }
        guard current.sequence < Int64.max, next.sequence == current.sequence + 1 else {
            throw RestoreJournalError.invalidTransition
        }
        guard next.updatedAtMilliseconds >= current.updatedAtMilliseconds else {
            throw RestoreJournalError.invalidTransition
        }
        // `createdAtMilliseconds` is bound by the immutable armed marker. It
        // must fail before any replacement journal bytes are published.
        guard next.createdAtMilliseconds == current.createdAtMilliseconds else {
            throw RestoreJournalError.invalidTransition
        }
        guard RestoreJournalIdentityV1(current) == RestoreJournalIdentityV1(next) else {
            throw RestoreJournalError.invalidTransition
        }
        try requirePreserved(current.aRecordsDigest, next.aRecordsDigest)
        try requirePreserved(current.aRecordCounts, next.aRecordCounts)
        try requirePreserved(current.portableABasename, next.portableABasename)
        try requirePreserved(current.portableAByteCount, next.portableAByteCount)
        try requirePreserved(current.portableAChecksum, next.portableAChecksum)
        try requirePreserved(current.portableARecordsDigest, next.portableARecordsDigest)
        try requirePreserved(current.physicalAStoreUUID, next.physicalAStoreUUID)
        try requirePreserved(current.physicalARecordsDigest, next.physicalARecordsDigest)
        if next.phase == .critical {
            guard next.criticalFromPhase == current.phase else {
                throw RestoreJournalError.invalidTransition
            }
        }
    }

    static func validate(content: RestoreJournalContentV1) throws {
        guard content.format == RestoreJournalV1.format else {
            throw RestoreJournalError.wrongFormat(content.format)
        }
        guard content.version == RestoreJournalV1.version else {
            throw RestoreJournalError.unsupportedVersion(content.version)
        }
        guard content.sequence >= 0 else {
            throw RestoreJournalError.invalidContent("negative sequence")
        }
        guard content.createdAtMilliseconds >= 0,
              content.updatedAtMilliseconds >= content.createdAtMilliseconds else {
            throw RestoreJournalError.invalidContent("invalid timestamps")
        }
        try validateImmutableIdentity(content)

        try validateOptionalPair(
            content.aRecordsDigest,
            content.aRecordCounts,
            name: "A evidence"
        )
        try validateOptionalGroup(
            [
                content.portableABasename != nil,
                content.portableAByteCount != nil,
                content.portableAChecksum != nil,
                content.portableARecordsDigest != nil
            ],
            name: "portable A evidence"
        )
        try validateOptionalPair(
            content.physicalAStoreUUID,
            content.physicalARecordsDigest,
            name: "physical A evidence"
        )

        if content.phase == .critical {
            guard let from = content.criticalFromPhase,
                  from != .critical,
                  isStableReasonCode(content.criticalReasonCode) else {
                throw RestoreJournalError.invalidContent("invalid critical state")
            }
        } else if content.criticalFromPhase != nil || content.criticalReasonCode != nil {
            throw RestoreJournalError.invalidContent("critical fields outside critical state")
        }
        try validateSequence(content)

        let evidencePhase = try evidenceSourcePhase(for: content)
        let requirements = evidenceRequirements(for: evidencePhase)
        let hasA = content.aRecordsDigest != nil
        let hasPortableA = content.portableABasename != nil
        let hasPhysicalA = content.physicalAStoreUUID != nil
        guard hasA == requirements.requiresA,
              hasPortableA == requirements.requiresPortableA,
              hasPhysicalA == requirements.requiresPhysicalA else {
            throw RestoreJournalError.invalidContent("evidence outside phase matrix")
        }

        if let aRecordsDigest = content.aRecordsDigest {
            guard isLowercaseSHA256(aRecordsDigest), let aRecordCounts = content.aRecordCounts else {
                throw RestoreJournalError.invalidContent("invalid A evidence")
            }
            try validate(recordCounts: aRecordCounts)
        }
        if let portableABasename = content.portableABasename {
            try validatePortableABasename(portableABasename)
            guard let byteCount = content.portableAByteCount,
                  (1...HourleafBackupLimitsV1.maximumFileBytes).contains(byteCount),
                  let checksum = content.portableAChecksum,
                  isLowercaseSHA256(checksum),
                  let recordsDigest = content.portableARecordsDigest,
                  isLowercaseSHA256(recordsDigest),
                  recordsDigest == content.aRecordsDigest else {
                throw RestoreJournalError.invalidContent("invalid portable A evidence")
            }
        }
        if let storeUUID = content.physicalAStoreUUID {
            guard isLowercaseUUID(storeUUID),
                  let recordsDigest = content.physicalARecordsDigest,
                  isLowercaseSHA256(recordsDigest),
                  recordsDigest == content.aRecordsDigest else {
                throw RestoreJournalError.invalidContent("invalid physical A evidence")
            }
        }
        if requirements.requiresPortableA {
            guard content.aRecordsDigest != content.candidateRecordsDigest
                    || content.aRecordCounts != content.candidateRecordCounts else {
                throw RestoreJournalError.invalidContent("A equals B after no-op boundary")
            }
        }

        if content.phase == .prepared, content.sequence != 0 {
            throw RestoreJournalError.invalidContent("prepared sequence")
        }
    }

    /// Validates an independently observed live ledger before any metadata is
    /// removed or renamed. The source phase must still be the durable phase
    /// represented by the trusted journal being terminalized.
    static func validateTerminalDecision(
        _ decision: RestoreTerminalDecisionV1,
        against content: RestoreJournalContentV1
    ) throws {
        try validate(content: content)
        guard decision.transactionID.uuidString.lowercased() == content.transactionID,
              decision.sourcePhase == content.phase,
              content.phase != .critical else {
            throw RestoreJournalError.invalidTerminalDecision
        }

        switch decision.target {
        case .unstarted:
            guard decision.sourcePhase == .prepared,
                  decision.recordsDigest == nil,
                  decision.recordCounts == nil else {
                throw RestoreJournalError.invalidTerminalDecision
            }
        case .a:
            guard terminalTargetIsAllowed(.a, from: decision.sourcePhase),
                  decision.recordsDigest == content.aRecordsDigest,
                  decision.recordCounts == content.aRecordCounts else {
                throw RestoreJournalError.invalidTerminalDecision
            }
        case .b:
            guard terminalTargetIsAllowed(.b, from: decision.sourcePhase),
                  decision.recordsDigest == content.candidateRecordsDigest,
                  decision.recordCounts == content.candidateRecordCounts else {
                throw RestoreJournalError.invalidTerminalDecision
            }
        }
    }

    static func validateBasename(_ basename: String) throws {
        guard (1...255).contains(basename.utf8.count),
              !basename.contains("/"),
              !basename.contains("\\"),
              !basename.utf8.contains(0),
              basename != ".",
              basename != "..",
              URL(fileURLWithPath: basename).lastPathComponent == basename else {
            throw RestoreJournalError.invalidBasename(basename)
        }
    }

    private static func validateImmutableIdentity(_ content: RestoreJournalContentV1) throws {
        guard isLowercaseUUID(content.transactionID) else {
            throw RestoreJournalError.invalidContent("transaction ID")
        }
        guard isLowercaseSHA256(content.transactionNonce) else {
            throw RestoreJournalError.invalidContent("transaction nonce")
        }
        guard content.candidateBackupBasename == RestoreJournalV1.candidateBackupBasename,
              content.candidateStoreBasename == RestoreJournalV1.candidateStoreBasename,
              content.physicalAStoreBasename == RestoreJournalV1.physicalAStoreBasename,
              content.rollbackAStoreBasename == RestoreJournalV1.rollbackAStoreBasename else {
            throw RestoreJournalError.invalidContent("fixed basename")
        }
        try validateBasename(content.candidateBackupBasename)
        try validateBasename(content.candidateStoreBasename)
        try validateBasename(content.physicalAStoreBasename)
        try validateBasename(content.rollbackAStoreBasename)
        guard (1...HourleafBackupLimitsV1.maximumFileBytes).contains(content.candidateBackupByteCount),
              isLowercaseSHA256(content.candidateBackupChecksum),
              isLowercaseSHA256(content.candidateRecordsDigest) else {
            throw RestoreJournalError.invalidContent("candidate evidence")
        }
        try validate(recordCounts: content.candidateRecordCounts)
    }

    private static func validate(marker: RestoreArmedContentV1) throws {
        guard marker.format == RestoreJournalV1.armedFormat else {
            throw RestoreJournalError.wrongFormat(marker.format)
        }
        guard marker.version == RestoreJournalV1.version else {
            throw RestoreJournalError.unsupportedVersion(marker.version)
        }
        guard isLowercaseUUID(marker.transactionID),
              isLowercaseSHA256(marker.transactionNonce),
              marker.journalBasename == RestoreJournalV1.journalBasename,
              isLowercaseSHA256(marker.journalIdentityDigest),
              marker.createdAtMilliseconds >= 0 else {
            throw RestoreJournalError.invalidMarker("marker fields")
        }
        try validateBasename(marker.journalBasename)
    }

    private static func validate(checksum: RestoreJournalIntegrityV1) throws {
        guard checksum.algorithm == RestoreJournalV1.checksumAlgorithm else {
            throw RestoreJournalError.unsupportedChecksumAlgorithm(checksum.algorithm)
        }
        guard isLowercaseSHA256(checksum.value) else {
            throw RestoreJournalError.checksumMismatch
        }
    }

    static func validatePortableABasename(_ basename: String) throws {
        _ = try portableAFinalName(for: basename)
    }

    static func portableAFinalName(
        for basename: String
    ) throws -> RestoreProvisionalPortableAArtifactNameV1 {
        try validateBasename(basename)
        let prefix = "Hourleaf-Backup-"
        let suffix = ".hourleafbackup"
        guard basename.hasPrefix(prefix), basename.hasSuffix(suffix) else {
            throw RestoreJournalError.invalidBasename(basename)
        }
        let bodyStart = basename.index(basename.startIndex, offsetBy: prefix.count)
        let bodyEnd = basename.index(basename.endIndex, offsetBy: -suffix.count)
        let body = String(basename[bodyStart..<bodyEnd])
        guard body.utf8.count == 29 else {
            throw RestoreJournalError.invalidBasename(basename)
        }
        let timestamp = String(body.prefix(20))
        let checksumPrefix = String(body.suffix(8))
        guard body.dropFirst(20).first == "-",
              isExporterTimestamp(timestamp),
              checksumPrefix.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RestoreJournalError.invalidBasename(basename)
        }
        return .final(basename)
    }

    static func portableAPartialName(
        for basename: String
    ) throws -> RestoreProvisionalPortableAArtifactNameV1 {
        try validateBasename(basename)
        let prefix = ".Hourleaf-Backup-"
        let suffix = ".partial"
        guard basename.hasPrefix(prefix), basename.hasSuffix(suffix) else {
            throw RestoreJournalError.invalidBasename(basename)
        }
        let identifierStart = basename.index(basename.startIndex, offsetBy: prefix.count)
        let identifierEnd = basename.index(basename.endIndex, offsetBy: -suffix.count)
        let identifier = String(basename[identifierStart..<identifierEnd])
        guard isLowercaseUUID(identifier) else {
            throw RestoreJournalError.invalidBasename(basename)
        }
        return .partial(basename)
    }

    static func portableAFinalChecksumPrefix(for basename: String) throws -> String {
        _ = try portableAFinalName(for: basename)
        let suffix = ".hourleafbackup"
        let end = basename.index(basename.endIndex, offsetBy: -suffix.count)
        let body = basename[..<end]
        return String(body.suffix(8))
    }

    private static func validate(recordCounts: RestoreRecordCountsV1) throws {
        let values = [
            recordCounts.acknowledgements,
            recordCounts.archives,
            recordCounts.entries,
            recordCounts.policies,
            recordCounts.presets,
            recordCounts.receipts,
            recordCounts.reminders,
            recordCounts.revisions,
            recordCounts.states
        ]
        guard values.allSatisfy({ $0 >= 0 }) else {
            throw RestoreJournalError.invalidContent("negative record count")
        }
        guard recordCounts.acknowledgements <= HourleafBackupLimitsV1.maximumAcknowledgements,
              recordCounts.archives <= HourleafBackupLimitsV1.maximumArchives,
              recordCounts.entries <= HourleafBackupLimitsV1.maximumEntries,
              recordCounts.policies <= HourleafBackupLimitsV1.maximumPolicies,
              recordCounts.presets <= HourleafBackupLimitsV1.maximumPresets,
              recordCounts.receipts <= HourleafBackupLimitsV1.maximumReceipts,
              recordCounts.reminders <= HourleafBackupLimitsV1.maximumReminders,
              recordCounts.revisions <= HourleafBackupLimitsV1.maximumRevisions,
              recordCounts.states <= HourleafBackupLimitsV1.maximumStates else {
            throw RestoreJournalError.invalidContent("record count limit")
        }
        var total = 1 // Settings
        for value in values {
            let addition = total.addingReportingOverflow(value)
            guard !addition.overflow else {
                throw RestoreJournalError.invalidContent("record count overflow")
            }
            total = addition.partialValue
        }
        guard total <= HourleafBackupLimitsV1.maximumRecords else {
            throw RestoreJournalError.invalidContent("total record count")
        }
    }

    private static func evidenceSourcePhase(
        for content: RestoreJournalContentV1
    ) throws -> RestoreJournalPhase {
        if content.phase == .critical {
            guard let criticalFromPhase = content.criticalFromPhase else {
                throw RestoreJournalError.invalidContent("missing critical source phase")
            }
            return criticalFromPhase
        }
        return content.phase
    }

    private static func evidenceRequirements(
        for phase: RestoreJournalPhase
    ) -> RestoreJournalEvidenceRequirementsV1 {
        switch phase {
        case .prepared:
            .init(requiresA: false, requiresPortableA: false, requiresPhysicalA: false)
        case .maintenanceAcquired:
            .init(requiresA: true, requiresPortableA: false, requiresPhysicalA: false)
        case .preRestoreBackupVerified, .oldStoreCopyStarted:
            .init(requiresA: true, requiresPortableA: true, requiresPhysicalA: false)
        case .oldStoreCopyVerified,
             .replacementStarted,
             .replacementReturned,
             .newStoreVerifiedRemindersPending,
             .rollbackStarted,
             .oldStoreVerifiedRemindersPending:
            .init(requiresA: true, requiresPortableA: true, requiresPhysicalA: true)
        case .critical:
            // `critical` is projected through `criticalFromPhase` above.
            .init(requiresA: false, requiresPortableA: false, requiresPhysicalA: false)
        }
    }

    private static func validateSequence(_ content: RestoreJournalContentV1) throws {
        let allowed: Set<Int64>
        if content.phase == .critical {
            guard let source = content.criticalFromPhase else {
                throw RestoreJournalError.invalidContent("missing critical source phase")
            }
            allowed = Set(noncriticalSequences(for: source).map { $0 + 1 })
        } else {
            allowed = Set(noncriticalSequences(for: content.phase))
        }
        guard allowed.contains(content.sequence) else {
            throw RestoreJournalError.invalidContent("phase sequence")
        }
    }

    private static func noncriticalSequences(for phase: RestoreJournalPhase) -> [Int64] {
        switch phase {
        case .prepared: [0]
        case .maintenanceAcquired: [1]
        case .preRestoreBackupVerified: [2]
        case .oldStoreCopyStarted: [3]
        case .oldStoreCopyVerified: [4]
        case .replacementStarted: [5]
        case .replacementReturned: [6]
        case .newStoreVerifiedRemindersPending: [7]
        case .rollbackStarted: [6, 7, 8]
        case .oldStoreVerifiedRemindersPending: [7, 8, 9]
        case .critical: []
        }
    }

    private static func terminalTargetIsAllowed(
        _ target: RestoreTerminalTargetV1,
        from phase: RestoreJournalPhase
    ) -> Bool {
        switch (phase, target) {
        case (.prepared, .unstarted),
             (.maintenanceAcquired, .a),
             (.preRestoreBackupVerified, .a),
             (.oldStoreCopyStarted, .a),
             (.oldStoreCopyVerified, .a),
             (.replacementStarted, .a),
             (.replacementStarted, .b),
             (.replacementReturned, .b),
             (.newStoreVerifiedRemindersPending, .b),
             (.rollbackStarted, .a),
             (.oldStoreVerifiedRemindersPending, .a):
            true
        default:
            false
        }
    }

    private static func validateOptionalPair<A, B>(
        _ first: A?,
        _ second: B?,
        name: String
    ) throws {
        guard (first == nil) == (second == nil) else {
            throw RestoreJournalError.invalidContent("incomplete \(name)")
        }
    }

    private static func validateOptionalGroup(_ presence: [Bool], name: String) throws {
        guard let first = presence.first, presence.allSatisfy({ $0 == first }) else {
            throw RestoreJournalError.invalidContent("incomplete \(name)")
        }
    }

    private static func requirePreserved<T: Equatable>(_ current: T?, _ next: T?) throws {
        if let current, next != current {
            throw RestoreJournalError.invalidTransition
        }
    }

    private static func isStableReasonCode(_ value: String?) -> Bool {
        guard let value, (1...80).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45 // -
                || byte == 46 // .
                || byte == 95 // _
        }
    }

    private static func isLowercaseUUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private static func isExporterTimestamp(_ value: String) -> Bool {
        guard value.utf8.count == 20 else { return false }
        let bytes = Array(value.utf8)
        let separators: [Int: UInt8] = [4: 45, 7: 45, 10: 84, 13: 45, 16: 45, 19: 90]
        for index in bytes.indices {
            if let separator = separators[index] {
                guard bytes[index] == separator else { return false }
            } else if !(48...57).contains(bytes[index]) {
                return false
            }
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        guard let parsed = formatter.date(from: value) else { return false }
        return formatter.string(from: parsed) == value
    }

    private static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct RestoreJournalEvidenceRequirementsV1: Equatable, Sendable {
    let requiresA: Bool
    let requiresPortableA: Bool
    let requiresPhysicalA: Bool
}

private struct RestoreJournalIdentityV1: Codable, Equatable, Sendable {
    let format: String
    let version: Int
    let transactionID: String
    let transactionNonce: String
    let candidateBackupBasename: String
    let candidateStoreBasename: String
    let physicalAStoreBasename: String
    let rollbackAStoreBasename: String
    let candidateBackupByteCount: Int
    let candidateBackupChecksum: String
    let candidateRecordsDigest: String
    let candidateRecordCounts: RestoreRecordCountsV1

    init(_ content: RestoreJournalContentV1) {
        format = content.format
        version = content.version
        transactionID = content.transactionID
        transactionNonce = content.transactionNonce
        candidateBackupBasename = content.candidateBackupBasename
        candidateStoreBasename = content.candidateStoreBasename
        physicalAStoreBasename = content.physicalAStoreBasename
        rollbackAStoreBasename = content.rollbackAStoreBasename
        candidateBackupByteCount = content.candidateBackupByteCount
        candidateBackupChecksum = content.candidateBackupChecksum
        candidateRecordsDigest = content.candidateRecordsDigest
        candidateRecordCounts = content.candidateRecordCounts
    }
}

enum RestoreJournalFileKind: String, Equatable, Sendable {
    case journal
    case marker

    var basename: String {
        switch self {
        case .journal: RestoreJournalV1.journalBasename
        case .marker: RestoreJournalV1.armedBasename
        }
    }

    var partialStem: String {
        switch self {
        case .journal: "journal-v1"
        case .marker: "armed-v1"
        }
    }
}

enum RestoreJournalFaultPoint: Equatable, Sendable {
    case beforePartialCreate(RestoreJournalFileKind)
    case afterPayloadWrite(RestoreJournalFileKind)
    case afterFileSync(RestoreJournalFileKind)
    case afterPartialReadback(RestoreJournalFileKind)
    case afterRename(RestoreJournalFileKind)
    case afterDirectorySync(RestoreJournalFileKind)
    case afterFinalReadback(RestoreJournalFileKind)
    case afterArmingDirectorySync
    case afterActiveRename
    case afterRecoveryRootSync
    case afterCompletedRename
    case afterCompletedRootSync
    case afterCompletedMarkerRemoval
    case afterCompletedJournalRemoval
    case afterCompletedJSONRemoval
    case afterCompletedDirectorySync
    case afterCompletedDirectoryRemoval
    case afterCompletedCleanupRootSync
    case afterProvisionalPortableAFirstRemoval
}

typealias RestoreJournalFaultInjector = @Sendable (RestoreJournalFaultPoint) throws -> Void

/// A deliberately narrow seam around one durable JSON file publication. The
/// production implementation owns POSIX sync/rename details; tests can inject
/// a tiny fake without making the restore flow depend on a storage framework.
protocol RestoreJournalDurableWriting: Sendable {
    func write(
        _ data: Data,
        to finalURL: URL,
        kind: RestoreJournalFileKind,
        replacingExistingFinal: Bool,
        verify: @escaping @Sendable (Data) throws -> Void
    ) throws

    func synchronizeDirectory(at directoryURL: URL) throws
}

struct RestoreDurableJSONWriter: RestoreJournalDurableWriting, Sendable {
    typealias UUIDSource = @Sendable () -> UUID

    private let protectionReader: any HourleafFileProtectionReading
    private let faultInjector: RestoreJournalFaultInjector
    private let uuidSource: UUIDSource

    init(
        protectionReader: any HourleafFileProtectionReading = FoundationFileProtectionReader(),
        faultInjector: @escaping RestoreJournalFaultInjector = { _ in },
        uuidSource: @escaping UUIDSource = UUID.init
    ) {
        self.protectionReader = protectionReader
        self.faultInjector = faultInjector
        self.uuidSource = uuidSource
    }

    func write(
        _ data: Data,
        to finalURL: URL,
        kind: RestoreJournalFileKind,
        replacingExistingFinal: Bool,
        verify: @escaping @Sendable (Data) throws -> Void
    ) throws {
        try RestoreJournalCodecV1.validateBasename(finalURL.lastPathComponent)
        let parent = finalURL.deletingLastPathComponent().standardizedFileURL
        let standardizedFinal = finalURL.standardizedFileURL
        guard standardizedFinal.deletingLastPathComponent() == parent else {
            throw RestoreJournalError.invalidBasename(finalURL.lastPathComponent)
        }
        try verifyProtectedDirectory(at: parent)
        let maximumBytes = kind == .journal
            ? RestoreJournalV1.maximumJournalBytes
            : RestoreJournalV1.maximumMarkerBytes
        guard data.count <= maximumBytes else {
            throw RestoreJournalError.fileTooLarge(actual: data.count, limit: maximumBytes)
        }
        if !replacingExistingFinal, FileManager.default.fileExists(atPath: finalURL.path) {
            throw RestoreJournalError.fileSystem("final metadata file already exists")
        }

        let partialURL = parent.appendingPathComponent(
            ".\(kind.partialStem).\(uuidSource().uuidString.lowercased()).partial",
            isDirectory: false
        )
        try faultInjector(.beforePartialCreate(kind))
        let descriptor = Darwin.open(
            partialURL.path,
            O_WRONLY | O_CREAT | O_EXCL,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw RestoreJournalError.fileSystem("could not reserve metadata partial")
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var didClose = false
        defer {
            if !didClose { try? handle.close() }
        }
        do {
            try FileManager.default.setAttributes(
                [.protectionKey: RestoreJournalV1.requiredProtectionClass],
                ofItemAtPath: partialURL.path
            )
            try verifyProtectedRegularFile(at: partialURL)
            try handle.write(contentsOf: data)
            try faultInjector(.afterPayloadWrite(kind))
            try synchronize(descriptor: descriptor)
            try faultInjector(.afterFileSync(kind))
            try handle.close()
            didClose = true
        } catch let error as RestoreJournalError {
            throw error
        } catch {
            throw RestoreJournalError.fileSystem(error.localizedDescription)
        }

        try verifyReadback(at: partialURL, expected: data, kind: kind, verify: verify)
        try faultInjector(.afterPartialReadback(kind))
        let published: Int32
        if replacingExistingFinal {
            published = Darwin.rename(partialURL.path, finalURL.path)
        } else {
            published = Darwin.renameatx_np(
                AT_FDCWD,
                partialURL.path,
                AT_FDCWD,
                finalURL.path,
                UInt32(RENAME_EXCL)
            )
        }
        guard published == 0 else {
            throw RestoreJournalError.fileSystem("could not publish recovery metadata")
        }
        try faultInjector(.afterRename(kind))
        try synchronizeDirectory(at: parent)
        try faultInjector(.afterDirectorySync(kind))
        try verifyReadback(at: finalURL, expected: data, kind: kind, verify: verify)
        try faultInjector(.afterFinalReadback(kind))
    }

    func synchronizeDirectory(at directoryURL: URL) throws {
        try verifyProtectedDirectory(at: directoryURL)
        let descriptor = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw RestoreJournalError.fileSystem("could not open metadata directory")
        }
        defer { _ = Darwin.close(descriptor) }
        try synchronize(descriptor: descriptor)
    }

    private func verifyReadback(
        at url: URL,
        expected: Data,
        kind: RestoreJournalFileKind,
        verify: @escaping @Sendable (Data) throws -> Void
    ) throws {
        try verifyProtectedRegularFile(at: url)
        let actual = try boundedData(
            at: url,
            limit: kind == .journal ? RestoreJournalV1.maximumJournalBytes : RestoreJournalV1.maximumMarkerBytes
        )
        guard actual == expected else {
            throw RestoreJournalError.fileSystem("metadata readback changed")
        }
        try verify(actual)
    }

    private func verifyProtectedRegularFile(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RestoreJournalError.fileSystem("metadata file is not a regular file")
        }
        try verifyProtection(at: url)
    }

    private func verifyProtectedDirectory(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RestoreJournalError.fileSystem("metadata parent is not a directory")
        }
        try verifyProtection(at: url)
    }

    private func verifyProtection(at url: URL) throws {
        let observed = try protectionReader.protectionClass(at: url)
        if observed == RestoreJournalV1.requiredProtectionClass { return }
        #if targetEnvironment(simulator)
        if observed == nil { return }
        #endif
        throw RestoreJournalError.protectionMismatch
    }

    private func boundedData(at url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw RestoreJournalError.fileTooLarge(actual: data.count, limit: limit)
        }
        return data
    }

    private func synchronize(descriptor: Int32) throws {
        if Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard Darwin.fsync(descriptor) == 0 else {
            throw RestoreJournalError.fileSystem("could not synchronize recovery metadata")
        }
    }
}

struct VerifiedRestoreTransactionV1: Equatable, Sendable {
    let rootDirectory: URL
    let activeDirectory: URL
    let journal: VerifiedRestoreJournalV1
    let marker: VerifiedRestoreArmedMarkerV1
    let trustedReservedPartials: [String]
    let provisionalPortableAArtifacts: RestoreProvisionalPortableAArtifactsV1
}

struct RedactedRestoreCriticalState: Equatable, Sendable {
    let reasonCode: String
}

enum RestoreStartupDisposition: Equatable, Sendable {
    case idle
    case recover(VerifiedRestoreTransactionV1)
    case critical(RedactedRestoreCriticalState)
}

protocol RestoreJournalStoring: Sendable {
    func inspectBeforeStoreLoad() throws -> RestoreStartupDisposition
    func arm(_ prepared: RestoreJournalContentV1) throws
    func advance(
        to phase: RestoreJournalPhase,
        mutate: (inout RestoreJournalContentV1) throws -> Void
    ) throws
    func removeTrustedReservedPartials() throws
    func discardProvisionalPortableAArtifacts(
        afterProvingLiveA decision: RestoreTerminalDecisionV1
    ) throws
    func complete(_ decision: RestoreTerminalDecisionV1) throws
    func cleanupCompletedTransactions() throws
}

/// Owns restore metadata only. It never opens, copies, replaces, deletes, or
/// enumerates a SQLite family; Core Data remains the sole authority for those
/// operations.
final class RestoreJournalStoreV1: RestoreJournalStoring, @unchecked Sendable {
    typealias MillisecondClock = @Sendable () -> Int64

    private let rootDirectory: URL
    private let protectionReader: any HourleafFileProtectionReading
    private let durableWriter: any RestoreJournalDurableWriting
    private let faultInjector: RestoreJournalFaultInjector
    private let clock: MillisecondClock
    private let lock = NSLock()

    init(
        rootDirectory: URL,
        protectionReader: any HourleafFileProtectionReading = FoundationFileProtectionReader(),
        durableWriter: (any RestoreJournalDurableWriting)? = nil,
        faultInjector: @escaping RestoreJournalFaultInjector = { _ in },
        clock: @escaping MillisecondClock = {
            Int64((Date.now.timeIntervalSince1970 * 1_000).rounded(.down))
        }
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.protectionReader = protectionReader
        self.durableWriter = durableWriter ?? RestoreDurableJSONWriter(
            protectionReader: protectionReader,
            faultInjector: faultInjector
        )
        self.faultInjector = faultInjector
        self.clock = clock
    }

    static func defaultRecoveryRoot(
        fileManager: FileManager = .default,
        applicationSupportDirectory: (() -> URL?)? = nil
    ) throws -> URL {
        let resolvedApplicationSupport: URL?
        if let applicationSupportDirectory {
            resolvedApplicationSupport = applicationSupportDirectory()
        } else {
            resolvedApplicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        }
        guard let applicationSupport = resolvedApplicationSupport else {
            throw RestoreJournalError.applicationSupportUnavailable
        }
        return applicationSupport.appendingPathComponent(
            RestoreJournalV1.recoveryDirectoryName,
            isDirectory: true
        )
    }

    /// Strictly read-only. A trusted reserved partial or a strictly typed
    /// exporter publication state is surfaced but never removed here.
    func inspectBeforeStoreLoad() throws -> RestoreStartupDisposition {
        lock.withLock {
            do {
                guard pathEntryExists(at: rootDirectory) else {
                    return .idle
                }
                try verifyProtectedDirectory(at: rootDirectory)
                try validateRecoveryRootMembers()
                let activeURL = try exactChildURL(
                    in: rootDirectory,
                    named: RestoreJournalV1.activeDirectoryName
                )
                guard pathEntryExists(at: activeURL) else {
                    return .idle
                }
                let transaction = try readTrustedActive(allowProvisionalPortableA: true)
                if transaction.journal.content.phase == .critical {
                    guard let reasonCode = transaction.journal.content.criticalReasonCode else {
                        throw RestoreJournalError.transactionUnavailable
                    }
                    return .critical(RedactedRestoreCriticalState(reasonCode: reasonCode))
                }
                return .recover(transaction)
            } catch {
                return .critical(RedactedRestoreCriticalState(reasonCode: redactedReason(for: error)))
            }
        }
    }

    func arm(_ prepared: RestoreJournalContentV1) throws {
        try lock.withLock {
            try RestoreJournalCodecV1.validate(content: prepared)
            guard prepared.phase == .prepared, prepared.sequence == 0 else {
                throw RestoreJournalError.invalidTransition
            }
            try ensureProtectedDirectory(at: rootDirectory)
            try validateRecoveryRootMembers()
            let activeURL = try exactChildURL(
                in: rootDirectory,
                named: RestoreJournalV1.activeDirectoryName
            )
            guard !pathEntryExists(at: activeURL) else {
                throw RestoreJournalError.activeTransactionExists
            }
            let armingURL = try exactChildURL(
                in: rootDirectory,
                named: ".arming-\(prepared.transactionID)"
            )
            guard !pathEntryExists(at: armingURL) else {
                throw RestoreJournalError.fileSystem("arming transaction already exists")
            }
            try FileManager.default.createDirectory(at: armingURL, withIntermediateDirectories: false)
            try setAndVerifyDirectoryProtection(at: armingURL)

            let journal = try RestoreJournalCodecV1.encode(content: prepared)
            let marker = try RestoreJournalCodecV1.encode(marker: RestoreJournalCodecV1.marker(for: prepared))
            let journalURL = try exactChildURL(in: armingURL, named: RestoreJournalV1.journalBasename)
            let markerURL = try exactChildURL(in: armingURL, named: RestoreJournalV1.armedBasename)
            try durableWriter.write(
                journal.data,
                to: journalURL,
                kind: .journal,
                replacingExistingFinal: false,
                verify: { data in
                    _ = try RestoreJournalCodecV1.decodeAndVerify(data)
                }
            )
            try durableWriter.write(
                marker.data,
                to: markerURL,
                kind: .marker,
                replacingExistingFinal: false,
                verify: { data in
                    _ = try RestoreJournalCodecV1.decodeAndVerifyMarker(data)
                }
            )
            try verifyTransaction(journal: journal, marker: marker)
            try durableWriter.synchronizeDirectory(at: armingURL)
            try faultInjector(.afterArmingDirectorySync)
            guard Darwin.renameatx_np(
                AT_FDCWD,
                armingURL.path,
                AT_FDCWD,
                activeURL.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw RestoreJournalError.fileSystem("could not arm restore transaction")
            }
            try faultInjector(.afterActiveRename)
            try durableWriter.synchronizeDirectory(at: rootDirectory)
            try faultInjector(.afterRecoveryRootSync)
            _ = try readTrustedActive()
        }
    }

    func advance(
        to phase: RestoreJournalPhase,
        mutate: (inout RestoreJournalContentV1) throws -> Void
    ) throws {
        try lock.withLock {
            let bindsPortableA = phase == .preRestoreBackupVerified
            let current = try readTrustedActive(
                allowProvisionalPortableA: bindsPortableA
            )
            let provisionalPortableA: (basename: String, backup: VerifiedHourleafBackupV1)?
            if bindsPortableA {
                guard current.journal.content.phase == .maintenanceAcquired else {
                    throw RestoreJournalError.invalidTransition
                }
                switch current.provisionalPortableAArtifacts {
                case let .single(.final(basename)):
                    let finalURL = try exactChildURL(in: current.activeDirectory, named: basename)
                    provisionalPortableA = (
                        basename,
                        try readVerifiedPortableAFinal(at: finalURL, basename: basename)
                    )
                case .none, .single(.partial), .publishedPair:
                    throw RestoreJournalError.invalidTransition
                }
            } else {
                provisionalPortableA = nil
            }
            var next = current.journal.content
            try mutate(&next)
            next.phase = phase
            guard current.journal.content.sequence < Int64.max else {
                throw RestoreJournalError.invalidTransition
            }
            next.sequence = current.journal.content.sequence + 1
            next.updatedAtMilliseconds = max(clock(), current.journal.content.updatedAtMilliseconds)
            try RestoreJournalCodecV1.validateTransition(from: current.journal.content, to: next)
            if let provisionalPortableA {
                guard next.portableABasename == provisionalPortableA.basename,
                      next.portableAByteCount == provisionalPortableA.backup.byteCount,
                      next.portableAChecksum == provisionalPortableA.backup.checksum.value,
                      next.portableARecordsDigest == provisionalPortableA.backup.recordsDigest,
                      next.aRecordCounts == RestoreRecordCountsV1(provisionalPortableA.backup.recordCounts),
                      next.aRecordsDigest == provisionalPortableA.backup.recordsDigest else {
                    throw RestoreJournalError.invalidTransition
                }
            }
            let verified = try RestoreJournalCodecV1.encode(content: next)
            let journalURL = try exactChildURL(
                in: current.activeDirectory,
                named: RestoreJournalV1.journalBasename
            )
            try durableWriter.write(
                verified.data,
                to: journalURL,
                kind: .journal,
                replacingExistingFinal: true,
                verify: { data in
                    _ = try RestoreJournalCodecV1.decodeAndVerify(data)
                }
            )
            let readback = try readTrustedActive()
            guard readback.journal.data == verified.data else {
                throw RestoreJournalError.fileSystem("journal readback changed")
            }
        }
    }

    /// Removes only reservation-shaped partials that a prior read-only
    /// preflight has proven correspond to a trusted final metadata file.
    func removeTrustedReservedPartials() throws {
        try lock.withLock {
            let transaction = try readTrustedActive()
            for basename in transaction.trustedReservedPartials {
                let partialURL = try exactChildURL(in: transaction.activeDirectory, named: basename)
                try verifyProtectedRegularFile(at: partialURL)
                try FileManager.default.removeItem(at: partialURL)
            }
            if !transaction.trustedReservedPartials.isEmpty {
                try durableWriter.synchronizeDirectory(at: transaction.activeDirectory)
            }
        }
    }

    /// The caller must provide a proof-bound decision from an independently
    /// reopened ledger. This method never infers a target from metadata alone.
    /// It touches JSON directories only; all SQLite artifact cleanup remains
    /// with typed Core Data ownership.
    func complete(_ decision: RestoreTerminalDecisionV1) throws {
        try lock.withLock {
            let transaction = try readTrustedActive()
            try RestoreJournalCodecV1.validateTerminalDecision(
                decision,
                against: transaction.journal.content
            )
            guard transaction.trustedReservedPartials.isEmpty else {
                throw RestoreJournalError.transactionUnavailable
            }
            let members = try activeMemberNames(at: transaction.activeDirectory)
            let expected = Set([RestoreJournalV1.journalBasename, RestoreJournalV1.armedBasename])
            guard Set(members) == expected else {
                throw RestoreJournalError.transactionUnavailable
            }
            let completedURL = try exactChildURL(
                in: rootDirectory,
                named: ".completed-\(transaction.journal.content.transactionID)"
            )
            guard !pathEntryExists(at: completedURL) else {
                throw RestoreJournalError.fileSystem("completed transaction already exists")
            }
            try durableWriter.synchronizeDirectory(at: transaction.activeDirectory)
            guard Darwin.renameatx_np(
                AT_FDCWD,
                transaction.activeDirectory.path,
                AT_FDCWD,
                completedURL.path,
                UInt32(RENAME_EXCL)
            ) == 0 else {
                throw RestoreJournalError.fileSystem("could not terminalize restore transaction")
            }
            try faultInjector(.afterCompletedRename)
            try durableWriter.synchronizeDirectory(at: rootDirectory)
            try faultInjector(.afterCompletedRootSync)
            try cleanupCompletedTransaction(
                at: completedURL,
                expectedTransactionID: transaction.journal.content.transactionID
            )
        }
    }

    /// A maintenance-phase exporter can leave one bounded, protected final or
    /// partial, or its one verified hard-link publication pair, across a crash.
    /// Only a separately validated exact-A decision may discard it, and this
    /// method never accepts a caller-supplied URL.
    func discardProvisionalPortableAArtifacts(
        afterProvingLiveA decision: RestoreTerminalDecisionV1
    ) throws {
        try lock.withLock {
            let transaction = try readTrustedActive(allowProvisionalPortableA: true)
            try RestoreJournalCodecV1.validateTerminalDecision(
                decision,
                against: transaction.journal.content
            )
            guard decision.sourcePhase == .maintenanceAcquired, decision.target == .a else {
                throw RestoreJournalError.invalidTerminalDecision
            }
            switch transaction.provisionalPortableAArtifacts {
            case .none:
                return
            case let .single(artifact):
                try removeProvisionalPortableAArtifact(
                    artifact,
                    from: transaction.activeDirectory
                )
                try durableWriter.synchronizeDirectory(at: transaction.activeDirectory)
            case let .publishedPair(final, partial):
                // Re-prove the hard-link relationship before touching either
                // pathname. Removing the final first leaves a strict, typed
                // partial window if power is lost before the second unlink.
                try verifyPublishedPortableAPair(
                    in: transaction.activeDirectory,
                    final: final,
                    partial: partial
                )
                try removeProvisionalPortableAArtifact(final, from: transaction.activeDirectory)
                try durableWriter.synchronizeDirectory(at: transaction.activeDirectory)
                try faultInjector(.afterProvisionalPortableAFirstRemoval)
                try removeProvisionalPortableAArtifact(partial, from: transaction.activeDirectory)
                try durableWriter.synchronizeDirectory(at: transaction.activeDirectory)
            }
            _ = try readTrustedActive()
        }
    }

    /// Safe to call after a restart. It deletes only exact, protected terminal
    /// metadata directories; preflight itself remains strictly read-only.
    func cleanupCompletedTransactions() throws {
        try lock.withLock {
            guard pathEntryExists(at: rootDirectory) else { return }
            try verifyProtectedDirectory(at: rootDirectory)
            try validateRecoveryRootMembers()
            for completedURL in try completedTransactionDirectories() {
                try cleanupCompletedTransaction(at: completedURL, expectedTransactionID: nil)
            }
        }
    }

    private func readTrustedActive(
        allowProvisionalPortableA: Bool = false
    ) throws -> VerifiedRestoreTransactionV1 {
        try verifyProtectedDirectory(at: rootDirectory)
        try validateRecoveryRootMembers()
        let activeURL = try exactChildURL(in: rootDirectory, named: RestoreJournalV1.activeDirectoryName)
        try verifyProtectedDirectory(at: activeURL)
        let journalURL = try exactChildURL(in: activeURL, named: RestoreJournalV1.journalBasename)
        let markerURL = try exactChildURL(in: activeURL, named: RestoreJournalV1.armedBasename)
        let journal = try readVerifiedJournal(at: journalURL)
        let marker = try readVerifiedMarker(at: markerURL)
        try verifyTransaction(journal: journal, marker: marker)

        var expected = Set([RestoreJournalV1.journalBasename, RestoreJournalV1.armedBasename])
        if let portableABasename = journal.content.portableABasename {
            let portableURL = try exactChildURL(in: activeURL, named: portableABasename)
            if FileManager.default.fileExists(atPath: portableURL.path) {
                let portableA = try readVerifiedPortableAFinal(at: portableURL, basename: portableABasename)
                guard portableA.byteCount == journal.content.portableAByteCount,
                      portableA.checksum.value == journal.content.portableAChecksum,
                      portableA.recordsDigest == journal.content.portableARecordsDigest,
                      RestoreRecordCountsV1(portableA.recordCounts) == journal.content.aRecordCounts,
                      portableA.recordsDigest == journal.content.aRecordsDigest else {
                    throw RestoreJournalError.transactionUnavailable
                }
                expected.insert(portableABasename)
            } else if journal.content.phase.requiresPortableArtifactOnDisk {
                throw RestoreJournalError.transactionUnavailable
            }
        }

        var trustedPartials: [String] = []
        var provisionalFinal: RestoreProvisionalPortableAArtifactNameV1?
        var provisionalPartial: RestoreProvisionalPortableAArtifactNameV1?
        for basename in try activeMemberNames(at: activeURL) {
            if expected.contains(basename) { continue }
            if allowProvisionalPortableA, journal.content.phase == .maintenanceAcquired {
                if let final = try? RestoreJournalCodecV1.portableAFinalName(for: basename) {
                    guard provisionalFinal == nil else {
                        throw RestoreJournalError.transactionUnavailable
                    }
                    let portableURL = try exactChildURL(in: activeURL, named: basename)
                    _ = try readVerifiedPortableAFinal(at: portableURL, basename: final.basename)
                    provisionalFinal = final
                    continue
                }
                if let partial = try? RestoreJournalCodecV1.portableAPartialName(for: basename) {
                    guard provisionalPartial == nil else {
                        throw RestoreJournalError.transactionUnavailable
                    }
                    let partialURL = try exactChildURL(in: activeURL, named: basename)
                    try verifyProvisionalPortableAPartial(at: partialURL)
                    provisionalPartial = partial
                    continue
                }
            }
            guard let kind = reservedPartialKind(for: basename) else {
                throw RestoreJournalError.transactionUnavailable
            }
            let partialURL = try exactChildURL(in: activeURL, named: basename)
            try verifyProtectedRegularFile(at: partialURL)
            let finalURL = try exactChildURL(in: activeURL, named: kind.basename)
            switch kind {
            case .journal:
                _ = try readVerifiedJournal(at: finalURL)
            case .marker:
                _ = try readVerifiedMarker(at: finalURL)
            }
            trustedPartials.append(basename)
        }
        let provisionalPortableA: RestoreProvisionalPortableAArtifactsV1
        switch (provisionalFinal, provisionalPartial) {
        case (nil, nil):
            provisionalPortableA = .none
        case let (final?, nil):
            provisionalPortableA = .single(final)
        case let (nil, partial?):
            provisionalPortableA = .single(partial)
        case let (final?, partial?):
            try verifyPublishedPortableAPair(
                in: activeURL,
                final: final,
                partial: partial
            )
            provisionalPortableA = .publishedPair(final: final, partial: partial)
        }
        return VerifiedRestoreTransactionV1(
            rootDirectory: rootDirectory,
            activeDirectory: activeURL,
            journal: journal,
            marker: marker,
            trustedReservedPartials: trustedPartials.sorted(),
            provisionalPortableAArtifacts: provisionalPortableA
        )
    }

    private func verifyTransaction(
        journal: VerifiedRestoreJournalV1,
        marker: VerifiedRestoreArmedMarkerV1
    ) throws {
        guard marker.content.transactionID == journal.content.transactionID,
              marker.content.transactionNonce == journal.content.transactionNonce,
              marker.content.createdAtMilliseconds == journal.content.createdAtMilliseconds,
              marker.content.journalBasename == RestoreJournalV1.journalBasename,
              marker.content.journalIdentityDigest == journal.identityDigest else {
            throw RestoreJournalError.transactionUnavailable
        }
    }

    private func readVerifiedJournal(at url: URL) throws -> VerifiedRestoreJournalV1 {
        try verifyProtectedRegularFile(at: url)
        let data = try boundedData(at: url, limit: RestoreJournalV1.maximumJournalBytes)
        return try RestoreJournalCodecV1.decodeAndVerify(data)
    }

    private func readVerifiedMarker(at url: URL) throws -> VerifiedRestoreArmedMarkerV1 {
        try verifyProtectedRegularFile(at: url)
        let data = try boundedData(at: url, limit: RestoreJournalV1.maximumMarkerBytes)
        return try RestoreJournalCodecV1.decodeAndVerifyMarker(data)
    }

    private func readVerifiedPortableAFinal(
        at url: URL,
        basename: String
    ) throws -> VerifiedHourleafBackupV1 {
        _ = try RestoreJournalCodecV1.portableAFinalName(for: basename)
        try verifyProtectedRegularFile(at: url)
        let data = try boundedData(at: url, limit: HourleafBackupLimitsV1.maximumFileBytes)
        let backup: VerifiedHourleafBackupV1
        do {
            backup = try HourleafBackupCodec.decodeAndVerify(data)
        } catch {
            throw RestoreJournalError.transactionUnavailable
        }
        guard backup.data == data,
              backup.checksum.value.hasPrefix(
                try RestoreJournalCodecV1.portableAFinalChecksumPrefix(for: basename)
              ) else {
            throw RestoreJournalError.transactionUnavailable
        }
        return backup
    }

    private func verifyProvisionalPortableAPartial(at url: URL) throws {
        try verifyProtectedRegularFile(at: url)
        _ = try boundedData(at: url, limit: HourleafBackupLimitsV1.maximumFileBytes)
    }

    /// Both exporter names must designate the same protected, bounded file.
    /// They live in the one active transaction directory, so equal file number
    /// proves the expected hard-link relationship on the same recovery volume.
    private func verifyPublishedPortableAPair(
        in activeDirectory: URL,
        final: RestoreProvisionalPortableAArtifactNameV1,
        partial: RestoreProvisionalPortableAArtifactNameV1
    ) throws {
        guard case let .final(finalBasename) = final,
              case let .partial(partialBasename) = partial,
              try RestoreJournalCodecV1.portableAFinalName(for: finalBasename) == final,
              try RestoreJournalCodecV1.portableAPartialName(for: partialBasename) == partial else {
            throw RestoreJournalError.transactionUnavailable
        }
        let finalURL = try exactChildURL(in: activeDirectory, named: finalBasename)
        let partialURL = try exactChildURL(in: activeDirectory, named: partialBasename)
        let backup = try readVerifiedPortableAFinal(at: finalURL, basename: finalBasename)
        try verifyProvisionalPortableAPartial(at: partialURL)
        let finalIdentity = try regularFileIdentity(at: finalURL)
        let partialIdentity = try regularFileIdentity(at: partialURL)
        guard finalIdentity.fileNumber == partialIdentity.fileNumber,
              finalIdentity.byteCount == partialIdentity.byteCount,
              finalIdentity.byteCount == backup.byteCount else {
            throw RestoreJournalError.transactionUnavailable
        }
    }

    private func removeProvisionalPortableAArtifact(
        _ artifact: RestoreProvisionalPortableAArtifactNameV1,
        from activeDirectory: URL
    ) throws {
        let artifactURL = try exactChildURL(in: activeDirectory, named: artifact.basename)
        switch artifact {
        case let .final(basename):
            _ = try readVerifiedPortableAFinal(at: artifactURL, basename: basename)
        case let .partial(basename):
            _ = try RestoreJournalCodecV1.portableAPartialName(for: basename)
            try verifyProvisionalPortableAPartial(at: artifactURL)
        }
        try FileManager.default.removeItem(at: artifactURL)
    }

    private func regularFileIdentity(at url: URL) throws -> (fileNumber: NSNumber, byteCount: Int) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileNumber = attributes[.systemFileNumber] as? NSNumber,
              let byteCountNumber = attributes[.size] as? NSNumber,
              byteCountNumber.int64Value >= 0,
              byteCountNumber.int64Value <= Int64(HourleafBackupLimitsV1.maximumFileBytes) else {
            throw RestoreJournalError.transactionUnavailable
        }
        return (fileNumber, Int(byteCountNumber.int64Value))
    }

    /// Every root sibling is checked even while `active` exists. A completed
    /// directory may contain a durable-cleanup residue (one JSON member or
    /// none) after a power loss, but it can never participate in recovery.
    private func validateRecoveryRootMembers() throws {
        for url in try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            let basename = url.lastPathComponent
            if basename == RestoreJournalV1.activeDirectoryName {
                try verifyProtectedDirectory(at: url)
            } else if isTransactionDirectory(basename, prefix: ".arming-") {
                try verifyProtectedDirectory(at: url)
            } else if isTransactionDirectory(basename, prefix: ".completed-") {
                try validateCompletedTransactionDirectory(at: url)
            } else {
                throw RestoreJournalError.transactionUnavailable
            }
        }
    }

    private func completedTransactionDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        .filter { isTransactionDirectory($0.lastPathComponent, prefix: ".completed-") }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func validateCompletedTransactionDirectory(at url: URL) throws {
        try verifyProtectedDirectory(at: url)
        let transactionID = try transactionID(inDirectoryBasename: url.lastPathComponent, prefix: ".completed-")
        let members = try activeMemberNames(at: url)
        let allowed = Set([RestoreJournalV1.journalBasename, RestoreJournalV1.armedBasename])
        guard Set(members).isSubset(of: allowed) else {
            throw RestoreJournalError.transactionUnavailable
        }
        let journalURL = try exactChildURL(in: url, named: RestoreJournalV1.journalBasename)
        let markerURL = try exactChildURL(in: url, named: RestoreJournalV1.armedBasename)
        let journal: VerifiedRestoreJournalV1?
        let marker: VerifiedRestoreArmedMarkerV1?
        if members.contains(RestoreJournalV1.journalBasename) {
            journal = try readVerifiedJournal(at: journalURL)
            guard journal?.content.transactionID == transactionID else {
                throw RestoreJournalError.transactionUnavailable
            }
        } else {
            journal = nil
        }
        if members.contains(RestoreJournalV1.armedBasename) {
            marker = try readVerifiedMarker(at: markerURL)
            guard marker?.content.transactionID == transactionID else {
                throw RestoreJournalError.transactionUnavailable
            }
        } else {
            marker = nil
        }
        if let journal, let marker {
            try verifyTransaction(journal: journal, marker: marker)
        }
    }

    private func cleanupCompletedTransaction(
        at completedURL: URL,
        expectedTransactionID: String?
    ) throws {
        try validateCompletedTransactionDirectory(at: completedURL)
        let transactionID = try transactionID(
            inDirectoryBasename: completedURL.lastPathComponent,
            prefix: ".completed-"
        )
        guard expectedTransactionID == nil || expectedTransactionID == transactionID else {
            throw RestoreJournalError.transactionUnavailable
        }
        let markerURL = try exactChildURL(in: completedURL, named: RestoreJournalV1.armedBasename)
        if FileManager.default.fileExists(atPath: markerURL.path) {
            try verifyProtectedRegularFile(at: markerURL)
            try FileManager.default.removeItem(at: markerURL)
            try faultInjector(.afterCompletedMarkerRemoval)
        }
        let journalURL = try exactChildURL(in: completedURL, named: RestoreJournalV1.journalBasename)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try verifyProtectedRegularFile(at: journalURL)
            try FileManager.default.removeItem(at: journalURL)
            try faultInjector(.afterCompletedJournalRemoval)
        }
        try faultInjector(.afterCompletedJSONRemoval)
        let remainingMembers = try activeMemberNames(at: completedURL)
        guard remainingMembers.isEmpty else {
            throw RestoreJournalError.transactionUnavailable
        }
        try durableWriter.synchronizeDirectory(at: completedURL)
        try faultInjector(.afterCompletedDirectorySync)
        try FileManager.default.removeItem(at: completedURL)
        try faultInjector(.afterCompletedDirectoryRemoval)
        try durableWriter.synchronizeDirectory(at: rootDirectory)
        try faultInjector(.afterCompletedCleanupRootSync)
    }

    private func activeMemberNames(at activeURL: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: activeURL.path).sorted()
    }

    private func ensureProtectedDirectory(at url: URL) throws {
        if pathEntryExists(at: url) {
            try verifyProtectedDirectory(at: url)
            return
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try setAndVerifyDirectoryProtection(at: url)
    }

    private func setAndVerifyDirectoryProtection(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: RestoreJournalV1.requiredProtectionClass],
            ofItemAtPath: url.path
        )
        try verifyProtectedDirectory(at: url)
    }

    private func verifyProtectedDirectory(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RestoreJournalError.transactionUnavailable
        }
        try verifyProtection(at: url)
    }

    private func verifyProtectedRegularFile(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RestoreJournalError.transactionUnavailable
        }
        try verifyProtection(at: url)
    }

    private func verifyProtection(at url: URL) throws {
        let observed = try protectionReader.protectionClass(at: url)
        if observed == RestoreJournalV1.requiredProtectionClass { return }
        #if targetEnvironment(simulator)
        if observed == nil { return }
        #endif
        throw RestoreJournalError.protectionMismatch
    }

    private func exactChildURL(in parent: URL, named basename: String) throws -> URL {
        try RestoreJournalCodecV1.validateBasename(basename)
        let standardizedParent = parent.standardizedFileURL
        let url = standardizedParent.appendingPathComponent(basename, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == standardizedParent else {
            throw RestoreJournalError.invalidBasename(basename)
        }
        return url
    }

    /// `fileExists` follows symlinks and returns false for a dangling one.
    /// Recovery must treat that path entry as present so the subsequent type
    /// validation fails closed instead of incorrectly returning `idle`.
    private func pathEntryExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) { return true }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func boundedData(at url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw RestoreJournalError.fileTooLarge(actual: data.count, limit: limit)
        }
        return data
    }

    private func isTransactionDirectory(_ basename: String, prefix: String) -> Bool {
        (try? transactionID(inDirectoryBasename: basename, prefix: prefix)) != nil
    }

    private func transactionID(
        inDirectoryBasename basename: String,
        prefix: String
    ) throws -> String {
        guard basename.hasPrefix(prefix) else {
            throw RestoreJournalError.transactionUnavailable
        }
        let identifier = String(basename.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: identifier), uuid.uuidString.lowercased() == identifier else {
            throw RestoreJournalError.transactionUnavailable
        }
        return identifier
    }

    private func reservedPartialKind(for basename: String) -> RestoreJournalFileKind? {
        for kind in [RestoreJournalFileKind.journal, .marker] {
            let prefix = ".\(kind.partialStem)."
            guard basename.hasPrefix(prefix), basename.hasSuffix(".partial") else { continue }
            let identifierStart = basename.index(basename.startIndex, offsetBy: prefix.count)
            let identifierEnd = basename.index(basename.endIndex, offsetBy: -".partial".count)
            let identifier = String(basename[identifierStart..<identifierEnd])
            guard let uuid = UUID(uuidString: identifier), uuid.uuidString.lowercased() == identifier else {
                continue
            }
            return kind
        }
        return nil
    }

    private func redactedReason(for error: Error) -> String {
        switch error {
        case RestoreJournalError.protectionMismatch:
            "protection-mismatch"
        case RestoreJournalError.invalidJSON, RestoreJournalError.nonCanonicalJSON,
             RestoreJournalError.checksumMismatch, RestoreJournalError.unsupportedVersion,
             RestoreJournalError.unsupportedChecksumAlgorithm, RestoreJournalError.wrongFormat:
            "untrusted-json"
        case RestoreJournalError.invalidBasename:
            "invalid-basename"
        case RestoreJournalError.fileTooLarge:
            "metadata-too-large"
        case RestoreJournalError.transactionUnavailable:
            "untrusted-transaction"
        default:
            "recovery-inspection-failed"
        }
    }
}

private extension RestoreJournalPhase {
    var requiresPortableArtifactOnDisk: Bool {
        switch self {
        case .preRestoreBackupVerified,
             .oldStoreCopyStarted,
             .oldStoreCopyVerified,
             .replacementStarted,
             .replacementReturned,
             .rollbackStarted:
            true
        case .prepared,
             .maintenanceAcquired,
             .newStoreVerifiedRemindersPending,
             .oldStoreVerifiedRemindersPending,
             .critical:
            false
        }
    }
}
