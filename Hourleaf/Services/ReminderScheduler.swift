import Foundation
import UserNotifications

@MainActor
protocol ReminderScheduling: Sendable {
    func requestAuthorization() async throws -> Bool
    func reschedule(_ reminders: [ReminderSchedule]) async throws
}

@MainActor
protocol ReminderUserNotificationCenter: Sendable {
    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?)
    func authorizationStatus() async -> ReminderAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
    func pendingNotificationRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

@MainActor
final class ReminderScheduler: NSObject, ReminderScheduling {
    static let shared = ReminderScheduler()

    private let center: any ReminderUserNotificationCenter
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let notificationDelegate = NotificationDelegate()
    private weak var router: AppRouter?

    init(
        center: any ReminderUserNotificationCenter = SystemReminderUserNotificationCenter(),
        now: @escaping @Sendable () -> Date = { .now },
        calendar: Calendar = .hourleaf
    ) {
        self.center = center
        self.now = now
        self.calendar = calendar
    }

    func configure(router: AppRouter) {
        self.router = router
        notificationDelegate.configure(owner: self)
        center.setDelegate(notificationDelegate)
        registerCategories()
    }

    func notificationAuthorizationStatus() async -> ReminderAuthorizationStatus {
        await center.authorizationStatus()
    }

    func requestAuthorization() async throws -> Bool {
        try await authorizationStatus(requestIfNeeded: true)
    }

    func reschedule(_ reminders: [ReminderSchedule]) async throws {
        registerCategories()
        try await removePendingWeeklyRequests()

        guard await center.authorizationStatus().allowsScheduling else {
            return
        }

        for reminder in reminders where reminder.isEnabled {
            try await center.add(weeklyRequest(for: reminder))
        }
    }

    func scheduleQuietGap(_ request: QuietGapSchedulingRequest) async throws -> QuietGapSchedulingOutcome {
        registerCategories()
        try await removePendingQuietGapRequests()

        guard request.isEnabled else {
            return .disabled
        }

        guard (1...30).contains(request.gapDays) else {
            return .invalidConfiguration
        }

        let isAuthorized = try await authorizationStatus(
            requestIfNeeded: request.requestAuthorizationIfNeeded
        )
        guard isAuthorized else {
            let status = await center.authorizationStatus()
            return status == .notDetermined ? .authorizationRequired : .authorizationDenied
        }

        guard let candidate = QuietGapReminderCalculator.candidate(
            for: request,
            now: now(),
            calendar: calendar
        ) else {
            return .noCandidate
        }

        try await center.add(quietGapRequest(for: candidate))
        return .scheduled(candidate)
    }

    func cancelFollowUp(reminderID: UUID?, targetDay: LocalDay) {
        center.removePendingNotificationRequests(withIdentifiers: [
            followupIdentifier(reminderID: reminderID, targetDay: targetDay)
        ])
    }

    func handleResponse(_ context: ReminderNotificationResponseContext) async throws {
        switch context.action {
        case .open, .addTime:
            guard context.payload.destination == .quickEntry else {
                return
            }
            router?.route(to: .quickEntry)
        case .nothingToRecord:
            guard let event = nothingToRecordEvent(from: context) else {
                return
            }
            cancelFollowUp(reminderID: event.reminderID, targetDay: event.day)
            router?.publish(reminderEvent: .acknowledgeNothingToRecord(event))
        case .later:
            guard let request = followupRequest(from: context) else {
                return
            }
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            try await center.add(request)
        case .unknown:
            return
        }
    }

