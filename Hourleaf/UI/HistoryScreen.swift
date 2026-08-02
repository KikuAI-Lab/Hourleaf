import SwiftUI

struct HistoryScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingEntry: LedgerEntryRecord?
    @State private var entryToDelete: LedgerEntryRecord?

    var body: some View {
        NavigationStack {
            Group {
                if model.entryRecords.isEmpty {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "leaf",
                        description: Text("history.empty.message")
                    )
                } else {
                    List(model.entryRecords) { record in
                        Button { editingEntry = record } label: { entryRow(record.entry) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { entryToDelete = record } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("historyEntry_\(record.id.uuidString)")
                    }
                    .listStyle(.insetGrouped)
                }
            }
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
        }
    }

    private func entryRow(_ entry: TimeEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind == .service ? .green : .orange)
                .frame(width: 30, height: 30)
                .background((entry.kind == .service ? Color.green : Color.orange).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.kind.localizedName).font(.headline)
                Text(AppDateText.day(entry.day))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("historyEntryDate_\(entry.day.year)_\(entry.day.month)_\(entry.day.day)")
                if let note = entry.note, !note.isEmpty {
                    Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(DurationText.format(minutes: entry.minutes)).font(.headline.monospacedDigit())
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
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
        NavigationStack {
            Form {
                Picker("entry.type", selection: $kind) {
                    ForEach(EntryKind.allCases) { Text($0.localizedName).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker(
                    "entry.date",
                    selection: $date,
                    in: model.settings.ledgerStartMonth.date(calendar: .hourleaf)...Date(),
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
