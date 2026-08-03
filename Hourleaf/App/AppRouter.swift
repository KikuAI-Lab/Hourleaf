import Combine
import Foundation

enum AppRoute: Equatable, Sendable {
    case quickEntry
}

/// Holds the next in-app destination until the root view is ready to consume it.
/// Keeping the route here makes launches from notifications and App Intents safe
/// even when they arrive before the SwiftUI hierarchy is observing state.
@MainActor
final class AppRouter: ObservableObject {
    @Published private(set) var pendingRoute: AppRoute?
    @Published private(set) var ledgerChangeGeneration: UInt64 = 0

    func route(to route: AppRoute) {
        pendingRoute = route
    }

    func consumePendingRoute() -> AppRoute? {
        defer { pendingRoute = nil }
        return pendingRoute
    }

    /// Retains a verified external/system ledger write until an active root can
    /// refresh its single in-memory model from the shared repository.
    func notifyLedgerChanged() {
        ledgerChangeGeneration &+= 1
    }
}
