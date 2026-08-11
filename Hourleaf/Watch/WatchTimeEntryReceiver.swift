import Foundation

struct WatchTimeEntryReceiver: Sendable {
    private let repository: any LedgerRepository
    private let afterCommit: @Sendable () async -> Void

    init(
        repository: any LedgerRepository,
        router: AppRouter? = nil,
        quickSurfaceRefresher: QuickSurfaceIntentProjectionRefresher = .disabled
    ) {
        self.repository = repository
        afterCommit = {
            await quickSurfaceRefresher.refreshAfterMutation()
            if let router {
                await router.notifyLedgerChanged()
            }
        }
    }

    func receive(_ data: Data) async -> WatchTimeEntryResponseV1 {
        let envelope: WatchTimeEntryEnvelopeV1
        do {
            envelope = try WatchTimeEntryEnvelopeV1.decode(data)
        } catch {
            return WatchTimeEntryResponseV1(
                mutationID: Self.unknownMutationID,
                status: .rejected
            )
        }

        let kind: EntryKind = switch envelope.kind {
        case .service: .service
        case .credit: .credit
        }
        let date = LocalDay(
            year: envelope.day.year,
            month: envelope.day.month,
            day: envelope.day.day
        ).date(calendar: .hourleaf)

        do {
            let receipt = try await AddTimeEntryCommand(repository: repository).execute(
                kind: kind,
                date: date,
                hours: envelope.minutes / 60,
                minutes: envelope.minutes % 60,
                note: nil,
                mutationID: envelope.mutationID,
                entryID: envelope.entryID,
                occurredAt: envelope.occurredAt,
                source: .watch
            )
            await afterCommit()
            return WatchTimeEntryResponseV1(
                mutationID: envelope.mutationID,
                status: receipt.wasReplay ? .replayed : .saved
            )
        } catch is EntryValidationError {
            return WatchTimeEntryResponseV1(
                mutationID: envelope.mutationID,
                status: .rejected
            )
        } catch is EntryMutationError {
            return WatchTimeEntryResponseV1(
                mutationID: envelope.mutationID,
                status: .failed
            )
        } catch {
            return WatchTimeEntryResponseV1(
                mutationID: envelope.mutationID,
                status: .failed
            )
        }
    }

    private static let unknownMutationID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!
}
