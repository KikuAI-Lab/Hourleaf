import XCTest
@testable import Hourleaf

@MainActor
final class WatchTimeEntryTests: XCTestCase {
    func testEnvelopeAndResponseRoundTripPreserveExactIdentity() throws {
        let mutationID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let entryID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let occurredAt = Date(timeIntervalSince1970: 1_786_359_600)
        let envelope = try WatchTimeEntryEnvelopeV1(
            mutationID: mutationID,
            entryID: entryID,
            kind: .credit,
            day: WatchCivilDayV1(year: 2026, month: 8, day: 10),
            minutes: 95,
            occurredAt: occurredAt
        )

        let encoded = try envelope.encoded()
        XCTAssertLessThanOrEqual(encoded.count, WatchTimeEntryEnvelopeV1.maximumEncodedBytes)
        XCTAssertEqual(try WatchTimeEntryEnvelopeV1.decode(encoded), envelope)

        let response = WatchTimeEntryResponseV1(mutationID: mutationID, status: .saved)
        XCTAssertEqual(
            try WatchTimeEntryResponseV1.decode(
                response.encoded(),
                expecting: mutationID
            ),
            response
        )
        XCTAssertThrowsError(
            try WatchTimeEntryResponseV1.decode(
                response.encoded(),
                expecting: UUID()
            )
        ) { error in
            XCTAssertEqual(error as? WatchTimeEntryContractError, .responseMismatch)
        }
    }

    func testContractRejectsInvalidDurationsDatesVersionsAndPayloadBounds() throws {
        XCTAssertThrowsError(try WatchTimeEntryDurationV1.totalMinutes(hours: 0, minutes: 0)) { caughtError in
            XCTAssertEqual(caughtError as? WatchTimeEntryContractError, .emptyDuration)
        }
        XCTAssertThrowsError(try WatchTimeEntryDurationV1.totalMinutes(hours: 100, minutes: 0)) { caughtError in
            XCTAssertEqual(caughtError as? WatchTimeEntryContractError, .invalidHours)
        }
        XCTAssertThrowsError(try WatchTimeEntryDurationV1.totalMinutes(hours: 0, minutes: 60)) { caughtError in
            XCTAssertEqual(caughtError as? WatchTimeEntryContractError, .invalidMinutes)
        }
        XCTAssertThrowsError(try WatchCivilDayV1(year: 2026, month: 2, day: 29)) { caughtError in
            XCTAssertEqual(caughtError as? WatchTimeEntryContractError, .invalidDay)
        }
        XCTAssertThrowsError(
            try WatchTimeEntryEnvelopeV1.decode(
                Data(repeating: 0, count: WatchTimeEntryEnvelopeV1.maximumEncodedBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? WatchTimeEntryContractError, .payloadTooLarge)
        }

        let unsupported = UnsupportedEnvelopeFixture(
            version: 2,
            mutationID: UUID(),
            entryID: UUID(),
            kind: .service,
            day: try WatchCivilDayV1(year: 2026, month: 8, day: 10),
            minutes: 1,
            occurredAt: Date(timeIntervalSince1970: 1_786_359_600)
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        XCTAssertThrowsError(
            try WatchTimeEntryEnvelopeV1.decode(encoder.encode(unsupported))
        ) { error in
            XCTAssertEqual(error as? WatchTimeEntryContractError, .unsupportedVersion)
        }
    }

    func testSpokenDurationConvertsCompoundUnitsWithoutRoundingUserInput() throws {
        XCTAssertEqual(
            try WatchTimeEntryDurationV1.totalMinutes(
                duration: Measurement(value: 1.5, unit: UnitDuration.hours)
            ),
            90
        )
        XCTAssertEqual(
            try WatchTimeEntryDurationV1.totalMinutes(
                duration: Measurement(value: 80, unit: UnitDuration.minutes)
            ),
            80
        )
        XCTAssertThrowsError(
            try WatchTimeEntryDurationV1.totalMinutes(
                duration: Measurement(value: 90, unit: UnitDuration.seconds)
            )
        ) { error in
            XCTAssertEqual(error as? WatchTimeEntryContractError, .invalidMinutes)
        }
        XCTAssertThrowsError(
            try WatchTimeEntryDurationV1.totalMinutes(
                duration: Measurement(value: 0, unit: UnitDuration.minutes)
            )
        ) { error in
            XCTAssertEqual(error as? WatchTimeEntryContractError, .emptyDuration)
        }
        XCTAssertThrowsError(
            try WatchTimeEntryDurationV1.totalMinutes(
                duration: Measurement(value: 100, unit: UnitDuration.hours)
            )
        ) { error in
            XCTAssertEqual(error as? WatchTimeEntryContractError, .durationTooLarge)
        }
    }

    func testWatchUserShortcutsHaveDistinctFixedKindIntentIdentifiers() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("HourleafWatch")
                .appendingPathComponent("WatchRecordTimeIntent.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("struct WatchRecordServiceTimeIntent: AppIntent"))
        XCTAssertTrue(source.contains("struct WatchRecordCreditTimeIntent: AppIntent"))
        XCTAssertTrue(source.contains("intent: WatchRecordServiceTimeIntent()"))
        XCTAssertTrue(source.contains("intent: WatchRecordCreditTimeIntent()"))
        XCTAssertFalse(source.contains("WatchRecordTimeIntent(kind:"))
        XCTAssertFalse(source.contains(".requiresAuthentication"))
        XCTAssertEqual(
            source.components(separatedBy: ".alwaysAllowed").count - 1,
            2
        )
    }

    func testReceiverWritesServiceAndCreditThroughWatchMutationSource() async throws {
        let repository = try await makeRepository()
        let router = AppRouter()
        let receiver = WatchTimeEntryReceiver(repository: repository, router: router)
        let day = try WatchCivilDayV1(Date.now)
        let service = try WatchTimeEntryEnvelopeV1(
            kind: .service,
            day: day,
            minutes: 75
        )
        let credit = try WatchTimeEntryEnvelopeV1(
            kind: .credit,
            day: day,
            minutes: 45
        )

        let serviceResponse = await receiver.receive(try service.encoded())
        let creditResponse = await receiver.receive(try credit.encoded())
        XCTAssertEqual(serviceResponse.status, .saved)
        XCTAssertEqual(creditResponse.status, .saved)

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.count, 2)
        XCTAssertEqual(snapshot.activeEntries.first(where: { $0.kind == .service })?.minutes, 75)
        XCTAssertEqual(snapshot.activeEntries.first(where: { $0.kind == .credit })?.minutes, 45)
        XCTAssertTrue(snapshot.entryRevisions.allSatisfy { $0.source == EntryMutationSource.watch.rawValue })
        XCTAssertTrue(snapshot.entryRevisions.allSatisfy { $0.note == nil })
        XCTAssertEqual(router.ledgerChangeGeneration, 2)
    }

    func testReceiverReplayIsIdempotentAndReturnsReplayed() async throws {
        let repository = try await makeRepository()
        let receiver = WatchTimeEntryReceiver(repository: repository)
        let envelope = try WatchTimeEntryEnvelopeV1(
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000010")!,
            entryID: UUID(uuidString: "20000000-0000-0000-0000-000000000010")!,
            kind: .service,
            day: WatchCivilDayV1(Date.now),
            minutes: 30
        )
        let data = try envelope.encoded()

        let firstResponse = await receiver.receive(data)
        let replayResponse = await receiver.receive(data)
        XCTAssertEqual(firstResponse.status, .saved)
        XCTAssertEqual(replayResponse.status, .replayed)

        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertEqual(snapshot.activeEntries.count, 1)
        XCTAssertEqual(snapshot.entryRevisions.count, 1)
        XCTAssertEqual(snapshot.entryRevisions.first?.mutationID, envelope.mutationID)
    }

    func testReceiverRejectsMalformedPayloadAndDoesNotWrite() async throws {
        let repository = try await makeRepository()
        let receiver = WatchTimeEntryReceiver(repository: repository)

        let response = await receiver.receive(Data("not a property list".utf8))

        XCTAssertEqual(response.status, .rejected)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.entryRevisions.isEmpty)
    }

