import XCTest
@testable import Hourleaf

@MainActor
final class QuietGapReminderTests: XCTestCase {
    func testDisabledProducesNoCandidate() {
        let calendar = makeReminderTestCalendar()
        let now = makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 12, calendar: calendar)
        let request = QuietGapSchedulingRequest(
            isEnabled: false,
            ledgerStartMonth: MonthKey(year: 2026, month: 1),
            entries: [makeServiceRecord(day: LocalDay(year: 2026, month: 7, day: 27))],
            acknowledgements: []
        )

        XCTAssertNil(QuietGapReminderCalculator.candidate(for: request, now: now, calendar: calendar))
    }

    func testActiveServiceAnchorsNextCheckAtLocalEighteenHundred() {
        let calendar = makeReminderTestCalendar(timeZoneID: "Europe/Uzhgorod")
        let now = makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 12, calendar: calendar)
        let request = QuietGapSchedulingRequest(
            isEnabled: true,
            gapDays: 7,
            ledgerStartMonth: MonthKey(year: 2026, month: 1),
            entries: [makeServiceRecord(day: LocalDay(year: 2026, month: 7, day: 27))],
            acknowledgements: []
        )

        let candidate = QuietGapReminderCalculator.candidate(for: request, now: now, calendar: calendar)

        XCTAssertEqual(candidate?.targetDay, LocalDay(year: 2026, month: 8, day: 3))
        XCTAssertEqual(candidate?.triggerDate, makeReminderTestDate(
            year: 2026,
            month: 8,
            day: 3,
            hour: 18,
            calendar: calendar
        ))
    }

    func testPastTriggerAdvancesToNextBoundary() {
        let calendar = makeReminderTestCalendar(timeZoneID: "Europe/Uzhgorod")
        let now = makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 19, calendar: calendar)
        let request = QuietGapSchedulingRequest(
            isEnabled: true,
            gapDays: 7,
            ledgerStartMonth: MonthKey(year: 2026, month: 1),
            entries: [makeServiceRecord(day: LocalDay(year: 2026, month: 7, day: 27))],
            acknowledgements: []
        )

        let candidate = QuietGapReminderCalculator.candidate(for: request, now: now, calendar: calendar)

        XCTAssertEqual(candidate?.targetDay, LocalDay(year: 2026, month: 8, day: 10))
        XCTAssertEqual(candidate?.triggerDate, makeReminderTestDate(
            year: 2026,
            month: 8,
            day: 10,
            hour: 18,
            calendar: calendar
        ))
    }

    func testFutureAcknowledgementFailsClosed() {
        let calendar = makeReminderTestCalendar()
        let now = makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 12, calendar: calendar)
        let request = QuietGapSchedulingRequest(
            isEnabled: true,
            gapDays: 7,
            ledgerStartMonth: MonthKey(year: 2026, month: 1),
            entries: [makeServiceRecord(day: LocalDay(year: 2026, month: 7, day: 27))],
            acknowledgements: [makeAcknowledgementRecord(day: LocalDay(year: 2026, month: 8, day: 4))]
        )

        XCTAssertNil(QuietGapReminderCalculator.candidate(for: request, now: now, calendar: calendar))
    }

    func testQuietGapSchedulingRequestsAuthorizationOnlyWhenExplicitlyAsked() async throws {
        let center = FakeReminderNotificationCenter()
        center.authorizationStatusValue = .notDetermined
        center.requestsByIdentifier = [
            ReminderNotificationRequestID.weekly(reminderID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!): makeReminderPayloadRequest(
                identifier: ReminderNotificationRequestID.weekly(reminderID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!),
                payload: ReminderNotificationPayload(kind: .weekly, reminderID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
            ),
            ReminderNotificationRequestID.quietGap(targetDay: LocalDay(year: 2026, month: 7, day: 30)): makeReminderPayloadRequest(
                identifier: ReminderNotificationRequestID.quietGap(targetDay: LocalDay(year: 2026, month: 7, day: 30)),
                payload: ReminderNotificationPayload(kind: .quietGap, targetDay: LocalDay(year: 2026, month: 7, day: 30))
            ),
            ReminderNotificationRequestID.quietGapFollowup(targetDay: LocalDay(year: 2026, month: 7, day: 30)): makeReminderPayloadRequest(
                identifier: ReminderNotificationRequestID.quietGapFollowup(targetDay: LocalDay(year: 2026, month: 7, day: 30)),
                payload: ReminderNotificationPayload(kind: .followup, targetDay: LocalDay(year: 2026, month: 7, day: 30)),
                categoryIdentifier: ReminderNotificationCategoryID.followup
            )
        ]
        let calendar = makeReminderTestCalendar()
        let now = makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 12, calendar: calendar)
        let scheduler = ReminderScheduler(center: center, now: { now }, calendar: calendar)
        let baseRequest = QuietGapSchedulingRequest(
            isEnabled: true,
            gapDays: 7,
            ledgerStartMonth: MonthKey(year: 2026, month: 1),
            entries: [makeServiceRecord(day: LocalDay(year: 2026, month: 7, day: 27))],
            acknowledgements: [],
            requestAuthorizationIfNeeded: false
        )

        let noPromptOutcome = try await scheduler.scheduleQuietGap(baseRequest)

        XCTAssertEqual(noPromptOutcome, .authorizationRequired)
        XCTAssertEqual(center.requestAuthorizationCallCount, 0)
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.weekly(
            reminderID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )])
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.quietGapFollowup(
            targetDay: LocalDay(year: 2026, month: 7, day: 30)
        )])

        center.authorizationStatusValue = .notDetermined
        center.requestAuthorizationResult = true
        let promptOutcome = try await scheduler.scheduleQuietGap(
            QuietGapSchedulingRequest(
                isEnabled: true,
                gapDays: 7,
                ledgerStartMonth: MonthKey(year: 2026, month: 1),
                entries: [makeServiceRecord(day: LocalDay(year: 2026, month: 7, day: 27))],
                acknowledgements: [],
                requestAuthorizationIfNeeded: true
            )
        )

        guard case let .scheduled(candidate) = promptOutcome else {
            return XCTFail("Expected scheduled quiet-gap candidate")
        }
        XCTAssertEqual(center.requestAuthorizationCallCount, 1)
        XCTAssertEqual(candidate.targetDay, LocalDay(year: 2026, month: 8, day: 3))
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.weekly(
            reminderID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        )])
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.quietGapFollowup(
            targetDay: LocalDay(year: 2026, month: 7, day: 30)
        )])
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.quietGap(
            targetDay: LocalDay(year: 2026, month: 8, day: 3)
        )])
    }
}
