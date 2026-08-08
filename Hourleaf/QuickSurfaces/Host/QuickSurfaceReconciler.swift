import Foundation

enum QuickSurfaceReconcilerError: LocalizedError, Equatable, Sendable {
    case projectionTotalsUnavailable
    case invalidGeneratedAt

    var errorDescription: String? {
        switch self {
        case .projectionTotalsUnavailable:
            return "Quick-surface totals are unavailable."
        case .invalidGeneratedAt:
            return "Quick-surface state cannot use the current clock."
        }
    }
}

/// Host-only projection writer. It never reads Core Data itself: callers pass
/// one already-authoritative snapshot, then this type performs one coordinated
/// sidecar transition while preserving the latest timer phase.
struct QuickSurfaceReconciler: @unchecked Sendable {
    private static let maximumProjectionMinutes = Int(Int32.max)

    let stateStore: QuickSurfaceStateStoreV1
    private let calendar: Calendar
    private let timeZone: TimeZone
    private let clock: @Sendable () -> Date

    init(
        stateStore: QuickSurfaceStateStoreV1,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone? = nil,
        clock: @escaping @Sendable () -> Date = { .now }
    ) {
        let resolvedTimeZone = timeZone ?? calendar.timeZone
        var resolvedCalendar = calendar
        resolvedCalendar.timeZone = resolvedTimeZone

        self.stateStore = stateStore
        self.calendar = resolvedCalendar
        self.timeZone = resolvedTimeZone
        self.clock = clock
    }

    /// Creates revision 1 only when no host sidecar exists. If another process
    /// wins the create-if-absent race, reconcile its host-owned fields under
    /// ordinary fail-private rules while preserving its timer phase.
    func bootstrap(
        snapshot: LedgerSnapshot,
        preferences: QuickSurfacePreferences? = nil
    ) throws -> QuickSurfaceStateV1 {
        let resolvedPreferences = preferences ?? snapshot.settingsMetadata.quickSurfacePreferences
        let now = try currentProjectionDate()
        let requestedPrivacy: QuickSurfacePrivacyModeV1 = resolvedPreferences.privacyMode == .showTotals
            ? .showTotals
            : .hideTotals
        let projection: QuickSurfaceProjectionV1
        do {
            projection = try makeProjection(
                snapshot: snapshot,
                privacyMode: requestedPrivacy,
                generatedAt: now
            )
        } catch {
            if requestedPrivacy == .showTotals {
                try publishUnavailableProjection(
                    snapshot: snapshot,
                    preferences: resolvedPreferences
                )
            }
            throw error
        }
        let initial = QuickSurfaceStateV1(
            revision: 1,
            projection: projection,
            timerEnabled: resolvedPreferences.timerVisible,
            timer: .idle
        )
        _ = try stateStore.createIfAbsent(initial)

        // A competing host process can win create-if-absent. Reconcile once
        // with ordinary fail-private policy so host-owned fields converge
        // without elevating a hidden/disabled winner or touching its timer.
        return try reconcile(
            snapshot: snapshot,
            preferences: resolvedPreferences,
            permitElevation: false
        )
    }

    /// Reconciles an existing state. Ordinary calls are fail-private: a hidden
    /// or disabled sidecar is never elevated merely because persisted settings
    /// say shown/enabled. The caller may opt into elevation only after an
    /// explicit preference flow has completed its required first step.
    func reconcile(
        snapshot: LedgerSnapshot,
        preferences: QuickSurfacePreferences? = nil,
        permitElevation: Bool = false
    ) throws -> QuickSurfaceStateV1 {
        let resolvedPreferences = preferences ?? snapshot.settingsMetadata.quickSurfacePreferences
        let current = try readCurrentStateIfPresent()
        let now = try projectionDateForReconciliation(
            current: current,
            privacyMode: resolvedPreferences.privacyMode
        )
        let hiddenProjection = try makeProjection(
            snapshot: snapshot,
            privacyMode: .hideTotals,
            generatedAt: now
        )
        let shouldPrepareShownProjection = resolvedPreferences.privacyMode == .showTotals
            && (permitElevation || current == nil || current?.projection.privacyMode == .showTotals)
        let shownProjection: QuickSurfaceProjectionV1?
        do {
            shownProjection = try shouldPrepareShownProjection
                ? makeProjection(snapshot: snapshot, privacyMode: .showTotals, generatedAt: now)
                : nil
        } catch {
            try publishUnavailableProjection(
                snapshot: snapshot,
                preferences: resolvedPreferences
            )
            throw error
        }

        return try stateStore.replace { latest in
            let shouldShow = resolvedPreferences.privacyMode == .showTotals
                && (permitElevation || latest == nil || latest?.projection.privacyMode == .showTotals)
            let proposedProjection = shouldShow ? (shownProjection ?? hiddenProjection) : hiddenProjection
            let projection = latest.map { current in
                shouldKeepExistingProjection(current.projection, insteadOf: proposedProjection)
                    ? current.projection
                    : proposedProjection
            } ?? proposedProjection
            let timerEnabled = resolvedTimerEnabled(
                current: latest,
                preferences: resolvedPreferences,
                permitElevation: permitElevation
            )

            guard let latest else {
                return QuickSurfaceStateV1(
                    revision: 1,
                    projection: projection,
                    timerEnabled: timerEnabled,
                    timer: .idle
                )
            }
            guard latest.projection != projection || latest.timerEnabled != timerEnabled else {
                return latest
            }

            return QuickSurfaceStateV1(
                revision: try latest.nextRevision(),
                projection: projection,
                timerEnabled: timerEnabled,
                timer: latest.timer
            )
        }
    }

