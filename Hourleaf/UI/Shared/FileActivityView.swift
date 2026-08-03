import SwiftUI
import UIKit

/// An opaque file hand-off for the system share sheet.
@MainActor
final class FileSharePayload: Identifiable {
    let id: UUID
    fileprivate let url: URL
    private var cleanupAction: (() -> Void)?

    init(url: URL, id: UUID = UUID(), cleanup: @escaping () -> Void) {
        self.id = id
        self.url = url
        cleanupAction = cleanup
    }

    /// Idempotent so activity completion and sheet dismissal can both call it.
    func cleanup() {
        guard let cleanupAction else { return }
        self.cleanupAction = nil
        cleanupAction()
    }
}

@MainActor
struct FileActivityView: UIViewControllerRepresentable {
    let payload: FileSharePayload
    let completion: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(payload: payload, completion: completion)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: [payload.url],
            applicationActivities: nil
        )
        controller.completionWithItemsHandler = { _, completed, _, _ in
            context.coordinator.finish(completed: completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    static func dismantleUIViewController(
        _ uiViewController: UIActivityViewController,
        coordinator: Coordinator
    ) {
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator {
        private let payload: FileSharePayload
        private let completion: (Bool) -> Void
        private var didFinish = false

        init(payload: FileSharePayload, completion: @escaping (Bool) -> Void) {
            self.payload = payload
            self.completion = completion
        }

        func finish(completed: Bool) {
            payload.cleanup()
            guard !didFinish else { return }
            didFinish = true
            completion(completed)
        }

        func dismantle() {
            payload.cleanup()
        }
    }
}
