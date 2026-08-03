import Combine
import Foundation

struct BackupConfidenceEvaluator: Sendable {
    let evidenceStore: VerifiedExportEvidenceStore
    let snapshot: @Sendable () async throws -> HourleafBackupRecordsV1

    func evaluate() async -> BackupConfidenceState {
        do {
            guard let evidence = try await evidenceStore.read() else {
                return .noVerifiedExport
            }
            let records = try await snapshot()
            let digest = try HourleafBackupCodec.storeDigest(records)
            if digest == evidence.recordsDigest {
                return .matches(verifiedAt: evidence.verifiedAt)
            }
            return .recordsChanged(verifiedAt: evidence.verifiedAt)
        } catch {
            return .unavailable
        }
    }
}

@MainActor
final class BackupConfidenceStatusModel: ObservableObject {
    @Published private(set) var state: BackupConfidenceState?

    private let evaluator: BackupConfidenceEvaluator
    private var refreshTask: Task<Void, Never>?
    private var queuedRefresh = false

    init(
        state: BackupConfidenceState? = nil,
        evaluator: BackupConfidenceEvaluator
    ) {
        self.state = state
        self.evaluator = evaluator
    }

    func requestRefresh() {
        guard refreshTask == nil else {
            queuedRefresh = true
            return
        }

        refreshTask = Task { [weak self] in
            guard let self else { return }
            while true {
                let nextState = await evaluator.evaluate()
                await MainActor.run {
                    self.state = nextState
                }

                let shouldContinue = await MainActor.run { () -> Bool in
                    if queuedRefresh {
                        queuedRefresh = false
                        return true
                    }
                    refreshTask = nil
                    return false
                }
                if !shouldContinue { break }
            }
        }
    }
}
