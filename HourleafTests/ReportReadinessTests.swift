import CoreData
import XCTest
@testable import Hourleaf

final class ReportReadinessTests: XCTestCase {
    private let june = MonthKey(year: 2026, month: 6)
    private let july = MonthKey(year: 2026, month: 7)
    private let august = MonthKey(year: 2026, month: 8)
    private let september = MonthKey(year: 2026, month: 9)

    func testReportV1FingerprintGoldenValuesRemainCompatible() {
        var settings = makeSettings(ledgerStartMonth: july)
        settings.openingServiceCarryMinutes = 5
        settings.openingCreditCarryMinutes = 7
        let report = MonthlyReport(
            month: july,
            rawServiceMinutes: 125,
            rawCreditMinutes: 61,
            serviceCarryIn: 5,
            creditCarryIn: 7,
            serviceHours: 2,
            creditHours: 1,
            serviceCarryOut: 10,
            creditCarryOut: 8
        )
        let expectedCalculation = "18f6a78b8adb48afc463b7f4205788ecf2c75f452db57f7098c12a1aa062f858"
        let text = "July 2026\nHours: 2\nCredit hours: 1"
        let expectedPresentation = "bfe44652e9b8e22131b90416512a633f2c3261b0ccbb26b2e17b9135e31e9618"

        XCTAssertEqual(
            ReportFingerprint.calculation(
                report: report,
                entries: [],
                settings: settings,
                policies: []
            ),
            expectedCalculation
        )
        XCTAssertEqual(
            ReportFingerprint.calculationV1(
                report: report,
                entries: [],
                settings: settings,
                policies: []
            ),
            expectedCalculation
        )
        XCTAssertEqual(
            ReportFingerprint.presentation(
                calculationFingerprint: expectedCalculation,
                language: .english,
                creditLabel: "Credit hours",
                templateID: "standard",
                text: text
            ),
            expectedPresentation
        )
        XCTAssertEqual(
            ReportFingerprint.presentationV1(
                calculationFingerprint: expectedCalculation,
                language: .english,
                creditLabel: "Credit hours",
                templateID: "standard",
                text: text
            ),
            expectedPresentation
        )
    }

    func testReportV2CanonicalGoldenValues() {
        let report = MonthlyReport(
            month: july,
            rawServiceMinutes: 125,
            rawCreditMinutes: 61,
            serviceCarryIn: 5,
            creditCarryIn: 7,
            serviceHours: 2,
            creditHours: 1,
            serviceCarryOut: 10,
            creditCarryOut: 8
        )
        let entries = [
            makeEntry(
                id: "00000000-0000-0000-0000-0000000000AB",
                kind: .credit,
                day: LocalDay(year: 2026, month: 7, day: 20),
                minutes: 61
            ),
            makeEntry(
                id: "00000000-0000-0000-0000-000000000001",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 15),
                minutes: 125
            )
        ]
        let calculation = ReportFingerprint.calculationV2(
            report: report,
            entries: entries,
            mode: .carry
        )
        let expectedCalculation = "v2:fc92d7b6d0a7883d9ab66927dabe095f4aad3d3d68909c6ee2e73921e697d8e8"
        let expectedPresentation = "v2:675e0a6da1eed6d325e2a8b3e53bb7fcacc7408ac45ba3f1dc14f9538741fd74"

