import UIKit
import XCTest
@testable import Hourleaf

@MainActor
final class QuickSurfaceApplicationBackgroundTaskTests: XCTestCase {
    func testNormalCompletionEndsValidTaskExactlyOnce() {
        let spy = QuickSurfaceApplicationBackgroundTaskSpy()
        let task = makeTask(spy: spy)

        task.end()
        task.end()

        XCTAssertEqual(spy.endedIdentifiers, [spy.identifier])
    }

    func testExpirationBeforeActivationEndsReturnedTaskExactlyOnce() {
        let spy = QuickSurfaceApplicationBackgroundTaskSpy(expireBeforeReturning: true)
        let task = makeTask(spy: spy)

        task.end()

        XCTAssertEqual(spy.endedIdentifiers, [spy.identifier])
    }

    func testExpirationAfterActivationAndNormalCompletionEndTaskExactlyOnce() {
        let spy = QuickSurfaceApplicationBackgroundTaskSpy()
        let task = makeTask(spy: spy)

        spy.expire()
        task.end()

        XCTAssertEqual(spy.endedIdentifiers, [spy.identifier])
    }

    func testInvalidTaskIdentifierIsNeverEnded() {
        let spy = QuickSurfaceApplicationBackgroundTaskSpy(identifier: .invalid)
        let task = makeTask(spy: spy)

        task.end()

        XCTAssertTrue(spy.endedIdentifiers.isEmpty)
    }

    private func makeTask(
        spy: QuickSurfaceApplicationBackgroundTaskSpy
    ) -> QuickSurfaceApplicationBackgroundTask {
        QuickSurfaceApplicationBackgroundTask(
            beginOperation: { expirationHandler in
                spy.begin(expirationHandler: expirationHandler)
            },
            endOperation: { identifier in
                spy.end(identifier)
            }
        )
    }
}

@MainActor
private final class QuickSurfaceApplicationBackgroundTaskSpy {
    let identifier: UIBackgroundTaskIdentifier
    let expireBeforeReturning: Bool
    private(set) var endedIdentifiers: [UIBackgroundTaskIdentifier] = []
    private var expirationHandler: (@MainActor @Sendable () -> Void)?

    init(
        identifier: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 42),
        expireBeforeReturning: Bool = false
    ) {
        self.identifier = identifier
        self.expireBeforeReturning = expireBeforeReturning
    }

    func begin(
        expirationHandler: @escaping @MainActor @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier {
        self.expirationHandler = expirationHandler
        if expireBeforeReturning {
            expirationHandler()
        }
        return identifier
    }

    func expire() {
        expirationHandler?()
    }

    func end(_ identifier: UIBackgroundTaskIdentifier) {
        endedIdentifiers.append(identifier)
    }
}