    func testReceiverDoesNotClaimSuccessWhenRepositoryRejectsFutureDay() async throws {
        let now = Date.now
        let repository = try await makeRepository(clock: { now })
        let receiver = WatchTimeEntryReceiver(repository: repository)
        let tomorrow = now.addingTimeInterval(24 * 60 * 60)
        let envelope = try WatchTimeEntryEnvelopeV1(
            kind: .service,
            day: WatchCivilDayV1(tomorrow),
            minutes: 60,
            occurredAt: now
        )

        let response = await receiver.receive(try envelope.encoded())
        XCTAssertEqual(response.status, .failed)
        let snapshot = try await repository.ledgerSnapshot()
        XCTAssertTrue(snapshot.entries.isEmpty)
        XCTAssertTrue(snapshot.entryRevisions.isEmpty)
    }

    private func makeRepository(
        clock: @escaping @Sendable () -> Date = { .now }
    ) async throws -> CoreDataLedgerRepository {
        let repository = CoreDataLedgerRepository(
            persistence: PersistenceController(inMemory: true, cloudSyncEnabled: false),
            clock: clock
        )
        var settings = try await repository.loadSettings()
        settings.ledgerStartMonth = MonthKey(Date.now, calendar: .hourleaf)
        settings.baselineServiceYearStart = MonthKey(
            year: settings.ledgerStartMonth.month >= 9
                ? settings.ledgerStartMonth.year
                : settings.ledgerStartMonth.year - 1,
            month: 9
        )
        try await repository.saveSettings(settings)
        return repository
    }
}

private struct UnsupportedEnvelopeFixture: Encodable {
    let version: Int
    let mutationID: UUID
    let entryID: UUID
    let kind: WatchTimeEntryKindV1
    let day: WatchCivilDayV1
    let minutes: Int
    let occurredAt: Date
}