        XCTAssertEqual(calculation, expectedCalculation)
        XCTAssertEqual(
            ReportFingerprint.presentationV2(
                calculationFingerprint: calculation,
                templateID: "standard",
                text: "July 2026\nHours: 2\nCredit hours: 1"
            ),
            expectedPresentation
        )
        XCTAssertEqual(
            ReportFingerprint.presentation(
                calculationFingerprint: calculation,
                language: .ukrainian,
                creditLabel: "Not hashed separately",
                templateID: "standard",
                text: "July 2026\nHours: 2\nCredit hours: 1"
            ),
            expectedPresentation
        )
    }

    func testReportV2FingerprintIsDeterministicAcrossInputOrder() throws {
        let first = makeEntry(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .credit,
            day: LocalDay(year: 2026, month: 7, day: 2),
            minutes: 30
        )
        let second = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 90
        )
        let report = try XCTUnwrap(report(for: july, entries: [first, second], mode: .carry))

        XCTAssertEqual(
            ReportFingerprint.calculationV2(report: report, entries: [first, second], mode: .carry),
            ReportFingerprint.calculationV2(report: report, entries: [second, first], mode: .carry)
        )
    }

    func testReportV2FingerprintChangesForEntryIdentityKindDayOrMinutes() throws {
        let base = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 90
        )
        let report = try XCTUnwrap(report(for: july, entries: [base], mode: .carry))
        let baseFingerprint = ReportFingerprint.calculationV2(
            report: report,
            entries: [base],
            mode: .carry
        )
        let variants = [
            makeEntry(
                id: "00000000-0000-0000-0000-000000000002",
                kind: base.kind,
                day: base.day,
                minutes: base.minutes
            ),
            makeEntry(id: base.id.uuidString, kind: .credit, day: base.day, minutes: base.minutes),
            makeEntry(
                id: base.id.uuidString,
                kind: base.kind,
                day: LocalDay(year: 2026, month: 7, day: 2),
                minutes: base.minutes
            ),
            makeEntry(id: base.id.uuidString, kind: base.kind, day: base.day, minutes: 91)
        ]

        for variant in variants {
            XCTAssertNotEqual(
                ReportFingerprint.calculationV2(report: report, entries: [variant], mode: .carry),
                baseFingerprint
            )
        }
    }

    func testReportV2FingerprintIgnoresNoteTimestampsSourceAndRevision() throws {
        let id = "00000000-0000-0000-0000-000000000001"
        let first = makeEntry(
            id: id,
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 90,
            note: "First note",
            createdAt: fixedDate(1),
            updatedAt: fixedDate(2)
        )
        let second = makeEntry(
            id: id,
            kind: .service,
            day: first.day,
            minutes: first.minutes,
            note: "Different note",
            createdAt: fixedDate(100),
            updatedAt: fixedDate(200)
        )
        let firstSnapshot = makeSnapshot(
            entries: [makeRecord(first, source: "app", revision: 1)],
            settings: makeSettings(ledgerStartMonth: july)
        )
        let secondSnapshot = makeSnapshot(
            entries: [makeRecord(second, source: "shortcut", revision: 99)],
            settings: makeSettings(ledgerStartMonth: july)
        )

        let firstDraft = try XCTUnwrap(ReportReadiness.draft(for: july, in: firstSnapshot))
        let secondDraft = try XCTUnwrap(ReportReadiness.draft(for: july, in: secondSnapshot))
        XCTAssertEqual(firstDraft.calculationFingerprint, secondDraft.calculationFingerprint)
    }

    func testReportV2PresentationChangesOnlyWhenExactTextChanges() throws {
        var firstSettings = makeSettings(ledgerStartMonth: july)
        firstSettings.creditLabelEnglish = "Unused credit label A"
        var secondSettings = firstSettings
        secondSettings.creditLabelEnglish = "Unused credit label B"
        let entry = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 60
        )
        let firstDraft = try XCTUnwrap(ReportReadiness.draft(
            for: july,
            in: makeSnapshot(entries: [makeRecord(entry)], settings: firstSettings)
        ))
        let secondDraft = try XCTUnwrap(ReportReadiness.draft(
            for: july,
            in: makeSnapshot(entries: [makeRecord(entry)], settings: secondSettings)
        ))

        XCTAssertEqual(firstDraft.text, secondDraft.text)
        XCTAssertEqual(firstDraft.presentationFingerprint, secondDraft.presentationFingerprint)
        XCTAssertNotEqual(
            ReportFingerprint.presentationV2(
                calculationFingerprint: firstDraft.calculationFingerprint,
                templateID: firstDraft.templateID,
                text: firstDraft.text + "!"
            ),
            firstDraft.presentationFingerprint
        )
    }

    func testDiscardedMinutesChangeTheirOwnMonthButNotNextMonth() throws {
        let first = snapshotWithSingleEntry(minutes: 61, month: june, mode: .discard)
        let second = snapshotWithSingleEntry(minutes: 62, month: june, mode: .discard)

        XCTAssertNotEqual(
            try XCTUnwrap(ReportReadiness.draft(for: june, in: first)).calculationFingerprint,
            try XCTUnwrap(ReportReadiness.draft(for: june, in: second)).calculationFingerprint
        )
        XCTAssertEqual(
            try XCTUnwrap(ReportReadiness.draft(for: july, in: first)).calculationFingerprint,
            try XCTUnwrap(ReportReadiness.draft(for: july, in: second)).calculationFingerprint
        )
    }

    func testCarryChangePropagatesOnlyThroughChangedCarryIn() throws {
        let first = snapshotWithSingleEntry(minutes: 61, month: june, mode: .carry)
        let second = snapshotWithSingleEntry(minutes: 62, month: june, mode: .carry)
        let firstJune = try XCTUnwrap(ReportReadiness.draft(for: june, in: first))
        let secondJune = try XCTUnwrap(ReportReadiness.draft(for: june, in: second))
        let firstJuly = try XCTUnwrap(ReportReadiness.draft(for: july, in: first))
        let secondJuly = try XCTUnwrap(ReportReadiness.draft(for: july, in: second))

        XCTAssertNotEqual(firstJune.calculationFingerprint, secondJune.calculationFingerprint)
        XCTAssertEqual(firstJuly.report.serviceCarryIn, 1)
        XCTAssertEqual(secondJuly.report.serviceCarryIn, 2)
        XCTAssertNotEqual(firstJuly.calculationFingerprint, secondJuly.calculationFingerprint)
    }

    func testAugustEditDoesNotChangeSeptemberV2Fingerprint() throws {
        let first = snapshotWithSingleEntry(minutes: 61, month: august, mode: .carry)
        let second = snapshotWithSingleEntry(minutes: 62, month: august, mode: .carry)

        XCTAssertNotEqual(
            try XCTUnwrap(ReportReadiness.draft(for: august, in: first)).calculationFingerprint,
            try XCTUnwrap(ReportReadiness.draft(for: august, in: second)).calculationFingerprint
        )
        XCTAssertEqual(
            try XCTUnwrap(ReportReadiness.draft(for: september, in: first)).calculationFingerprint,
            try XCTUnwrap(ReportReadiness.draft(for: september, in: second)).calculationFingerprint
        )
    }

    func testReportDraftSortsEntriesByDayCreatedAtUUID() throws {
        let laterDay = makeEntry(
            id: "00000000-0000-0000-0000-000000000004",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 2),
            minutes: 10,
            createdAt: fixedDate(1)
        )
        let laterCreation = makeEntry(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 10,
            createdAt: fixedDate(2)
        )
        let higherUUID = makeEntry(
            id: "00000000-0000-0000-0000-000000000003",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 10,
            createdAt: fixedDate(1)
        )
        let lowerUUID = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .credit,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 10,
            createdAt: fixedDate(1)
        )
        let snapshot = makeSnapshot(
            entries: [laterDay, laterCreation, higherUUID, lowerUUID].map { makeRecord($0) },
            settings: makeSettings(ledgerStartMonth: july)
        )

        let draft = try XCTUnwrap(ReportReadiness.draft(for: july, in: snapshot))
        XCTAssertEqual(
            draft.entries.map(\.id),
            [lowerUUID.id, higherUUID.id, laterCreation.id, laterDay.id]
        )
    }

    func testReportDraftKeepsServiceAndCreditSeparate() throws {
        var settings = makeSettings(ledgerStartMonth: july)
        settings.openingServiceCarryMinutes = 5
        settings.openingCreditCarryMinutes = 7
        let entries = [
            makeEntry(
                id: "00000000-0000-0000-0000-000000000001",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 1),
                minutes: 90
            ),
            makeEntry(
                id: "00000000-0000-0000-0000-000000000002",
                kind: .credit,
                day: LocalDay(year: 2026, month: 7, day: 1),
                minutes: 130
            )
        ]
        let draft = try XCTUnwrap(ReportReadiness.draft(
            for: july,
            in: makeSnapshot(entries: entries.map { makeRecord($0) }, settings: settings)
        ))

        XCTAssertEqual(draft.report.rawServiceMinutes, 90)
        XCTAssertEqual(draft.report.rawCreditMinutes, 130)
        XCTAssertEqual(draft.report.serviceHours, 1)
        XCTAssertEqual(draft.report.creditHours, 2)
        XCTAssertEqual(draft.report.serviceCarryOut, 35)
        XCTAssertEqual(draft.report.creditCarryOut, 17)
    }

    func testExistingCarryRoundDiscardAndAugustRulesRemainExact() throws {
        let service = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 8, day: 1),
            minutes: 119
        )
        let credit = makeEntry(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .credit,
            day: LocalDay(year: 2026, month: 8, day: 1),
            minutes: 89
        )

        let carry = try XCTUnwrap(report(for: august, entries: [service, credit], mode: .carry))
        let rounded = try XCTUnwrap(report(for: august, entries: [service, credit], mode: .roundNearest))
        let discarded = try XCTUnwrap(report(for: august, entries: [service, credit], mode: .discard))
        XCTAssertEqual([carry.serviceHours, carry.creditHours], [1, 1])
        XCTAssertEqual([carry.serviceCarryOut, carry.creditCarryOut], [0, 0])
        XCTAssertEqual([rounded.serviceHours, rounded.creditHours], [2, 1])
        XCTAssertEqual([rounded.serviceCarryOut, rounded.creditCarryOut], [0, 0])
        XCTAssertEqual([discarded.serviceHours, discarded.creditHours], [1, 1])
        XCTAssertEqual([discarded.serviceCarryOut, discarded.creditCarryOut], [0, 0])
    }

    func testReportDraftRejectsBeforeLedgerStartAndExcludesDeletedEntries() throws {
        let active = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 1),
            minutes: 60
        )
        let deleted = makeEntry(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 2),
            minutes: 120
        )
        let snapshot = makeSnapshot(
            entries: [makeRecord(active), makeRecord(deleted, deletedAt: fixedDate(3))],
            settings: makeSettings(ledgerStartMonth: july)
        )

        XCTAssertNil(ReportReadiness.draft(for: june, in: snapshot))
        let draft = try XCTUnwrap(ReportReadiness.draft(for: july, in: snapshot))
        XCTAssertEqual(draft.entries.map(\.id), [active.id])
        XCTAssertEqual(draft.report.rawServiceMinutes, 60)
    }

    func testReportLifecycleStateRetainsExistingRawStorageValues() throws {
        XCTAssertEqual(ReportLifecycleState.allCases.map(\.rawValue), [
            "draft", "ready", "reviewed", "prepared", "sent", "changed"
        ])
        let encoded = try JSONEncoder().encode(ReportLifecycleState.changed)
        XCTAssertEqual(try JSONDecoder().decode(ReportLifecycleState.self, from: encoded), .changed)
    }

    func testServiceYearBoundaryIsSeptemberThroughAugust() throws {
        let start = MonthKey(year: 2025, month: 9)
        var settings = makeSettings(ledgerStartMonth: start)
        settings.baselineServiceYearStart = start
        let entries = [
            makeEntry(
                id: "00000000-0000-0000-0000-000000000001",
                kind: .service,
                day: LocalDay(year: 2025, month: 9, day: 1),
                minutes: 60
            ),
            makeEntry(
                id: "00000000-0000-0000-0000-000000000002",
                kind: .service,
                day: LocalDay(year: 2026, month: 8, day: 31),
                minutes: 120
            ),
            makeEntry(
                id: "00000000-0000-0000-0000-000000000003",
                kind: .service,
                day: LocalDay(year: 2026, month: 9, day: 1),
                minutes: 240
            )
        ]

        let draft = try XCTUnwrap(ReportReadiness.serviceYearDraft(
            starting: start,
            in: makeSnapshot(entries: entries.map { makeRecord($0) }, settings: settings)
        ))
        XCTAssertEqual(draft.startMonth, start)
        XCTAssertEqual(draft.endMonth, MonthKey(year: 2026, month: 8))
        XCTAssertEqual(draft.actualServiceMinutes, 180)
    }

    func testArchiveIncludesOnlyActiveServiceEntries() throws {
        let start = MonthKey(year: 2025, month: 9)
        let settings = makeSettings(ledgerStartMonth: start)
        let included = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2026, month: 1, day: 1),
            minutes: 60
        )
        let credit = makeEntry(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .credit,
            day: included.day,
            minutes: 120
        )
        let deleted = makeEntry(
            id: "00000000-0000-0000-0000-000000000003",
            kind: .service,
            day: included.day,
            minutes: 180
        )
        let before = makeEntry(
            id: "00000000-0000-0000-0000-000000000004",
            kind: .service,
            day: LocalDay(year: 2025, month: 8, day: 31),
            minutes: 240
        )

        let draft = try XCTUnwrap(ReportReadiness.serviceYearDraft(
            starting: start,
            in: makeSnapshot(
                entries: [
                    makeRecord(included),
                    makeRecord(credit),
                    makeRecord(deleted, deletedAt: fixedDate(5)),
                    makeRecord(before)
                ],
                settings: settings
            )
        ))
        XCTAssertEqual(draft.actualServiceMinutes, 60)
    }

    func testArchiveSeparatesActualBaselineAndTargetAndAllowsAboveSixHundredHours() throws {
        let start = MonthKey(year: 2025, month: 9)
        var settings = makeSettings(ledgerStartMonth: start)
        settings.baselineServiceYearStart = start
        settings.baselineServiceYearMinutes = 120
        let entry = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2025, month: 9, day: 1),
            minutes: 36_061
        )

        let draft = try XCTUnwrap(ReportReadiness.serviceYearDraft(
            starting: start,
            in: makeSnapshot(entries: [makeRecord(entry)], settings: settings)
        ))
        XCTAssertEqual(draft.actualServiceMinutes, 36_061)
        XCTAssertEqual(draft.baselineServiceMinutes, 120)
        XCTAssertEqual(draft.targetMinutes, 36_000)
        XCTAssertGreaterThan(draft.actualServiceMinutes + draft.baselineServiceMinutes, draft.targetMinutes)
    }

    func testArchiveIgnoresMonthlyRoundingAndCarry() throws {
        let start = MonthKey(year: 2025, month: 9)
        var firstSettings = makeSettings(ledgerStartMonth: start)
        firstSettings.openingServiceCarryMinutes = 59
        let entry = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2025, month: 9, day: 1),
            minutes: 61
        )
        let carrySnapshot = makeSnapshot(
            entries: [makeRecord(entry)],
            settings: firstSettings,
            policies: [ReportingPolicy(effectiveMonth: start, mode: .carry, createdAt: fixedDate(1))]
        )
        var discardSettings = firstSettings
        discardSettings.openingServiceCarryMinutes = 0
        let discardSnapshot = makeSnapshot(
            entries: [makeRecord(entry)],
            settings: discardSettings,
            policies: [ReportingPolicy(effectiveMonth: start, mode: .discard, createdAt: fixedDate(2))]
        )

        let carry = try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: start, in: carrySnapshot))
        let discard = try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: start, in: discardSnapshot))
        XCTAssertEqual(carry.actualServiceMinutes, 61)
        XCTAssertEqual(carry, discard)
    }

    func testArchiveFingerprintIgnoresCreditNotesTimestampsSourceAndRevision() throws {
        let start = MonthKey(year: 2025, month: 9)
        let settings = makeSettings(ledgerStartMonth: start)
        let firstService = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: 2025, month: 9, day: 1),
            minutes: 60,
            note: "One",
            createdAt: fixedDate(1),
            updatedAt: fixedDate(2)
        )
        let secondService = makeEntry(
            id: firstService.id.uuidString,
            kind: .service,
            day: firstService.day,
            minutes: firstService.minutes,
            note: "Two",
            createdAt: fixedDate(100),
            updatedAt: fixedDate(200)
        )
        let credit = makeEntry(
            id: "00000000-0000-0000-0000-000000000002",
            kind: .credit,
            day: firstService.day,
            minutes: 300
        )
        let first = makeSnapshot(
            entries: [makeRecord(firstService, source: "app", revision: 1)],
            settings: settings
        )
        let second = makeSnapshot(
            entries: [
                makeRecord(secondService, source: "shortcut", revision: 99),
                makeRecord(credit)
            ],
            settings: settings
        )

        XCTAssertEqual(
            try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: start, in: first)),
            try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: start, in: second))
        )
    }

    func testServiceYearFingerprintCanonicalGoldenValue() {
        let start = MonthKey(year: 2025, month: 9)
        let end = MonthKey(year: 2026, month: 8)
        let entries = [
            makeEntry(
                id: "00000000-0000-0000-0000-0000000000AB",
                kind: .service,
                day: LocalDay(year: 2026, month: 8, day: 31),
                minutes: 61
            ),
            makeEntry(
                id: "00000000-0000-0000-0000-000000000001",
                kind: .service,
                day: LocalDay(year: 2025, month: 9, day: 1),
                minutes: 36_000
            )
        ]

        XCTAssertEqual(
            ServiceYearFingerprint.calculation(
                startMonth: start,
                endMonth: end,
                actualServiceMinutes: 36_061,
                baselineServiceMinutes: 120,
                targetMinutes: 36_000,
                entries: entries
            ),
            "service-year-v1:87b6129d39b4346476e44189283ea70a1a387a455691710e4baeff6c75970eea"
        )
    }

    func testBaselineAppliesOnlyToItsNamedServiceYear() throws {
        let firstStart = MonthKey(year: 2025, month: 9)
        let secondStart = MonthKey(year: 2026, month: 9)
        var settings = makeSettings(ledgerStartMonth: firstStart)
        settings.baselineServiceYearStart = firstStart
        settings.baselineServiceYearMinutes = 600
        let snapshot = makeSnapshot(settings: settings)

        XCTAssertEqual(
            try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: firstStart, in: snapshot))
                .baselineServiceMinutes,
            600
        )
        XCTAssertEqual(
            try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: secondStart, in: snapshot))
                .baselineServiceMinutes,
            0
        )
    }

    func testServiceYearDraftRejectsNonSeptemberAndYearsBeforeLedgerStart() {
        let settings = makeSettings(ledgerStartMonth: MonthKey(year: 2026, month: 9))
        let snapshot = makeSnapshot(settings: settings)

        XCTAssertNil(ReportReadiness.serviceYearDraft(
            starting: MonthKey(year: 2026, month: 8),
            in: snapshot
        ))
        XCTAssertNil(ReportReadiness.serviceYearDraft(
            starting: MonthKey(year: 2024, month: 9),
            in: snapshot
        ))
    }

    func testCurrentMonthIsDraftAndCannotReviewOrPrepare() async throws {
        let repository = makeRepository()
        try await configureLedgerStart(repository, month: july)
        let now = makeDate(year: 2026, month: 7, day: 15, hour: 12)
        let snapshot = try await repository.ledgerSnapshot()
        let openDraft = try XCTUnwrap(ReportReadiness.draft(for: july, in: snapshot))

        await assertLifecycleError(.monthStillOpen) {
            _ = try await repository.reviewReport(
                ReviewReportRequest(
                    month: self.july,
                    expectedCalculationFingerprint: openDraft.calculationFingerprint,
                    expectedPresentationFingerprint: openDraft.presentationFingerprint,
                    reviewedAt: now
                )
            )
        }

        await assertLifecycleError(.monthStillOpen) {
            _ = try await repository.prepareReport(
                PrepareReportRequest(
                    month: self.july,
                    expectedCalculationFingerprint: openDraft.calculationFingerprint,
                    expectedPresentationFingerprint: openDraft.presentationFingerprint,
                    snapshotID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!,
                    preparedAt: now
                )
            )
        }
    }

    func testClosedZeroEntryMonthBecomesReadyOnReconcile() async throws {
        let repository = makeRepository()
        try await configureLedgerStart(repository, month: june)

        let ledger = try await repository.reconcileReportLifecycle(
            asOf: makeDate(year: 2026, month: 8, day: 1, hour: 0, minute: 1)
        )
        XCTAssertEqual(ledger.reportStates.count, 1)
        XCTAssertEqual(ledger.reportStates.first?.month, july)
        XCTAssertEqual(ledger.reportStates.first?.state, .ready)
    }

    func testReviewRejectsFingerprintMismatchWithoutWrites() async throws {
        let repository = makeRepository()
        try await configureLedgerStart(repository, month: june)
        try await createEntry(
            makeEntry(
                id: "30000000-0000-0000-0000-000000000001",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 3),
                minutes: 90,
                createdAt: fixedDate(10)
            ),
            in: repository
        )
        let draft = try await reportDraft(from: repository, month: july)
        let before = try await repository.ledgerSnapshot()

        await assertLifecycleError(.reportChanged) {
            _ = try await repository.reviewReport(
                ReviewReportRequest(
                    month: self.july,
                    expectedCalculationFingerprint: draft.calculationFingerprint + "-mismatch",
                    expectedPresentationFingerprint: draft.presentationFingerprint,
                    reviewedAt: self.makeDate(year: 2026, month: 8, day: 1, hour: 9)
                )
            )
        }

        let ledger = try await repository.ledgerSnapshot()
        XCTAssertEqual(ledger.reportStates, before.reportStates)
        XCTAssertEqual(ledger.reportSnapshots, before.reportSnapshots)
    }

    func testPrepareReplayReturnsExistingSnapshotAfterLaterMutation() async throws {
        let repository = makeRepository()
        try await configureLedgerStart(repository, month: june)
        let entry = makeEntry(
            id: "30000000-0000-0000-0000-000000000002",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 5),
            minutes: 120,
            createdAt: fixedDate(10)
        )
        let createReceipt = try await createEntry(entry, in: repository)
        let originalDraft = try await reportDraft(from: repository, month: july)
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: july,
                expectedCalculationFingerprint: originalDraft.calculationFingerprint,
                expectedPresentationFingerprint: originalDraft.presentationFingerprint,
                reviewedAt: makeDate(year: 2026, month: 8, day: 1, hour: 8)
            )
        )
        let snapshotID = UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        let preparedAt = makeDate(year: 2026, month: 8, day: 1, hour: 9)
        let first = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: originalDraft.calculationFingerprint,
                expectedPresentationFingerprint: originalDraft.presentationFingerprint,
                snapshotID: snapshotID,
                preparedAt: preparedAt
            )
        )
        XCTAssertFalse(first.wasReplay)

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000001")!,
                entryID: entry.id,
                expectedRevision: createReceipt.appliedRevision,
                operation: .update,
                values: EntryMutationValues(
                    kind: .service,
                    day: entry.day,
                    minutes: 180,
                    note: nil
                ),
                occurredAt: makeDate(year: 2026, month: 8, day: 1, hour: 10),
                source: .appHistory
            )
        )

        let replay = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: originalDraft.calculationFingerprint,
                expectedPresentationFingerprint: originalDraft.presentationFingerprint,
                snapshotID: snapshotID,
                preparedAt: preparedAt
            )
        )
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.snapshot.id, snapshotID)
        XCTAssertEqual(replay.snapshot.receipt.text, first.snapshot.receipt.text)
        XCTAssertEqual(replay.ledger.reportSnapshots.count, 1)
    }

    func testMarkSentCurrentAndOlderSnapshotBehaviorsAndIdempotency() async throws {
        let (_, repository) = makeRepositoryWithPersistence()
        try await configureLedgerStart(repository, month: june)
        try await createEntry(
            makeEntry(
                id: "30000000-0000-0000-0000-000000000099",
                kind: .service,
                day: LocalDay(year: 2026, month: 7, day: 9),
                minutes: 120,
                createdAt: fixedDate(30)
            ),
            in: repository
        )
        let currentLedger = try await repository.ledgerSnapshot()
        let currentDraft = try XCTUnwrap(ReportReadiness.draft(for: july, in: currentLedger))
        let currentV1CalculationFingerprint = ReportFingerprint.calculation(
            report: currentDraft.report,
            entries: currentLedger.activeEntries,
            settings: currentLedger.settings,
            policies: currentLedger.policies
        )
        let older = ReportReceipt(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000010")!,
            month: july,
            text: "July 2026\nHours: 1",
            serviceHours: 1,
            creditHours: 0,
            serviceCarryOut: 0,
            creditCarryOut: 0,
            preparedAt: fixedDate(100),
            confirmedSentAt: nil
        )
        let newer = ReportReceipt(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000011")!,
            month: july,
            text: currentDraft.text,
            serviceHours: currentDraft.report.serviceHours,
            creditHours: currentDraft.report.creditHours,
            serviceCarryOut: currentDraft.report.serviceCarryOut,
            creditCarryOut: currentDraft.report.creditCarryOut,
            preparedAt: fixedDate(200),
            confirmedSentAt: nil
        )
        try await repository.testOnlySaveReceiptFixture(older, details: reportDetails(for: older, rawServiceMinutes: 60))
        try await repository.testOnlySaveReceiptFixture(
            newer,
            details: ReportSnapshotDetails(
                report: currentDraft.report,
                reportingMode: currentDraft.reportingMode,
                reportLanguage: currentDraft.reportLanguage,
                creditLabel: currentDraft.creditLabel,
                templateID: currentDraft.templateID,
                calculationFingerprint: currentV1CalculationFingerprint,
                presentationFingerprint: ReportFingerprint.presentation(
                    calculationFingerprint: currentV1CalculationFingerprint,
                    language: currentDraft.reportLanguage,
                    creditLabel: currentDraft.creditLabel,
                    templateID: currentDraft.templateID,
                    text: currentDraft.text
                )
            )
        )

        let sentAt = makeDate(year: 2026, month: 8, day: 1, hour: 10)
        let afterOlder = try await repository.markReportSent(
            MarkReportSentRequest(snapshotID: older.id, confirmedAt: sentAt)
        )
        XCTAssertEqual(afterOlder.reportStates.first?.state, .prepared)
        XCTAssertEqual(afterOlder.reportStates.first?.currentSnapshotID, newer.id)
        XCTAssertEqual(
            afterOlder.reportSnapshots.first(where: { $0.id == older.id })?.receipt.confirmedSentAt,
            sentAt
        )

        let currentSentAt = makeDate(year: 2026, month: 8, day: 1, hour: 11)
        let afterCurrent = try await repository.markReportSent(
            MarkReportSentRequest(snapshotID: newer.id, confirmedAt: currentSentAt)
        )
        let sentState = try XCTUnwrap(afterCurrent.reportStates.first)
        XCTAssertEqual(sentState.state, .sent)
        XCTAssertEqual(sentState.currentSnapshotID, newer.id)
        XCTAssertEqual(
            afterCurrent.reportSnapshots.first(where: { $0.id == newer.id })?.receipt.confirmedSentAt,
            currentSentAt
        )

        let repeatResult = try await repository.markReportSent(
            MarkReportSentRequest(
                snapshotID: newer.id,
                confirmedAt: makeDate(year: 2026, month: 8, day: 1, hour: 12)
            )
        )
        let repeatedState = try XCTUnwrap(repeatResult.reportStates.first)
        XCTAssertEqual(repeatedState.updatedAt, sentState.updatedAt)
        XCTAssertEqual(
            repeatResult.reportSnapshots.first(where: { $0.id == newer.id })?.receipt.confirmedSentAt,
            currentSentAt
        )
    }

    func testPrepareClampsPreparedTimestampAboveSeriesMaximum() async throws {
        let (persistence, repository) = makeRepositoryWithPersistence()
        try await configureLedgerStart(repository, month: june)
        let entry = makeEntry(
            id: "30000000-0000-0000-0000-000000000003",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 6),
            minutes: 120,
            createdAt: fixedDate(10)
        )
        try await createEntry(entry, in: repository)
        let draft = try await reportDraft(from: repository, month: july)
        let reviewTime = makeDate(year: 2026, month: 8, day: 1, hour: 8)
        _ = try await repository.reviewReport(
            ReviewReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                reviewedAt: reviewTime
            )
        )
        let firstID = UUID(uuidString: "40000000-0000-0000-0000-000000000020")!
        let firstPreparedAt = makeDate(year: 2026, month: 8, day: 1, hour: 9)
        _ = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                snapshotID: firstID,
                preparedAt: firstPreparedAt
            )
        )
        try setReviewedState(
            in: persistence,
            month: july,
            currentSnapshotID: firstID,
            calculationFingerprint: draft.calculationFingerprint,
            presentationFingerprint: draft.presentationFingerprint,
            updatedAt: makeDate(year: 2026, month: 8, day: 1, hour: 9, minute: 30)
        )

        let second = try await repository.prepareReport(
            PrepareReportRequest(
                month: july,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                expectedPresentationFingerprint: draft.presentationFingerprint,
                snapshotID: UUID(uuidString: "40000000-0000-0000-0000-000000000021")!,
                preparedAt: makeDate(year: 2026, month: 8, day: 1, hour: 8, minute: 30)
            )
        )
        XCTAssertEqual(second.snapshot.version, 2)
        XCTAssertEqual(second.snapshot.supersedesID, firstID)
        XCTAssertGreaterThan(second.snapshot.receipt.preparedAt, firstPreparedAt)
    }

    func testReportGraphRejectsMissingHeadState() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        try seedBaselineSettings(into: persistence, ledgerStartMonth: june)
        let context = persistence.container.viewContext
        let first = insertReceiptEntity(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000030")!,
            month: july,
            text: "July 2026\nHours: 1",
            preparedAt: fixedDate(100),
            version: 1,
            supersedesID: nil,
            rawServiceMinutes: 60,
            in: context
        )
        let second = insertReceiptEntity(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000031")!,
            month: july,
            text: "July 2026\nHours: 2",
            preparedAt: fixedDate(200),
            version: 2,
            supersedesID: first.id,
            rawServiceMinutes: 120,
            in: context
        )
        _ = second
        let state = context.insert(ReportStateEntity.self)
        state.id = UUID()
        state.monthKey = july.key
        state.state = ReportLifecycleState.prepared.rawValue
        state.currentSnapshotID = first.id
        state.updatedAt = fixedDate(300)
        try context.save()

        let repository = CoreDataLedgerRepository(persistence: persistence)
        do {
            _ = try await repository.ledgerSnapshot()
            XCTFail("Expected invalid graph.")
        } catch let error as LedgerRepositoryError {
            guard case .invalidManagedObject = error else {
                return XCTFail("Expected invalidManagedObject, got \(error).")
            }
        }
    }

    func testArchiveGraphRejectsForkedSeries() async throws {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        try seedBaselineSettings(into: persistence, ledgerStartMonth: MonthKey(year: 2026, month: 1))
        let context = persistence.container.viewContext
        let first = context.insert(ServiceYearArchiveEntity.self)
        first.id = UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        first.startMonthKey = MonthKey(year: 2025, month: 9).key
        first.endMonthKey = MonthKey(year: 2026, month: 8).key
        first.actualServiceMinutes = 60
        first.baselineServiceMinutes = 0
        first.targetMinutes = 36_000
        first.calculationFingerprint = "service-year-v1:first"
        first.version = 1
        first.createdAt = fixedDate(100)

        let second = context.insert(ServiceYearArchiveEntity.self)
        second.id = UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
        second.startMonthKey = first.startMonthKey
        second.endMonthKey = first.endMonthKey
        second.actualServiceMinutes = 120
        second.baselineServiceMinutes = 0
        second.targetMinutes = 36_000
        second.calculationFingerprint = "service-year-v1:second"
        second.version = 2
        second.supersedesID = first.id
        second.createdAt = fixedDate(200)

        let third = context.insert(ServiceYearArchiveEntity.self)
        third.id = UUID(uuidString: "60000000-0000-0000-0000-000000000003")!
        third.startMonthKey = first.startMonthKey
        third.endMonthKey = first.endMonthKey
        third.actualServiceMinutes = 180
        third.baselineServiceMinutes = 0
        third.targetMinutes = 36_000
        third.calculationFingerprint = "service-year-v1:third"
        third.version = 3
        third.supersedesID = first.id
        third.createdAt = fixedDate(300)
        try context.save()

        let repository = CoreDataLedgerRepository(persistence: persistence)
        do {
            _ = try await repository.ledgerSnapshot()
            XCTFail("Expected invalid archive graph.")
        } catch let error as LedgerRepositoryError {
            guard case .invalidManagedObject = error else {
                return XCTFail("Expected invalidManagedObject, got \(error).")
            }
        }
    }

    func testCloseServiceYearAllowsPartialFirstYearServiceOnlyAndReplayAfterLaterMutation() async throws {
        let repository = makeRepository()
        try await configureLedgerStart(repository, month: MonthKey(year: 2026, month: 1))
        let firstServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-000000000004",
            kind: .service,
            day: LocalDay(year: 2026, month: 2, day: 10),
            minutes: 5_999,
            createdAt: fixedDate(10)
        )
        let secondServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-000000000006",
            kind: .service,
            day: LocalDay(year: 2026, month: 4, day: 12),
            minutes: 5_999,
            createdAt: fixedDate(15)
        )
        let thirdServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-000000000007",
            kind: .service,
            day: LocalDay(year: 2026, month: 6, day: 8),
            minutes: 5_999,
            createdAt: fixedDate(18)
        )
        let fourthServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-000000000008",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 20),
            minutes: 5_999,
            createdAt: fixedDate(19)
        )
        let fifthServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-000000000009",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 25),
            minutes: 5_999,
            createdAt: fixedDate(20)
        )
        let sixthServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-00000000000A",
            kind: .service,
            day: LocalDay(year: 2026, month: 7, day: 28),
            minutes: 5_999,
            createdAt: fixedDate(21)
        )
        let seventhServiceEntry = makeEntry(
            id: "30000000-0000-0000-0000-00000000000B",
            kind: .service,
            day: LocalDay(year: 2026, month: 8, day: 3),
            minutes: 66,
            createdAt: fixedDate(22)
        )
        let creditEntry = makeEntry(
            id: "30000000-0000-0000-0000-000000000005",
            kind: .credit,
            day: LocalDay(year: 2026, month: 3, day: 10),
            minutes: 600,
            createdAt: fixedDate(20)
        )
        let firstCreate = try await createEntry(firstServiceEntry, in: repository)
        try await createEntry(secondServiceEntry, in: repository)
        try await createEntry(thirdServiceEntry, in: repository)
        try await createEntry(fourthServiceEntry, in: repository)
        try await createEntry(fifthServiceEntry, in: repository)
        try await createEntry(sixthServiceEntry, in: repository)
        try await createEntry(seventhServiceEntry, in: repository)
        try await createEntry(creditEntry, in: repository)

        let start = MonthKey(year: 2025, month: 9)
        let draft = try await serviceYearDraft(from: repository, startMonth: start)
        let archiveID = UUID(uuidString: "60000000-0000-0000-0000-000000000010")!
        let first = try await repository.closeServiceYear(
            CloseServiceYearRequest(
                startMonth: start,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                archiveID: archiveID,
                createdAt: makeDate(year: 2026, month: 9, day: 2, hour: 9)
            )
        )
        XCTAssertFalse(first.wasReplay)
        XCTAssertEqual(first.archive.actualServiceMinutes, 36_060)
        XCTAssertEqual(first.archive.baselineServiceMinutes, 0)
        XCTAssertEqual(first.archive.targetMinutes, 36_000)

        _ = try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(uuidString: "50000000-0000-0000-0000-000000000010")!,
                entryID: firstServiceEntry.id,
                expectedRevision: firstCreate.appliedRevision,
                operation: .update,
                values: EntryMutationValues(
                    kind: .service,
                    day: firstServiceEntry.day,
                    minutes: 5_998,
                    note: nil
                ),
                occurredAt: makeDate(year: 2026, month: 8, day: 3, hour: 10),
                source: .appHistory
            )
        )

        let replay = try await repository.closeServiceYear(
            CloseServiceYearRequest(
                startMonth: start,
                expectedCalculationFingerprint: draft.calculationFingerprint,
                archiveID: archiveID,
                createdAt: makeDate(year: 2026, month: 9, day: 2, hour: 9)
            )
        )
        XCTAssertTrue(replay.wasReplay)
        XCTAssertEqual(replay.archive.id, archiveID)
        XCTAssertEqual(replay.ledger.serviceYearArchives.count, 1)
    }

    private func report(
        for month: MonthKey,
        entries: [TimeEntry],
        mode: RemainderMode
    ) -> MonthlyReport? {
        ReportCalculator.timeline(
            entries: entries,
            from: month,
            through: month,
            openingServiceCarry: 0,
            openingCreditCarry: 0,
            policies: [ReportingPolicy(effectiveMonth: month, mode: mode, createdAt: fixedDate(1))]
        ).last
    }

    private func snapshotWithSingleEntry(
        minutes: Int,
        month: MonthKey,
        mode: RemainderMode
    ) -> LedgerSnapshot {
        let entry = makeEntry(
            id: "00000000-0000-0000-0000-000000000001",
            kind: .service,
            day: LocalDay(year: month.year, month: month.month, day: 1),
            minutes: minutes
        )
        return makeSnapshot(
            entries: [makeRecord(entry)],
            settings: makeSettings(ledgerStartMonth: month),
            policies: [ReportingPolicy(effectiveMonth: month, mode: mode, createdAt: fixedDate(1))]
        )
    }

    private func makeSettings(ledgerStartMonth: MonthKey) -> AppSettings {
        var settings = AppSettings()
        settings.reportLanguage = .english
        settings.ledgerStartMonth = ledgerStartMonth
        settings.baselineServiceYearMinutes = 0
        settings.baselineServiceYearStart = MonthKey(
            year: ledgerStartMonth.month >= 9 ? ledgerStartMonth.year : ledgerStartMonth.year - 1,
            month: 9
        )
        settings.openingServiceCarryMinutes = 0
        settings.openingCreditCarryMinutes = 0
        return settings
    }

    private func makeRepository() -> CoreDataLedgerRepository {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        return CoreDataLedgerRepository(persistence: persistence)
    }

    private func makeRepositoryWithPersistence() -> (PersistenceController, CoreDataLedgerRepository) {
        let persistence = PersistenceController(inMemory: true, cloudSyncEnabled: false)
        return (persistence, CoreDataLedgerRepository(persistence: persistence))
    }

    private func configureLedgerStart(
        _ repository: CoreDataLedgerRepository,
        month: MonthKey
    ) async throws {
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = month
        settings.baselineServiceYearStart = MonthKey(
            year: month.month >= 9 ? month.year : month.year - 1,
            month: 9
        )
        try await repository.saveSettings(settings)
    }

    private func createEntry(
        _ entry: TimeEntry,
        in repository: CoreDataLedgerRepository
    ) async throws -> EntryMutationReceipt {
        try await repository.apply(
            EntryMutationCommand(
                mutationID: UUID(),
                entryID: entry.id,
                expectedRevision: nil,
                operation: .create,
                values: EntryMutationValues(
                    kind: entry.kind,
                    day: entry.day,
                    minutes: entry.minutes,
                    note: entry.note
                ),
                occurredAt: entry.updatedAt,
                source: .appQuickEntry
            )
        )
    }

    private func reportDraft(
        from repository: CoreDataLedgerRepository,
        month: MonthKey
    ) async throws -> ReportDraft {
        let snapshot = try await repository.ledgerSnapshot()
        return try XCTUnwrap(ReportReadiness.draft(for: month, in: snapshot))
    }

    private func serviceYearDraft(
        from repository: CoreDataLedgerRepository,
        startMonth: MonthKey
    ) async throws -> ServiceYearDraft {
        let snapshot = try await repository.ledgerSnapshot()
        return try XCTUnwrap(ReportReadiness.serviceYearDraft(starting: startMonth, in: snapshot))
    }

    private func reportDetails(
        for receipt: ReportReceipt,
        rawServiceMinutes: Int
    ) -> ReportSnapshotDetails {
        let calculationFingerprint = "calculation-\(receipt.id.uuidString.lowercased())"
        return ReportSnapshotDetails(
            report: MonthlyReport(
                month: receipt.month,
                rawServiceMinutes: rawServiceMinutes,
                rawCreditMinutes: 0,
                serviceCarryIn: 0,
                creditCarryIn: 0,
                serviceHours: receipt.serviceHours,
                creditHours: receipt.creditHours,
                serviceCarryOut: receipt.serviceCarryOut,
                creditCarryOut: receipt.creditCarryOut
            ),
            reportingMode: .carry,
            reportLanguage: .english,
            creditLabel: "Credit hours",
            templateID: "standard",
            calculationFingerprint: calculationFingerprint,
            presentationFingerprint: ReportFingerprint.presentation(
                calculationFingerprint: calculationFingerprint,
                language: .english,
                creditLabel: "Credit hours",
                templateID: "standard",
                text: receipt.text
            )
        )
    }

    private func setReviewedState(
        in persistence: PersistenceController,
        month: MonthKey,
        currentSnapshotID: UUID,
        calculationFingerprint: String,
        presentationFingerprint: String,
        updatedAt: Date
    ) throws {
        let context = persistence.container.viewContext
        let request: NSFetchRequest<ReportStateEntity> = ReportStateEntity.request()
        request.predicate = NSPredicate(format: "monthKey == %@", month.key)
        let state = try context.fetch(request).first ?? context.insert(ReportStateEntity.self)
        state.id = state.id ?? UUID()
        state.monthKey = month.key
        state.state = ReportLifecycleState.reviewed.rawValue
        state.currentSnapshotID = currentSnapshotID
        state.reviewedCalculationFingerprint = calculationFingerprint
        state.reviewedPresentationFingerprint = presentationFingerprint
        state.lastStableState = nil
        state.changedAt = nil
        state.updatedAt = updatedAt
        try context.save()
    }

    private func seedBaselineSettings(
        into persistence: PersistenceController,
        ledgerStartMonth: MonthKey
    ) throws {
        let context = persistence.container.viewContext
        let settings = context.insert(SettingsEntity.self)
        settings.id = UUID(uuidString: "10000000-0000-0000-0000-000000000099")!
        settings.reportLanguage = ReportLanguage.english.rawValue
        settings.creditLabelEnglish = "Credit hours"
        settings.creditLabelRussian = "Кредит часов"
        settings.creditLabelUkrainian = "Кредит годин"
        settings.ledgerStartMonth = ledgerStartMonth.key
        settings.baselineServiceYearMinutes = 0
        settings.baselineServiceYearStart = MonthKey(year: 2025, month: 9).key
        settings.openingServiceCarryMinutes = 0
        settings.openingCreditCarryMinutes = 0
        settings.onboardingComplete = true
        settings.updatedAt = fixedDate(1)
        settings.dataRevision = 2
        settings.planningVisible = false
        settings.quietGapCheckEnabled = false
        settings.quietGapDays = 7
        settings.timerVisible = false
        settings.syncMode = "localOnly"
        settings.widgetPrivacyMode = "private"
        try context.save()
    }

    @discardableResult
    private func insertReceiptEntity(
        id: UUID,
        month: MonthKey,
        text: String,
        preparedAt: Date,
        version: Int32,
        supersedesID: UUID?,
        rawServiceMinutes: Int,
        in context: NSManagedObjectContext
    ) -> ReportReceiptEntity {
        let object = context.insert(ReportReceiptEntity.self)
        object.id = id
        object.monthKey = month.key
        object.reportText = text
        object.serviceHours = Int32(rawServiceMinutes / 60)
        object.creditHours = 0
        object.serviceCarryOut = Int32(rawServiceMinutes % 60)
        object.creditCarryOut = 0
        object.preparedAt = preparedAt
        object.confirmedSentAt = nil
        object.schemaVersion = 2
        object.version = version
        object.supersedesID = supersedesID
        object.rawServiceMinutes = Int64(rawServiceMinutes)
        object.rawCreditMinutes = 0
        object.serviceCarryIn = 0
        object.creditCarryIn = 0
        object.reportingMode = RemainderMode.carry.rawValue
        object.reportLanguage = ReportLanguage.english.rawValue
        object.creditLabel = "Credit hours"
        object.templateID = "standard"
        object.calculationFingerprint = "v2:\(id.uuidString.lowercased())"
        object.presentationFingerprint = "v2:p-\(id.uuidString.lowercased())"
        object.createdBySource = ReportReadiness.reportSnapshotSource
        object.legacyCalculationUnavailable = false
        return object
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 0,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar.hourleaf
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date ?? fixedDate(9_999)
    }

    private func assertLifecycleError(
        _ expected: ReportLifecycleError,
        operation: @escaping () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected).")
        } catch let error as ReportLifecycleError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Expected \(expected), got \(error).")
        }
    }

    private func makeSnapshot(
        entries: [LedgerEntryRecord] = [],
        settings: AppSettings,
        policies: [ReportingPolicy] = []
    ) -> LedgerSnapshot {
        LedgerSnapshot(
            entries: entries,
            settings: settings,
            settingsMetadata: LedgerSettingsMetadata(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                dataRevision: 2,
                planningVisible: false,
                quietGapCheckEnabled: false,
                quietGapDays: 7,
                timerVisible: false,
                syncMode: "localOnly",
                widgetPrivacyMode: "private",
                lastPurgeAt: nil
            ),
            policies: policies,
            reminders: [],
            reportSnapshots: [],
            reportStates: [],
            entryRevisions: [],
            presets: [],
            dayAcknowledgements: [],
            serviceYearArchives: []
        )
    }

    private func makeRecord(
        _ entry: TimeEntry,
        deletedAt: Date? = nil,
        source: String = "app",
        revision: Int64 = 1
    ) -> LedgerEntryRecord {
        LedgerEntryRecord(
            entry: entry,
            deletedAt: deletedAt,
            source: source,
            revision: revision,
            lastMutationID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
    }

    private func makeEntry(
        id: String,
        kind: EntryKind,
        day: LocalDay,
        minutes: Int,
        note: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) -> TimeEntry {
        let createdAt = createdAt ?? fixedDate(1)
        return TimeEntry(
            id: UUID(uuidString: id)!,
            kind: kind,
            day: day,
            minutes: minutes,
            note: note,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt
        )
    }

    private func fixedDate(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }
}