    private func readCurrentStateIfPresent() throws -> QuickSurfaceStateV1? {
        do {
            return try stateStore.read()
        } catch QuickSurfaceStateStoreError.missingFile {
            return nil
        }
    }

    /// A totals calculation cannot be represented safely. Publish the
    /// data-minimized form first, then let the caller report the projection as
    /// unavailable. This avoids leaving an old shown projection eligible for a
    /// system surface after a ledger mutation made the new total unrepresentable.
    private func publishUnavailableProjection(
        snapshot: LedgerSnapshot,
        preferences: QuickSurfacePreferences
    ) throws {
        var failPrivatePreferences = preferences
        failPrivatePreferences.privacyMode = .hideTotals
        _ = try reconcile(
            snapshot: snapshot,
            preferences: failPrivatePreferences,
            permitElevation: false
        )
    }

    private func currentProjectionDate() throws -> Date {
        let now = clock()
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else {
            throw QuickSurfaceReconcilerError.invalidGeneratedAt
        }
        return now
    }

    /// Redaction must remain possible even if the device wall clock is
    /// temporarily invalid. Reusing the already-validated timestamp from an
    /// existing projection changes no displayed totals and lets the host
    /// physically remove previously published values. Creating or showing a
    /// projection still requires a valid current clock.
    private func projectionDateForReconciliation(
        current: QuickSurfaceStateV1?,
        privacyMode: WidgetPrivacyMode
    ) throws -> Date {
        do {
            return try currentProjectionDate()
        } catch {
            guard privacyMode == .hideTotals,
                  let generatedAt = current?.projection.generatedAtEpochSeconds else {
                throw error
            }
            return Date(timeIntervalSince1970: generatedAt)
        }
    }

    private func makeProjection(
        snapshot: LedgerSnapshot,
        privacyMode: QuickSurfacePrivacyModeV1,
        generatedAt: Date
    ) throws -> QuickSurfaceProjectionV1 {
        let generatedAtEpochSeconds = generatedAt.timeIntervalSince1970
        switch privacyMode {
        case .hideTotals:
            return try QuickSurfaceProjectionV1(
                privacyMode: .hideTotals,
                monthKey: nil,
                timeZoneIdentifier: nil,
                serviceMinutes: nil,
                creditMinutes: nil,
                generatedAtEpochSeconds: generatedAtEpochSeconds
            )

        case .showTotals:
            let currentMonth = MonthKey(generatedAt, calendar: calendar)
            var serviceMinutes = 0
            var creditMinutes = 0

            for record in snapshot.entries where !record.isDeleted && record.entry.day.monthKey == currentMonth {
                switch record.entry.kind {
                case .service:
                    serviceMinutes = try addProjectionMinutes(serviceMinutes, record.entry.minutes)
                case .credit:
                    creditMinutes = try addProjectionMinutes(creditMinutes, record.entry.minutes)
                }
            }

            return try QuickSurfaceProjectionV1(
                privacyMode: .showTotals,
                monthKey: currentMonth.key,
                timeZoneIdentifier: timeZone.identifier,
                serviceMinutes: serviceMinutes,
                creditMinutes: creditMinutes,
                generatedAtEpochSeconds: generatedAtEpochSeconds
            )
        }
    }

    private func addProjectionMinutes(_ total: Int, _ value: Int) throws -> Int {
        let (next, overflow) = total.addingReportingOverflow(value)
        guard !overflow, (0...Self.maximumProjectionMinutes).contains(next) else {
            throw QuickSurfaceReconcilerError.projectionTotalsUnavailable
        }
        return next
    }

    private func shouldKeepExistingProjection(
        _ lhs: QuickSurfaceProjectionV1,
        insteadOf rhs: QuickSurfaceProjectionV1
    ) -> Bool {
        lhs.privacyMode == rhs.privacyMode
            && lhs.monthKey == rhs.monthKey
            && lhs.timeZoneIdentifier == rhs.timeZoneIdentifier
            && lhs.serviceMinutes == rhs.serviceMinutes
            && lhs.creditMinutes == rhs.creditMinutes
            && lhs.generatedAtEpochSeconds <= rhs.generatedAtEpochSeconds
    }

    private func resolvedTimerEnabled(
        current: QuickSurfaceStateV1?,
        preferences: QuickSurfacePreferences,
        permitElevation: Bool
    ) -> Bool {
        guard let current else { return preferences.timerVisible }

        switch current.timer {
        case .idle:
            guard preferences.timerVisible else { return false }
            return permitElevation || current.timerEnabled
        case .running, .reviewPending, .finalizing:
            // M1 forbids disabling a non-idle session. Preserve its state
            // rather than making an invalid transition or discarding evidence.
            return current.timerEnabled
        }
    }
}
