import XCTest
import UserNotifications
@testable import Hourleaf

@MainActor
final class ReminderSchedulerTests: XCTestCase {
    func testConfigureRegistersCategoriesWithoutRequestingAuthorization() async throws {
        let center = FakeReminderNotificationCenter()
        center.authorizationStatusValue = .notDetermined
        let scheduler = ReminderScheduler(
            center: center,
            now: { .distantPast },
            calendar: makeReminderTestCalendar()
        )
        let router = AppRouter()

        scheduler.configure(router: router)
        let status = await scheduler.notificationAuthorizationStatus()

        XCTAssertEqual(status, .notDetermined)
        XCTAssertEqual(center.requestAuthorizationCallCount, 0)
        XCTAssertEqual(Set(center.categories.map(\.identifier)), [
            ReminderNotificationCategoryID.primary,
            ReminderNotificationCategoryID.followup
        ])

        let primary = try XCTUnwrap(center.categories.first(where: {
            $0.identifier == ReminderNotificationCategoryID.primary
        }))
        XCTAssertEqual(primary.actions.map(\.identifier), [
            ReminderNotificationActionID.add,
            ReminderNotificationActionID.nothing,
            ReminderNotificationActionID.later
        ])
        XCTAssertEqual(primary.actions.first?.options, [.foreground])

        let followup = try XCTUnwrap(center.categories.first(where: {
            $0.identifier == ReminderNotificationCategoryID.followup
        }))
        XCTAssertEqual(followup.actions.map(\.identifier), [
            ReminderNotificationActionID.add,
            ReminderNotificationActionID.nothing
        ])
    }

