import WidgetKit

/// Requests the system to re-read the quick-surface sidecar after a verified
/// host or intent projection. The operation is deliberately synchronous and
/// best-effort: WidgetKit owns scheduling and has no rollback contract.
struct QuickSurfaceSystemReloader: Sendable {
    private let operation: @Sendable () -> Void

    static let disabled = QuickSurfaceSystemReloader(operation: {})

    static let live = QuickSurfaceSystemReloader {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadAllControls()
        }
    }

    init(operation: @escaping @Sendable () -> Void) {
        self.operation = operation
    }

    func reload() {
        operation()
    }
}
