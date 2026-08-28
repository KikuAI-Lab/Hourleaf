import Foundation
@preconcurrency import UIKit

/// Keeps one short host-app sidecar reconciliation alive if iOS moves the app
/// to the background. The WidgetKit extension keeps using its own system
/// execution budget and never links this UIKit-only policy.
struct QuickSurfaceHostExecutionActivity: Sendable {
    private let beginOperation: @Sendable () async -> QuickSurfaceHostExecutionLease

    static let immediate = QuickSurfaceHostExecutionActivity {
        QuickSurfaceHostExecutionLease(endOperation: {})
    }

    static let application = QuickSurfaceHostExecutionActivity {
        let task = await MainActor.run {
            QuickSurfaceApplicationBackgroundTask()
        }
        return QuickSurfaceHostExecutionLease {
            task.end()
        }
    }

    init(
        beginOperation: @escaping @Sendable () async -> QuickSurfaceHostExecutionLease
    ) {
        self.beginOperation = beginOperation
    }

    func begin() async -> QuickSurfaceHostExecutionLease {
        await beginOperation()
    }
}

struct QuickSurfaceHostExecutionLease: Sendable {
    private let endOperation: @MainActor @Sendable () -> Void

    init(endOperation: @escaping @MainActor @Sendable () -> Void) {
        self.endOperation = endOperation
    }

    func end() async {
        await endOperation()
    }
}

/// Balances UIKit's task identifier across normal completion, expiration, an
/// invalid grant, and the rare case where expiration races task activation.
@MainActor
final class QuickSurfaceApplicationBackgroundTask {
    typealias BeginOperation = @MainActor @Sendable (
        _ expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    typealias EndOperation = @MainActor @Sendable (UIBackgroundTaskIdentifier) -> Void

    private enum State {
        case starting
        case active(UIBackgroundTaskIdentifier)
        case endedBeforeActivation
        case ended
    }

    private var state: State = .starting
    private let endOperation: EndOperation

    convenience init() {
        self.init(
            beginOperation: { expirationHandler in
                UIApplication.shared.beginBackgroundTask(
                    withName: "Hourleaf Quick Surface Reconcile",
                    expirationHandler: expirationHandler
                )
            },
            endOperation: { identifier in
                UIApplication.shared.endBackgroundTask(identifier)
            }
        )
    }

    init(
        beginOperation: BeginOperation,
        endOperation: @escaping EndOperation
    ) {
        self.endOperation = endOperation
        let identifier = beginOperation { [weak self] in
            self?.end()
        }
        activate(identifier)
    }

    func end() {
        switch state {
        case .starting:
            state = .endedBeforeActivation
        case let .active(identifier):
            state = .ended
            endOperation(identifier)
        case .endedBeforeActivation, .ended:
            break
        }
    }

    private func activate(_ identifier: UIBackgroundTaskIdentifier) {
        switch state {
        case .starting:
            state = identifier == .invalid ? .ended : .active(identifier)
        case .endedBeforeActivation:
            state = .ended
            if identifier != .invalid {
                endOperation(identifier)
            }
        case .active, .ended:
            break
        }
    }
}
