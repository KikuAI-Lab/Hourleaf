import SwiftUI

struct QuickSurfaceTimerRow: View {
    @EnvironmentObject private var model: AppModel
    let manualDraftIsPristine: Bool

    @State private var presentedReview: TimerReviewPresentation?

    var body: some View {
        Group {
            if model.quickSurfaceAvailability != .ready {
                unavailableRow
            } else if let state = model.quickSurfaceState {
                timerRow(state)
            } else {
                unavailableRow
            }
        }
        .padding(14)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickSurfaceTimerRow")
        .onChange(of: model.quickSurfaceState) { _, state in
            guard manualDraftIsPristine,
                  let state,
                  case let .reviewPending(review) = state.timer
            else { return }
            presentedReview = TimerReviewPresentation(review: review)
        }
        .sheet(item: $presentedReview) { presentation in
            QuickSurfaceTimerReviewView(review: presentation.review)
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private func timerRow(_ state: QuickSurfaceStateV1) -> some View {
        if !state.timerEnabled {
            unavailableRow
        } else {
            switch state.timer {
            case .idle:
                row(
                    title: String(localized: "quick_surfaces.timer.title"),
                    detail: String(localized: "quick_surfaces.timer.idle"),
                    symbol: "timer",
                    actionTitle: String(localized: "quick_surfaces.timer.start"),
                    actionIdentifier: "startQuickSurfaceTimerButton"
                ) {
                    Task { await model.startQuickSurfaceTimer() }
                }

            case let .running(running):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    row(
                        title: String(localized: "quick_surfaces.timer.running"),
                        detail: String(
                            format: String(localized: "quick_surfaces.timer.elapsed_format"),
                            elapsedText(running, at: context.date)
                        ),
                        symbol: "stopwatch.fill",
                        actionTitle: String(localized: "quick_surfaces.timer.stop"),
                        actionIdentifier: "stopQuickSurfaceTimerButton"
                    ) {
                        Task { await model.stopQuickSurfaceTimer() }
                    }
                }

            case let .reviewPending(review):
                row(
                    title: String(localized: "quick_surfaces.timer.ready_to_review"),
                    detail: suggestedDurationText(review),
                    symbol: "checkmark.circle",
                    actionTitle: String(localized: "quick_surfaces.timer.review"),
                    actionIdentifier: "reviewQuickSurfaceTimerButton"
                ) {
                    presentedReview = TimerReviewPresentation(review: review)
                }

            case .finalizing:
                row(
                    title: String(localized: "quick_surfaces.timer.finalizing"),
                    detail: String(localized: "quick_surfaces.timer.review_pending"),
                    symbol: "arrow.triangle.2.circlepath",
                    actionTitle: String(localized: "quick_surfaces.timer.retry"),
                    actionIdentifier: "retryQuickSurfaceTimerButton"
                ) {
                    Task { _ = await model.retryQuickSurfaceFinalization() }
                }
            }
        }
    }

    private var unavailableRow: some View {
        row(
            title: String(localized: "quick_surfaces.timer.unavailable"),
            detail: String(localized: "quick_surfaces.timer.unavailable_detail"),
            symbol: "timer",
            actionTitle: String(localized: "quick_surfaces.timer.settings"),
            actionIdentifier: "openQuickSurfaceSettingsButton"
        ) {
            model.selectedTab = .settings
        }
    }

    private func row(
        title: String,
        detail: String,
        symbol: String,
        actionTitle: String,
        actionIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
                .tint(.green)
                .disabled(model.isQuickSurfaceActionInFlight)
                .accessibilityIdentifier(actionIdentifier)
        }
    }

    private func elapsedText(_ running: TimerSessionV1.Running, at date: Date) -> String {
        let assessment = TimerSessionCommandV1.evaluateStop(
            running: running,
            clock: TimerClockSnapshotV1(
                wallNow: date,
                uptimeNowSeconds: ProcessInfo.processInfo.systemUptime
            )
        )
        let seconds = max(Int64(0), assessment.elapsedSeconds)
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02lld:%02lld:%02lld", hours, minutes, remainingSeconds)
    }

