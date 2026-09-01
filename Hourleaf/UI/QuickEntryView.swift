import SwiftUI

private struct PreviousReportSharePayload: Identifiable {
    let id = UUID()
    let text: String
}

struct QuickEntryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(TimeSelectionFeedbackPreference.storageKey)
    private var timeSelectionFeedbackEnabled = TimeSelectionFeedbackPreference.defaultValue
    @State private var kind: EntryKind = .service
    @State private var date = Date()
    @State private var hours = 0
    @State private var minutes = 0
    @State private var note = ""
    @State private var isSaving = false
    @State private var didInitializeDate = false
    @State private var bibleStudyFeedback = SelectionHapticFeedback()
    @State private var previousReportSharePayload: PreviousReportSharePayload?
    @State private var isSendingPreviousReport = false
    @FocusState private var noteFocused: Bool

    private var previousMonth: MonthKey {
        model.currentMonth.advanced(by: -1, calendar: .hourleaf)
    }

    private var previousReportBannerState: PreviousReportBannerState? {
        guard previousMonth >= model.settings.ledgerStartMonth else { return nil }

        switch model.lifecycleState(for: previousMonth) {
        case .ready:
            return .ready
        case .changed:
            return .changed
        case .reviewed:
            return .reviewed
        case .prepared:
            return .prepared
        case .sent, .draft:
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: usesCompactVerticalLayout ? 14 : 18) {
                    if let state = previousReportBannerState { reportBanner(state) }
                    if shouldShowQuickSurfaceTimer {
                        QuickSurfaceTimerRow(manualDraftIsPristine: manualDraftIsPristine)
                    }
                    entryCard
                    monthSummary
                }
                .padding(.horizontal)
                .padding(.vertical, usesCompactVerticalLayout ? 12 : 16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            .sheet(item: $previousReportSharePayload) { payload in
                ActivityView(text: payload.text) { _ in
                    previousReportSharePayload = nil
                }
            }
            .onChange(of: model.quickEntryResetGeneration) { _, _ in
                resetDraft()
            }
            .onAppear {
                guard !didInitializeDate else { return }
                date = model.currentDate
                didInitializeDate = true
            }
            .onChange(of: model.currentDate) { previousDate, currentDate in
                guard LocalDay(date, calendar: .hourleaf) == LocalDay(previousDate, calendar: .hourleaf) else {
                    return
                }
                date = currentDate
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        // A report is normally submitted for the latest closed
                        // month. If Hourleaf started this month, the month
                        // chooser still opens on the earliest valid month.
                        model.openReport(max(previousMonth, model.settings.ledgerStartMonth))
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("quick.share_report"))
                    .accessibilityIdentifier("shareReportButton")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("common.done") {
                        noteFocused = false
                    }
                    .accessibilityIdentifier("dismissEntryKeyboardButton")
                }
            }
        }
    }

    private func reportBanner(_ state: PreviousReportBannerState) -> some View {
        let monthLabel = AppDateText.month(previousMonth)
        let title = String(
            format: String(localized: state.formatKey),
            monthLabel
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: state.symbolName)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.headline)
                    Text(state.statusKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 8) { previousReportActions(state, title: title) }
                } else {
                    HStack(spacing: 8) { previousReportActions(state, title: title) }
                }
            }

            Text("report.action.send_now_note")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(
            Color.accentColor.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }

    @ViewBuilder
    private func previousReportActions(_ state: PreviousReportBannerState, title: String) -> some View {
        Button {
            model.openReport(previousMonth)
        } label: {
            Text(state.reviewActionKey)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(state.statusKey))
        .accessibilityIdentifier("previousReportBanner")

        Button {
            sendPreviousReportNow()
        } label: {
            Group {
                if isSendingPreviousReport {
                    ProgressView()
                } else {
                    Label("report.action.send_now", systemImage: "paperplane.fill")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color.accentColor)
        .disabled(isSendingPreviousReport)
        .accessibilityIdentifier("sendPreviousReportNowButton")
    }

    private func sendPreviousReportNow() {
        guard !isSendingPreviousReport else { return }
        let displayedDraft = model.reportDraft(for: previousMonth)
        isSendingPreviousReport = true

        Task { @MainActor in
            defer { isSendingPreviousReport = false }
            guard let snapshot = await model.sendReportImmediately(displayedDraft) else { return }
            previousReportSharePayload = PreviousReportSharePayload(text: snapshot.receipt.text)
        }
    }

    private var entryCard: some View {
        VStack(spacing: usesCompactVerticalLayout ? 14 : 16) {
            Picker("entry.type", selection: $kind) {
                ForEach(EntryKind.allCases) { item in
                    Text(item.localizedName).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel(Text("entry.type"))
            .accessibilityIdentifier("entryKindPicker")

            dateInput

            Divider()
            TimeWheelPicker(
                hours: $hours,
                minutes: $minutes,
                wheelHeight: usesCompactVerticalLayout ? 138 : 150,
                selectionFeedbackEnabled: timeSelectionFeedbackEnabled
            )
            Divider()

            TextField("entry.note_placeholder", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .focused($noteFocused)
                .accessibilityLabel(Text("entry.note_placeholder"))
                .accessibilityIdentifier("entryNoteField")

            Button(action: save) {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Label("entry.save", systemImage: "plus")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, usesCompactVerticalLayout ? 11 : 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(isSaving || (hours == 0 && minutes == 0))
            .accessibilityIdentifier("saveEntryButton")
        }
        .padding(.horizontal)
        .padding(.vertical, usesCompactVerticalLayout ? 14 : 16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var dateInput: some View {
        let lowerBound = model.settings.ledgerStartMonth.date(calendar: .hourleaf)
        let range = lowerBound...max(lowerBound, model.currentDate)
        let selection = Binding(
            get: { min(max(date, range.lowerBound), range.upperBound) },
            set: { date = $0 }
        )
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text("entry.date").font(.headline)
                DatePicker("entry.date", selection: selection, in: range, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("entry.date"))
            .accessibilityIdentifier("entryDatePicker")
        } else {
            DatePicker("entry.date", selection: selection, in: range, displayedComponents: .date)
                .datePickerStyle(.compact)
                .accessibilityLabel(Text("entry.date"))
                .accessibilityIdentifier("entryDatePicker")
        }
    }

    private var monthSummary: some View {
        let month = MonthKey(date, calendar: .hourleaf)
        let report = model.report(for: month)
        return VStack(spacing: usesCompactVerticalLayout ? 12 : 14) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        summaryMetric("quick.month_service", minutes: report.rawServiceMinutes)
                        summaryMetric("quick.month_credit", minutes: report.rawCreditMinutes)
                    }
                } else {
                    HStack {
                        summaryMetric("quick.month_service", minutes: report.rawServiceMinutes)
                        Spacer()
                        summaryMetric("quick.month_credit", minutes: report.rawCreditMinutes, trailing: true)
                    }
                }
            }
            Divider()
            bibleStudyCounter(for: month)
        }
        .padding(.horizontal)
        .padding(.vertical, usesCompactVerticalLayout ? 14 : 16)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private func summaryMetric(_ key: LocalizedStringKey, minutes: Int, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(DurationText.format(minutes: minutes)).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
    }

    @ViewBuilder
    private func bibleStudyCounter(for month: MonthKey) -> some View {
        let count = model.bibleStudyCount(for: month)
        let isUpdating = model.updatingBibleStudyMonths.contains(month)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                bibleStudyLabel
                bibleStudyButtons(count: count, month: month, isUpdating: isUpdating)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: 12) {
                bibleStudyLabel
                Spacer(minLength: 8)
                bibleStudyButtons(count: count, month: month, isUpdating: isUpdating)
            }
        }
    }

    private var bibleStudyLabel: some View {
        Text("quick.bible_studies")
            .font(.headline)
            .accessibilityIdentifier("bibleStudyLabel")
    }

    private func bibleStudyButtons(
        count: Int,
        month: MonthKey,
        isUpdating: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Button {
                updateBibleStudyCount(count - 1, for: month)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(isUpdating || count <= MonthlyBibleStudyCount.allowedRange.lowerBound)
            .accessibilityLabel(Text("quick.bible_studies.decrease"))
            .accessibilityIdentifier("decreaseBibleStudyCountButton")

            Text(count, format: .number)
                .font(.headline.monospacedDigit())
                .frame(minWidth: 28)
                .contentTransition(.numericText())
                .accessibilityLabel(Text("quick.bible_studies"))
                .accessibilityValue(Text(verbatim: String(count)))
                .accessibilityIdentifier("bibleStudyCount")

            Button {
                updateBibleStudyCount(count + 1, for: month)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.bordered)
            .disabled(isUpdating || count >= MonthlyBibleStudyCount.allowedRange.upperBound)
            .accessibilityLabel(Text("quick.bible_studies.increase"))
            .accessibilityIdentifier("increaseBibleStudyCountButton")
        }
    }

    private func updateBibleStudyCount(_ count: Int, for month: MonthKey) {
        if timeSelectionFeedbackEnabled {
            bibleStudyFeedback.prepare()
        }
        Task {
            guard await model.updateBibleStudyCount(count, for: month),
                  timeSelectionFeedbackEnabled else { return }
            bibleStudyFeedback.play()
        }
    }

    private func save() {
        guard !isSaving, (hours != 0 || minutes != 0) else { return }
        isSaving = true
        noteFocused = false
        Task {
            defer { isSaving = false }
            guard await model.addEntry(kind: kind, date: date, hours: hours, minutes: minutes, note: note) else { return }
            hours = 0
            minutes = 0
            note = ""
        }
    }

    private var shouldShowQuickSurfaceTimer: Bool {
        model.quickSurfacePreferences.timerVisible || model.quickSurfaceTimerWasRequested
    }

    private var usesCompactVerticalLayout: Bool {
        !dynamicTypeSize.isAccessibilitySize
    }

    private var manualDraftIsPristine: Bool {
        kind == .service
            && LocalDay(date, calendar: .hourleaf) == LocalDay(model.currentDate, calendar: .hourleaf)
            && hours == 0
            && minutes == 0
            && note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !noteFocused
    }

    private func resetDraft() {
        kind = .service
        date = model.currentDate
        hours = 0
        minutes = 0
        note = ""
        noteFocused = false
    }
}

private enum PreviousReportBannerState {
    case ready
    case changed
    case reviewed
    case prepared

    var formatKey: String.LocalizationValue {
        switch self {
        case .ready:
            "report.banner.ready_format"
        case .changed:
            "report.banner.changed_format"
        case .reviewed:
            "report.banner.reviewed_format"
        case .prepared:
            "report.banner.prepared_format"
        }
    }

    var statusKey: LocalizedStringKey {
        switch self {
        case .ready:
            "report.state.ready"
        case .changed:
            "report.state.changed"
        case .reviewed:
            "report.state.reviewed"
        case .prepared:
            "report.state.prepared"
        }
    }

    var reviewActionKey: LocalizedStringKey {
        switch self {
        case .ready:
            "report.action.review"
        case .changed:
            "report.action.review_correction"
        case .reviewed, .prepared:
            "report.action.open"
        }
    }

    var symbolName: String {
        switch self {
        case .ready:
            "doc.text.magnifyingglass"
        case .changed:
            "arrow.trianglehead.2.clockwise.rotate.90"
        case .reviewed:
            "checkmark.circle"
        case .prepared:
            "square.and.arrow.up"
        }
    }
}