    func testRescheduleOnlyReplacesWeeklyNamespace() async throws {
        let center = FakeReminderNotificationCenter()
        let calendar = makeReminderTestCalendar()
        let reminderID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        center.requestsByIdentifier = [
            "hourleaf.reminder.weekly.legacy": makeReminderPayloadRequest(
                identifier: "hourleaf.reminder.weekly.legacy",
                payload: ReminderNotificationPayload(kind: .weekly, reminderID: reminderID)
            ),
            ReminderNotificationRequestID.followup(reminderID: reminderID, targetDay: LocalDay(year: 2026, month: 8, day: 3)): makeReminderPayloadRequest(
                identifier: ReminderNotificationRequestID.followup(reminderID: reminderID, targetDay: LocalDay(year: 2026, month: 8, day: 3)),
                payload: ReminderNotificationPayload(kind: .followup, reminderID: reminderID, targetDay: LocalDay(year: 2026, month: 8, day: 3)),
                categoryIdentifier: ReminderNotificationCategoryID.followup
            ),
            ReminderNotificationRequestID.quietGap(targetDay: LocalDay(year: 2026, month: 8, day: 10)): makeReminderPayloadRequest(
                identifier: ReminderNotificationRequestID.quietGap(targetDay: LocalDay(year: 2026, month: 8, day: 10)),
                payload: ReminderNotificationPayload(kind: .quietGap, targetDay: LocalDay(year: 2026, month: 8, day: 10))
            ),
            "com.example.other": makeReminderPayloadRequest(
                identifier: "com.example.other",
                payload: ReminderNotificationPayload(kind: .quietGap, targetDay: LocalDay(year: 2026, month: 8, day: 11))
            )
        ]

        let scheduler = ReminderScheduler(center: center, now: { .distantPast }, calendar: calendar)
        try await scheduler.reschedule([
            ReminderSchedule(id: reminderID, weekday: 2, hour: 13, minute: 30, isEnabled: true)
        ])

        XCTAssertEqual(Set(center.removedIdentifierBatches.flatMap { $0 }), ["hourleaf.reminder.weekly.legacy"])
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.followup(
            reminderID: reminderID,
            targetDay: LocalDay(year: 2026, month: 8, day: 3)
        )])
        XCTAssertNotNil(center.requestsByIdentifier[ReminderNotificationRequestID.quietGap(
            targetDay: LocalDay(year: 2026, month: 8, day: 10)
        )])
        XCTAssertNotNil(center.requestsByIdentifier["com.example.other"])

        let weeklyRequest = try XCTUnwrap(center.requestsByIdentifier[ReminderNotificationRequestID.weekly(reminderID: reminderID)])
        XCTAssertEqual(weeklyRequest.content.categoryIdentifier, ReminderNotificationCategoryID.primary)
        XCTAssertEqual(
            ReminderNotificationPayload(userInfo: weeklyRequest.content.userInfo),
            ReminderNotificationPayload(kind: .weekly, reminderID: reminderID)
        )
    }

    func testAddActionRoutesQuickEntryWithoutEmittingReminderEvent() async throws {
        let center = FakeReminderNotificationCenter()
        let scheduler = ReminderScheduler(center: center, now: { .distantPast }, calendar: makeReminderTestCalendar())
        let router = AppRouter()
        scheduler.configure(router: router)

        try await scheduler.handleResponse(
            ReminderNotificationResponseContext(
                action: .addTime,
                payload: ReminderNotificationPayload(
                    kind: .weekly,
                    reminderID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
                ),
                requestIdentifier: "weekly",
                deliveryDate: Date(timeIntervalSinceReferenceDate: 0),
                responseDate: Date(timeIntervalSinceReferenceDate: 0)
            )
        )

        XCTAssertEqual(router.pendingRoute, .quickEntry)
        XCTAssertNil(router.pendingReminderEvent)
        XCTAssertTrue(center.requestsByIdentifier.isEmpty)
    }

    func testNothingToRecordEmitsTypedResponseEventWithoutImmediateCenterMutation() async throws {
        let center = FakeReminderNotificationCenter()
        let calendar = makeReminderTestCalendar()
        let reminderID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let targetDay = LocalDay(year: 2026, month: 8, day: 3)
        let followupIdentifier = ReminderNotificationRequestID.followup(reminderID: reminderID, targetDay: targetDay)
        center.requestsByIdentifier[followupIdentifier] = makeReminderPayloadRequest(
            identifier: followupIdentifier,
            payload: ReminderNotificationPayload(kind: .followup, reminderID: reminderID, targetDay: targetDay),
            categoryIdentifier: ReminderNotificationCategoryID.followup
        )
        let scheduler = ReminderScheduler(center: center, now: { .distantPast }, calendar: calendar)
        let router = AppRouter()
        scheduler.configure(router: router)

        try await scheduler.handleResponse(
            ReminderNotificationResponseContext(
                action: .nothingToRecord,
                payload: ReminderNotificationPayload(kind: .weekly, reminderID: reminderID),
                requestIdentifier: "weekly",
                deliveryDate: makeReminderTestDate(
                    year: 2026,
                    month: 8,
                    day: 3,
                    hour: 18,
                    calendar: calendar
                ),
                responseDate: makeReminderTestDate(
                    year: 2026,
                    month: 8,
                    day: 3,
                    hour: 18,
                    minute: 1,
                    calendar: calendar
                )
            )
        )

        XCTAssertNotNil(center.requestsByIdentifier[followupIdentifier])
        XCTAssertEqual(
            router.pendingReminderEvent,
            .response(
                ReminderNotificationResponseContext(
                    action: .nothingToRecord,
                    payload: ReminderNotificationPayload(kind: .weekly, reminderID: reminderID),
                    requestIdentifier: "weekly",
                    deliveryDate: makeReminderTestDate(
                        year: 2026,
                        month: 8,
                        day: 3,
                        hour: 18,
                        calendar: calendar
                    ),
                    responseDate: makeReminderTestDate(
                        year: 2026,
                        month: 8,
                        day: 3,
                        hour: 18,
                        minute: 1,
                        calendar: calendar
                    )
                )
            )
        )
    }

    func testLaterEmitsRetainedResponseEventWithoutSchedulingDirectly() async throws {
        let center = FakeReminderNotificationCenter()
        let calendar = makeReminderTestCalendar()
        let reminderID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let scheduler = ReminderScheduler(
            center: center,
            now: { Date(timeIntervalSince1970: 1_785_499_200) },
            calendar: calendar
        )
        let router = AppRouter()
        scheduler.configure(router: router)

        let context = ReminderNotificationResponseContext(
            action: .later,
            payload: ReminderNotificationPayload(kind: .weekly, reminderID: reminderID),
            requestIdentifier: "weekly",
            deliveryDate: makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 18, calendar: calendar),
            responseDate: makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 18, minute: 5, calendar: calendar)
        )

        try await scheduler.handleResponse(context)
        try await scheduler.handleResponse(context)

        XCTAssertTrue(center.requestsByIdentifier.isEmpty)
        XCTAssertEqual(router.pendingReminderEvent, .response(context))
    }

    func testScheduleFollowUpUsesExactResponseDatePlusSixtyMinutes() async throws {
        let center = FakeReminderNotificationCenter()
        let calendar = makeReminderTestCalendar()
        let reminderID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let scheduler = ReminderScheduler(center: center, now: { .distantPast }, calendar: calendar)

        let context = ReminderNotificationResponseContext(
            action: .later,
            payload: ReminderNotificationPayload(kind: .weekly, reminderID: reminderID),
            requestIdentifier: "weekly",
            deliveryDate: makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 18, calendar: calendar),
            responseDate: makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 18, minute: 5, calendar: calendar)
        )

        try await scheduler.scheduleFollowUp(from: context)

        let identifier = ReminderNotificationRequestID.followup(
            reminderID: reminderID,
            targetDay: LocalDay(year: 2026, month: 8, day: 3)
        )
        let request = try XCTUnwrap(center.requestsByIdentifier[identifier])
        XCTAssertEqual(
            ReminderNotificationPayload(userInfo: request.content.userInfo),
            ReminderNotificationPayload(
                kind: .followup,
                reminderID: reminderID,
                targetDay: LocalDay(year: 2026, month: 8, day: 3)
            )
        )
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        let fireDate = calendar.date(from: trigger.dateComponents)
        XCTAssertEqual(
            fireDate,
            makeReminderTestDate(year: 2026, month: 8, day: 3, hour: 19, minute: 5, calendar: calendar)
        )
    }

    func testUnknownActionAndMalformedPayloadDoNothing() async throws {
        let center = FakeReminderNotificationCenter()
        let scheduler = ReminderScheduler(center: center, now: { .distantPast }, calendar: makeReminderTestCalendar())
        let router = AppRouter()
        scheduler.configure(router: router)

        try await scheduler.handleResponse(
            ReminderNotificationResponseContext(
                action: .unknown("custom"),
                payload: ReminderNotificationPayload(kind: .weekly, reminderID: UUID()),
                requestIdentifier: "weekly",
                deliveryDate: .distantPast,
                responseDate: .distantPast
            )
        )

        XCTAssertNil(router.pendingRoute)
        XCTAssertNil(router.pendingReminderEvent)
        XCTAssertTrue(center.requestsByIdentifier.isEmpty)
        XCTAssertNil(ReminderNotificationPayload(userInfo: [
            ReminderNotificationUserInfoKey.schemaVersion: 2,
            ReminderNotificationUserInfoKey.kind: ReminderNotificationKind.weekly.rawValue,
            ReminderNotificationUserInfoKey.destination: ReminderNotificationDestination.quickEntry.rawValue
        ]))
    }
}
