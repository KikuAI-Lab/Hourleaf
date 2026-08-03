import Foundation
import UserNotifications

enum ReminderNotificationDestination: String, Sendable {
    case quickEntry = "quick-entry"

    private static let userInfoKey = "destination"

    init?(userInfo: [AnyHashable: Any]) {
        guard let rawValue = userInfo[Self.userInfoKey] as? String else {
            return nil
        }
        self.init(rawValue: rawValue)
    }

    @MainActor
    static func route(userInfo: [AnyHashable: Any], using router: AppRouter) {
        guard let destination = Self(userInfo: userInfo) else {
            return
        }

        destination.route(using: router)
    }

    @MainActor
    func route(using router: AppRouter) {
        switch self {
        case .quickEntry:
            router.route(to: .quickEntry)
        }
    }
}

@MainActor
protocol ReminderScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func reschedule(_ reminders: [ReminderSchedule]) async throws
}

@MainActor
final class ReminderScheduler: NSObject, ReminderScheduling {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()
    private let notificationDelegate = NotificationDelegate()

    func configure(router: AppRouter) {
        notificationDelegate.configure(router: router)
        center.delegate = notificationDelegate
    }

    func requestAuthorization() async throws -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound])
        @unknown default:
            return false
        }
    }

    func reschedule(_ reminders: [ReminderSchedule]) async throws {
        let pending = await center.pendingNotificationRequests()
        let identifiers = pending.map(\.identifier).filter { $0.hasPrefix("hourleaf.reminder.") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        for reminder in reminders where reminder.isEnabled {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "reminder.notification.title")
            content.body = String(localized: "reminder.notification.body")
            content.sound = .default
            content.userInfo = ["destination": ReminderNotificationDestination.quickEntry.rawValue]
            let components = DateComponents(
                calendar: .hourleaf,
                hour: reminder.hour,
                minute: reminder.minute,
                weekday: reminder.weekday
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: "hourleaf.reminder.\(reminder.id.uuidString)",
                content: content,
                trigger: trigger
            )
            try await center.add(request)
        }
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    private var router: AppRouter?

    func configure(router: AppRouter) {
        self.router = router
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let destination = ReminderNotificationDestination(
            userInfo: response.notification.request.content.userInfo
        ) else {
            return
        }

        await MainActor.run {
            guard let router = self.router else {
                return
            }
            destination.route(using: router)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
