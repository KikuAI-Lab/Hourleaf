import Foundation
import UserNotifications

enum ReminderNotificationDestination: String, Sendable {
    case quickEntry = "quick-entry"

    private static let userInfoKey = ReminderNotificationUserInfoKey.destination

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

enum ReminderNotificationKind: String, Sendable {
    case weekly
    case followup
    case quietGap
}

enum ReminderNotificationAction: Equatable, Sendable {
    case open
    case addTime
    case nothingToRecord
    case later
    case unknown(String)

    init(identifier: String) {
        switch identifier {
        case UNNotificationDefaultActionIdentifier:
            self = .open
        case ReminderNotificationActionID.add:
            self = .addTime
        case ReminderNotificationActionID.nothing:
            self = .nothingToRecord
        case ReminderNotificationActionID.later:
            self = .later
        default:
            self = .unknown(identifier)
        }
    }
}

enum ReminderNotificationCategoryID {
    static let primary = "hourleaf.reminder.primary.v1"
    static let followup = "hourleaf.reminder.followup.v1"
}

enum ReminderNotificationActionID {
    static let add = "hourleaf.reminder.add.v1"
    static let nothing = "hourleaf.reminder.nothing.v1"
    static let later = "hourleaf.reminder.later.v1"
}

enum ReminderNotificationUserInfoKey {
    static let schemaVersion = "schemaVersion"
    static let kind = "kind"
    static let reminderID = "reminderID"
    static let targetDay = "targetDay"
    static let destination = "destination"
}

struct ReminderNotificationPayload: Equatable, Sendable {
    static let schemaVersion = 1

    let kind: ReminderNotificationKind
    let reminderID: UUID?
    let targetDay: LocalDay?
    let destination: ReminderNotificationDestination

    init(
        kind: ReminderNotificationKind,
        reminderID: UUID? = nil,
        targetDay: LocalDay? = nil,
        destination: ReminderNotificationDestination = .quickEntry
    ) {
        self.kind = kind
        self.reminderID = reminderID
        self.targetDay = targetDay
        self.destination = destination
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard
            let schemaVersion = userInfo[ReminderNotificationUserInfoKey.schemaVersion] as? Int,
            schemaVersion == Self.schemaVersion,
            let rawKind = userInfo[ReminderNotificationUserInfoKey.kind] as? String,
            let kind = ReminderNotificationKind(rawValue: rawKind),
            let rawDestination = userInfo[ReminderNotificationUserInfoKey.destination] as? String,
            let destination = ReminderNotificationDestination(rawValue: rawDestination)
        else {
            return nil
        }

        let reminderID: UUID?
        if let rawReminderID = userInfo[ReminderNotificationUserInfoKey.reminderID] as? String {
            guard let parsed = UUID(uuidString: rawReminderID) else {
                return nil
            }
            reminderID = parsed
        } else {
            reminderID = nil
        }

        let targetDay: LocalDay?
        if let rawTargetDay = userInfo[ReminderNotificationUserInfoKey.targetDay] as? String {
            guard let parsed = LocalDay(key: rawTargetDay) else {
                return nil
            }
            targetDay = parsed
        } else {
            targetDay = nil
        }

        self.init(
            kind: kind,
            reminderID: reminderID,
            targetDay: targetDay,
            destination: destination
        )
    }

    var userInfo: [AnyHashable: Any] {
        var value: [AnyHashable: Any] = [
            ReminderNotificationUserInfoKey.schemaVersion: Self.schemaVersion,
            ReminderNotificationUserInfoKey.kind: kind.rawValue,
            ReminderNotificationUserInfoKey.destination: destination.rawValue
        ]
        if let reminderID {
            value[ReminderNotificationUserInfoKey.reminderID] = reminderID.uuidString.lowercased()
        }
        if let targetDay {
            value[ReminderNotificationUserInfoKey.targetDay] = targetDay.key
        }
        return value
    }
}

struct ReminderNotificationResponseContext: Equatable, Sendable {
    let action: ReminderNotificationAction
    let payload: ReminderNotificationPayload
    let requestIdentifier: String
    let deliveryDate: Date
    let responseDate: Date

    init(
        action: ReminderNotificationAction,
        payload: ReminderNotificationPayload,
        requestIdentifier: String,
        deliveryDate: Date,
        responseDate: Date
    ) {
        self.action = action
        self.payload = payload
        self.requestIdentifier = requestIdentifier
        self.deliveryDate = deliveryDate
        self.responseDate = responseDate
    }

    init?(
        response: UNNotificationResponse,
        responseDate: Date = .now
    ) {
        guard let payload = ReminderNotificationPayload(
            userInfo: response.notification.request.content.userInfo
        ) else {
            return nil
        }
        self.init(
            action: ReminderNotificationAction(identifier: response.actionIdentifier),
            payload: payload,
            requestIdentifier: response.notification.request.identifier,
            deliveryDate: response.notification.date,
            responseDate: responseDate
        )
    }
}

enum ReminderNothingToRecordSource: String, Equatable, Sendable {
    case scheduledReminder
    case quietGap
}

struct ReminderNothingToRecordEvent: Equatable, Sendable {
    let day: LocalDay
    let source: ReminderNothingToRecordSource
    let reminderID: UUID?
}

enum ReminderNotificationEvent: Equatable, Sendable {
    case response(ReminderNotificationResponseContext)
}

enum ReminderAuthorizationStatus: Equatable, Sendable {
    case notDetermined
    case authorized
    case denied
    case provisional
    case ephemeral
    case unknown

    var allowsScheduling: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }

    var showsInlineGuidance: Bool {
        switch self {
        case .denied, .unknown:
            return true
        case .notDetermined, .authorized, .provisional, .ephemeral:
            return false
        }
    }
}

enum ReminderNotificationRequestID {
    static let weeklyPrefix = "hourleaf.reminder.weekly."
    static let followupWeeklyPrefix = "hourleaf.reminder.followup.weekly."
    static let quietGapPrefix = "hourleaf.reminder.quiet-gap."
    static let quietGapFollowupPrefix = "hourleaf.reminder.followup.quiet-gap."

    static func weekly(reminderID: UUID) -> String {
        "\(weeklyPrefix)\(reminderID.uuidString.lowercased())"
    }

    static func followup(reminderID: UUID, targetDay: LocalDay) -> String {
        "\(followupWeeklyPrefix)\(reminderID.uuidString.lowercased()).\(targetDay.key)"
    }

    static func quietGap(targetDay: LocalDay) -> String {
        "\(quietGapPrefix)\(targetDay.key)"
    }

    static func quietGapFollowup(targetDay: LocalDay) -> String {
        "\(quietGapFollowupPrefix)\(targetDay.key)"
    }
}

extension ReminderNotificationResponseContext {
    func targetDay(calendar: Calendar) -> LocalDay? {
        switch payload.kind {
        case .weekly:
            return LocalDay(deliveryDate, calendar: calendar)
        case .followup, .quietGap:
            return payload.targetDay
        }
    }

    func nothingToRecordEvent(calendar: Calendar) -> ReminderNothingToRecordEvent? {
        guard let targetDay = targetDay(calendar: calendar) else {
            return nil
        }

        let source: ReminderNothingToRecordSource
        switch payload.kind {
        case .quietGap:
            source = .quietGap
        case .followup where payload.reminderID == nil:
            source = .quietGap
        case .weekly, .followup:
            source = .scheduledReminder
        }

        return ReminderNothingToRecordEvent(
            day: targetDay,
            source: source,
            reminderID: payload.reminderID
        )
    }
}
