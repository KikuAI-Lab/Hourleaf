import CryptoKit
import Foundation
import XCTest
@testable import Hourleaf

final class RestoreJournalTests: XCTestCase {
    func testJournalCanonicalEncodingWritesEveryNullableKeyAsNull() throws {
        let content = preparedJournal()
        let verified = try RestoreJournalCodecV1.encode(content: content)
        let text = try XCTUnwrap(String(data: verified.data, encoding: .utf8))

        for key in [
            "aRecordsDigest",
            "aRecordCounts",
            "portableABasename",
            "portableAByteCount",
            "portableAChecksum",
            "portableARecordsDigest",
            "physicalAStoreUUID",
            "physicalARecordsDigest",
            "criticalFromPhase",
            "criticalReasonCode"
        ] {
            XCTAssertTrue(text.contains("\"\(key)\":null"), "Missing explicit null for \(key).")
        }
        XCTAssertEqual(try RestoreJournalCodecV1.decodeAndVerify(verified.data), verified)

        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerify(Data([0x20]) + verified.data)) {
            XCTAssertEqual($0 as? RestoreJournalError, .nonCanonicalJSON)
        }
    }

    func testJournalAndMarkerRejectChecksumVersionAndMissingNullableFields() throws {
        let journal = preparedJournal()
        let validJournal = try RestoreJournalCodecV1.encode(content: journal)
        let validMarker = try RestoreJournalCodecV1.encode(marker: RestoreJournalCodecV1.marker(for: journal))

        var wrongVersion = journal
        wrongVersion.version = 2
        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerify(try uncheckedJournalData(wrongVersion))) {
            XCTAssertEqual($0 as? RestoreJournalError, .unsupportedVersion(2))
        }

        var tamperedEnvelope = try JSONDecoder().decode(RestoreJournalEnvelopeV1.self, from: validJournal.data)
        tamperedEnvelope.checksum.value = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerify(try canonicalData(tamperedEnvelope))) {
            XCTAssertEqual($0 as? RestoreJournalError, .checksumMismatch)
        }

        var missingNullObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validJournal.data) as? [String: Any]
        )
        var missingNullContent = try XCTUnwrap(missingNullObject["content"] as? [String: Any])
        missingNullContent.removeValue(forKey: "physicalARecordsDigest")
        missingNullObject["content"] = missingNullContent
        let missingNullData = try JSONSerialization.data(withJSONObject: missingNullObject, options: [.sortedKeys])
        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerify(missingNullData)) {
            XCTAssertEqual($0 as? RestoreJournalError, .invalidJSON)
        }

        var badMarker = try JSONDecoder().decode(RestoreArmedEnvelopeV1.self, from: validMarker.data)
        badMarker.content.version = 2
        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerifyMarker(try uncheckedMarkerData(badMarker.content))) {
            XCTAssertEqual($0 as? RestoreJournalError, .unsupportedVersion(2))
        }

        var tamperedMarker = try JSONDecoder().decode(RestoreArmedEnvelopeV1.self, from: validMarker.data)
        tamperedMarker.checksum.value = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerifyMarker(try canonicalData(tamperedMarker))) {
            XCTAssertEqual($0 as? RestoreJournalError, .checksumMismatch)
        }
        XCTAssertThrowsError(try RestoreJournalCodecV1.decodeAndVerifyMarker(Data([0x20]) + validMarker.data)) {
            XCTAssertEqual($0 as? RestoreJournalError, .nonCanonicalJSON)
        }
    }

    func testStrictEvidenceRequirementsNoOpBoundaryAndTransitions() throws {
        let prepared = preparedJournal()
        var maintenance = prepared
        maintenance.phase = .maintenanceAcquired
        maintenance.sequence = 1
        maintenance.aRecordsDigest = prepared.candidateRecordsDigest // Legal only while deciding no-op.
        maintenance.aRecordCounts = prepared.candidateRecordCounts
        XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: maintenance))
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: prepared, to: maintenance))

        var impossibleAfterNoOp = maintenance
        impossibleAfterNoOp.phase = .preRestoreBackupVerified
        impossibleAfterNoOp.sequence = 2
        impossibleAfterNoOp.portableABasename = portableBasename()
        impossibleAfterNoOp.portableAByteCount = 1
        impossibleAfterNoOp.portableAChecksum = digest("p")
        impossibleAfterNoOp.portableARecordsDigest = maintenance.aRecordsDigest
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: impossibleAfterNoOp))

        var normalMaintenance = prepared
        normalMaintenance.phase = .maintenanceAcquired
        normalMaintenance.sequence = 1
        normalMaintenance.aRecordsDigest = digest("a")
        normalMaintenance.aRecordCounts = sampleCounts
        var portableA = normalMaintenance
        portableA.phase = .preRestoreBackupVerified
        portableA.sequence = 2
        portableA.portableABasename = portableBasename()
        portableA.portableAByteCount = 123
        portableA.portableAChecksum = digest("p")
        portableA.portableARecordsDigest = digest("a")
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: normalMaintenance, to: portableA))

        var copied = portableA
        copied.phase = .oldStoreCopyStarted
        copied.sequence = 3
        var evidence = copied
        evidence.phase = .oldStoreCopyVerified
        evidence.sequence = 4
        evidence.physicalAStoreUUID = physicalUUID
        evidence.physicalARecordsDigest = digest("a")
        var replacementStarted = evidence
        replacementStarted.phase = .replacementStarted
        replacementStarted.sequence = 5
        var replacementReturned = replacementStarted
        replacementReturned.phase = .replacementReturned
        replacementReturned.sequence = 6

        var rollbackFromStarted = replacementStarted
        rollbackFromStarted.phase = .rollbackStarted
        rollbackFromStarted.sequence = 6
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: replacementStarted, to: rollbackFromStarted))
        var rollbackFromReturned = replacementReturned
        rollbackFromReturned.phase = .rollbackStarted
        rollbackFromReturned.sequence = 7
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: replacementReturned, to: rollbackFromReturned))

        var bPending = replacementReturned
        bPending.phase = .newStoreVerifiedRemindersPending
        bPending.sequence = 7
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: replacementReturned, to: bPending))
        let encodedBPending = try RestoreJournalCodecV1.encode(content: bPending)
        XCTAssertEqual(try RestoreJournalCodecV1.decodeAndVerify(encodedBPending.data).content, bPending)

        var lateRollback = bPending
        lateRollback.phase = .rollbackStarted
        lateRollback.sequence = 8
        XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: lateRollback))
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: bPending, to: lateRollback))

        var lateAPending = lateRollback
        lateAPending.phase = .oldStoreVerifiedRemindersPending
        lateAPending.sequence = 9
        XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: lateAPending))
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: lateRollback, to: lateAPending))
        let encodedLateAPending = try RestoreJournalCodecV1.encode(content: lateAPending)
        XCTAssertEqual(try RestoreJournalCodecV1.decodeAndVerify(encodedLateAPending.data).content, lateAPending)

        var lateRollbackWrongSequence = bPending
        lateRollbackWrongSequence.phase = .rollbackStarted
        lateRollbackWrongSequence.sequence = 7
        XCTAssertThrowsError(
            try RestoreJournalCodecV1.validateTransition(from: bPending, to: lateRollbackWrongSequence)
        )
        var directAPending = bPending
        directAPending.phase = .oldStoreVerifiedRemindersPending
        directAPending.sequence = 8
        XCTAssertThrowsError(
            try RestoreJournalCodecV1.validateTransition(from: bPending, to: directAPending)
        )

        var critical = replacementStarted
        critical.phase = .critical
        critical.sequence = 6
        critical.criticalFromPhase = .replacementStarted
        critical.criticalReasonCode = "evidence-unavailable"
        XCTAssertNoThrow(try RestoreJournalCodecV1.validateTransition(from: replacementStarted, to: critical))
        XCTAssertFalse(RestoreJournalCodecV1.canTransition(from: .critical, to: .rollbackStarted))
    }

    func testPreRestoreBackupVerifiedDirectlySelectsAPendingSequence3() throws {
        try assertDirectAPending(
            from: .preRestoreBackupVerified,
            expectedSequence: 3,
            expectsPhysicalA: false
        )
    }

    func testOldStoreCopyStartedDirectlySelectsAPendingSequence4() throws {
        try assertDirectAPending(
            from: .oldStoreCopyStarted,
            expectedSequence: 4,
            expectsPhysicalA: false
        )
    }

    func testOldStoreCopyVerifiedDirectlySelectsAPendingSequence5() throws {
        try assertDirectAPending(
            from: .oldStoreCopyVerified,
            expectedSequence: 5,
            expectsPhysicalA: true
        )
    }

    func testAPendingSequence3And4ForbidPhysicalAEvidence() throws {
        for sequence in [Int64(3), 4] {
            let content = try aPendingJournal(sequence: sequence)
            XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: content))

            var inventedPhysical = content
            inventedPhysical.physicalAStoreUUID = physicalUUID
            inventedPhysical.physicalARecordsDigest = content.aRecordsDigest
            XCTAssertThrowsError(
                try RestoreJournalCodecV1.validate(content: inventedPhysical),
                "A-pending sequence \(sequence) must not invent physical-A evidence."
            )
        }
    }

    func testAPendingSequence5And7Through9RequirePhysicalAEvidence() throws {
        for sequence in [Int64(5), 7, 8, 9] {
            let content = try aPendingJournal(sequence: sequence)
            XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: content))

            var missingPhysical = content
            missingPhysical.physicalAStoreUUID = nil
            missingPhysical.physicalARecordsDigest = nil
            XCTAssertThrowsError(
                try RestoreJournalCodecV1.validate(content: missingPhysical),
                "A-pending sequence \(sequence) must retain physical-A evidence."
            )
        }
    }

    func testCriticalAPendingProjectionUsesSourceSequenceMinusOne() throws {
        for sourceSequence in [Int64(3), 4, 5, 7, 8, 9] {
            var critical = try aPendingJournal(sequence: sourceSequence)
            critical.phase = .critical
            critical.sequence = sourceSequence + 1
            critical.criticalFromPhase = .oldStoreVerifiedRemindersPending
            critical.criticalReasonCode = "recovery-evidence-failed"
            XCTAssertNoThrow(
                try RestoreJournalCodecV1.validate(content: critical),
                "Critical projection must use A-pending source sequence \(sourceSequence)."
            )

            if sourceSequence == 3 || sourceSequence == 4 {
                critical.physicalAStoreUUID = physicalUUID
                critical.physicalARecordsDigest = critical.aRecordsDigest
            } else {
                critical.physicalAStoreUUID = nil
                critical.physicalARecordsDigest = nil
            }
            XCTAssertThrowsError(
                try RestoreJournalCodecV1.validate(content: critical),
                "Critical projection accepted evidence for the wrong source sequence."
            )
        }
    }

    func testEvidenceMatrixRejectsFutureFieldsAndOversizedBackupEvidence() throws {
        let backup = try verifiedPortableA()
        let basename = portableBasename(for: backup)
        var maintenance = preparedJournal()
        maintenance.phase = .maintenanceAcquired
        maintenance.sequence = 1
        bindAEvidence(&maintenance, from: backup)
        XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: maintenance))

        var earlyPortable = maintenance
        bindPortableAEvidence(&earlyPortable, basename: basename, from: backup)
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: earlyPortable))

        var portable = maintenance
        portable.phase = .preRestoreBackupVerified
        portable.sequence = 2
        bindPortableAEvidence(&portable, basename: basename, from: backup)
        XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: portable))

        var futurePhysical = portable
        futurePhysical.physicalAStoreUUID = physicalUUID
        futurePhysical.physicalARecordsDigest = backup.recordsDigest
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: futurePhysical))

        var criticalFromPortable = portable
        criticalFromPortable.phase = .critical
        criticalFromPortable.sequence = 3
        criticalFromPortable.criticalFromPhase = .preRestoreBackupVerified
        criticalFromPortable.criticalReasonCode = "portable-verification-failed"
        XCTAssertNoThrow(try RestoreJournalCodecV1.validate(content: criticalFromPortable))
        criticalFromPortable.physicalAStoreUUID = physicalUUID
        criticalFromPortable.physicalARecordsDigest = backup.recordsDigest
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: criticalFromPortable))

        var afterNoOp = portable
        afterNoOp.aRecordsDigest = afterNoOp.candidateRecordsDigest
        afterNoOp.aRecordCounts = afterNoOp.candidateRecordCounts
        afterNoOp.portableARecordsDigest = afterNoOp.candidateRecordsDigest
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: afterNoOp))

        var oversizedCandidate = preparedJournal()
        oversizedCandidate.candidateBackupByteCount = HourleafBackupLimitsV1.maximumFileBytes + 1
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: oversizedCandidate))

        var oversizedPortable = portable
        oversizedPortable.portableAByteCount = HourleafBackupLimitsV1.maximumFileBytes + 1
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: oversizedPortable))

        var impossibleSequence = try journal(for: .replacementStarted)
        impossibleSequence.sequence = 4
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: impossibleSequence))
        var impossibleCriticalSequence = criticalFromPortable
        impossibleCriticalSequence.sequence = 4
        XCTAssertThrowsError(try RestoreJournalCodecV1.validate(content: impossibleCriticalSequence))
    }

    func testBasenameUUIDAndCriticalValidationRejectTraversalAndAmbiguity() throws {
        XCTAssertThrowsError(try RestoreJournalCodecV1.validateBasename("../journal-v1.json"))
        XCTAssertThrowsError(try RestoreJournalCodecV1.validateBasename("journal\\v1.json"))
        XCTAssertThrowsError(try RestoreJournalCodecV1.validateBasename("journal\u{0}v1.json"))
        XCTAssertThrowsError(try RestoreJournalCodecV1.validateBasename(String(repeating: "a", count: 256)))
        XCTAssertNoThrow(try RestoreJournalCodecV1.validatePortableABasename(portableBasename()))
        XCTAssertNoThrow(
            try RestoreJournalCodecV1.portableAPartialName(
                for: ".Hourleaf-Backup-00000000-0000-0000-0000-000000000003.partial"
            )
        )
        XCTAssertThrowsError(try RestoreJournalCodecV1.validatePortableABasename("Hourleaf-Backup-a.hourleafbackup"))
        XCTAssertThrowsError(
            try RestoreJournalCodecV1.portableAPartialName(
                for: ".Hourleaf-Backup-00000000-0000-0000-0000-00000000000A.partial"
            )
        )

        var traversal = preparedJournal()
        traversal.candidateBackupBasename = "../candidate.hourleafbackup"
        XCTAssertThrowsError(try RestoreJournalCodecV1.encode(content: traversal))

        var uppercaseID = preparedJournal()
        uppercaseID.transactionID = uppercaseID.transactionID.uppercased()
        XCTAssertThrowsError(try RestoreJournalCodecV1.encode(content: uppercaseID))

        var invalidCritical = preparedJournal()
        invalidCritical.phase = .critical
        invalidCritical.sequence = 1
        invalidCritical.criticalFromPhase = .prepared
        invalidCritical.criticalReasonCode = "not a stable reason"
        XCTAssertThrowsError(try RestoreJournalCodecV1.encode(content: invalidCritical))
    }

    func testCompleteAcceptsOnlyFourCorrectedTerminalPairs() throws {
        let allowed: [(RestoreJournalPhase, RestoreTerminalTargetV1)] = [
            (.prepared, .unstarted),
            (.maintenanceAcquired, .a),
            (.newStoreVerifiedRemindersPending, .b),
            (.oldStoreVerifiedRemindersPending, .a)
        ]
        let targets: [RestoreTerminalTargetV1] = [.unstarted, .a, .b]

        for phase in RestoreJournalPhase.allCases {
            let content = try journal(for: phase)
            for target in targets {
                let operation = {
                    try RestoreJournalCodecV1.validateTerminalDecision(
                        self.terminalDecision(for: content, target: target),
                        against: content
                    )
                }
                if allowed.contains(where: { $0.0 == phase && $0.1 == target }) {
                    XCTAssertNoThrow(
                        try operation(),
                        "Expected \(phase) -> \(target) to be terminalizable."
                    )
                } else {
                    XCTAssertThrowsError(
                        try operation(),
                        "Unexpected terminal pair \(phase) -> \(target)."
                    )
                }
            }
        }

        let bPending = try journal(for: .newStoreVerifiedRemindersPending)
        var wrongEvidence = terminalDecision(for: bPending, target: .b)
        wrongEvidence = RestoreTerminalDecisionV1(
            transactionID: wrongEvidence.transactionID,
            sourcePhase: wrongEvidence.sourcePhase,
            target: .b,
            recordsDigest: digest("wrong"),
            recordCounts: wrongEvidence.recordCounts
        )
        XCTAssertThrowsError(
            try RestoreJournalCodecV1.validateTerminalDecision(wrongEvidence, against: bPending)
        )
    }

    func testCompleteRejectsEveryJournalBoundPrePendingAndIntermediatePhase() throws {
        let forbiddenPhases: [RestoreJournalPhase] = [
            .preRestoreBackupVerified,
            .oldStoreCopyStarted,
            .oldStoreCopyVerified,
            .replacementStarted,
            .replacementReturned,
            .rollbackStarted
        ]
        for phase in forbiddenPhases {
            let content = try journal(for: phase)
            for target in [RestoreTerminalTargetV1.unstarted, .a, .b] {
                XCTAssertThrowsError(
                    try RestoreJournalCodecV1.validateTerminalDecision(
                        terminalDecision(for: content, target: target),
                        against: content
                    ),
                    "Pre-pending/intermediate phase \(phase) terminalized as \(target)."
                )
            }
        }
    }

    func testMissingPortableABeforePendingIsCriticalForEveryDirectSource() throws {
        let backup = try verifiedPortableA()
        for source in directAPendingSources {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent(source.rawValue, isDirectory: true)
            let store = makeStore(root: root)
            let basename = try advanceToDirectAPendingSource(store, source: source, backup: backup)
            let portableURL = root.appendingPathComponent("active/\(basename)")
            try FileManager.default.removeItem(at: portableURL)

            XCTAssertEqual(
                try makeStore(root: root).inspectBeforeStoreLoad(),
                .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction")),
                "Missing portable A before \(source) became trusted."
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: portableURL.path))
        }
    }

    func testMissingPortableAAfterDirectPendingRemainsTrustedAndCompletesA() throws {
        let backup = try verifiedPortableA()
        for source in directAPendingSources {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent(source.rawValue, isDirectory: true)
            let store = makeStore(root: root)
            let basename = try advanceToDirectAPendingSource(store, source: source, backup: backup)
            try store.advance(to: .oldStoreVerifiedRemindersPending) { _ in }

            let portableURL = root.appendingPathComponent("active/\(basename)")
            try FileManager.default.removeItem(at: portableURL)
            let fresh = makeStore(root: root)
            let recovered = try recoveredTransaction(fresh)
            XCTAssertEqual(recovered.journal.content.phase, .oldStoreVerifiedRemindersPending)
            XCTAssertEqual(recovered.journal.content.sequence, directAPendingSequence(after: source))
            XCTAssertFalse(FileManager.default.fileExists(atPath: portableURL.path))

            try fresh.complete(try terminalDecision(from: fresh, target: .a))
            XCTAssertEqual(try fresh.inspectBeforeStoreLoad(), .idle)
        }
    }

    func testDirectPendingJournalFaultLeavesOldOrNewTrustedStateWithPortableA() throws {
        let backup = try verifiedPortableA()
        let faultPoints: [RestoreJournalFaultPoint] = [
            .afterPayloadWrite(.journal),
            .afterFileSync(.journal),
            .afterPartialReadback(.journal),
            .afterRename(.journal),
            .afterDirectorySync(.journal),
            .afterFinalReadback(.journal)
        ]
        let newJournalFaultPoints: [RestoreJournalFaultPoint] = [
            .afterRename(.journal),
            .afterDirectorySync(.journal),
            .afterFinalReadback(.journal)
        ]

        for source in directAPendingSources {
            for point in faultPoints {
                let sandbox = try makeSandbox()
                defer { try? FileManager.default.removeItem(at: sandbox) }
                let root = sandbox.appendingPathComponent(
                    "\(source.rawValue)-\(UUID().uuidString)",
                    isDirectory: true
                )
                let normal = makeStore(root: root)
                let basename = try advanceToDirectAPendingSource(normal, source: source, backup: backup)
                let sourceJournal = try recoveredTransaction(normal).journal.content
                let portableURL = root.appendingPathComponent("active/\(basename)")
                let portableBytes = try Data(contentsOf: portableURL)
                let failing = makeStore(root: root, faultInjector: { observed in
                    if observed == point { throw JournalInjectedFailure.failed }
                })

                XCTAssertThrowsError(
                    try failing.advance(to: .oldStoreVerifiedRemindersPending) { _ in },
                    "Expected injected write fault \(point) from \(source)."
                )
                let recovered = try recoveredTransaction(makeStore(root: root))
                if newJournalFaultPoints.contains(point) {
                    XCTAssertEqual(recovered.journal.content.phase, .oldStoreVerifiedRemindersPending)
                    XCTAssertEqual(
                        recovered.journal.content.sequence,
                        directAPendingSequence(after: source)
                    )
                } else {
                    XCTAssertEqual(recovered.journal.content.phase, source)
                    XCTAssertEqual(recovered.journal.content.sequence, sourceJournal.sequence)
                }
                XCTAssertEqual(try Data(contentsOf: portableURL), portableBytes)
            }
        }
    }

    func testArmAdvanceAndTerminalCleanupUseTrustedCanonicalFiles() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        let prepared = preparedJournal()
        let portableA = try verifiedPortableA()

        try store.arm(prepared)
        let active = root.appendingPathComponent("active", isDirectory: true)
        XCTAssertEqual(try names(in: active), ["armed-v1.json", "journal-v1.json"])
        try assertRecover(store, phase: .prepared)

        try store.advance(to: .maintenanceAcquired) { journal in
            bindAEvidence(&journal, from: portableA)
        }
        try assertRecover(store, phase: .maintenanceAcquired)

        let portableName = portableBasename(for: portableA)
        try portableA.data.write(to: active.appendingPathComponent(portableName))
        try store.advance(to: .preRestoreBackupVerified) { journal in
            bindPortableAEvidence(&journal, basename: portableName, from: portableA)
        }
        try store.advance(to: .oldStoreCopyStarted) { _ in }
        try store.advance(to: .oldStoreCopyVerified) { journal in
            journal.physicalAStoreUUID = physicalUUID
            journal.physicalARecordsDigest = portableA.recordsDigest
        }
        try store.advance(to: .replacementStarted) { _ in }
        try store.advance(to: .replacementReturned) { _ in }
        try store.advance(to: .newStoreVerifiedRemindersPending) { _ in }
        try FileManager.default.removeItem(at: active.appendingPathComponent(portableName))

        try store.complete(try terminalDecision(from: store, target: .b))
        XCTAssertFalse(FileManager.default.fileExists(atPath: active.path))
        XCTAssertEqual(try names(in: root), [])
        XCTAssertEqual(try store.inspectBeforeStoreLoad(), .idle)
    }

    func testPreparedAndExplicitNoOpCanTerminalizeWithoutReplacement() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let preparedRoot = sandbox.appendingPathComponent("prepared", isDirectory: true)
        let preparedStore = makeStore(root: preparedRoot)
        try preparedStore.arm(preparedJournal())
        try preparedStore.complete(try terminalDecision(from: preparedStore, target: .unstarted))
        XCTAssertEqual(try preparedStore.inspectBeforeStoreLoad(), .idle)

        let noOpRoot = sandbox.appendingPathComponent("no-op", isDirectory: true)
        let noOpStore = makeStore(root: noOpRoot)
        let prepared = preparedJournal()
        try noOpStore.arm(prepared)
        try noOpStore.advance(to: .maintenanceAcquired) { journal in
            journal.aRecordsDigest = prepared.candidateRecordsDigest
            journal.aRecordCounts = prepared.candidateRecordCounts
        }
        try noOpStore.complete(try terminalDecision(from: noOpStore, target: .a))
        XCTAssertEqual(try noOpStore.inspectBeforeStoreLoad(), .idle)
    }

    func testMarkerBoundCreatedAtMutationFailsBeforeJournalReplacement() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        try store.arm(preparedJournal())
        let journalURL = root.appendingPathComponent("active/journal-v1.json")
        let original = try Data(contentsOf: journalURL)
        let backup = try verifiedPortableA()

        XCTAssertThrowsError(
            try store.advance(to: .maintenanceAcquired) { journal in
                bindAEvidence(&journal, from: backup)
                journal.createdAtMilliseconds += 1
            }
        ) { error in
            XCTAssertEqual(error as? RestoreJournalError, .invalidTransition)
        }
        XCTAssertEqual(try Data(contentsOf: journalURL), original)
        try assertRecover(store, phase: .prepared)
    }

    func testWriterFaultsPreserveReservedPartialOrTrustedFinalBeforeActive() throws {
        for point in [
            RestoreJournalFaultPoint.afterFileSync(.journal),
            .afterPartialReadback(.journal),
            .afterRename(.journal),
            .afterDirectorySync(.journal),
            .afterFinalReadback(.journal)
        ] {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
            let store = makeStore(root: root, faultInjector: { observed in
                if observed == point { throw JournalInjectedFailure.failed }
            })

            XCTAssertThrowsError(try store.arm(preparedJournal()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("active").path))
            let arming = try XCTUnwrap(try names(in: root).first(where: { $0.hasPrefix(".arming-") }))
            let members = try names(in: root.appendingPathComponent(arming, isDirectory: true))
            switch point {
            case .afterFileSync, .afterPartialReadback:
                XCTAssertEqual(members.count, 1)
                XCTAssertTrue(members[0].hasPrefix(".journal-v1."))
                XCTAssertTrue(members[0].hasSuffix(".partial"))
            case .afterRename, .afterDirectorySync, .afterFinalReadback:
                XCTAssertEqual(members, ["journal-v1.json"])
            default:
                XCTFail("Unexpected test fault point")
            }
            XCTAssertEqual(try store.inspectBeforeStoreLoad(), .idle)
        }
    }

    func testMarkerWritesAndActivePromotionFaultsRemainInspectableAfterReinstantiation() throws {
        for point in [
            RestoreJournalFaultPoint.afterFileSync(.marker),
            .afterPartialReadback(.marker),
            .afterRename(.marker),
            .afterDirectorySync(.marker),
            .afterFinalReadback(.marker)
        ] {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent("marker-\(UUID().uuidString)", isDirectory: true)
            let failing = makeStore(root: root, faultInjector: { observed in
                if observed == point { throw JournalInjectedFailure.failed }
            })
            XCTAssertThrowsError(try failing.arm(preparedJournal()))
            XCTAssertEqual(try makeStore(root: root).inspectBeforeStoreLoad(), .idle)
        }

        for point in [
            RestoreJournalFaultPoint.afterArmingDirectorySync,
            .afterActiveRename,
            .afterRecoveryRootSync
        ] {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent("promotion-\(UUID().uuidString)", isDirectory: true)
            let failing = makeStore(root: root, faultInjector: { observed in
                if observed == point { throw JournalInjectedFailure.failed }
            })
            XCTAssertThrowsError(try failing.arm(preparedJournal()))
            let fresh = makeStore(root: root)
            if point == .afterArmingDirectorySync {
                XCTAssertEqual(try fresh.inspectBeforeStoreLoad(), .idle)
            } else {
                try assertRecover(fresh, phase: .prepared)
            }
        }
    }

    func testInActiveJournalReplacementFaultsKeepOldOrNewTrustedPhase() throws {
        for point in [
            RestoreJournalFaultPoint.afterPayloadWrite(.journal),
            .afterFileSync(.journal),
            .afterPartialReadback(.journal),
            .afterRename(.journal),
            .afterDirectorySync(.journal),
            .afterFinalReadback(.journal)
        ] {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent("replace-\(UUID().uuidString)", isDirectory: true)
            let normal = makeStore(root: root)
            try normal.arm(preparedJournal())
            let backup = try verifiedPortableA()
            let failing = makeStore(root: root, faultInjector: { observed in
                if observed == point { throw JournalInjectedFailure.failed }
            })
            XCTAssertThrowsError(
                try failing.advance(to: .maintenanceAcquired) { journal in
                    bindAEvidence(&journal, from: backup)
                }
            )
            let fresh = makeStore(root: root)
            switch point {
            case .afterRename, .afterDirectorySync, .afterFinalReadback:
                try assertRecover(fresh, phase: .maintenanceAcquired)
            default:
                try assertRecover(fresh, phase: .prepared)
            }
        }
    }

    func testTerminalCleanupFaultsAreIdempotentAndPreflightNeverCleans() throws {
        for point in [
            RestoreJournalFaultPoint.afterCompletedRename,
            .afterCompletedRootSync,
            .afterCompletedMarkerRemoval,
            .afterCompletedJournalRemoval,
            .afterCompletedJSONRemoval,
            .afterCompletedDirectorySync,
            .afterCompletedDirectoryRemoval,
            .afterCompletedCleanupRootSync
        ] {
            let sandbox = try makeSandbox()
            defer { try? FileManager.default.removeItem(at: sandbox) }
            let root = sandbox.appendingPathComponent("terminal-\(UUID().uuidString)", isDirectory: true)
            let failing = makeStore(root: root, faultInjector: { observed in
                if observed == point { throw JournalInjectedFailure.failed }
            })
            try failing.arm(preparedJournal())
            let decision = try terminalDecision(from: failing, target: .unstarted)
            XCTAssertThrowsError(try failing.complete(decision))

            let fresh = makeStore(root: root)
            let beforeInspection = try names(in: root)
            XCTAssertEqual(try fresh.inspectBeforeStoreLoad(), .idle)
            XCTAssertEqual(try names(in: root), beforeInspection)
            try fresh.cleanupCompletedTransactions()
            XCTAssertEqual(try names(in: root), [])
        }
    }

    func testFreshStoreReinstantiatesEveryDurableRecoveryPhase() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let backup = try verifiedPortableA()
        let root = sandbox.appendingPathComponent("normal", isDirectory: true)
        let store = makeStore(root: root)
        try store.arm(preparedJournal())
        try assertRecover(makeStore(root: root), phase: .prepared)
        try store.advance(to: .maintenanceAcquired) { journal in
            bindAEvidence(&journal, from: backup)
        }
        try assertRecover(makeStore(root: root), phase: .maintenanceAcquired)
        let active = root.appendingPathComponent("active", isDirectory: true)
        let basename = portableBasename(for: backup)
        try backup.data.write(to: active.appendingPathComponent(basename))
        try assertRecover(makeStore(root: root), phase: .maintenanceAcquired)
        try store.advance(to: .preRestoreBackupVerified) { journal in
            bindPortableAEvidence(&journal, basename: basename, from: backup)
        }
        try assertRecover(makeStore(root: root), phase: .preRestoreBackupVerified)
        try store.advance(to: .oldStoreCopyStarted) { _ in }
        try assertRecover(makeStore(root: root), phase: .oldStoreCopyStarted)
        try store.advance(to: .oldStoreCopyVerified) { journal in
            journal.physicalAStoreUUID = physicalUUID
            journal.physicalARecordsDigest = backup.recordsDigest
        }
        try assertRecover(makeStore(root: root), phase: .oldStoreCopyVerified)
        try store.advance(to: .replacementStarted) { _ in }
        try assertRecover(makeStore(root: root), phase: .replacementStarted)
        try store.advance(to: .replacementReturned) { _ in }
        try assertRecover(makeStore(root: root), phase: .replacementReturned)
        try store.advance(to: .newStoreVerifiedRemindersPending) { _ in }
        try assertRecover(makeStore(root: root), phase: .newStoreVerifiedRemindersPending)
        let bPendingJournalURL = active.appendingPathComponent("journal-v1.json")
        let bPendingJournal = try Data(contentsOf: bPendingJournalURL)
        XCTAssertThrowsError(
            try store.advance(to: .oldStoreVerifiedRemindersPending) { _ in }
        )
        XCTAssertThrowsError(try store.complete(try terminalDecision(from: store, target: .a)))
        XCTAssertEqual(try Data(contentsOf: bPendingJournalURL), bPendingJournal)
        try store.advance(to: .rollbackStarted) { _ in }
        let lateRollback = try recoveredTransaction(makeStore(root: root))
        XCTAssertEqual(lateRollback.journal.content.phase, .rollbackStarted)
        XCTAssertEqual(lateRollback.journal.content.sequence, 8)
        try store.advance(to: .oldStoreVerifiedRemindersPending) { _ in }
        let lateAPending = try recoveredTransaction(makeStore(root: root))
        XCTAssertEqual(lateAPending.journal.content.phase, .oldStoreVerifiedRemindersPending)
        XCTAssertEqual(lateAPending.journal.content.sequence, 9)

        let rollbackRoot = sandbox.appendingPathComponent("rollback", isDirectory: true)
        let rollbackStore = makeStore(root: rollbackRoot)
        try armMaintenance(rollbackStore, backup: backup)
        let rollbackActive = rollbackRoot.appendingPathComponent("active", isDirectory: true)
        try backup.data.write(to: rollbackActive.appendingPathComponent(basename))
        try rollbackStore.advance(to: .preRestoreBackupVerified) { journal in
            bindPortableAEvidence(&journal, basename: basename, from: backup)
        }
        try rollbackStore.advance(to: .oldStoreCopyStarted) { _ in }
        try rollbackStore.advance(to: .oldStoreCopyVerified) { journal in
            journal.physicalAStoreUUID = physicalUUID
            journal.physicalARecordsDigest = backup.recordsDigest
        }
        try rollbackStore.advance(to: .replacementStarted) { _ in }
        try rollbackStore.advance(to: .rollbackStarted) { _ in }
        let rollback = try recoveredTransaction(makeStore(root: rollbackRoot))
        XCTAssertEqual(rollback.journal.content.phase, .rollbackStarted)
        XCTAssertEqual(rollback.journal.content.sequence, 6)
        try rollbackStore.advance(to: .oldStoreVerifiedRemindersPending) { _ in }
        let aPending = try recoveredTransaction(makeStore(root: rollbackRoot))
        XCTAssertEqual(aPending.journal.content.phase, .oldStoreVerifiedRemindersPending)
        XCTAssertEqual(aPending.journal.content.sequence, 7)
    }

    func testPreflightIsReadOnlyAndReservedPartialNeedsTrustedFinal() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        try store.arm(preparedJournal())
        let active = root.appendingPathComponent("active", isDirectory: true)
        let partial = active.appendingPathComponent(".journal-v1.00000000-0000-0000-0000-000000000007.partial")
        let partialBytes = Data("unfinished journal".utf8)
        try partialBytes.write(to: partial)

        guard case let .recover(transaction) = try store.inspectBeforeStoreLoad() else {
            return XCTFail("Trusted final plus reserved partial must remain recoverable.")
        }
        XCTAssertEqual(transaction.trustedReservedPartials, [partial.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes, "Preflight must not remove a partial.")
        let storing: any RestoreJournalStoring = store
        try storing.removeTrustedReservedPartials()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

        try Data("unexpected".utf8).write(to: active.appendingPathComponent("unexpected"))
        XCTAssertEqual(
            try store.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: active.appendingPathComponent("unexpected").path))
    }

    func testDefaultRecoveryRootFailsClosedWithoutFallbackOrDirectoryCreation() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let applicationSupport = sandbox.appendingPathComponent("Application Support", isDirectory: true)
        let expected = applicationSupport.appendingPathComponent("RestoreRecovery", isDirectory: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.path))
        XCTAssertEqual(
            try RestoreJournalStoreV1.defaultRecoveryRoot(
                applicationSupportDirectory: { applicationSupport }
            ),
            expected
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertThrowsError(
            try RestoreJournalStoreV1.defaultRecoveryRoot(applicationSupportDirectory: { nil })
        ) {
            XCTAssertEqual($0 as? RestoreJournalError, .applicationSupportUnavailable)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
    }

    func testMaintenanceExporterWindowsAndHardLinkedPublishedPairAreRecoverable() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let backup = try verifiedPortableA()
        let finalName = portableBasename(for: backup)
        let partialName = ".Hourleaf-Backup-00000000-0000-0000-0000-000000000003.partial"

        let finalRoot = sandbox.appendingPathComponent("final", isDirectory: true)
        let finalStore = makeStore(root: finalRoot)
        try armMaintenance(finalStore, backup: backup)
        let finalURL = finalRoot.appendingPathComponent("active/\(finalName)")
        try backup.data.write(to: finalURL)
        let finalTransaction = try recoveredTransaction(finalStore)
        XCTAssertEqual(finalTransaction.provisionalPortableAArtifacts, .single(.final(finalName)))
        let decision = try terminalDecision(from: finalStore, target: .a)
        try finalStore.discardProvisionalPortableAArtifacts(afterProvingLiveA: decision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        try finalStore.complete(decision)
        XCTAssertEqual(try finalStore.inspectBeforeStoreLoad(), .idle)

        let partialRoot = sandbox.appendingPathComponent("partial", isDirectory: true)
        let partialStore = makeStore(root: partialRoot)
        try armMaintenance(partialStore, backup: backup)
        let partialURL = partialRoot.appendingPathComponent("active/\(partialName)")
        let partialBytes = Data("incomplete portable A".utf8)
        try partialBytes.write(to: partialURL)
        let partialTransaction = try recoveredTransaction(partialStore)
        XCTAssertEqual(partialTransaction.provisionalPortableAArtifacts, .single(.partial(partialName)))
        XCTAssertEqual(try Data(contentsOf: partialURL), partialBytes)

        let pairRoot = sandbox.appendingPathComponent("published-pair", isDirectory: true)
        let pairStore = makeStore(root: pairRoot)
        try armMaintenance(pairStore, backup: backup)
        let pairFinal = pairRoot.appendingPathComponent("active/\(finalName)")
        let pairPartial = pairRoot.appendingPathComponent("active/\(partialName)")
        try backup.data.write(to: pairPartial)
        try FileManager.default.linkItem(at: pairPartial, to: pairFinal)
        let finalBeforeRecovery = try Data(contentsOf: pairFinal)
        let partialBeforeRecovery = try Data(contentsOf: pairPartial)
        let pairTransaction = try recoveredTransaction(pairStore)
        XCTAssertEqual(
            pairTransaction.provisionalPortableAArtifacts,
            .publishedPair(final: .final(finalName), partial: .partial(partialName))
        )
        XCTAssertEqual(try Data(contentsOf: pairFinal), finalBeforeRecovery)
        XCTAssertEqual(try Data(contentsOf: pairPartial), partialBeforeRecovery)

        let pairDecision = try terminalDecision(from: pairStore, target: .a)
        let failingPairStore = makeStore(root: pairRoot) { point in
            if point == .afterProvisionalPortableAFirstRemoval {
                throw JournalInjectedFailure.failed
            }
        }
        XCTAssertThrowsError(
            try failingPairStore.discardProvisionalPortableAArtifacts(afterProvingLiveA: pairDecision)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairFinal.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pairPartial.path))
        XCTAssertEqual(try Data(contentsOf: pairPartial), partialBeforeRecovery)

        let recoveredAfterFirstRemoval = makeStore(root: pairRoot)
        let survivorTransaction = try recoveredTransaction(recoveredAfterFirstRemoval)
        XCTAssertEqual(survivorTransaction.provisionalPortableAArtifacts, .single(.partial(partialName)))
        XCTAssertEqual(try Data(contentsOf: pairPartial), partialBeforeRecovery)
        try recoveredAfterFirstRemoval.discardProvisionalPortableAArtifacts(afterProvingLiveA: pairDecision)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pairPartial.path))
        try recoveredAfterFirstRemoval.discardProvisionalPortableAArtifacts(afterProvingLiveA: pairDecision)
        try recoveredAfterFirstRemoval.complete(pairDecision)
        XCTAssertEqual(try recoveredAfterFirstRemoval.inspectBeforeStoreLoad(), .idle)

        let separateRoot = sandbox.appendingPathComponent("separate-files", isDirectory: true)
        let separateStore = makeStore(root: separateRoot)
        try armMaintenance(separateStore, backup: backup)
        let separateFinal = separateRoot.appendingPathComponent("active/\(finalName)")
        let separatePartial = separateRoot.appendingPathComponent("active/\(partialName)")
        try backup.data.write(to: separateFinal)
        try backup.data.write(to: separatePartial)
        let separateFinalBefore = try Data(contentsOf: separateFinal)
        let separatePartialBefore = try Data(contentsOf: separatePartial)
        XCTAssertEqual(
            try separateStore.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )
        XCTAssertEqual(try Data(contentsOf: separateFinal), separateFinalBefore)
        XCTAssertEqual(try Data(contentsOf: separatePartial), separatePartialBefore)

        let checksumMismatchRoot = sandbox.appendingPathComponent("checksum-mismatch", isDirectory: true)
        let checksumMismatchStore = makeStore(root: checksumMismatchRoot)
        try armMaintenance(checksumMismatchStore, backup: backup)
        let checksumMismatchPartial = checksumMismatchRoot.appendingPathComponent("active/\(partialName)")
        let mismatchedChecksumPrefix = backup.checksum.value.hasPrefix("deadbeef")
            ? "feedface"
            : "deadbeef"
        let checksumMismatchFinal = checksumMismatchRoot.appendingPathComponent(
            "active/\(portableBasename(checksumPrefix: mismatchedChecksumPrefix))"
        )
        try backup.data.write(to: checksumMismatchPartial)
        try FileManager.default.linkItem(at: checksumMismatchPartial, to: checksumMismatchFinal)
        XCTAssertEqual(
            try checksumMismatchStore.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )

        let extraRoot = sandbox.appendingPathComponent("extra-artifact", isDirectory: true)
        let extraStore = makeStore(root: extraRoot)
        try armMaintenance(extraStore, backup: backup)
        let extraActive = extraRoot.appendingPathComponent("active", isDirectory: true)
        let extraPartial = extraActive.appendingPathComponent(partialName)
        try backup.data.write(to: extraPartial)
        try FileManager.default.linkItem(
            at: extraPartial,
            to: extraActive.appendingPathComponent(finalName)
        )
        try Data("unexpected exporter member".utf8).write(
            to: extraActive.appendingPathComponent(
                ".Hourleaf-Backup-00000000-0000-0000-0000-000000000004.partial"
            )
        )
        XCTAssertEqual(
            try extraStore.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )

        let wrongNameRoot = sandbox.appendingPathComponent("wrong-name", isDirectory: true)
        let wrongNameStore = makeStore(root: wrongNameRoot)
        try armMaintenance(wrongNameStore, backup: backup)
        let wrongNameURL = wrongNameRoot.appendingPathComponent("active/.Hourleaf-Backup-not-a-uuid.partial")
        try backup.data.write(to: wrongNameURL)
        XCTAssertEqual(
            try wrongNameStore.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )

        let wrongProtectionRoot = sandbox.appendingPathComponent("wrong-protection", isDirectory: true)
        let wrongProtectionStore = makeStore(root: wrongProtectionRoot)
        try armMaintenance(wrongProtectionStore, backup: backup)
        let wrongProtectionFinal = wrongProtectionRoot.appendingPathComponent("active/\(finalName)")
        let wrongProtectionPartial = wrongProtectionRoot.appendingPathComponent("active/\(partialName)")
        try backup.data.write(to: wrongProtectionPartial)
        try FileManager.default.linkItem(at: wrongProtectionPartial, to: wrongProtectionFinal)
        let mismatchedProtectionStore = makeStore(
            root: wrongProtectionRoot,
            protectionReader: PathSensitiveJournalProtectionReader(
                mismatchedPaths: [wrongProtectionPartial.standardizedFileURL.path]
            )
        )
        XCTAssertEqual(
            try mismatchedProtectionStore.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "protection-mismatch"))
        )
    }

    func testPortableABindingRejectsPartialOrMismatchedEvidenceBeforeJournalWrite() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let backup = try verifiedPortableA()
        let finalName = portableBasename(for: backup)

        let root = sandbox.appendingPathComponent("binding", isDirectory: true)
        let store = makeStore(root: root)
        try armMaintenance(store, backup: backup)
        let active = root.appendingPathComponent("active", isDirectory: true)
        try backup.data.write(to: active.appendingPathComponent(finalName))
        let journalURL = active.appendingPathComponent("journal-v1.json")
        let before = try Data(contentsOf: journalURL)
        XCTAssertThrowsError(
            try store.advance(to: .preRestoreBackupVerified) { journal in
                bindPortableAEvidence(&journal, basename: finalName, from: backup)
                journal.portableAByteCount = backup.byteCount + 1
            }
        )
        XCTAssertEqual(try Data(contentsOf: journalURL), before)
        try store.advance(to: .preRestoreBackupVerified) { journal in
            bindPortableAEvidence(&journal, basename: finalName, from: backup)
        }
        try assertRecover(store, phase: .preRestoreBackupVerified)

        let pairRoot = sandbox.appendingPathComponent("binding-published-pair", isDirectory: true)
        let pairStore = makeStore(root: pairRoot)
        try armMaintenance(pairStore, backup: backup)
        let pairPartialName = ".Hourleaf-Backup-00000000-0000-0000-0000-000000000004.partial"
        let pairActive = pairRoot.appendingPathComponent("active", isDirectory: true)
        let pairPartial = pairActive.appendingPathComponent(pairPartialName)
        let pairFinal = pairActive.appendingPathComponent(finalName)
        try backup.data.write(to: pairPartial)
        try FileManager.default.linkItem(at: pairPartial, to: pairFinal)
        XCTAssertEqual(
            try recoveredTransaction(pairStore).provisionalPortableAArtifacts,
            .publishedPair(final: .final(finalName), partial: .partial(pairPartialName))
        )
        let pairJournal = try Data(contentsOf: pairActive.appendingPathComponent("journal-v1.json"))
        XCTAssertThrowsError(
            try pairStore.advance(to: .preRestoreBackupVerified) { journal in
                bindPortableAEvidence(&journal, basename: finalName, from: backup)
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: pairActive.appendingPathComponent("journal-v1.json")),
            pairJournal
        )

        let ambiguousRoot = sandbox.appendingPathComponent("binding-ambiguous", isDirectory: true)
        let ambiguousStore = makeStore(root: ambiguousRoot)
        try armMaintenance(ambiguousStore, backup: backup)
        let ambiguousActive = ambiguousRoot.appendingPathComponent("active", isDirectory: true)
        try backup.data.write(to: ambiguousActive.appendingPathComponent(finalName))
        try Data().write(
            to: ambiguousActive.appendingPathComponent(
                ".Hourleaf-Backup-00000000-0000-0000-0000-000000000004.partial"
            )
        )
        let ambiguousJournal = try Data(contentsOf: ambiguousActive.appendingPathComponent("journal-v1.json"))
        XCTAssertThrowsError(
            try ambiguousStore.advance(to: .preRestoreBackupVerified) { journal in
                bindPortableAEvidence(&journal, basename: finalName, from: backup)
            }
        )
        XCTAssertEqual(
            try Data(contentsOf: ambiguousActive.appendingPathComponent("journal-v1.json")),
            ambiguousJournal
        )
    }

    func testTrustedCriticalJournalBlocksRecoveryWithoutRewritingBytes() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        let backup = try verifiedPortableA()
        try armMaintenance(store, backup: backup)
        try store.advance(to: .critical) { journal in
            journal.criticalFromPhase = .maintenanceAcquired
            journal.criticalReasonCode = "live-store-unreadable"
        }
        let journalURL = root.appendingPathComponent("active/journal-v1.json")
        let before = try Data(contentsOf: journalURL)
        XCTAssertEqual(
            try store.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "live-store-unreadable"))
        )
        XCTAssertEqual(try Data(contentsOf: journalURL), before)
    }

    func testCompleteRejectsWrongProofAndReplacementReturnedAWithoutChangingActive() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        let backup = try verifiedPortableA()
        try armMaintenance(store, backup: backup)
        let active = root.appendingPathComponent("active", isDirectory: true)
        let portableName = portableBasename(for: backup)
        try backup.data.write(to: active.appendingPathComponent(portableName))
        try store.advance(to: .preRestoreBackupVerified) { journal in
            bindPortableAEvidence(&journal, basename: portableName, from: backup)
        }
        try store.advance(to: .oldStoreCopyStarted) { _ in }
        try store.advance(to: .oldStoreCopyVerified) { journal in
            journal.physicalAStoreUUID = physicalUUID
            journal.physicalARecordsDigest = backup.recordsDigest
        }
        try store.advance(to: .replacementStarted) { _ in }
        let journalURL = active.appendingPathComponent("journal-v1.json")
        let before = try Data(contentsOf: journalURL)
        var wrongB = try terminalDecision(from: store, target: .b)
        wrongB = RestoreTerminalDecisionV1(
            transactionID: wrongB.transactionID,
            sourcePhase: wrongB.sourcePhase,
            target: .b,
            recordsDigest: digest("wrong-live-b"),
            recordCounts: wrongB.recordCounts
        )
        XCTAssertThrowsError(try store.complete(wrongB))
        XCTAssertEqual(try Data(contentsOf: journalURL), before)

        try store.advance(to: .replacementReturned) { _ in }
        let returnedBefore = try Data(contentsOf: journalURL)
        XCTAssertThrowsError(try store.complete(try terminalDecision(from: store, target: .a)))
        XCTAssertEqual(try Data(contentsOf: journalURL), returnedBefore)
    }

    func testMissingOrMismatchedTrustedMembersBlockWithoutRewritingEvidence() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        let prepared = preparedJournal()
        try store.arm(prepared)
        let active = root.appendingPathComponent("active", isDirectory: true)
        let markerURL = active.appendingPathComponent("armed-v1.json")

        let originalMarker = try Data(contentsOf: markerURL)
        var marker = try RestoreJournalCodecV1.marker(for: prepared)
        marker.journalIdentityDigest = digest("wrong")
        let mismatchedMarker = try uncheckedMarkerData(marker)
        try mismatchedMarker.write(to: markerURL, options: .atomic)
        XCTAssertEqual(
            try store.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )
        XCTAssertEqual(try Data(contentsOf: markerURL), mismatchedMarker)

        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            try store.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "recovery-inspection-failed"))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertNotEqual(originalMarker, mismatchedMarker)
    }

    func testProtectionMismatchAndBadPartialRemainCriticalWithoutWrites() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let protectedStore = makeStore(root: root)
        try protectedStore.arm(preparedJournal())

        let mismatched = RestoreJournalStoreV1(
            rootDirectory: root,
            protectionReader: JournalProtectionReader(value: "NSFileProtectionNone"),
            clock: { 10 }
        )
        XCTAssertEqual(
            try mismatched.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "protection-mismatch"))
        )

        let active = root.appendingPathComponent("active", isDirectory: true)
        let journalURL = active.appendingPathComponent("journal-v1.json")
        try FileManager.default.removeItem(at: journalURL)
        let orphan = active.appendingPathComponent(".journal-v1.00000000-0000-0000-0000-000000000008.partial")
        try Data("orphan".utf8).write(to: orphan)
        let fresh = makeStore(root: root)
        XCTAssertEqual(
            try fresh.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "recovery-inspection-failed"))
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testRootAndActiveSymlinksAndUnexpectedHiddenRootMemberBlockPreflight() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let target = sandbox.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let rootLink = sandbox.appendingPathComponent("RestoreRecovery-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: target)
        XCTAssertEqual(
            try makeStore(root: rootLink).inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )
        let danglingRootLink = sandbox.appendingPathComponent("RestoreRecovery-dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            atPath: danglingRootLink.path,
            withDestinationPath: sandbox.appendingPathComponent("missing-target").path
        )
        XCTAssertEqual(
            try makeStore(root: danglingRootLink).inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )

        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let activeTarget = sandbox.appendingPathComponent("active-target", isDirectory: true)
        try FileManager.default.createDirectory(at: activeTarget, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("active", isDirectory: true),
            withDestinationURL: activeTarget
        )
        XCTAssertEqual(
            try makeStore(root: root).inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )

        try FileManager.default.removeItem(at: root.appendingPathComponent("active", isDirectory: true))
        try Data("stray".utf8).write(to: root.appendingPathComponent(".unexpected"))
        XCTAssertEqual(
            try makeStore(root: root).inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )
    }

    func testActiveInspectionValidatesEveryProtectedRootSibling() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent("RestoreRecovery", isDirectory: true)
        let store = makeStore(root: root)
        try store.arm(preparedJournal())
        let completed = root.appendingPathComponent(
            ".completed-00000000-0000-0000-0000-000000000009",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: false)
        try assertRecover(store, phase: .prepared)

        let wrongProtection = PathSensitiveJournalProtectionReader(
            mismatchedPaths: [completed.standardizedFileURL.path]
        )
        XCTAssertEqual(
            try makeStore(root: root, protectionReader: wrongProtection).inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "protection-mismatch"))
        )

        try Data("stray".utf8).write(to: root.appendingPathComponent(".unexpected"))
        XCTAssertEqual(
            try store.inspectBeforeStoreLoad(),
            .critical(RedactedRestoreCriticalState(reasonCode: "untrusted-transaction"))
        )
    }

    private func assertRecover(
        _ store: RestoreJournalStoreV1,
        phase: RestoreJournalPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        guard case let .recover(transaction) = try store.inspectBeforeStoreLoad() else {
            return XCTFail("Expected a trusted recovery transaction.", file: file, line: line)
        }
        XCTAssertEqual(transaction.journal.content.phase, phase, file: file, line: line)
    }

    private func preparedJournal() -> RestoreJournalContentV1 {
        RestoreJournalContentV1(
            transactionID: transactionID,
            transactionNonce: digest("nonce"),
            createdAtMilliseconds: 1_000,
            candidateBackupByteCount: 321,
            candidateBackupChecksum: digest("candidate-checksum"),
            candidateRecordsDigest: digest("candidate-records"),
            candidateRecordCounts: sampleCounts
        )
    }

    private func verifiedPortableA() throws -> VerifiedHourleafBackupV1 {
        try HourleafBackupCodec.encode(
            content: HourleafBackupContentV1(
                exportedAt: 1_234_567,
                records: RestoreFixture.records()
            )
        )
    }

    private func portableBasename(
        checksumPrefix: String = "0123abcd"
    ) -> String {
        "Hourleaf-Backup-2026-08-03T06-32-43Z-\(checksumPrefix).hourleafbackup"
    }

    private func portableBasename(for backup: VerifiedHourleafBackupV1) -> String {
        portableBasename(checksumPrefix: String(backup.checksum.value.prefix(8)))
    }

    private func bindAEvidence(
        _ journal: inout RestoreJournalContentV1,
        from backup: VerifiedHourleafBackupV1
    ) {
        journal.aRecordsDigest = backup.recordsDigest
        journal.aRecordCounts = RestoreRecordCountsV1(backup.recordCounts)
    }

    private func bindPortableAEvidence(
        _ journal: inout RestoreJournalContentV1,
        basename: String,
        from backup: VerifiedHourleafBackupV1
    ) {
        journal.portableABasename = basename
        journal.portableAByteCount = backup.byteCount
        journal.portableAChecksum = backup.checksum.value
        journal.portableARecordsDigest = backup.recordsDigest
    }

    private func assertDirectAPending(
        from source: RestoreJournalPhase,
        expectedSequence: Int64,
        expectsPhysicalA: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let root = sandbox.appendingPathComponent(source.rawValue, isDirectory: true)
        let store = makeStore(root: root)
        let backup = try verifiedPortableA()
        let basename = try advanceToDirectAPendingSource(store, source: source, backup: backup)
        let current = try recoveredTransaction(store).journal.content

        var wrongSequence = current
        wrongSequence.phase = .oldStoreVerifiedRemindersPending
        wrongSequence.sequence = wrongDirectAPendingSequence(after: source)
        XCTAssertNoThrow(
            try RestoreJournalCodecV1.validate(content: wrongSequence),
            "Wrong-sequence fixture must itself be a valid journal.",
            file: file,
            line: line
        )
        XCTAssertThrowsError(
            try RestoreJournalCodecV1.validateTransition(from: current, to: wrongSequence),
            "Direct A-pending transition accepted the wrong sequence.",
            file: file,
            line: line
        )

        try store.advance(to: .oldStoreVerifiedRemindersPending) { _ in }
        let pending = try recoveredTransaction(makeStore(root: root)).journal.content
        XCTAssertEqual(pending.phase, .oldStoreVerifiedRemindersPending, file: file, line: line)
        XCTAssertEqual(pending.sequence, expectedSequence, file: file, line: line)
        XCTAssertEqual(pending.physicalAStoreUUID != nil, expectsPhysicalA, file: file, line: line)
        XCTAssertEqual(pending.physicalARecordsDigest != nil, expectsPhysicalA, file: file, line: line)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("active/\(basename)").path),
            file: file,
            line: line
        )
    }

    @discardableResult
    private func advanceToDirectAPendingSource(
        _ store: RestoreJournalStoreV1,
        source: RestoreJournalPhase,
        backup: VerifiedHourleafBackupV1
    ) throws -> String {
        guard directAPendingSources.contains(source) else {
            throw JournalInjectedFailure.failed
        }
        try armMaintenance(store, backup: backup)
        let active = try recoveredTransaction(store).activeDirectory
        let basename = portableBasename(for: backup)
        try backup.data.write(to: active.appendingPathComponent(basename))
        try store.advance(to: .preRestoreBackupVerified) { journal in
            bindPortableAEvidence(&journal, basename: basename, from: backup)
        }
        if source == .preRestoreBackupVerified { return basename }

        try store.advance(to: .oldStoreCopyStarted) { _ in }
        if source == .oldStoreCopyStarted { return basename }

        try store.advance(to: .oldStoreCopyVerified) { journal in
            journal.physicalAStoreUUID = physicalUUID
            journal.physicalARecordsDigest = backup.recordsDigest
        }
        return basename
    }

    private func directAPendingSequence(after source: RestoreJournalPhase) -> Int64 {
        switch source {
        case .preRestoreBackupVerified: 3
        case .oldStoreCopyStarted: 4
        case .oldStoreCopyVerified: 5
        default: -1
        }
    }

    private func wrongDirectAPendingSequence(after source: RestoreJournalPhase) -> Int64 {
        switch source {
        case .preRestoreBackupVerified: 4
        case .oldStoreCopyStarted: 3
        case .oldStoreCopyVerified: 7
        default: -1
        }
    }

    private func aPendingJournal(sequence: Int64) throws -> RestoreJournalContentV1 {
        let source: RestoreJournalPhase
        switch sequence {
        case 3:
            source = .preRestoreBackupVerified
        case 4:
            source = .oldStoreCopyStarted
        case 5:
            source = .oldStoreCopyVerified
        case 7, 8, 9:
            source = .oldStoreVerifiedRemindersPending
        default:
            throw JournalInjectedFailure.failed
        }
        var content = try journal(for: source)
        content.phase = .oldStoreVerifiedRemindersPending
        content.sequence = sequence
        return content
    }

    private func journal(for phase: RestoreJournalPhase) throws -> RestoreJournalContentV1 {
        if phase == .prepared { return preparedJournal() }
        let backup = try verifiedPortableA()
        let basename = portableBasename(for: backup)
        var content = preparedJournal()
        content.phase = phase
        bindAEvidence(&content, from: backup)
        switch phase {
        case .maintenanceAcquired:
            content.sequence = 1
        case .preRestoreBackupVerified:
            content.sequence = 2
            bindPortableAEvidence(&content, basename: basename, from: backup)
        case .oldStoreCopyStarted:
            content.sequence = 3
            bindPortableAEvidence(&content, basename: basename, from: backup)
        case .oldStoreCopyVerified:
            content.sequence = 4
            bindPortableAEvidence(&content, basename: basename, from: backup)
            content.physicalAStoreUUID = physicalUUID
            content.physicalARecordsDigest = backup.recordsDigest
        case .replacementStarted:
            content.sequence = 5
            bindPortableAEvidence(&content, basename: basename, from: backup)
            content.physicalAStoreUUID = physicalUUID
            content.physicalARecordsDigest = backup.recordsDigest
        case .replacementReturned:
            content.sequence = 6
            bindPortableAEvidence(&content, basename: basename, from: backup)
            content.physicalAStoreUUID = physicalUUID
            content.physicalARecordsDigest = backup.recordsDigest
        case .newStoreVerifiedRemindersPending:
            content.sequence = 7
            bindPortableAEvidence(&content, basename: basename, from: backup)
            content.physicalAStoreUUID = physicalUUID
            content.physicalARecordsDigest = backup.recordsDigest
        case .rollbackStarted:
            content.sequence = 6
            bindPortableAEvidence(&content, basename: basename, from: backup)
            content.physicalAStoreUUID = physicalUUID
            content.physicalARecordsDigest = backup.recordsDigest
        case .oldStoreVerifiedRemindersPending:
            content.sequence = 7
            bindPortableAEvidence(&content, basename: basename, from: backup)
            content.physicalAStoreUUID = physicalUUID
            content.physicalARecordsDigest = backup.recordsDigest
        case .critical:
            content.sequence = 4
            content.criticalFromPhase = .oldStoreCopyStarted
            content.criticalReasonCode = "recovery-evidence-failed"
            bindPortableAEvidence(&content, basename: basename, from: backup)
        case .prepared:
            break
        }
        return content
    }

    private func terminalDecision(
        for content: RestoreJournalContentV1,
        target: RestoreTerminalTargetV1
    ) -> RestoreTerminalDecisionV1 {
        let transaction = UUID(uuidString: content.transactionID)!
        switch target {
        case .unstarted:
            return RestoreTerminalDecisionV1(
                transactionID: transaction,
                sourcePhase: content.phase,
                target: .unstarted
            )
        case .a:
            return RestoreTerminalDecisionV1(
                transactionID: transaction,
                sourcePhase: content.phase,
                target: .a,
                recordsDigest: content.aRecordsDigest,
                recordCounts: content.aRecordCounts
            )
        case .b:
            return RestoreTerminalDecisionV1(
                transactionID: transaction,
                sourcePhase: content.phase,
                target: .b,
                recordsDigest: content.candidateRecordsDigest,
                recordCounts: content.candidateRecordCounts
            )
        }
    }

    private func armMaintenance(
        _ store: RestoreJournalStoreV1,
        backup: VerifiedHourleafBackupV1
    ) throws {
        try store.arm(preparedJournal())
        try store.advance(to: .maintenanceAcquired) { journal in
            bindAEvidence(&journal, from: backup)
        }
    }

    private func recoveredTransaction(_ store: RestoreJournalStoreV1) throws -> VerifiedRestoreTransactionV1 {
        guard case let .recover(transaction) = try store.inspectBeforeStoreLoad() else {
            throw JournalInjectedFailure.failed
        }
        return transaction
    }

    private func terminalDecision(
        from store: RestoreJournalStoreV1,
        target: RestoreTerminalTargetV1
    ) throws -> RestoreTerminalDecisionV1 {
        let content = try recoveredTransaction(store).journal.content
        let transaction = UUID(uuidString: content.transactionID)!
        switch target {
        case .unstarted:
            return RestoreTerminalDecisionV1(
                transactionID: transaction,
                sourcePhase: content.phase,
                target: .unstarted
            )
        case .a:
            return RestoreTerminalDecisionV1(
                transactionID: transaction,
                sourcePhase: content.phase,
                target: .a,
                recordsDigest: content.aRecordsDigest,
                recordCounts: content.aRecordCounts
            )
        case .b:
            return RestoreTerminalDecisionV1(
                transactionID: transaction,
                sourcePhase: content.phase,
                target: .b,
                recordsDigest: content.candidateRecordsDigest,
                recordCounts: content.candidateRecordCounts
            )
        }
    }

    private func makeStore(
        root: URL,
        protectionReader: (any HourleafFileProtectionReading)? = nil,
        faultInjector: @escaping RestoreJournalFaultInjector = { _ in }
    ) -> RestoreJournalStoreV1 {
        let reader = protectionReader ?? JournalProtectionReader(
            value: FileProtectionType.completeUntilFirstUserAuthentication.rawValue
        )
        return RestoreJournalStoreV1(
            rootDirectory: root,
            protectionReader: reader,
            faultInjector: faultInjector,
            clock: { 2_000 }
        )
    }

    private func makeSandbox() throws -> URL {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("RestoreJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        return sandbox
    }

    private func names(in url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func uncheckedJournalData(_ content: RestoreJournalContentV1) throws -> Data {
        let contentData = try canonicalData(content)
        return try canonicalData(RestoreJournalEnvelopeV1(
            content: content,
            checksum: RestoreJournalIntegrityV1(value: sha256(contentData))
        ))
    }

    private func uncheckedMarkerData(_ content: RestoreArmedContentV1) throws -> Data {
        let contentData = try canonicalData(content)
        return try canonicalData(RestoreArmedEnvelopeV1(
            content: content,
            checksum: RestoreJournalIntegrityV1(value: sha256(contentData))
        ))
    }

    private func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func digest(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private var sampleCounts: RestoreRecordCountsV1 {
        RestoreRecordCountsV1(
            acknowledgements: 1,
            archives: 1,
            entries: 2,
            policies: 1,
            presets: 1,
            receipts: 1,
            reminders: 1,
            revisions: 2,
            states: 1
        )
    }

    private var transactionID: String { "a0000000-0000-0000-0000-000000000001" }
    private var physicalUUID: String { "00000000-0000-0000-0000-000000000002" }
    private var directAPendingSources: [RestoreJournalPhase] {
        [.preRestoreBackupVerified, .oldStoreCopyStarted, .oldStoreCopyVerified]
    }
}

private enum JournalInjectedFailure: Error {
    case failed
}

private final class JournalProtectionReader: HourleafFileProtectionReading, @unchecked Sendable {
    private let value: String?

    init(value: String?) {
        self.value = value
    }

    func protectionClass(at _: URL) throws -> String? {
        value
    }
}

private final class PathSensitiveJournalProtectionReader: HourleafFileProtectionReading, @unchecked Sendable {
    private let mismatchedPaths: Set<String>

    init(mismatchedPaths: Set<String>) {
        self.mismatchedPaths = mismatchedPaths
    }

    func protectionClass(at url: URL) throws -> String? {
        if mismatchedPaths.contains(url.standardizedFileURL.path) {
            return "NSFileProtectionNone"
        }
        return FileProtectionType.completeUntilFirstUserAuthentication.rawValue
    }
}
