import Foundation

enum QuickSurfaceDisplayAvailabilityV1: Equatable, Sendable {
    case ready
    case unavailable
    case protected
    case needsReset
}

enum QuickSurfaceDisplayTotalsV1: Equatable, Sendable {
    case absent
    case shown(
        monthKey: String,
        serviceMinutes: Int,
        creditMinutes: Int,
        bibleStudyCount: Int?,
        serviceYearMinutes: Int?,
        serviceYearTargetMinutes: Int?
    )
}

enum QuickSurfaceDisplayTimerV1: Equatable, Sendable {
    case disabled
    case idle
    case running(startedAtEpochSeconds: Double)
    case reviewPending
    case finalizing
}

struct QuickSurfaceDisplayStateV1: Equatable, Sendable {
    let availability: QuickSurfaceDisplayAvailabilityV1
    let totals: QuickSurfaceDisplayTotalsV1
    let timer: QuickSurfaceDisplayTimerV1

    static func fallback(
        _ availability: QuickSurfaceDisplayAvailabilityV1
    ) -> QuickSurfaceDisplayStateV1 {
        QuickSurfaceDisplayStateV1(
            availability: availability,
            totals: .absent,
            timer: .disabled
        )
    }
}

enum QuickSurfaceDisplayReducerV1 {
    static func reduce(
        state: QuickSurfaceStateV1
    ) -> QuickSurfaceDisplayStateV1 {
        reduce(state: state, asOf: Date())
    }

    static func reduce(
        state: QuickSurfaceStateV1,
        asOf: Date
    ) -> QuickSurfaceDisplayStateV1 {
        guard state.revision > 0, state.revision < .max else {
            return .fallback(.needsReset)
        }

        let totals: QuickSurfaceDisplayTotalsV1
        switch state.projection.privacyMode {
        case .hideTotals:
            totals = .absent
        case .showTotals:
            guard
                let monthKey = state.projection.monthKey,
                let serviceMinutes = state.projection.serviceMinutes,
                let creditMinutes = state.projection.creditMinutes,
                isValidMonthKey(monthKey),
                (0...Int(Int32.max)).contains(serviceMinutes),
                (0...Int(Int32.max)).contains(creditMinutes)
            else {
                return .fallback(.needsReset)
            }
            guard let timeZoneIdentifier = state.projection.timeZoneIdentifier,
                  let timeZone = TimeZone(identifier: timeZoneIdentifier),
                  asOf.timeIntervalSince1970.isFinite
            else {
                return .fallback(.needsReset)
            }
            let extendedMetrics = [
                state.projection.bibleStudyCount != nil,
                state.projection.serviceYearMinutes != nil,
                state.projection.serviceYearTargetMinutes != nil
            ]
            guard extendedMetrics.allSatisfy({ $0 }) || extendedMetrics.allSatisfy({ !$0 }) else {
                return .fallback(.needsReset)
            }
            if let bibleStudyCount = state.projection.bibleStudyCount,
               let serviceYearMinutes = state.projection.serviceYearMinutes,
               let serviceYearTargetMinutes = state.projection.serviceYearTargetMinutes {
                guard
                    (0...999).contains(bibleStudyCount),
                    (0...Int(Int32.max)).contains(serviceYearMinutes),
                    (1...Int(Int32.max)).contains(serviceYearTargetMinutes)
                else {
                    return .fallback(.needsReset)
                }
            }
            if isCurrentMonth(monthKey, asOf: asOf, timeZone: timeZone) {
                totals = .shown(
                    monthKey: monthKey,
                    serviceMinutes: serviceMinutes,
                    creditMinutes: creditMinutes,
                    bibleStudyCount: state.projection.bibleStudyCount,
                    serviceYearMinutes: state.projection.serviceYearMinutes,
                    serviceYearTargetMinutes: state.projection.serviceYearTargetMinutes
                )
            } else {
                // The projection is valid but belongs to a previous civil
                // month. Keep timer/control availability while omitting stale
                // totals from the process boundary.
                totals = .absent
            }
        }

        let timer: QuickSurfaceDisplayTimerV1
        guard state.timerEnabled else {
            timer = .disabled
            return QuickSurfaceDisplayStateV1(
                availability: .ready,
                totals: totals,
                timer: timer
            )
        }

        switch state.timer {
        case .idle:
            timer = .idle
        case let .running(running):
            timer = .running(startedAtEpochSeconds: running.startedAtEpochSeconds)
        case .reviewPending:
            timer = .reviewPending
        case .finalizing:
            timer = .finalizing
        }

        return QuickSurfaceDisplayStateV1(
            availability: .ready,
            totals: totals,
            timer: timer
        )
    }

    static func reduce(
        readResult: Result<QuickSurfaceStateV1, QuickSurfaceStateStoreError>
    ) -> QuickSurfaceDisplayStateV1 {
        reduce(readResult: readResult, asOf: Date())
    }

    static func reduce(
        readResult: Result<QuickSurfaceStateV1, QuickSurfaceStateStoreError>,
        asOf: Date
    ) -> QuickSurfaceDisplayStateV1 {
        switch readResult {
        case let .success(state):
            return reduce(state: state, asOf: asOf)
        case let .failure(error):
            return fallback(for: error)
        }
    }

    private static func fallback(
        for error: QuickSurfaceStateStoreError
    ) -> QuickSurfaceDisplayStateV1 {
        .fallback(availability(for: error))
    }

    private static func availability(
        for error: QuickSurfaceStateStoreError
    ) -> QuickSurfaceDisplayAvailabilityV1 {
        switch error {
        case .protectedBeforeFirstUnlock,
             .protectionReadbackFailed,
             .backupExclusionReadbackFailed:
            return .protected

        case .missingFile,
             .invalidRoot,
             .unavailableRoot,
             .accessBusy,
             .leaseUnavailable,
             .leaseReleased,
             .leaseRootMismatch,
             .leaseIdentityMismatch,
             .leaseReleaseFailed:
            return .unavailable

        case .corrupt,
             .unsupportedVersion,
             .pathEscape,
             .symlinkDetected,
             .coordinationFailed,
             .readFailed,
             .writeFailed,
             .attributeApplyFailed,
             .readbackMismatch,
             .invalidInitialRevision,
             .invalidRevisionTransition,
             .revisionUnavailable,
             .currentStateMismatch,
             .lockFileInvalid:
            return .needsReset
        }
    }

    private static func isValidMonthKey(_ value: String) -> Bool {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard
            components.count == 2,
            let year = Int(components[0]),
            let month = Int(components[1]),
            value == String(format: "%04d-%02d", year, month),
            (1...9_999).contains(year),
            (1...12).contains(month)
        else {
            return false
        }
        return true
    }

    private static func isCurrentMonth(
        _ monthKey: String,
        asOf date: Date,
        timeZone: TimeZone
    ) -> Bool {
        guard date.timeIntervalSince1970.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        guard let year = components.year, let month = components.month else {
            return false
        }
        return monthKey == String(format: "%04d-%02d", year, month)
    }
}
