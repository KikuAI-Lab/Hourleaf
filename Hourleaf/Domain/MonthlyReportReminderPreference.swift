import Foundation

/// The monthly report reminder is a local convenience preference. It is kept
/// outside the ledger so changing it never changes Core Data or backup data.
struct MonthlyReportReminderPreference: Equatable, Sendable {
    static let defaultsKey = "hourleaf.monthlyReportReminder.enabled"

    let isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard defaults.object(forKey: defaultsKey) != nil else {
            return Self(isEnabled: true)
        }
        return Self(isEnabled: defaults.bool(forKey: defaultsKey))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(isEnabled, forKey: Self.defaultsKey)
    }
}
