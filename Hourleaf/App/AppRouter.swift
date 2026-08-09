import Combine
import Foundation

enum AppRoute: Equatable, Sendable {
    case quickEntry
    case progress
    case progressReport(MonthKey)
}

/// Holds the next in-app destination until the root view is ready to consume it.
/// Keeping the route here makes launches from notifications and App Intents safe
/// even when they arrive before the SwiftUI hierarchy is observing state.
@MainActor
final class AppRouter: ObservableObject {
    @Published private(set) var pendingRoute: AppRoute?
    @Published private(set) var pendingReminderEvent: ReminderNotificationEvent?
    @Published private(set) var ledgerChangeGeneration: UInt64 = 0

    func route(to route: AppRoute) {
        pendingRoute = route
    }

    /// Routes only the exact configured cold/warm quick-entry URL. Query,
    /// fragment, and path variants are intentionally rejected by the shared
    /// matcher so no external value crosses the app boundary.
    @discardableResult
    func routeIfQuickEntryURL(
        _ url: URL,
        bundle: Bundle = .main
    ) -> Bool {
        guard HourleafQuickEntryURL.matches(url: url, bundle: bundle) else {
            return false
        }
        route(to: .quickEntry)
        return true
    }

    func consumePendingRoute() -> AppRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    func publish(reminderEvent: ReminderNotificationEvent) {
        pendingReminderEvent = reminderEvent
    }

    func consumePendingReminderEvent() -> ReminderNotificationEvent? {
        defer { pendingReminderEvent = nil }
        return pendingReminderEvent
    }

    /// Retains a verified external/system ledger write until an active root can
    /// refresh its single in-memory model from the shared repository.
    func notifyLedgerChanged() {
        ledgerChangeGeneration &+= 1
    }
}
