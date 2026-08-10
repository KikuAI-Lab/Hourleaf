import SwiftUI

struct HistoryScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var viewMode: HistoryViewMode = .list
    @State private var editingEntry: LedgerEntryRecord?
    @State private var entryToDelete: LedgerEntryRecord?
    @State private var calendarMonth: MonthKey?
    @State private var selectedDay: LocalDay?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                viewModePicker
                historyContent
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("history.title")
            .sheet(item: $editingEntry) { entry in
                EntryEditorView(record: entry)
                    .environmentObject(model)
            }
            .alert(deleteTitle, isPresented: deleteBinding, presenting: entryToDelete) { entry in
                Button("common.cancel", role: .cancel) { entryToDelete = nil }
                Button("common.delete", role: .destructive) {
                    Task { _ = await model.deleteEntry(entry) }
                    entryToDelete = nil
                }
            } message: { _ in Text(deleteMessage) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        RecentlyDeletedScreen()
                            .environmentObject(model)
                    } label: {
                        Label("history.recently_deleted", systemImage: "trash")
                    }
                    .accessibilityIdentifier("recentlyDeletedButton")
                }
            }
            .onAppear(perform: normalizeCalendarState)
            .onChange(of: model.settings.ledgerStartMonth) { _, _ in normalizeCalendarState() }
            .onChange(of: model.currentMonth) { _, _ in normalizeCalendarState() }
            .onChange(of: calendarMonth) { _, _ in selectedDay = nil }
        }
    }

    private var viewModePicker: some View {
        Picker("history.view_mode", selection: $viewMode) {
            Text("history.view.list").tag(HistoryViewMode.list)
            Text("history.view.calendar").tag(HistoryViewMode.calendar)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(minHeight: 44)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityLabel(Text("history.view_mode"))
        .accessibilityIdentifier("historyViewModePicker")
    }

    @ViewBuilder
    private var historyContent: some View {
        switch viewMode {
        case .list:
            listContent
        case .calendar:
            calendarContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if model.entryRecords.isEmpty {
            ContentUnavailableView(
                "history.empty.title",
                systemImage: "leaf",
                description: Text("history.empty.message")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(model.entryRecords) { record in
                    entryButton(record)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var calendarContent: some View {
        List {
            Section {
                calendarPanel
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if let selectedDay {
                let entries = HistoryCalendar.activeEntries(on: selectedDay, records: model.entryRecords)
                Section {
                    if entries.isEmpty {
                        Text(String(
                            format: String(localized: "history.calendar.entries_format"),
                            Int64(entries.count)
                        ))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(entries) { record in
                            entryButton(record)
                        }
                    }
                } header: {
                    Text(AppDateText.day(selectedDay))
                }
            } else if model.entryRecords.isEmpty {
                Section {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "leaf",
                        description: Text("history.empty.message")
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var calendarPanel: some View {
        let month = displayedCalendarMonth
        let activeDays = HistoryCalendar.activeDays(in: month, records: model.entryRecords)
        let cells = HistoryCalendar.cells(in: month)

        return VStack(spacing: 12) {
            HStack {
                Button {
                    guard month > model.settings.ledgerStartMonth else { return }
                    calendarMonth = month.advanced(by: -1, calendar: .hourleaf)
                } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                }
                .disabled(month <= model.settings.ledgerStartMonth)
                .accessibilityLabel(Text("history.calendar.previous_month"))
                .accessibilityIdentifier("historyCalendarPreviousMonthButton")

                Spacer()
                Text(AppDateText.month(month))
                    .font(.headline)
                    .accessibilityIdentifier("historyCalendarMonth")
                Spacer()

                Button {
                    guard month < model.currentMonth else { return }
                    calendarMonth = month.advanced(by: 1, calendar: .hourleaf)
                } label: {
                    Image(systemName: "chevron.right")
                        .frame(width: 44, height: 44)
                }
                .disabled(month >= model.currentMonth)
                .accessibilityLabel(Text("history.calendar.next_month"))
                .accessibilityIdentifier("historyCalendarNextMonthButton")
            }
            .padding(.horizontal, 8)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(HistoryCalendar.weekdaySymbols().enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .accessibilityHidden(true)
                }
                ForEach(cells) { cell in
                    if let day = cell.day {
                        let entryCount = activeDays.contains(day)
                            ? HistoryCalendar.activeEntries(on: day, records: model.entryRecords).count
                            : 0
                        calendarDayButton(day, entryCount: entryCount)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    private func calendarDayButton(_ day: LocalDay, entryCount: Int) -> some View {
        let hasEntries = entryCount > 0
        let isSelected = selectedDay == day
        return Button {
            selectedDay = day
        } label: {
            VStack(spacing: 2) {
                Text(String(day.day))
                    .font(.body.weight(isSelected || hasEntries ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                Circle()
                    .fill(hasEntries ? (isSelected ? Color.white : Color.accentColor) : Color.clear)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                isSelected ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppDateText.day(day)))
        .accessibilityValue(
            hasEntries
                ? Text(String(
                    format: String(localized: "history.calendar.entries_format"),
                    Int64(entryCount)
                ))
                : Text(verbatim: "")
        )
        .accessibilityIdentifier("historyCalendarDay_\(day.key)")
    }

    private func entryButton(_ record: LedgerEntryRecord) -> some View {
        Button {
            editingEntry = record
        } label: {
            entryRow(record)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                entryToDelete = record
            } label: {
                Label("common.delete", systemImage: "trash")
            }
        }
        .accessibilityIdentifier("historyEntry_\(record.id.uuidString)")
    }

    private func entryRow(_ record: LedgerEntryRecord) -> some View {
        let entry = record.entry
        return HStack(spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind == .service ? Color.accentColor : Color.orange)
                .frame(width: 30, height: 30)
                .background((entry.kind == .service ? Color.accentColor : Color.orange).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind.localizedName).font(.headline)
                Text(AppDateText.day(entry.day))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyEntryDate_\(entry.day.year)_\(entry.day.month)_\(entry.day.day)")
                Text(String(
                    format: String(localized: "history.created_at_format"),
                    entry.createdAt.formatted(date: .abbreviated, time: .shortened)
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyEntryCreatedAt_\(entry.id.uuidString)")
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(DurationText.format(minutes: entry.minutes)).font(.headline.monospacedDigit())
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var displayedCalendarMonth: MonthKey {
        HistoryCalendar.clampedMonth(
            calendarMonth ?? model.currentMonth,
            start: model.settings.ledgerStartMonth,
            current: model.currentMonth
        )
    }

    private func normalizeCalendarState() {
        let normalized = HistoryCalendar.clampedMonth(
            calendarMonth ?? model.currentMonth,
            start: model.settings.ledgerStartMonth,
            current: model.currentMonth
        )
        calendarMonth = normalized
        if let selectedDay, selectedDay.monthKey != normalized {
            self.selectedDay = nil
        }
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { entryToDelete != nil }, set: { if !$0 { entryToDelete = nil } })
    }

    private var deleteTitle: String {
        guard let entryToDelete, model.changeAffectsConfirmedReport(from: entryToDelete.entry.day.monthKey) else {
            return String(localized: "history.delete.title")
        }
        return String(localized: "history.delete.report_title")
    }

    private var deleteMessage: String {
        guard let entryToDelete, model.changeAffectsConfirmedReport(from: entryToDelete.entry.day.monthKey) else {
            return String(localized: "history.delete.message")
        }
        return String(localized: "history.delete.report_message")
    }
}

private enum HistoryViewMode: Hashable {
    case list
    case calendar
}

private enum EntryEditorConfirmation {
    case editReportedEntry
    case deleteEntry
}

private struct EntryEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let record: LedgerEntryRecord
    private var entry: TimeEntry { record.entry }

    @State private var kind: EntryKind
    @State private var date: Date
    @State private var hours: Int
    @State private var minutes: Int
    @State private var note: String
    @State private var confirmation: EntryEditorConfirmation?

    init(record: LedgerEntryRecord) {
        self.record = record
        let entry = record.entry
        _kind = State(initialValue: entry.kind)
        _date = State(initialValue: entry.day.date(calendar: .hourleaf))
        _hours = State(initialValue: entry.minutes / 60)
        _minutes = State(initialValue: entry.minutes % 60)
        _note = State(initialValue: entry.note ?? "")
    }

    var body: some View {
        let lowerBound = model.settings.ledgerStartMonth.date(calendar: .hourleaf)
        NavigationStack {
            Form {
                Picker("entry.type", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker(
                    "entry.date",
                    selection: $date,
                    in: lowerBound...max(lowerBound, model.currentDate),
                    displayedComponents: .date
                )
                .accessibilityIdentifier("editEntryDatePicker")
                TimeWheelPicker(hours: $hours, minutes: $minutes)
                TextField("entry.note_placeholder", text: $note, axis: .vertical)
                    .accessibilityIdentifier("editEntryNoteField")
                Section {
                    Button(role: .destructive) {
                        confirmation = .deleteEntry
                    } label: {
                        Label("common.delete", systemImage: "trash")
                    }
                    .accessibilityIdentifier("deleteEditedEntryButton")
                }
            }
            .navigationTitle("history.edit_short")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.save") { attemptSave() }
                        .accessibilityIdentifier("saveEditedEntryButton")
                }
            }
            .alert(confirmationTitle, isPresented: confirmationBinding) {
                Button("common.cancel", role: .cancel) {}
                if confirmation == .deleteEntry {
                    Button("common.delete", role: .destructive) { performDelete() }
                } else {
                    Button("history.edit_anyway") { performSave() }
                }
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    private func attemptSave() {
        guard hours > 0 || minutes > 0 else {
            confirmation = .deleteEntry
            return
        }
        let earliest = min(entry.day.monthKey, MonthKey(date, calendar: .hourleaf))
        if model.changeAffectsConfirmedReport(from: earliest) {
            confirmation = .editReportedEntry
        } else {
            performSave()
        }
    }

    private func performSave() {
        confirmation = nil
        Task {
            if await model.updateEntry(record, kind: kind, date: date, hours: hours, minutes: minutes, note: note) {
                dismiss()
            }
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        )
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .editReportedEntry:
            String(localized: "history.edit.report_title")
        case .deleteEntry:
            deleteTitle
        case nil:
            ""
        }
    }

    private var confirmationMessage: String {
        confirmation == .deleteEntry
            ? deleteMessage
            : String(localized: "history.change_report_warning")
    }

    private var deleteTitle: String {
        model.changeAffectsConfirmedReport(from: entry.day.monthKey)
            ? String(localized: "history.delete.report_title")
            : String(localized: "history.delete.title")
    }

    private var deleteMessage: String {
        model.changeAffectsConfirmedReport(from: entry.day.monthKey)
            ? String(localized: "history.delete.report_message")
            : String(localized: "history.delete.message")
    }

    private func performDelete() {
        confirmation = nil
        Task {
            if await model.deleteEntry(record) {
                dismiss()
            }
        }
    }
}
