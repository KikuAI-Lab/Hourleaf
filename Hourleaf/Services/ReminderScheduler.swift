import Foundation
import UserNotifications

extension Notification.Name {
    static let openQuickEntry = Notification.Name("Hourleaf.openQuickEntry")
}
@MainActor
protocol ReminderScheduling {
    func requestAuthorization() async throws -> Bool
    func reschedule(_ reminders: [ReminderSchedule]) async throws
}

@MainActor
final class ReminderScheduler: NSObject, ReminderScheduling {
    static let shared = ReminderScheduler()

    private let center = UNUserNotificationCenter.current()

    func configure() {
        center.delegate = NotificationDelegate.shared
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
            content.userInfo = ["destination": "quick-entry"]
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
    static let shared = NotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run {
            NotificationCenter.default.post(name: .openQuickEntry, object: nil)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