    private func suggestedDurationText(_ review: TimerSessionV1.ReviewPending) -> String {
        guard let minutes = review.suggestedMinutes else {
            return String(localized: "quick_surfaces.review.manual_duration")
        }
        return DurationText.format(minutes: minutes)
    }
}

private struct TimerReviewPresentation: Identifiable {
    let review: TimerSessionV1.ReviewPending
    var id: UUID { review.sessionID }
}

private struct QuickSurfaceTimerReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let review: TimerSessionV1.ReviewPending
    @State private var kind: EntryKind = .service
    @State private var day: Date
    @State private var hours: Int
    @State private var minutes: Int
    @State private var showDiscardConfirmation = false

    init(review: TimerSessionV1.ReviewPending) {
        self.review = review
        let suggested = review.suggestedMinutes ?? 0
        _day = State(initialValue: Date(timeIntervalSince1970: review.stoppedAtEpochSeconds))
        _hours = State(initialValue: suggested / 60)
        _minutes = State(initialValue: suggested % 60)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("entry.type", selection: $kind) {
                        Text("quick_surfaces.review.service").tag(EntryKind.service)
                        Text("quick_surfaces.review.credit").tag(EntryKind.credit)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("timerReviewKindPicker")

                    DatePicker(
                        "quick_surfaces.review.day",
                        selection: dayBinding,
                        in: dayRange,
                        displayedComponents: .date
                    )
                    .accessibilityIdentifier("timerReviewDayPicker")
                }

                Section("quick_surfaces.review.duration") {
                    TimeWheelPicker(hours: $hours, minutes: $minutes)
                        .accessibilityIdentifier("timerReviewDurationPicker")
                }

                if review.clockAssessment == .recoveredWallClock {
                    Section {
                        Label(
                            "quick_surfaces.review.recovered_wall_clock",
                            systemImage: "clock.badge.exclamationmark"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("timerReviewRecoveredClockText")
                    }
                } else if review.clockAssessment == .manualRequired || review.suggestedMinutes == nil {
                    Section {
                        Label(
                            "quick_surfaces.review.manual_duration",
                            systemImage: "exclamationmark.circle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("timerReviewManualDurationText")
                    }
                }
            }
            .navigationTitle("quick_surfaces.review.title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("quick_surfaces.review.discard", role: .destructive) {
                        showDiscardConfirmation = true
                    }
                    .disabled(model.isQuickSurfaceActionInFlight)
                    .accessibilityIdentifier("discardTimerReviewButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("quick_surfaces.review.save") { save() }
                        .disabled(!canSave || model.isQuickSurfaceActionInFlight)
                        .accessibilityIdentifier("saveTimerReviewButton")
                }
            }
            .confirmationDialog(
                "quick_surfaces.review.discard.title",
                isPresented: $showDiscardConfirmation,
                titleVisibility: .visible
            ) {
                Button("quick_surfaces.review.discard.confirm", role: .destructive) {
                    discard()
                }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("quick_surfaces.review.discard.message")
            }
        }
    }

    private var totalMinutes: Int { hours * 60 + minutes }

    private var canSave: Bool {
        (1...5_999).contains(totalMinutes)
            && dayRange.contains(dayBinding.wrappedValue)
    }

    private var dayRange: ClosedRange<Date> {
        let lower = model.settings.ledgerStartMonth.date(calendar: .hourleaf)
        return lower...max(lower, model.currentDate)
    }

    private var dayBinding: Binding<Date> {
        Binding(
            get: { min(max(day, dayRange.lowerBound), dayRange.upperBound) },
            set: { day = $0 }
        )
    }

    private func save() {
        guard canSave else { return }
        let selectedDay = LocalDay(dayBinding.wrappedValue, calendar: .hourleaf)
        Task {
            if await model.saveQuickSurfaceReview(
                sessionID: review.sessionID,
                mutationID: review.mutationID,
                entryID: review.entryID,
                kind: kind,
                day: selectedDay,
                minutes: totalMinutes
            ) {
                dismiss()
            }
        }
    }

    private func discard() {
        Task {
            if await model.discardQuickSurfaceReview(
                sessionID: review.sessionID,
                mutationID: review.mutationID,
                entryID: review.entryID
            ) {
                dismiss()
            }
        }
    }
}
