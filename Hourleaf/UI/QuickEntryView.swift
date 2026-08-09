import SwiftUI

struct QuickEntryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var kind: EntryKind = .service
    @State private var date = Date()
    @State private var hours = 0
    @State private var minutes = 0
    @State private var note = ""
    @State private var isSaving = false
    @State private var didInitializeDate = false
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
                VStack(spacing: 18) {
                    if let state = previousReportBannerState { reportBanner(state) }
                    if shouldShowQuickSurfaceTimer {
                        QuickSurfaceTimerRow(manualDraftIsPristine: manualDraftIsPristine)
                    }
                    entryCard
                    monthSummary
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
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

        return Button {
            model.openReport(previousMonth)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: state.symbolName)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .font(.headline)
                    Text(state.statusKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding()
            .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityValue(Text(state.statusKey))
        .accessibilityIdentifier("previousReportBanner")
    }

    private var entryCard: some View {
        VStack(spacing: 16) {
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
            TimeWheelPicker(hours: $hours, minutes: $minutes)
            Divider()

            TextField("entry.note_placeholder", text: $note, axis: .vertical)
                .lineLimit(1...3)
                .focused($noteFocused)
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
                .padding(.vertical, 13)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(isSaving || (hours == 0 && minutes == 0))
            .accessibilityIdentifier("saveEntryButton")
        }
        .padding()
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
        let report = model.report(for: MonthKey(date, calendar: .hourleaf))
        return Group {
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
        .padding(.horizontal, 4)
    }

    private func summaryMetric(_ key: LocalizedStringKey, minutes: Int, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 4) {
            Text(key).font(.caption).foregroundStyle(.secondary)
            Text(DurationText.format(minutes: minutes)).font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
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
