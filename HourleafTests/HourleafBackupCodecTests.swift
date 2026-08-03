@preconcurrency import CoreData
import XCTest
@testable import Hourleaf

@MainActor
final class HourleafBackupCodecTests: XCTestCase {
    func testGoldenCanonicalBytesAndChecksumForFixedRecords() throws {
        let backup = try HourleafBackupCodec.encode(content: makeContent())

        XCTAssertEqual(backup.byteCount, 3_387)
        XCTAssertEqual(backup.checksum.value, "23be45de3687f2200b02f3c87dc42722ab67d10ece3e9d74e3c591631cc66533")
        XCTAssertEqual(try HourleafBackupCodec.decodeAndVerify(backup.data), backup)
    }

    func testShuffledArraysProduceTheSameCanonicalBytesAndStoreDigest() throws {
        var ordered = makeRecords()
        let secondPolicy = HourleafPolicyRevisionV1(
            carryAcrossServiceYear: false,
            createdAt: 22,
            effectiveMonth: "2026-08",
            id: id(51),
            mode: RemainderMode.discard.rawValue
        )
        ordered.policies.append(secondPolicy)
        var shuffled = ordered
        shuffled.entries.reverse()
        shuffled.policies.reverse()
        shuffled.receipts.reverse()
        shuffled.revisions.reverse()

        let first = try HourleafBackupCodec.encode(content: content(records: ordered))
        let second = try HourleafBackupCodec.encode(content: content(records: shuffled))
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.recordsDigest, second.recordsDigest)
    }

    func testStrictDecoderRejectsWhitespaceUnknownDuplicateAndCorruptJSON() throws {
        let data = try HourleafBackupCodec.encode(content: makeContent()).data
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        assertDecodeFails(Data((" " + text).utf8))
        assertDecodeFails(Data((text + "\n").utf8))
        assertDecodeFails(Data(("{\"unknown\":0," + text.dropFirst()).utf8))
        assertDecodeFails(Data(text.replacingOccurrences(of: "\"checksum\":", with: "\"checksum\":null,\"checksum\":").utf8))
        assertDecodeFails(Data(text.replacingOccurrences(of: " / ", with: " \\/ ").utf8))
        assertDecodeFails(Data((String(repeating: "[", count: 600) + String(repeating: "]", count: 600)).utf8))
        assertDecodeFails(Data([0xFF]))

        var corrupt = data
        corrupt[corrupt.index(before: corrupt.endIndex)] = 0x20
        assertDecodeFails(corrupt)
    }

    func testStrictDecoderRejectsWrongFormatVersionAndAlgorithm() throws {
        let text = try XCTUnwrap(String(data: HourleafBackupCodec.encode(content: makeContent()).data, encoding: .utf8))
        assertDecodeFails(Data(text.replacingOccurrences(of: HourleafBackupV1.format, with: "com.kikuai.hourleaf.backuX").utf8))
        assertDecodeFails(Data(text.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8))
        assertDecodeFails(Data(text.replacingOccurrences(of: "\"algorithm\":\"sha256\"", with: "\"algorithm\":\"SHA256\"").utf8))
    }

    func testStrictDecoderRejectsCanonicalSemanticContentWithStaleChecksum() throws {
        let data = try HourleafBackupCodec.encode(content: makeContent()).data
        var envelope = try JSONDecoder().decode(HourleafBackupEnvelopeV1.self, from: data)
        envelope.content.records.settings.planningVisible.toggle()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let staleChecksumData = try encoder.encode(envelope)

        XCTAssertThrowsError(try HourleafBackupCodec.decodeAndVerify(staleChecksumData)) { error in
            guard let backupError = error as? HourleafBackupError,
                  case .checksumMismatch = backupError else {
                return XCTFail("Expected checksumMismatch, got \(error)")
            }
        }
    }

    func testLimitsRejectOversizedFileCountsStringsAndIntegersWithoutTruncation() throws {
        assertDecodeFails(Data(repeating: 0, count: HourleafBackupLimitsV1.maximumFileBytes + 1))

        var tooMany = makeRecords()
        tooMany.entries = Array(repeating: tooMany.entries[0], count: HourleafBackupLimitsV1.maximumEntries + 1)
        assertEncodeFails(content(records: tooMany))

        var longNote = makeRecords()
        let note = String(repeating: "🙂", count: HourleafBackupLimitsV1.maximumNoteCharacters + 1)
        longNote.entries[0].note = note
        longNote.revisions[0].note = note
        assertEncodeFails(content(records: longNote))

        var invalidMinutes = makeRecords()
        invalidMinutes.entries[0].minutes = 6_000
        invalidMinutes.revisions[0].minutes = 6_000
        assertEncodeFails(content(records: invalidMinutes))

        var rawMinutesAtBoundary = makeRecords()
        rawMinutesAtBoundary.receipts[0].rawServiceMinutes = HourleafBackupLimitsV1.maximumAggregateMinutes
        rawMinutesAtBoundary.receipts[0].serviceHours = Int32(HourleafBackupLimitsV1.maximumAggregateMinutes / 60)
        rawMinutesAtBoundary.receipts[0].serviceCarryOut = Int32(HourleafBackupLimitsV1.maximumAggregateMinutes % 60)
        XCTAssertNoThrow(try HourleafBackupCodec.encode(content: content(records: rawMinutesAtBoundary)))

        var overflowingRawMinutes = makeRecords()
        overflowingRawMinutes.receipts[0].rawServiceMinutes = .max
        assertInvalidRecord(content(records: overflowingRawMinutes))

        var overflowingCreditMinutes = makeRecords()
        overflowingCreditMinutes.receipts[0].rawCreditMinutes = .max
        assertInvalidRecord(content(records: overflowingCreditMinutes))

        var overflowingBaseline = makeRecords()
        overflowingBaseline.settings.baselineServiceYearMinutes = .max
        assertInvalidRecord(content(records: overflowingBaseline))

        var overflowingArchive = makeRecords()
        overflowingArchive.archives[0].actualServiceMinutes = .max
        assertInvalidRecord(content(records: overflowingArchive))

        var overflowingArchiveBaseline = makeRecords()
        overflowingArchiveBaseline.archives[0].baselineServiceMinutes = .max
        assertInvalidRecord(content(records: overflowingArchiveBaseline))

        var overflowingArchiveTarget = makeRecords()
        overflowingArchiveTarget.archives[0].targetMinutes = .max
        assertInvalidRecord(content(records: overflowingArchiveTarget))

        var exhaustedReceiptVersion = makeRecords()
        exhaustedReceiptVersion.receipts[0].version = .max
        assertInvalidRecord(content(records: exhaustedReceiptVersion))

        var baselineAtBoundary = makeRecords()
        baselineAtBoundary.settings.baselineServiceYearMinutes = HourleafBackupLimitsV1.maximumBaselineMinutes
        XCTAssertNoThrow(try HourleafBackupCodec.encode(content: content(records: baselineAtBoundary)))

        var archiveAtAppMaximum = makeRecords()
        archiveAtAppMaximum.archives[0].actualServiceMinutes = HourleafBackupLimitsV1.maximumArchiveActualMinutes
        archiveAtAppMaximum.archives[0].baselineServiceMinutes = HourleafBackupLimitsV1.maximumBaselineMinutes
        archiveAtAppMaximum.archives[0].targetMinutes = HourleafBackupLimitsV1.maximumServiceYearTargetMinutes
        XCTAssertNoThrow(try HourleafBackupCodec.encode(content: content(records: archiveAtAppMaximum)))
    }

    func testSchemaMapExactlyCoversNineCollectionsAndSingletonSettings() {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        let model = persistence.container.managedObjectModel
        let expected = HourleafBackupSchemaV1.entityAttributes
        XCTAssertEqual(expected.count, 10)
        XCTAssertEqual(HourleafBackupSchemaV1.collectionEntityNames.count, 9)
        XCTAssertEqual(Set(expected.keys), Set(model.entities.compactMap(\.name)))

        for entity in model.entities {
            let name = try! XCTUnwrap(entity.name)
            XCTAssertEqual(Set(entity.attributesByName.keys), expected[name], "\(name) must not lose a raw attribute")
        }
    }

    func testRawNilAndWhitespaceUnicodeValuesRoundTripExactly() throws {
        let note = "  Русский / Українська / English 🙂 \"quoted\"\ntrailing  "
        var records = makeRecords(note: note)
        records.reminders[0].createdAt = nil
        records.reminders[0].updatedAt = nil
        records.entries[0].deletedAt = nil
        records.revisions[0].entryDeletedAt = nil
        records.settings.lastPurgeAt = nil
        records.settings.updatedAt = nil

        let decoded = try HourleafBackupCodec.decodeAndVerify(
            HourleafBackupCodec.encode(content: content(records: records)).data
        )
        XCTAssertEqual(decoded.content.records.entries[0].note, note)
        XCTAssertEqual(decoded.content.records.revisions[0].note, note)
        XCTAssertNil(decoded.content.records.reminders[0].createdAt)
        XCTAssertNil(decoded.content.records.reminders[0].updatedAt)
        XCTAssertNil(decoded.content.records.entries[0].deletedAt)
        XCTAssertNil(decoded.content.records.settings.lastPurgeAt)
        XCTAssertEqual(decoded.content.records, records)
    }

    func testCreateUpdateDeleteRestoreUndoChainPreservesActiveAndDeletedRawRows() throws {
        let records = makeMutationChainRecords()
        let backup = try HourleafBackupCodec.encode(content: content(records: records))
        let decoded = try HourleafBackupCodec.decodeAndVerify(backup.data)
        XCTAssertEqual(decoded.content.records.revisions.count, 5)
        XCTAssertEqual(decoded.content.records.entries[0].deletedAt, 12)
        XCTAssertEqual(decoded.content.records.entries[0].note, "  restored then undone  ")

        var broken = records
        broken.revisions[3].parentMutationID = broken.revisions[0].mutationID
        assertEncodeFails(content(records: broken))
    }

    func testMutationHistoryRejectsIllegalStateTransitionsAndUndoInverses() throws {
        var invalidSource = makeMutationChainRecords()
        invalidSource.revisions[1].source = EntryMutationSource.shortcut.rawValue
        assertInvalidGraph(content(records: invalidSource))

        var restoreFromActive = makeMutationChainRecords()
        restoreFromActive.revisions[1].operation = EntryMutationOperation.restore.rawValue
        restoreFromActive.revisions[1].source = EntryMutationSource.restore.rawValue
        assertInvalidGraph(content(records: restoreFromActive))

        var deleteWithoutTimestamp = makeMutationChainRecords()
        deleteWithoutTimestamp.revisions[2].entryDeletedAt = nil
        assertInvalidGraph(content(records: deleteWithoutTimestamp))

        var undoWithWrongInverse = makeMutationChainRecords()
        undoWithWrongInverse.revisions[4].entryDeletedAt = nil
        assertInvalidGraph(content(records: undoWithWrongInverse))
    }

    func testCurrentAndLegacyReportsArchivesAndLegacyCarryAcrossArePreserved() throws {
        var records = makeRecords()
        records.policies[0].carryAcrossServiceYear = true
        records.receipts.append(legacyReceipt())
        records.states.append(legacyState())
        records.archives.append(newerArchive())

        let decoded = try HourleafBackupCodec.decodeAndVerify(
            HourleafBackupCodec.encode(content: content(records: records)).data
        )
        XCTAssertTrue(decoded.content.records.policies[0].carryAcrossServiceYear)
        XCTAssertTrue(decoded.content.records.receipts.contains(where: \.legacyCalculationUnavailable))
        XCTAssertEqual(decoded.content.records.archives.count, 2)
    }

    func testReportAndArchiveSeriesRejectGapsStaleHeadsAndForks() throws {
        var linkedReports = makeRecords()
        var secondReceipt = currentReceipt()
        secondReceipt.id = id(72)
        secondReceipt.preparedAt = 16
        secondReceipt.supersedesID = id(7)
        secondReceipt.version = 2
        linkedReports.receipts.append(secondReceipt)
        linkedReports.states[0].currentSnapshotID = id(72)
        XCTAssertNoThrow(try HourleafBackupCodec.encode(content: content(records: linkedReports)))

        var versionGap = linkedReports
        versionGap.receipts[1].version = 3
        assertInvalidGraph(content(records: versionGap))

        var staleHead = linkedReports
        staleHead.states[0].currentSnapshotID = id(7)
        assertInvalidGraph(content(records: staleHead))

        var forkedReports = linkedReports
        var fork = secondReceipt
        fork.id = id(73)
        fork.preparedAt = 17
        fork.supersedesID = id(7)
        fork.version = 3
        forkedReports.receipts.append(fork)
        forkedReports.states[0].currentSnapshotID = id(73)
        assertInvalidGraph(content(records: forkedReports))

        var legacyUnlinkedReports = makeRecords()
        var unlinkedReceipt = secondReceipt
        unlinkedReceipt.supersedesID = nil
        legacyUnlinkedReports.receipts.append(unlinkedReceipt)
        legacyUnlinkedReports.states[0].currentSnapshotID = id(72)
        XCTAssertNoThrow(try HourleafBackupCodec.encode(content: content(records: legacyUnlinkedReports)))

        var forkedArchives = makeRecords()
        forkedArchives.archives.append(newerArchive())
        var archiveFork = newerArchive()
        archiveFork.id = id(92)
        archiveFork.createdAt = 22
        archiveFork.supersedesID = id(9)
        archiveFork.version = 3
        forkedArchives.archives.append(archiveFork)
        assertInvalidGraph(content(records: forkedArchives))
    }

    func testActualMutationSourcesAreAcceptedOnlyForTheirLiveOperations() throws {
        let createSources: [EntryMutationSource] = [
            .appQuickEntry, .appOneTap, .shortcut, .widget, .watch, .timer, .migration
        ]
        for source in createSources {
            var records = makeRecords()
            records.entries[0].source = source.rawValue
            records.revisions[0].source = source.rawValue
            _ = try HourleafBackupCodec.encode(content: content(records: records))
        }

        // The mutation chain covers appHistory (update/delete), restore, and
        // undo through their real operation/source pairs.
        _ = try HourleafBackupCodec.encode(content: content(records: makeMutationChainRecords()))

        var invalid = makeRecords()
        invalid.entries[0].source = EntryMutationSource.appHistory.rawValue
        invalid.revisions[0].source = EntryMutationSource.appHistory.rawValue
        assertInvalidGraph(content(records: invalid))
    }

    func testUnenforcedRawProvenanceStringsRemainLossless() throws {
        var records = makeRecords()
        records.acknowledgements[0].source = "quietDayPromptV2"
        records.receipts[0].createdBySource = "reportComposerV2"

        let decoded = try HourleafBackupCodec.decodeAndVerify(
            HourleafBackupCodec.encode(content: content(records: records)).data
        )
        XCTAssertEqual(decoded.content.records.acknowledgements[0].source, "quietDayPromptV2")
        XCTAssertEqual(decoded.content.records.receipts[0].createdBySource, "reportComposerV2")
    }

    func testBackupV1PreservesFutureRepositoryDataRevisionAsRawMetadata() throws {
        var records = makeRecords()
        records.settings.dataRevision = 3

        let decoded = try HourleafBackupCodec.decodeAndVerify(
            HourleafBackupCodec.encode(content: content(records: records)).data
        )
        XCTAssertEqual(decoded.content.version, HourleafBackupV1.version)
        XCTAssertEqual(decoded.content.records.settings.dataRevision, 3)
    }

    private func assertDecodeFails(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HourleafBackupCodec.decodeAndVerify(data), file: file, line: line)
    }

    private func assertEncodeFails(_ content: HourleafBackupContentV1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HourleafBackupCodec.encode(content: content), file: file, line: line)
    }

    private func assertInvalidRecord(_ content: HourleafBackupContentV1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HourleafBackupCodec.encode(content: content), file: file, line: line) { error in
            guard let backupError = error as? HourleafBackupError,
                  case .invalidRecord = backupError else {
                return XCTFail("Expected a typed invalidRecord rejection, got \(error)", file: file, line: line)
            }
        }
    }

    private func assertInvalidGraph(_ content: HourleafBackupContentV1, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try HourleafBackupCodec.encode(content: content), file: file, line: line) { error in
            guard let backupError = error as? HourleafBackupError,
                  case .invalidGraph = backupError else {
                return XCTFail("Expected a typed invalidGraph rejection, got \(error)", file: file, line: line)
            }
        }
    }

    private func content(records: HourleafBackupRecordsV1, exportedAt: Double = 20) -> HourleafBackupContentV1 {
        HourleafBackupContentV1(exportedAt: exportedAt, records: records)
    }

    private func makeContent() -> HourleafBackupContentV1 {
        content(records: makeRecords())
    }

    private func makeRecords(note: String = "  exact note / 🙂\n  ") -> HourleafBackupRecordsV1 {
        let entry = HourleafEntryV1(
            createdAt: 10,
            deletedAt: nil,
            id: id(1),
            kind: EntryKind.service.rawValue,
            lastMutationID: id(101),
            localDay: "2026-07-12",
            minutes: 75,
            note: note,
            revision: 1,
            source: EntryMutationSource.appQuickEntry.rawValue,
            updatedAt: 10
        )
        let revision = HourleafEntryRevisionV1(
            entryCreatedAt: 10,
            entryDeletedAt: nil,
            entryID: id(1),
            entryUpdatedAt: 10,
            id: id(2),
            kind: EntryKind.service.rawValue,
            localDay: "2026-07-12",
            minutes: 75,
            mutationID: id(101),
            note: note,
            occurredAt: 10,
            operation: EntryMutationOperation.create.rawValue,
            parentMutationID: nil,
            revertedMutationID: nil,
            revision: 1,
            source: EntryMutationSource.appQuickEntry.rawValue
        )
        return HourleafBackupRecordsV1(
            acknowledgements: [
                HourleafDayAcknowledgementV1(
                    createdAt: 16,
                    id: id(3),
                    localDay: "2026-07-13",
                    source: EntryMutationSource.appQuickEntry.rawValue,
                    status: "nothingToday",
                    updatedAt: 17
                )
            ],
            archives: [baseArchive()],
            entries: [entry],
            policies: [
                HourleafPolicyRevisionV1(
                    carryAcrossServiceYear: true,
                    createdAt: 11,
                    effectiveMonth: "2026-07",
                    id: id(4),
                    mode: RemainderMode.carry.rawValue
                )
            ],
            presets: [
                HourleafPresetV1(
                    createdAt: 12,
                    deletedAt: nil,
                    id: id(5),
                    kind: EntryKind.credit.rawValue,
                    minutes: 30,
                    position: 0,
                    updatedAt: 12
                )
            ],
            receipts: [currentReceipt()],
            reminders: [
                HourleafReminderV1(
                    createdAt: nil,
                    hour: 18,
                    id: id(6),
                    isEnabled: true,
                    minute: 45,
                    updatedAt: nil,
                    weekday: 3
                )
            ],
            revisions: [revision],
            settings: settings(),
            states: [currentState()]
        )
    }

    private func makeMutationChainRecords() -> HourleafBackupRecordsV1 {
        var records = makeRecords(note: "  restored then undone  ")
        let entryID = id(1)
        let mutationIDs = (101...105).map(id)
        let createdAt = 10.0
        records.revisions = [
            revision(id: id(2), entryID: entryID, mutationID: mutationIDs[0], parent: nil, reverted: nil, revision: 1, operation: .create, source: .appQuickEntry, updatedAt: 10, deletedAt: nil),
            revision(id: id(21), entryID: entryID, mutationID: mutationIDs[1], parent: mutationIDs[0], reverted: nil, revision: 2, operation: .update, source: .appHistory, updatedAt: 11, deletedAt: nil),
            revision(id: id(22), entryID: entryID, mutationID: mutationIDs[2], parent: mutationIDs[1], reverted: nil, revision: 3, operation: .delete, source: .appHistory, updatedAt: 12, deletedAt: 12),
            revision(id: id(23), entryID: entryID, mutationID: mutationIDs[3], parent: mutationIDs[2], reverted: nil, revision: 4, operation: .restore, source: .restore, updatedAt: 13, deletedAt: nil),
            revision(id: id(24), entryID: entryID, mutationID: mutationIDs[4], parent: mutationIDs[3], reverted: mutationIDs[3], revision: 5, operation: .undo, source: .undo, updatedAt: 14, deletedAt: 12)
        ]
        records.entries[0] = HourleafEntryV1(
            createdAt: createdAt,
            deletedAt: 12,
            id: entryID,
            kind: EntryKind.service.rawValue,
            lastMutationID: mutationIDs[4],
            localDay: "2026-07-12",
            minutes: 75,
            note: "  restored then undone  ",
            revision: 5,
            source: EntryMutationSource.undo.rawValue,
            updatedAt: 14
        )
        return records
    }

    private func revision(
        id revisionID: String,
        entryID: String,
        mutationID: String,
        parent: String?,
        reverted: String?,
        revision: Int64,
        operation: EntryMutationOperation,
        source: EntryMutationSource,
        updatedAt: Double,
        deletedAt: Double?
    ) -> HourleafEntryRevisionV1 {
        HourleafEntryRevisionV1(
            entryCreatedAt: 10,
            entryDeletedAt: deletedAt,
            entryID: entryID,
            entryUpdatedAt: updatedAt,
            id: revisionID,
            kind: EntryKind.service.rawValue,
            localDay: "2026-07-12",
            minutes: 75,
            mutationID: mutationID,
            note: "  restored then undone  ",
            occurredAt: updatedAt,
            operation: operation.rawValue,
            parentMutationID: parent,
            revertedMutationID: reverted,
            revision: revision,
            source: source.rawValue
        )
    }

    private func currentReceipt() -> HourleafReportReceiptV1 {
        let text = "Июль 2026\nService / Кредит годин"
        let calculation = "calculation-fingerprint-v1"
        let creditLabel = "Кредит годин"
        let templateID = "standard"
        return HourleafReportReceiptV1(
            calculationFingerprint: calculation,
            confirmedSentAt: nil,
            createdBySource: EntryMutationSource.appQuickEntry.rawValue,
            creditCarryIn: 0,
            creditCarryOut: 0,
            creditHours: 0,
            creditLabel: creditLabel,
            id: id(7),
            legacyCalculationUnavailable: false,
            monthKey: "2026-07",
            presentationFingerprint: ReportFingerprint.presentation(
                calculationFingerprint: calculation,
                language: .ukrainian,
                creditLabel: creditLabel,
                templateID: templateID,
                text: text
            ),
            preparedAt: 13,
            rawCreditMinutes: 0,
            rawServiceMinutes: 75,
            reportLanguage: ReportLanguage.ukrainian.rawValue,
            reportText: text,
            reportingMode: RemainderMode.carry.rawValue,
            schemaVersion: 1,
            serviceCarryIn: 0,
            serviceCarryOut: 15,
            serviceHours: 1,
            supersedesID: nil,
            templateID: templateID,
            version: 1
        )
    }

    private func legacyReceipt() -> HourleafReportReceiptV1 {
        HourleafReportReceiptV1(
            calculationFingerprint: nil,
            confirmedSentAt: 19,
            createdBySource: EntryMutationSource.migration.rawValue,
            creditCarryIn: 0,
            creditCarryOut: 0,
            creditHours: 0,
            creditLabel: nil,
            id: id(70),
            legacyCalculationUnavailable: true,
            monthKey: "2026-06",
            presentationFingerprint: nil,
            preparedAt: 18,
            rawCreditMinutes: 0,
            rawServiceMinutes: 0,
            reportLanguage: nil,
            reportText: "Legacy report",
            reportingMode: nil,
            schemaVersion: 1,
            serviceCarryIn: 0,
            serviceCarryOut: 0,
            serviceHours: 0,
            supersedesID: nil,
            templateID: nil,
            version: 1
        )
    }

    private func currentState() -> HourleafReportStateV1 {
        HourleafReportStateV1(
            changedAt: nil,
            currentSnapshotID: id(7),
            id: id(8),
            lastStableState: nil,
            monthKey: "2026-07",
            reviewedCalculationFingerprint: nil,
            reviewedPresentationFingerprint: nil,
            state: "prepared",
            updatedAt: 14
        )
    }

    private func legacyState() -> HourleafReportStateV1 {
        HourleafReportStateV1(
            changedAt: nil,
            currentSnapshotID: id(70),
            id: id(71),
            lastStableState: nil,
            monthKey: "2026-06",
            reviewedCalculationFingerprint: nil,
            reviewedPresentationFingerprint: nil,
            state: "sent",
            updatedAt: 19
        )
    }

    private func baseArchive() -> HourleafServiceYearArchiveV1 {
        HourleafServiceYearArchiveV1(
            actualServiceMinutes: 100,
            baselineServiceMinutes: 20,
            calculationFingerprint: "archive-v1",
            createdAt: 15,
            endMonthKey: "2026-08",
            id: id(9),
            startMonthKey: "2025-09",
            supersedesID: nil,
            targetMinutes: 36_000,
            version: 1
        )
    }

    private func newerArchive() -> HourleafServiceYearArchiveV1 {
        HourleafServiceYearArchiveV1(
            actualServiceMinutes: 125,
            baselineServiceMinutes: 20,
            calculationFingerprint: "archive-v2",
            createdAt: 21,
            endMonthKey: "2026-08",
            id: id(91),
            startMonthKey: "2025-09",
            supersedesID: id(9),
            targetMinutes: 36_000,
            version: 2
        )
    }

    private func settings() -> HourleafSettingsV1 {
        HourleafSettingsV1(
            baselineServiceYearMinutes: 600,
            baselineServiceYearStart: "2025-09",
            creditLabelEnglish: "Credit hours",
            creditLabelRussian: "Кредит часов",
            creditLabelUkrainian: "Кредит годин",
            dataRevision: 2,
            id: id(10),
            lastPurgeAt: nil,
            ledgerStartMonth: "2026-01",
            onboardingComplete: true,
            openingCreditCarryMinutes: 10,
            openingServiceCarryMinutes: 20,
            planningVisible: false,
            quietGapCheckEnabled: false,
            quietGapDays: 7,
            reportLanguage: ReportLanguage.ukrainian.rawValue,
            syncMode: nil,
            timerVisible: false,
            updatedAt: nil,
            widgetPrivacyMode: nil
        )
    }

    private func id(_ value: Int) -> String {
        String(format: "00000000-0000-0000-0000-%012d", value)
    }
}