    private func authorizationStatus(requestIfNeeded: Bool) async throws -> Bool {
        let status = await center.authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .unknown:
            return false
        case .notDetermined:
            guard requestIfNeeded else {
                return false
            }
            return try await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    private func registerCategories() {
        let add = UNNotificationAction(
            identifier: ReminderNotificationActionID.add,
            title: localizedString("reminder.action.add", defaultValue: "Add time"),
            options: [.foreground]
        )
        let nothing = UNNotificationAction(
            identifier: ReminderNotificationActionID.nothing,
            title: localizedString("reminder.action.nothing", defaultValue: "Nothing to record"),
            options: []
        )
        let later = UNNotificationAction(
            identifier: ReminderNotificationActionID.later,
            title: localizedString("reminder.action.later", defaultValue: "Later"),
            options: []
        )

        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: ReminderNotificationCategoryID.primary,
                actions: [add, nothing, later],
                intentIdentifiers: [],
                options: []
            ),
            UNNotificationCategory(
                identifier: ReminderNotificationCategoryID.followup,
                actions: [add, nothing],
                intentIdentifiers: [],
                options: []
            )
        ])
    }

    private func removePendingWeeklyRequests() async throws {
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(ReminderNotificationRequestID.weeklyPrefix) }
        guard !identifiers.isEmpty else {
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func removePendingQuietGapRequests() async throws {
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(ReminderNotificationRequestID.quietGapPrefix) }
        guard !identifiers.isEmpty else {
            return
        }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func weeklyRequest(for reminder: ReminderSchedule) -> UNNotificationRequest {
        let content = notificationContent(
            body: String(localized: "reminder.notification.body"),
            categoryIdentifier: ReminderNotificationCategoryID.primary,
            payload: ReminderNotificationPayload(
                kind: .weekly,
                reminderID: reminder.id
            )
        )
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                hour: reminder.hour,
                minute: reminder.minute,
                weekday: reminder.weekday
            ),
            repeats: true
        )
        return UNNotificationRequest(
            identifier: ReminderNotificationRequestID.weekly(reminderID: reminder.id),
            content: content,
            trigger: trigger
        )
    }

    private func quietGapRequest(for candidate: QuietGapReminderCandidate) -> UNNotificationRequest {
        let content = notificationContent(
            body: localizedString(
                "quiet_gap.notification.body",
                defaultValue: "Check your recent records?"
            ),
            categoryIdentifier: ReminderNotificationCategoryID.primary,
            payload: ReminderNotificationPayload(
                kind: .quietGap,
                targetDay: candidate.targetDay
            )
        )
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: candidate.triggerDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(
            identifier: ReminderNotificationRequestID.quietGap(targetDay: candidate.targetDay),
            content: content,
            trigger: trigger
        )
    }

    private func followupRequest(
        from context: ReminderNotificationResponseContext
    ) -> UNNotificationRequest? {
        guard context.payload.destination == .quickEntry else {
            return nil
        }

        switch context.payload.kind {
        case .followup:
            return nil
        case .weekly, .quietGap:
            break
        }

        guard let targetDay = targetDay(for: context) else {
            return nil
        }

        let body: String
        if context.payload.kind == .quietGap {
            body = localizedString(
                "quiet_gap.notification.body",
                defaultValue: "Check your recent records?"
            )
        } else {
            body = String(localized: "reminder.notification.body")
        }

        let payload = ReminderNotificationPayload(
            kind: .followup,
            reminderID: context.payload.reminderID,
            targetDay: targetDay
        )
        let content = notificationContent(
            body: body,
            categoryIdentifier: ReminderNotificationCategoryID.followup,
            payload: payload
        )
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60 * 60, repeats: false)
        return UNNotificationRequest(
            identifier: followupIdentifier(
                reminderID: context.payload.reminderID,
                targetDay: targetDay
            ),
            content: content,
            trigger: trigger
        )
    }

    private func targetDay(for context: ReminderNotificationResponseContext) -> LocalDay? {
        switch context.payload.kind {
        case .weekly:
            return LocalDay(context.deliveryDate, calendar: calendar)
        case .followup, .quietGap:
            return context.payload.targetDay
        }
    }

    private func nothingToRecordEvent(
        from context: ReminderNotificationResponseContext
    ) -> ReminderNothingToRecordEvent? {
        guard let targetDay = targetDay(for: context) else {
            return nil
        }

        let source: ReminderNothingToRecordSource
        switch context.payload.kind {
        case .quietGap:
            source = .quietGap
        case .followup where context.payload.reminderID == nil:
            source = .quietGap
        case .weekly, .followup:
            source = .scheduledReminder
        }

        return ReminderNothingToRecordEvent(
            day: targetDay,
            source: source,
            reminderID: context.payload.reminderID
        )
    }

    private func followupIdentifier(reminderID: UUID?, targetDay: LocalDay) -> String {
        if let reminderID {
            return ReminderNotificationRequestID.followup(
                reminderID: reminderID,
                targetDay: targetDay
            )
        }
        return ReminderNotificationRequestID.quietGapFollowup(targetDay: targetDay)
    }

    private func notificationContent(
        body: String,
        categoryIdentifier: String,
        payload: ReminderNotificationPayload
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "reminder.notification.title")
        content.body = body
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier
        content.userInfo = payload.userInfo
        return content
    }

    private func localizedString(_ key: String, defaultValue: String) -> String {
        NSLocalizedString(
            key,
            tableName: nil,
            bundle: .main,
            value: defaultValue,
            comment: ""
        )
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    weak var owner: ReminderScheduler?

    func configure(owner: ReminderScheduler) {
        self.owner = owner
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let context = ReminderNotificationResponseContext(response: response) else {
            return
        }
        try? await owner?.handleResponse(context)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private final class SystemReminderUserNotificationCenter: ReminderUserNotificationCenter, @unchecked Sendable {
    private let base = UNUserNotificationCenter.current()

    func setDelegate(_ delegate: UNUserNotificationCenterDelegate?) {
        base.delegate = delegate
    }

    func authorizationStatus() async -> ReminderAuthorizationStatus {
        let settings = await base.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        case .provisional:
            return .provisional
        case .ephemeral:
            return .ephemeral
        @unknown default:
            return .unknown
        }
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await base.requestAuthorization(options: options)
    }

    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        base.setNotificationCategories(categories)
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        await base.pendingNotificationRequests()
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await base.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        base.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
