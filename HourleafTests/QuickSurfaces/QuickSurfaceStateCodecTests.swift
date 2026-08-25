import XCTest
@testable import Hourleaf

final class QuickSurfaceStateCodecTests: XCTestCase {
    func testIdleStateRoundTripsToStableCanonicalBytes() throws {
        let state = try makeIdleState()
        let first = try QuickSurfaceStateV1.encodeCanonical(state)
        let second = try QuickSurfaceStateV1.encodeCanonical(state)

        XCTAssertEqual(first, second)
        XCTAssertLessThanOrEqual(first.count, QuickSurfaceStateV1.maximumFileBytes)
        XCTAssertEqual(try QuickSurfaceStateV1.decodeStrict(first), state)
    }

    func testRunningStateRoundTrips() throws {
        let state = try makeRunningState()
        XCTAssertEqual(try QuickSurfaceStateV1.decodeStrict(QuickSurfaceStateV1.encodeCanonical(state)), state)
    }

    func testLegacyCanonicalProjectionStillDecodesAndReencodesWithExtendedKeys() throws {
        let legacyJSON = #"{"projection":{"creditMinutes":null,"generatedAtEpochSeconds":100,"monthKey":null,"privacyMode":"hideTotals","serviceMinutes":null,"timeZoneIdentifier":null},"revision":1,"schemaVersion":1,"timer":{"phase":"idle"},"timerEnabled":false}"#
        let state = try QuickSurfaceStateV1.decodeStrict(Data(legacyJSON.utf8))

        XCTAssertNil(state.projection.bibleStudyCount)
        XCTAssertNil(state.projection.serviceYearMinutes)
        XCTAssertNil(state.projection.serviceYearTargetMinutes)

        let upgraded = try XCTUnwrap(
            String(data: QuickSurfaceStateV1.encodeCanonical(state), encoding: .utf8)
        )
        XCTAssertTrue(upgraded.contains("\"bibleStudyCount\":null"))
        XCTAssertTrue(upgraded.contains("\"serviceYearMinutes\":null"))
        XCTAssertTrue(upgraded.contains("\"serviceYearTargetMinutes\":null"))
    }

    func testLegacyCanonicalShownProjectionPreservesExistingTotals() throws {
        let legacyJSON = #"{"projection":{"creditMinutes":7,"generatedAtEpochSeconds":100,"monthKey":"2026-08","privacyMode":"showTotals","serviceMinutes":125,"timeZoneIdentifier":"Europe/Uzhgorod"},"revision":2,"schemaVersion":1,"timer":{"phase":"idle"},"timerEnabled":true}"#
        let state = try QuickSurfaceStateV1.decodeStrict(Data(legacyJSON.utf8))

        XCTAssertEqual(state.projection.monthKey, "2026-08")
        XCTAssertEqual(state.projection.serviceMinutes, 125)
        XCTAssertEqual(state.projection.creditMinutes, 7)
        XCTAssertNil(state.projection.bibleStudyCount)
        XCTAssertNil(state.projection.serviceYearMinutes)
        XCTAssertNil(state.projection.serviceYearTargetMinutes)
    }

    func testReviewPendingStateRoundTripsWithSuggestion() throws {
        let state = try makeReviewPendingState(suggestedMinutes: 42)
        XCTAssertEqual(try QuickSurfaceStateV1.decodeStrict(QuickSurfaceStateV1.encodeCanonical(state)), state)
    }

    func testFinalizingStateRoundTripsWithoutSuggestion() throws {
        let state = try makeFinalizingState(suggestedMinutes: nil)
        XCTAssertEqual(try QuickSurfaceStateV1.decodeStrict(QuickSurfaceStateV1.encodeCanonical(state)), state)
    }

    func testCanonicalEncodingUsesExactExpectedKeysAndNoPrivacyLeakFieldNames() throws {
        let data = try QuickSurfaceStateV1.encodeCanonical(makeFinalizingState(suggestedMinutes: 17))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertTrue(text.contains("\"schemaVersion\":1"))
        XCTAssertTrue(text.contains("\"phase\":\"finalizing\""))
        XCTAssertTrue(text.contains("\"suggestedMinutes\":17"))
        XCTAssertFalse(text.contains("\"note\""))
        XCTAssertFalse(text.contains("\"creditLabel\""))
        XCTAssertFalse(text.contains("\"history\""))
        XCTAssertFalse(text.contains("\"recentEntry\""))
    }

