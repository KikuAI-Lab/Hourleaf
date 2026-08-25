import AppIntents
import Foundation
import SwiftUI
import WidgetKit

enum HourleafQuickSurfaceKind {
    static let widget = "HourleafQuickSurfaceWidget"
    static let control = "HourleafQuickSurfaceTimerControl"
}

private enum HourleafQuickSurfaceCopy {
    static func resource(
        _ key: StaticString,
        defaultValue: String
    ) -> LocalizedStringResource {
        LocalizedStringResource(
            key,
            defaultValue: String.LocalizationValue(stringLiteral: defaultValue),
            table: "Localizable",
            bundle: .main
        )
    }

    static let widgetTitle = resource("quick_surface.widget.title", defaultValue: "Hourleaf")
    static let thisMonth = resource("quick_surface.widget.this_month", defaultValue: "This month")
    static let service = resource("quick_surface.widget.service", defaultValue: "Service")
    static let credit = resource("quick_surface.widget.credit", defaultValue: "Credit")
    static let minutesFormat = resource("quick_surface.widget.minutes_format", defaultValue: "%d min")
    static let hoursFormat = resource("quick_surface.widget.hours_format", defaultValue: "%d h")
    static let hoursMinutesFormat = resource(
        "quick_surface.widget.hours_minutes_format",
        defaultValue: "%d h %d min"
    )
    static let bibleStudies = resource(
        "quick_surface.widget.bible_studies",
        defaultValue: "Bible studies"
    )
    static let bibleStudiesCompact = resource(
        "quick_surface.widget.bible_studies_compact",
        defaultValue: "Studies"
    )
    static let serviceYear = resource(
        "quick_surface.widget.service_year",
        defaultValue: "Service year"
    )
    static let widgetDescription = resource(
        "quick_surface.widget.description",
        defaultValue: "This month's time and service-year progress"
    )
    static let timerRunning = resource("quick_surface.widget.timer_running", defaultValue: "Timer running")
    static let timerReady = resource("quick_surface.widget.timer_ready", defaultValue: "Timer ready")
    static let timerOff = resource("quick_surface.widget.timer_off", defaultValue: "Timer off")
    static let review = resource("quick_surface.widget.review", defaultValue: "Review in Hourleaf")
    static let saving = resource("quick_surface.widget.saving", defaultValue: "Saving in Hourleaf")
    static let totalsHidden = resource("quick_surface.widget.totals_hidden", defaultValue: "Totals hidden")
    static let unavailable = resource("quick_surface.widget.unavailable", defaultValue: "Quick view unavailable")
    static let protected = resource("quick_surface.widget.protected", defaultValue: "Unlock iPhone to view")
    static let needsReset = resource("quick_surface.widget.needs_reset", defaultValue: "Open Hourleaf to refresh")
    static let busy = resource("quick_surface.widget.busy", defaultValue: "Hourleaf is busy")
    static let accessibilityRunning = resource(
        "quick_surface.widget.accessibility_running",
        defaultValue: "Hourleaf timer is running"
    )
    static let accessibilityReview = resource(
        "quick_surface.widget.accessibility_review",
        defaultValue: "Hourleaf timer stopped; review it in Hourleaf"
    )
    static let accessibilityUnavailable = resource(
        "quick_surface.widget.accessibility_unavailable",
        defaultValue: "Hourleaf quick view is unavailable"
    )

