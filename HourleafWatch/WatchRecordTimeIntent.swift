import AppIntents
import Foundation

enum WatchRecordTimeIntentError: LocalizedError, Sendable {
    case invalidDuration

    var errorDescription: String? {
        String(localized: "watch.error.invalid_duration")
    }
}

struct WatchRecordServiceTimeIntent: AppIntent {
    static var title: LocalizedStringResource { "watch.shortcut.service" }
    static var description: IntentDescription {
        IntentDescription("watch.intent.record.description")
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(
        title: "watch.intent.duration",
        defaultUnit: .minutes,
        supportsNegativeNumbers: false,
        requestValueDialog: "watch.intent.duration_prompt"
    )
    var duration: Measurement<UnitDuration>

    @Parameter(title: "watch.intent.date", kind: .date)
    var date: Date?

    init() {}

    init(
        duration: Measurement<UnitDuration>? = nil,
        date: Date? = nil
    ) {
        if let duration {
            self.duration = duration
        }
        self.date = date
    }

    static var parameterSummary: some ParameterSummary {
        Summary("watch.intent.summary") {
            \.$duration
            \.$date
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await sendWatchTimeEntry(
            kind: .service,
            duration: duration,
            date: date
        )
        return .result(dialog: IntentDialog("watch.intent.saved"))
    }
}

/// A separate action identifier is intentional. A user shortcut stores the
/// action itself, not the preconfigured value passed by `AppShortcut`.
struct WatchRecordCreditTimeIntent: AppIntent {
    static var title: LocalizedStringResource { "watch.shortcut.credit" }
    static var description: IntentDescription {
        IntentDescription("watch.intent.record.description")
    }
    static var openAppWhenRun: Bool { false }
    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(
        title: "watch.intent.duration",
        defaultUnit: .minutes,
        supportsNegativeNumbers: false,
        requestValueDialog: "watch.intent.duration_prompt"
    )
    var duration: Measurement<UnitDuration>

    @Parameter(title: "watch.intent.date", kind: .date)
    var date: Date?

    init() {}

    init(
        duration: Measurement<UnitDuration>? = nil,
        date: Date? = nil
    ) {
        if let duration {
            self.duration = duration
        }
        self.date = date
    }

    static var parameterSummary: some ParameterSummary {
        Summary("watch.intent.summary") {
            \.$duration
            \.$date
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await sendWatchTimeEntry(
            kind: .credit,
            duration: duration,
            date: date
        )
        return .result(dialog: IntentDialog("watch.intent.saved"))
    }
}

private func sendWatchTimeEntry(
    kind: WatchTimeEntryKindV1,
    duration: Measurement<UnitDuration>,
    date: Date?
) async throws {
    let envelope: WatchTimeEntryEnvelopeV1
    do {
        let total = try WatchTimeEntryDurationV1.totalMinutes(duration: duration)
        let now = Date.now
        envelope = try WatchTimeEntryEnvelopeV1(
            kind: kind,
            day: WatchCivilDayV1(date ?? now),
            minutes: total,
            occurredAt: now
        )
    } catch {
        throw WatchRecordTimeIntentError.invalidDuration
    }

    try await HourleafWatchConnectivityClient.shared.send(envelope)
}

struct HourleafWatchShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor { .blue }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: WatchRecordServiceTimeIntent(),
            phrases: [
                "Record service time in \(.applicationName)",
                "\(.applicationName), record service time"
            ],
            shortTitle: "watch.shortcut.service",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: WatchRecordCreditTimeIntent(),
            phrases: [
                "Record credit time in \(.applicationName)",
                "\(.applicationName), record credit time"
            ],
            shortTitle: "watch.shortcut.credit",
            systemImageName: "plus.circle.fill"
        )
    }
}