    func testStrictDecoderRejectsWhitespaceReorderedKeysDuplicateKeysAndUnknownKeys() throws {
        let data = try QuickSurfaceStateV1.encodeCanonical(makeFinalizingState(suggestedMinutes: 17))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        assertDecodeFails(Data((" " + text).utf8), expecting: .nonCanonicalJSON)
        assertDecodeFails(Data((text + "\n").utf8), expecting: .nonCanonicalJSON)
        assertDecodeFails(
            Data(text.replacingOccurrences(of: "\"creditMinutes\":7,\"generatedAtEpochSeconds\":123.25", with: "\"generatedAtEpochSeconds\":123.25,\"creditMinutes\":7").utf8),
            expecting: .nonCanonicalJSON
        )
        assertDecodeFails(
            Data(text.replacingOccurrences(of: "\"timerEnabled\":true", with: "\"timerEnabled\":true,\"timerEnabled\":true").utf8),
            expecting: .nonCanonicalJSON
        )
        assertDecodeFails(
            Data(text.replacingOccurrences(of: "\"schemaVersion\":1,", with: "\"schemaVersion\":1,\"unknown\":0,").utf8),
            expecting: .wrongKeys(
                path: "state",
                expected: [],
                actual: []
            )
        )
    }

    func testStrictDecoderRejectsUnsupportedVersionCorruptJsonAndInvalidOverflowingNumbers() throws {
        let data = try QuickSurfaceStateV1.encodeCanonical(makeRunningState())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        assertDecodeFails(
            Data(text.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2").utf8),
            expecting: .unsupportedVersion(2)
        )
        assertDecodeFails(Data([0xFF]), expecting: .invalidJSON(""))
        assertDecodeFails(
            Data(text.replacingOccurrences(of: "\"revision\":3", with: "\"revision\":18446744073709551616").utf8),
            expecting: .invalidJSON("")
        )
        assertDecodeFails(
            Data(text.replacingOccurrences(of: "\"startedAtEpochSeconds\":100", with: "\"startedAtEpochSeconds\":1e999").utf8),
            expecting: .invalidJSON("")
        )
    }

    func testStrictDecoderRejectsPrivacyMatrices() throws {
        let hidden = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeIdleState()), encoding: .utf8))
        assertDecodeFails(
            Data(hidden.replacingOccurrences(of: "\"monthKey\":null", with: "\"monthKey\":\"2026-08\"").utf8),
            expecting: .invalidValue("hideTotals requires all projection totals to be nil")
        )

        let shown = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeRunningState()), encoding: .utf8))
        assertDecodeFails(
            Data(shown.replacingOccurrences(of: "\"monthKey\":\"2026-08\"", with: "\"monthKey\":null").utf8),
            expecting: .invalidValue("showTotals requires month, time zone, and both totals")
        )
        assertDecodeFails(
            Data(shown.replacingOccurrences(of: "\"serviceMinutes\":125", with: "\"serviceMinutes\":2147483648").utf8),
            expecting: .invalidValue("projection.serviceMinutes must be in 0...Int32.max")
        )
        assertDecodeFails(
            Data(shown.replacingOccurrences(of: "\"serviceYearMinutes\":24750", with: "\"serviceYearMinutes\":null").utf8),
            expecting: .invalidValue("showTotals requires either all extended metrics or none")
        )
        assertDecodeFails(
            Data(shown.replacingOccurrences(of: "\"bibleStudyCount\":4", with: "\"bibleStudyCount\":1000").utf8),
            expecting: .invalidValue("projection.bibleStudyCount must be in 0...999")
        )
    }

    func testStrictDecoderRejectsWrongPhaseExtraAndMissingFields() throws {
        let running = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeRunningState()), encoding: .utf8))
        assertDecodeFails(
            Data(running.replacingOccurrences(of: "\"startedSystemUptimeSeconds\":20", with: "\"startedSystemUptimeSeconds\":20,\"authorizedKind\":\"service\"").utf8),
            expecting: .wrongKeys(path: "timer", expected: [], actual: [])
        )

        let reviewPending = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeReviewPendingState(suggestedMinutes: 5)), encoding: .utf8))
        assertDecodeFails(
            Data(reviewPending.replacingOccurrences(of: ",\"entryID\":\"44444444-4444-4444-4444-444444444444\"", with: "").utf8),
            expecting: .wrongKeys(path: "timer", expected: [], actual: [])
        )
    }

    func testStrictDecoderRejectsInvalidMonthDayTimeZoneUuidEnumAndNonfiniteValues() throws {
        let finalizing = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeFinalizingState(suggestedMinutes: 15)), encoding: .utf8))
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"authorizedDay\":\"2026-08-03\"", with: "\"authorizedDay\":\"2026-02-30\"").utf8),
            expecting: .invalidValue("timer.authorizedDay must be YYYY-MM-DD")
        )
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"timeZoneIdentifier\":\"Europe/Uzhgorod\"", with: "\"timeZoneIdentifier\":\"Mars/Phobos\"").utf8),
            expecting: .invalidValue("projection.timeZoneIdentifier must be an existing IANA identifier")
        )
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"timeZoneIdentifier\":\"Europe/Uzhgorod\"", with: "\"timeZoneIdentifier\":\"EST\"").utf8),
            expecting: .invalidValue("projection.timeZoneIdentifier must be an existing IANA identifier")
        )
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"monthKey\":\"2026-08\"", with: "\"monthKey\":\"2026-13\"").utf8),
            expecting: .invalidValue("projection.monthKey must be YYYY-MM")
        )
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"sessionID\":\"33333333-3333-3333-3333-333333333333\"", with: "\"sessionID\":\"not-a-uuid\"").utf8),
            expecting: .invalidJSON("")
        )
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"clockAssessment\":\"manualRequired\"", with: "\"clockAssessment\":\"wrong\"").utf8),
            expecting: .invalidJSON("")
        )
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"authorizedAtEpochSeconds\":170", with: "\"authorizedAtEpochSeconds\":-1").utf8),
            expecting: .invalidValue("timer.authorizedAtEpochSeconds must be finite and nonnegative")
        )

        let leapDay = try makeFinalizingState(suggestedMinutes: nil, authorizedDay: "2024-02-29")
        XCTAssertEqual(
            try QuickSurfaceStateV1.decodeStrict(QuickSurfaceStateV1.encodeCanonical(leapDay)),
            leapDay
        )
    }

    func testStrictDecoderRejectsInvalidTimerBounds() throws {
        let reviewPending = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeReviewPendingState(suggestedMinutes: 5)), encoding: .utf8))
        assertDecodeFails(
            Data(reviewPending.replacingOccurrences(of: "\"elapsedSeconds\":3600", with: "\"elapsedSeconds\":-1").utf8),
            expecting: .invalidValue("timer.elapsedSeconds must be >= 0")
        )
        assertDecodeFails(
            Data(reviewPending.replacingOccurrences(of: "\"suggestedMinutes\":5", with: "\"suggestedMinutes\":6000").utf8),
            expecting: .invalidValue("timer.suggestedMinutes must be nil or in 1...5999")
        )

        let finalizing = try XCTUnwrap(String(data: QuickSurfaceStateV1.encodeCanonical(makeFinalizingState(suggestedMinutes: 15)), encoding: .utf8))
        assertDecodeFails(
            Data(finalizing.replacingOccurrences(of: "\"authorizedMinutes\":75", with: "\"authorizedMinutes\":0").utf8),
            expecting: .invalidValue("timer.authorizedMinutes must be in 1...5999")
        )
    }

    func testStrictDecoderRejectsOversizedFile() {
        let oversized = Data(repeating: 0x20, count: QuickSurfaceStateV1.maximumFileBytes + 1)
        assertDecodeFails(
            oversized,
            expecting: .fileTooLarge(actual: QuickSurfaceStateV1.maximumFileBytes + 1, limit: QuickSurfaceStateV1.maximumFileBytes)
        )
    }

    func testRevisionUInt64MaxRemainsCodecValid() throws {
        let state = QuickSurfaceStateV1(
            revision: .max,
            projection: try makeShownProjection(),
            timerEnabled: true,
            timer: .idle
        )
        XCTAssertEqual(try QuickSurfaceStateV1.decodeStrict(QuickSurfaceStateV1.encodeCanonical(state)), state)
    }

    private func makeIdleState() throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 1,
            projection: try QuickSurfaceProjectionV1(
                privacyMode: .hideTotals,
                monthKey: nil,
                timeZoneIdentifier: nil,
                serviceMinutes: nil,
                creditMinutes: nil,
                generatedAtEpochSeconds: 100
            ),
            timerEnabled: false,
            timer: .idle
        )
    }

    private func makeRunningState() throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 3,
            projection: try makeShownProjection(),
            timerEnabled: true,
            timer: .running(
                try .init(
                    sessionID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    startedAtEpochSeconds: 100,
                    startedSystemUptimeSeconds: 20
                )
            )
        )
    }

    private func makeReviewPendingState(suggestedMinutes: Int?) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 7,
            projection: try makeShownProjection(),
            timerEnabled: true,
            timer: .reviewPending(
                try .init(
                    sessionID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    startedAtEpochSeconds: 100,
                    stoppedAtEpochSeconds: 3_900,
                    elapsedSeconds: 3_600,
                    clockAssessment: .sameBootMonotonic,
                    suggestedMinutes: suggestedMinutes,
                    mutationID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    entryID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
                )
            )
        )
    }

    private func makeFinalizingState(
        suggestedMinutes: Int?,
        authorizedDay: String = "2026-08-03"
    ) throws -> QuickSurfaceStateV1 {
        QuickSurfaceStateV1(
            revision: 9,
            projection: try makeShownProjection(),
            timerEnabled: true,
            timer: .finalizing(
                try .init(
                    sessionID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    startedAtEpochSeconds: 100,
                    stoppedAtEpochSeconds: 3_900,
                    elapsedSeconds: 3_600,
                    clockAssessment: .manualRequired,
                    suggestedMinutes: suggestedMinutes,
                    mutationID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    entryID: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                    authorizedKind: .service,
                    authorizedDay: authorizedDay,
                    authorizedMinutes: 75,
                    authorizedAtEpochSeconds: 170
                )
            )
        )
    }

    private func makeShownProjection() throws -> QuickSurfaceProjectionV1 {
        try QuickSurfaceProjectionV1(
            privacyMode: .showTotals,
            monthKey: "2026-08",
            timeZoneIdentifier: "Europe/Uzhgorod",
            serviceMinutes: 125,
            creditMinutes: 7,
            bibleStudyCount: 4,
            serviceYearMinutes: 24_750,
            serviceYearTargetMinutes: 36_000,
            generatedAtEpochSeconds: 123.25
        )
    }

    private func assertDecodeFails(
        _ data: Data,
        expecting expected: QuickSurfaceStateCodecError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try QuickSurfaceStateV1.decodeStrict(data),
            file: file,
            line: line
        ) { error in
            guard let actual = error as? QuickSurfaceStateCodecError else {
                return XCTFail("Expected QuickSurfaceStateCodecError, got \(error)", file: file, line: line)
            }
            switch (expected, actual) {
            case let (.fileTooLarge(expectedActual, expectedLimit), .fileTooLarge(actualCount, actualLimit)):
                XCTAssertEqual(actualCount, expectedActual, file: file, line: line)
                XCTAssertEqual(actualLimit, expectedLimit, file: file, line: line)
            case let (.unsupportedVersion(expectedVersion), .unsupportedVersion(actualVersion)):
                XCTAssertEqual(actualVersion, expectedVersion, file: file, line: line)
            case (.nonCanonicalJSON, .nonCanonicalJSON):
                break
            case let (.wrongKeys(expectedPath, _, _), .wrongKeys(actualPath, _, _)):
                XCTAssertEqual(actualPath, expectedPath, file: file, line: line)
            case let (.invalidValue(expectedMessage), .invalidValue(actualMessage)):
                XCTAssertEqual(actualMessage, expectedMessage, file: file, line: line)
            case (.invalidJSON, .invalidJSON):
                break
            default:
                XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
            }
        }
    }
}