    static let controlTitle = resource("quick_surface.control.title", defaultValue: "Hourleaf timer")
    static let controlStart = resource("quick_surface.control.start", defaultValue: "Start timer")
    static let controlStop = resource("quick_surface.control.stop", defaultValue: "Stop timer")
    static let controlRunning = resource("quick_surface.control.running", defaultValue: "Running")
    static let controlReady = resource("quick_surface.control.ready", defaultValue: "Ready")
    static let controlReview = resource("quick_surface.control.review", defaultValue: "Review in Hourleaf")
    static let controlSaving = resource("quick_surface.control.saving", defaultValue: "Saving")
    static let controlUnavailable = resource("quick_surface.control.unavailable", defaultValue: "Unavailable")
    static let controlProtected = resource("quick_surface.control.protected", defaultValue: "Unlock iPhone")
    static let controlDisabled = resource("quick_surface.control.disabled", defaultValue: "Timer off")
    static let controlNeedsReset = resource("quick_surface.control.needs_reset", defaultValue: "Open Hourleaf")
    static let controlBusy = resource("quick_surface.control.busy", defaultValue: "Try again")
    static let controlFailure = resource("quick_surface.control.failure", defaultValue: "Could not update timer")
    static let controlStarted = resource("quick_surface.control.started", defaultValue: "Timer started")
    static let controlStopped = resource(
        "quick_surface.control.stopped",
        defaultValue: "Timer stopped. Continue in Hourleaf to review."
    )
    static let controlUnchangedStart = resource(
        "quick_surface.control.unchanged_start",
        defaultValue: "Timer is already running"
    )
    static let controlUnchangedStop = resource(
        "quick_surface.control.unchanged_stop",
        defaultValue: "Timer is already stopped"
    )
    static let controlContinueDialog = resource(
        "quick_surface.control.continue_dialog",
        defaultValue: "Continue in Hourleaf to review and save this time."
    )
    static let controlErrorBusy = resource(
        "quick_surface.control.error_busy",
        defaultValue: "Hourleaf is busy. Try again."
    )
    static let controlErrorUnavailable = resource(
        "quick_surface.control.error_unavailable",
        defaultValue: "Hourleaf quick controls are unavailable."
    )
    static let controlErrorProtected = resource(
        "quick_surface.control.error_protected",
        defaultValue: "Unlock iPhone, then try again."
    )
    static let controlErrorCorrupt = resource(
        "quick_surface.control.error_corrupt",
        defaultValue: "Open Hourleaf to refresh quick controls."
    )
    static let controlErrorReset = resource(
        "quick_surface.control.error_reset",
        defaultValue: "Open Hourleaf to reset quick controls."
    )
    static let controlErrorDisabled = resource(
        "quick_surface.control.error_disabled",
        defaultValue: "Turn on the timer in Hourleaf first."
    )
    static let controlErrorReview = resource(
        "quick_surface.control.error_review",
        defaultValue: "Continue in Hourleaf to review the stopped timer."
    )
    static let controlErrorRevision = resource(
        "quick_surface.control.error_revision",
        defaultValue: "Quick controls changed. Try again."
    )
    static let controlErrorClock = resource(
        "quick_surface.control.error_clock",
        defaultValue: "The clock needs attention in Hourleaf."
    )
}

private enum HourleafQuickSurfaceSnapshotReader {
    static func read() -> QuickSurfaceDisplayStateV1 {
        switch HourleafQuickSurfaceContainer.resolve() {
        case let .available(rootURL):
            let store = QuickSurfaceStateStoreV1(rootDirectory: rootURL)
            do {
                return QuickSurfaceDisplayReducerV1.reduce(state: try store.read(), asOf: Date())
            } catch let error as QuickSurfaceStateStoreError {
                let readResult: Result<QuickSurfaceStateV1, QuickSurfaceStateStoreError> = .failure(error)
                return QuickSurfaceDisplayReducerV1.reduce(readResult: readResult)
            } catch {
                return .fallback(.needsReset)
            }
        case .unavailable:
            return .fallback(.unavailable)
        }
    }
}

private enum HourleafQuickSurfaceReloads {
    static func requestWidgetReload() {
        WidgetCenter.shared.reloadTimelines(ofKind: HourleafQuickSurfaceKind.widget)
    }

    @available(iOS 18.0, *)
    static func requestControlReload() {
        ControlCenter.shared.reloadControls(ofKind: HourleafQuickSurfaceKind.control)
    }

    @available(iOS 18.0, *)
    static func requestAll() {
        requestWidgetReload()
        requestControlReload()
    }
}

struct HourleafQuickSurfaceEntry: TimelineEntry {
    let date: Date
    let displayState: QuickSurfaceDisplayStateV1
}

