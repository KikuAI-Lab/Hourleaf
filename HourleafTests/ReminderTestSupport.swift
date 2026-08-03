import Foundation
import UserNotifications
@testable import Hourleaf

final class FakeReminderNotificationCenter: ReminderUserNotificationCenter, @unchecked Sendable {
    var authorizationStatusValue: ReminderAuthorizationStatus = .authorized
    var requestAuthorizationResult = true
    var requestAuthorizationCallCount = 0
    var categories = Set<UNNotificationCategory>()
    var requestsByIdentifier: [String: UNNotificationRequest] = [:]
    var removedIdentifierBatches: [[String]] = []
    var delegate: UNUserNotificationCenterDelegate?

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        self.delegate = delegate
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        authorizationStatusValue
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCallCount += 1
        return requestAuthorizationResult
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        Array(requestsByIdentifier.values)
    }

    func add(_ request: UNNotificationRequest) async throws {
        requestsByIdentifier[request.identifier] = request
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedIdentifierBatches.append(identifiers)
        identifiers.forEach { requestsByIdentifier.removeValue(forKey: $0) }
    }
}

func makeReminderTestCalendar(timeZoneID: String = "Europe/Uzhgorod") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZoneID) ?? .gmt
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

func makeReminderTestDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int = 12,
    minute: Int = 0,
    second: Int = 0,
    calendar: Calendar
) -> Date {
    calendar.date(from: DateComponents(
        timeZone: calendar.timeZone,
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    )) ?? .distantPast
}

func makeReminderPayloadRequest(
    identifier: String,
    payload: ReminderNotificationPayload,
    categoryIdentifier: String = ReminderNotificationCategoryID.primary
) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "Hourleaf"
    content.body = "Reminder"
    content.categoryIdentifier = categoryIdentifier
    content.userInfo = payload.userInfo
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3600, repeats: false)
    return UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
}

func makeServiceRecord(
    day: LocalDay,
    deletedAt: Date? = nil
) -> LedgerEntryRecord {
    LedgerEntryRecord(
        entry: TimeEntry(
            id: UUID(),
            kind: .service,
            day: day,
            minutes: 60,
            note: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        ),
        deletedAt: deletedAt,
        source: "test",
        revision: 1,
        lastMutationID: UUID()
    )
}

func makeCreditRecord(day: LocalDay) -> LedgerEntryRecord {
    LedgerEntryRecord(
        entry: TimeEntry(
            id: UUID(),
            kind: .credit,
            day: day,
            minutes: 30,
            note: nil,
            createdAt: .distantPast,
            updatedAt: .distantPast
        ),
        deletedAt: nil,
        source: "test",
        revision: 1,
        lastMutationID: UUID()
    )
}

func makeAcknowledgementRecord(
    day: LocalDay,
    source: String = "scheduledReminder"
) -> DayAcknowledgementRecord {
    DayAcknowledgementRecord(
        id: UUID(),
        day: day,
        status: "nothingToday",
        source: source,
        createdAt: .distantPast,
        updatedAt: .distantPast
    )
}
