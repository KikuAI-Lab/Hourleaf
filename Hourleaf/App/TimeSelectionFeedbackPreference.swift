import Foundation

enum TimeSelectionChangeSource: Equatable, Sendable {
    case userInteraction
    case externalUpdate
}

/// A local presentation preference. It does not belong to the ministry ledger
/// and therefore is intentionally excluded from backups and report data.
enum TimeSelectionFeedbackPreference {
    static let storageKey = "hourleaf.timeSelectionFeedback.enabled"
    static let defaultValue = true

    static func storedValue(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: storageKey) != nil else {
            return defaultValue
        }
        return defaults.bool(forKey: storageKey)
    }

    static func shouldRequestFeedback(
        for source: TimeSelectionChangeSource,
        isEnabled: Bool,
        previousValue: Int,
        selectedValue: Int
    ) -> Bool {
        source == .userInteraction
            && isEnabled
            && previousValue != selectedValue
    }
}