struct HourleafQuickSurfaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> HourleafQuickSurfaceEntry {
        HourleafQuickSurfaceEntry(
            date: Date(),
            displayState: .fallback(.unavailable)
        )
    }

    func getSnapshot(
        in context: Context,
        completion: @escaping (HourleafQuickSurfaceEntry) -> Void
    ) {
        completion(
            HourleafQuickSurfaceEntry(
                date: Date(),
                displayState: HourleafQuickSurfaceSnapshotReader.read()
            )
        )
    }

    func getTimeline(
        in context: Context,
        completion: @escaping (Timeline<HourleafQuickSurfaceEntry>) -> Void
    ) {
        let entry = HourleafQuickSurfaceEntry(
            date: Date(),
            displayState: HourleafQuickSurfaceSnapshotReader.read()
        )
        // The running timer uses SwiftUI's native timer text. A bounded
        // refresh keeps protected or stale snapshots from lingering while
        // host and control transitions request immediate reloads.
        completion(
            Timeline(
                entries: [entry],
                policy: .after(Date(timeIntervalSinceNow: 15 * 60))
            )
        )
    }
}

struct HourleafQuickSurfaceWidgetView: View {
    let displayState: QuickSurfaceDisplayStateV1
    @Environment(\.widgetFamily) private var widgetFamily