/// The checked-in V2 model has nine array entities and one singleton Settings
/// entity. This test-only oracle makes a raw-attribute omission observable.
private enum HourleafBackupSchemaV1 {
    static let collectionEntityNames: Set<String> = [
        "DayAcknowledgementEntity",
        "EntryEntity",
        "EntryRevisionEntity",
        "PolicyRevisionEntity",
        "PresetEntity",
        "ReminderEntity",
        "ReportReceiptEntity",
        "ReportStateEntity",
        "ServiceYearArchiveEntity"
    ]

    static let entityAttributes: [String: Set<String>] = [
        "DayAcknowledgementEntity": ["createdAt", "id", "localDay", "source", "status", "updatedAt"],
        "EntryEntity": ["createdAt", "deletedAt", "id", "kind", "lastMutationID", "localDay", "minutes", "note", "revision", "source", "updatedAt"],
        "EntryRevisionEntity": ["entryCreatedAt", "entryDeletedAt", "entryID", "entryUpdatedAt", "id", "kind", "localDay", "minutes", "mutationID", "note", "occurredAt", "operation", "parentMutationID", "revertedMutationID", "revision", "source"],
        "PolicyRevisionEntity": ["carryAcrossServiceYear", "createdAt", "effectiveMonth", "id", "mode"],
        "PresetEntity": ["createdAt", "deletedAt", "id", "kind", "minutes", "position", "updatedAt"],
        "ReminderEntity": ["createdAt", "hour", "id", "isEnabled", "minute", "updatedAt", "weekday"],
        "ReportReceiptEntity": ["calculationFingerprint", "confirmedSentAt", "createdBySource", "creditCarryIn", "creditCarryOut", "creditHours", "creditLabel", "id", "legacyCalculationUnavailable", "monthKey", "presentationFingerprint", "preparedAt", "rawCreditMinutes", "rawServiceMinutes", "reportLanguage", "reportText", "reportingMode", "schemaVersion", "serviceCarryIn", "serviceCarryOut", "serviceHours", "supersedesID", "templateID", "version"],
        "ReportStateEntity": ["changedAt", "currentSnapshotID", "id", "lastStableState", "monthKey", "reviewedCalculationFingerprint", "reviewedPresentationFingerprint", "state", "updatedAt"],
        "ServiceYearArchiveEntity": ["actualServiceMinutes", "baselineServiceMinutes", "calculationFingerprint", "createdAt", "endMonthKey", "id", "startMonthKey", "supersedesID", "targetMinutes", "version"],
        "SettingsEntity": ["baselineServiceYearMinutes", "baselineServiceYearStart", "creditLabelEnglish", "creditLabelRussian", "creditLabelUkrainian", "dataRevision", "id", "lastPurgeAt", "ledgerStartMonth", "onboardingComplete", "openingCreditCarryMinutes", "openingServiceCarryMinutes", "planningVisible", "quietGapCheckEnabled", "quietGapDays", "reportLanguage", "syncMode", "timerVisible", "updatedAt", "widgetPrivacyMode"]
    ]
}
