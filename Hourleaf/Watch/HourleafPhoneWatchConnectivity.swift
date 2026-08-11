@preconcurrency import WatchConnectivity
import Foundation

final class HourleafPhoneWatchConnectivity: NSObject, @unchecked Sendable {
    typealias MessageHandler = @Sendable (Data) async -> WatchTimeEntryResponseV1

    static let shared = HourleafPhoneWatchConnectivity()

    private let lock = NSLock()
    private var handler: MessageHandler?
    private var session: WCSession?

    private override init() {
        super.init()
    }

    func configure(handler: @escaping MessageHandler) {
        lock.lock()
        self.handler = handler
        lock.unlock()

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        lock.lock()
        self.session = session
        lock.unlock()
        session.delegate = self
        session.activate()
    }

    private func currentHandler() -> MessageHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private static func fallbackResponse() -> Data {
        let mutationID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        return (try? WatchTimeEntryResponseV1(
            mutationID: mutationID,
            status: .failed
        ).encoded()) ?? Data()
    }
}

private final class WatchConnectivityReply: @unchecked Sendable {
    private let operation: (Data) -> Void

    init(_ operation: @escaping (Data) -> Void) {
        self.operation = operation
    }

    func send(_ data: Data) {
        operation(data)
    }
}

extension HourleafPhoneWatchConnectivity: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        guard let handler = currentHandler() else {
            replyHandler(Self.fallbackResponse())
            return
        }
        let reply = WatchConnectivityReply(replyHandler)
        Task {
            let response = await handler(messageData)
            reply.send((try? response.encoded()) ?? Self.fallbackResponse())
        }
    }
}
