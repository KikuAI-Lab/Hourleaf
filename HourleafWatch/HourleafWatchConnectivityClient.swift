@preconcurrency import WatchConnectivity
import Foundation

enum HourleafWatchConnectivityError: LocalizedError, Equatable, Sendable {
    case unavailable
    case rejected
    case notConfirmed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "watch.error.unavailable")
        case .rejected:
            String(localized: "watch.error.rejected")
        case .notConfirmed:
            String(localized: "watch.error.not_confirmed")
        }
    }
}

@MainActor
final class HourleafWatchConnectivityClient: NSObject {
    static let shared = HourleafWatchConnectivityClient()

    private let session: WCSession?
    private var activationWaiters: [CheckedContinuation<Bool, Never>] = []

    private override init() {
        if WCSession.isSupported() {
            session = .default
        } else {
            session = nil
        }
        super.init()
        session?.delegate = self
    }

    func activate() {
        session?.activate()
    }

    func send(_ envelope: WatchTimeEntryEnvelopeV1) async throws {
        guard let session else {
            throw HourleafWatchConnectivityError.unavailable
        }
        guard await activateIfNeeded(session) else {
            throw HourleafWatchConnectivityError.unavailable
        }

        let requestData = try envelope.encoded()
        let responseData: Data
        do {
            responseData = try await withCheckedThrowingContinuation { continuation in
                session.sendMessageData(
                    requestData,
                    replyHandler: { data in
                        continuation.resume(returning: data)
                    },
                    errorHandler: { _ in
                        continuation.resume(throwing: HourleafWatchConnectivityError.notConfirmed)
                    }
                )
            }
        } catch let error as HourleafWatchConnectivityError {
            throw error
        } catch {
            throw HourleafWatchConnectivityError.notConfirmed
        }

        let response: WatchTimeEntryResponseV1
        do {
            response = try WatchTimeEntryResponseV1.decode(
                responseData,
                expecting: envelope.mutationID
            )
        } catch {
            throw HourleafWatchConnectivityError.notConfirmed
        }

        switch response.status {
        case .saved, .replayed:
            return
        case .rejected:
            throw HourleafWatchConnectivityError.rejected
        case .failed:
            throw HourleafWatchConnectivityError.notConfirmed
        }
    }

    private func activateIfNeeded(_ session: WCSession) async -> Bool {
        if session.activationState == .activated {
            return true
        }
        return await withCheckedContinuation { continuation in
            activationWaiters.append(continuation)
            session.activate()
        }
    }

    private func finishActivation(_ succeeded: Bool) {
        let waiters = activationWaiters
        activationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: succeeded) }
    }
}

extension HourleafWatchConnectivityClient: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let succeeded = activationState == .activated && error == nil
        Task { @MainActor [weak self] in
            self?.finishActivation(succeeded)
        }
    }

#if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
}
