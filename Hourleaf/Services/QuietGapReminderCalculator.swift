import Foundation

struct QuietGapSchedulingRequest: Equatable, Sendable {
    let isEnabled: Bool
    let gapDays: Int
    let ledgerStartMonth: MonthKey
    let entries: [LedgerEntryRecord]
    let acknowledgements: [DayAcknowledgementRecord]
    let requestAuthorizationIfNeeded: Bool

    init(
        isEnabled: Bool,
        gapDays: Int = 7,
        ledgerStartMonth: MonthKey,
        entries: [LedgerEntryRecord],
        acknowledgements: [DayAcknowledgementRecord],
        requestAuthorizationIfNeeded: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.gapDays = gapDays
        self.ledgerStartMonth = ledgerStartMonth
        self.entries = entries
        self.acknowledgements = acknowledgements
        self.requestAuthorizationIfNeeded = requestAuthorizationIfNeeded
    }
}

struct QuietGapReminderCandidate: Equatable, Sendable {
    let targetDay: LocalDay
    let triggerDate: Date
}

enum QuietGapSchedulingOutcome: Equatable, Sendable {
    case disabled
    case invalidConfiguration
    case authorizationRequired
    case authorizationDenied
    case noCandidate
    case scheduled(QuietGapReminderCandidate)
}

enum QuietGapReminderCalculator {
    static func candidate(
        for request: QuietGapSchedulingRequest,
        now: Date,
        calendar: Calendar
    ) -> QuietGapReminderCandidate? {
        guard request.isEnabled, (1...30).contains(request.gapDays) else {
            return nil
        }

        let today = LocalDay(now, calendar: calendar)
        let activeServiceDays = Set(request.entries.compactMap { record -> LocalDay? in
            guard
                record.deletedAt == nil,
                record.entry.kind == .service,
                record.entry.day.monthKey >= request.ledgerStartMonth,
                record.entry.day <= today
            else {
                return nil
            }
            return record.entry.day
        })

        guard !activeServiceDays.isEmpty else {
            return nil
        }

        let acknowledgementDays: Set<LocalDay>
        do {
            acknowledgementDays = try Set(request.acknowledgements.map { record in
                guard
                    record.status == "nothingToday",
                    !record.source.isEmpty,
                    record.day.monthKey >= request.ledgerStartMonth,
                    record.day <= today
                else {
                    throw QuietGapValidationError.invalidAcknowledgement
                }
                return record.day
            })
        } catch {
            return nil
        }

        guard
            let anchorDay = (activeServiceDays.union(acknowledgementDays))
                .filter({ $0 <= today })
                .max()
        else {
            return nil
        }

        var candidateDay = anchorDay
        repeat {
            guard
                let anchorDate = calendar.date(
                    byAdding: .day,
                    value: request.gapDays,
                    to: candidateDay.date(calendar: calendar)
                )
            else {
                return nil
            }
            candidateDay = LocalDay(anchorDate, calendar: calendar)
            guard let triggerDate = triggerDate(for: candidateDay, calendar: calendar) else {
                return nil
            }
            if triggerDate > now {
                return QuietGapReminderCandidate(targetDay: candidateDay, triggerDate: triggerDate)
            }
        } while true
    }

    private static func triggerDate(for day: LocalDay, calendar: Calendar) -> Date? {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: day.year,
                month: day.month,
                day: day.day,
                hour: 18,
                minute: 0,
                second: 0
            )
        )
    }
}

private enum QuietGapValidationError: Error {
    case invalidAcknowledgement
}
