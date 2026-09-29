import Foundation

struct MonthlyGoalCelebration: Identifiable, Equatable, Sendable {
    let id: UUID
    let month: MonthKey

    init(id: UUID = UUID(), month: MonthKey) {
        self.id = id
        self.month = month
    }
}

/// Keeps this presentation-only milestone separate from the ministry ledger.
/// The stored observation prevents an app update from celebrating old totals,
/// while the celebrated month makes the moment occur at most once per month.
@MainActor
final class MonthlyGoalCelebrationTracker {
    static let thresholdMinutes = 50 * 60

    private enum Key {
        static let observedMonth = "hourleaf.monthlyGoal.observedMonth"
        static let observedMinutes = "hourleaf.monthlyGoal.observedMinutes"
        static let celebratedMonth = "hourleaf.monthlyGoal.celebratedMonth"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func observe(
        month: MonthKey,
        serviceMinutes: Int,
        creditMinutes: Int,
        allowsCelebration: Bool
    ) -> Bool {
        let combinedMinutes = max(0, serviceMinutes) + max(0, creditMinutes)
        let previousMonth = defaults.string(forKey: Key.observedMonth)
        let previousMinutes = defaults.integer(forKey: Key.observedMinutes)

        defaults.set(month.key, forKey: Key.observedMonth)
        defaults.set(combinedMinutes, forKey: Key.observedMinutes)

        guard previousMonth == month.key else { return false }
        guard allowsCelebration else { return false }
        guard previousMinutes < Self.thresholdMinutes else { return false }
        guard combinedMinutes >= Self.thresholdMinutes else { return false }
        guard defaults.string(forKey: Key.celebratedMonth) != month.key else { return false }

        defaults.set(month.key, forKey: Key.celebratedMonth)
        return true
    }
}
