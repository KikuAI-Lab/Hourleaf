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