    private enum Palette {
        static let accent = Color(
            red: 74.0 / 255.0,
            green: 109.0 / 255.0,
            blue: 167.0 / 255.0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            switch displayState.availability {
            case .ready:
                readyContent
            case .unavailable:
                statusContent(
                    HourleafQuickSurfaceCopy.unavailable,
                    systemImage: "questionmark.circle"
                )
            case .protected:
                statusContent(
                    HourleafQuickSurfaceCopy.protected,
                    systemImage: "lock.fill"
                )
            case .needsReset:
                statusContent(
                    HourleafQuickSurfaceCopy.needsReset,
                    systemImage: "arrow.clockwise.circle"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .containerBackground(.background, for: .widget)
        .widgetURL(HourleafQuickEntryURL.makeURL())
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "leaf.fill")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(HourleafQuickSurfaceCopy.widgetTitle)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Spacer(minLength: 4)

            if widgetFamily == .systemMedium,
               let monthDate {
                Text(monthDate, format: .dateTime.month(.wide))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var readyContent: some View {
        switch displayState.totals {
        case .absent:
            VStack(alignment: .leading, spacing: 8) {
                Label(HourleafQuickSurfaceCopy.totalsHidden, systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                salientTimerContent
            }
        case let .shown(
            _,
            serviceMinutes,
            creditMinutes,
            bibleStudyCount,
            serviceYearMinutes,
            serviceYearTargetMinutes
        ):
            Group {
                if widgetFamily == .systemMedium {
                    mediumTotals(
                        serviceMinutes: serviceMinutes,
                        creditMinutes: creditMinutes,
                        bibleStudyCount: bibleStudyCount,
                        serviceYearMinutes: serviceYearMinutes,
                        serviceYearTargetMinutes: serviceYearTargetMinutes
                    )
                } else {
                    smallTotals(
                        serviceMinutes: serviceMinutes,
                        creditMinutes: creditMinutes,
                        bibleStudyCount: bibleStudyCount
                    )
                }
            }
            // Totals are opt-in in the sidecar and remain privacy-sensitive
            // while rendered by the system on the lock screen.
            .privacySensitive()
        }
    }

    private func smallTotals(
        serviceMinutes: Int,
        creditMinutes: Int,
        bibleStudyCount: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(HourleafQuickSurfaceCopy.service)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(durationText(serviceMinutes))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(alignment: .top, spacing: 12) {
                smallMetric(
                    label: HourleafQuickSurfaceCopy.credit,
                    value: durationText(creditMinutes)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                if let bibleStudyCount {
                    smallMetric(
                        label: HourleafQuickSurfaceCopy.bibleStudiesCompact,
                        value: String(bibleStudyCount)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            salientTimerContent
        }
    }

    private func smallMetric(
        label: LocalizedStringResource,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .allowsTightening(true)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .allowsTightening(true)
        }
    }

    private func mediumTotals(
        serviceMinutes: Int,
        creditMinutes: Int,
        bibleStudyCount: Int?,
        serviceYearMinutes: Int?,
        serviceYearTargetMinutes: Int?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(HourleafQuickSurfaceCopy.service)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(durationText(serviceMinutes))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    compactMetric(
                        label: HourleafQuickSurfaceCopy.credit,
                        value: durationText(creditMinutes)
                    )
                    if let bibleStudyCount {
                        compactMetric(
                            label: HourleafQuickSurfaceCopy.bibleStudies,
                            value: String(bibleStudyCount)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                if let serviceYearMinutes,
                   let serviceYearTargetMinutes {
                    serviceYearProgress(
                        minutes: serviceYearMinutes,
                        targetMinutes: serviceYearTargetMinutes
                    )
                }
                salientTimerContent
            }
        }
    }

    private func compactMetric(
        label: LocalizedStringResource,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    private func serviceYearProgress(
        minutes: Int,
        targetMinutes: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(HourleafQuickSurfaceCopy.serviceYear)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(durationText(minutes)) / \(durationText(targetMinutes))")
                    .monospacedDigit()
            }
            .font(.caption2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            ProgressView(
                value: min(Double(minutes), Double(targetMinutes)),
                total: Double(targetMinutes)
            )
            .tint(Palette.accent)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var salientTimerContent: some View {
        switch displayState.timer {
        case .disabled, .idle:
            EmptyView()
        case let .running(startedAtEpochSeconds):
            let startDate = Date(timeIntervalSince1970: startedAtEpochSeconds)
            HStack(spacing: 5) {
                Image(systemName: "timer")
                    .accessibilityHidden(true)
                Text(startDate, style: .timer)
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Palette.accent)
            .lineLimit(1)
            .accessibilityLabel(HourleafQuickSurfaceCopy.accessibilityRunning)
        case .reviewPending:
            Label(HourleafQuickSurfaceCopy.review, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(Palette.accent)
                .lineLimit(2)
                .accessibilityLabel(HourleafQuickSurfaceCopy.accessibilityReview)
        case .finalizing:
            Label(HourleafQuickSurfaceCopy.saving, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .lineLimit(2)
        }
    }

    private var monthDate: Date? {
        guard case let .shown(monthKey, _, _, _, _, _) = displayState.totals else {
            return nil
        }
        let components = monthKey.split(separator: "-")
        guard
            components.count == 2,
            let year = Int(components[0]),
            let month = Int(components[1])
        else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: 15, hour: 12))
    }

    private func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 {
            return String.localizedStringWithFormat(
                String(localized: HourleafQuickSurfaceCopy.minutesFormat),
                remainder
            )
        }
        if remainder == 0 {
            return String.localizedStringWithFormat(
                String(localized: HourleafQuickSurfaceCopy.hoursFormat),
                hours
            )
        }
        return String.localizedStringWithFormat(
            String(localized: HourleafQuickSurfaceCopy.hoursMinutesFormat),
            hours,
            remainder
        )
    }

    private func statusContent(
        _ title: LocalizedStringResource,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .minimumScaleFactor(0.75)
            .accessibilityLabel(title)
    }
}

struct HourleafQuickSurfaceWidget: Widget {
    static let kind = HourleafQuickSurfaceKind.widget

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: Self.kind,
            provider: HourleafQuickSurfaceProvider()
        ) { entry in
            HourleafQuickSurfaceWidgetView(displayState: entry.displayState)
        }
        .configurationDisplayName(HourleafQuickSurfaceCopy.widgetTitle)
        .description(HourleafQuickSurfaceCopy.widgetDescription)
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

#if DEBUG
private extension HourleafQuickSurfaceEntry {
    static let preview = HourleafQuickSurfaceEntry(
        date: .now,
        displayState: QuickSurfaceDisplayStateV1(
            availability: .ready,
            totals: .shown(
                monthKey: "2026-08",
                serviceMinutes: 3_145,
                creditMinutes: 425,
                bibleStudyCount: 4,
                serviceYearMinutes: 24_750,
                serviceYearTargetMinutes: 36_000
            ),
            timer: .idle
        )
    )
}

#Preview(as: .systemSmall) {
    HourleafQuickSurfaceWidget()
} timeline: {
    HourleafQuickSurfaceEntry.preview
}

#Preview(as: .systemMedium) {
    HourleafQuickSurfaceWidget()
} timeline: {
    HourleafQuickSurfaceEntry.preview
}
#endif

@available(iOS 18.0, *)
struct HourleafTimerControlIntent: SetValueIntent {
    static var title: LocalizedStringResource {
        "quick_surface.control.title"
    }

    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy {
        .requiresLocalDeviceAuthentication
    }

    @Parameter(title: "quick_surface.control.title", default: false)
    var value: Bool

    init() {
        value = false
    }

    func perform() async throws -> some IntentResult {
        defer {
            HourleafQuickSurfaceReloads.requestAll()
        }

        let resolution = HourleafQuickSurfaceContainer.resolve()
        guard case let .available(rootURL) = resolution else {
            return .result(dialog: IntentDialog(HourleafQuickSurfaceCopy.controlErrorUnavailable))
        }

        let request: QuickSurfaceTimerControlRequestV1 = value ? .start : .stop
        let result = QuickSurfaceTimerControlTransactionV1().perform(
            request: request,
            stateStore: QuickSurfaceStateStoreV1(rootDirectory: rootURL)
        )

        switch result {
        case .committed:
            if value {
                return .result(dialog: IntentDialog(HourleafQuickSurfaceCopy.controlStarted))
            }
            return .result(dialog: IntentDialog(HourleafQuickSurfaceCopy.controlStopped))
        case .unchanged:
            return .result(
                dialog: IntentDialog(
                    value
                        ? HourleafQuickSurfaceCopy.controlUnchangedStart
                        : HourleafQuickSurfaceCopy.controlUnchangedStop
                )
            )
        case .reviewRequired:
            return .result(dialog: IntentDialog(HourleafQuickSurfaceCopy.controlErrorReview))
        case let .failed(failure):
            return .result(dialog: IntentDialog(copy(for: failure)))
        }
    }

    private func copy(
        for failure: QuickSurfaceTimerControlFailureV1
    ) -> LocalizedStringResource {
        switch failure {
        case .disabled:
            return HourleafQuickSurfaceCopy.controlErrorDisabled
        case .unavailable:
            return HourleafQuickSurfaceCopy.controlErrorUnavailable
        case .protected:
            return HourleafQuickSurfaceCopy.controlErrorProtected
        case .corrupt:
            return HourleafQuickSurfaceCopy.controlErrorCorrupt
        case .busy:
            return HourleafQuickSurfaceCopy.controlErrorBusy
        case .revisionExhausted:
            return HourleafQuickSurfaceCopy.controlErrorRevision
        case .invalidClock:
            return HourleafQuickSurfaceCopy.controlErrorClock
        }
    }
}

@available(iOS 18.0, *)
struct HourleafQuickSurfaceTimerControl: ControlWidget {
    static let kind = HourleafQuickSurfaceKind.control

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            let displayState = HourleafQuickSurfaceSnapshotReader.read()
            ControlWidgetToggle(
                isOn: displayState.isTimerRunning,
                action: HourleafTimerControlIntent(),
                label: {
                    Label(HourleafQuickSurfaceCopy.controlTitle, systemImage: "timer")
                },
                valueLabel: { isOn in
                    Text(
                        isOn
                            ? HourleafQuickSurfaceCopy.controlRunning
                            : displayState.controlValueLabel
                    )
                }
            )
            .disabled(!displayState.isControlEnabled)
        }
        .displayName(HourleafQuickSurfaceCopy.controlTitle)
        .description(HourleafQuickSurfaceCopy.controlContinueDialog)
    }
}

private extension QuickSurfaceDisplayStateV1 {
    var isTimerRunning: Bool {
        if case .running = timer { return true }
        return false
    }

    var isControlEnabled: Bool {
        guard availability == .ready else { return false }
        switch timer {
        case .idle, .running:
            return true
        case .disabled, .reviewPending, .finalizing:
            return false
        }
    }

    var controlValueLabel: LocalizedStringResource {
        switch availability {
        case .ready:
            switch timer {
            case .disabled:
                return HourleafQuickSurfaceCopy.controlDisabled
            case .idle:
                return HourleafQuickSurfaceCopy.controlReady
            case .running:
                return HourleafQuickSurfaceCopy.controlRunning
            case .reviewPending:
                return HourleafQuickSurfaceCopy.controlReview
            case .finalizing:
                return HourleafQuickSurfaceCopy.controlSaving
            }
        case .unavailable:
            return HourleafQuickSurfaceCopy.controlUnavailable
        case .protected:
            return HourleafQuickSurfaceCopy.controlProtected
        case .needsReset:
            return HourleafQuickSurfaceCopy.controlNeedsReset
        }
    }
}

@main
struct HourleafQuickSurfacesExtension: WidgetBundle {
    var body: some Widget {
        HourleafQuickSurfaceWidget()
        if #available(iOS 18.0, *) {
            HourleafQuickSurfaceTimerControl()
        }
    }
}
