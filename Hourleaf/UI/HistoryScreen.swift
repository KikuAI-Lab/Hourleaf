import SwiftUI

struct HistoryScreen: View {
    @EnvironmentObject private var model: AppModel
    @State private var editingEntry: TimeEntry?
    @State private var entryToDelete: TimeEntry?

    var body: some View {
        NavigationStack {
            Group {
                if model.entries.isEmpty {
                    ContentUnavailableView(
                        "history.empty.title",
                        systemImage: "leaf",
                        description: Text("history.empty.message")
                    )
                } else {
                    List(model.entries) { entry in
                        Button { editingEntry = entry } label: { entryRow(entry) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button(role: .destructive) { entryToDelete = entry } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                            .accessibilityIdentifier("historyEntry_\(entry.id.uuidString)")
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("history.title")
            .sheet(item: $editingEntry) { entry in
                EntryEditorView(entry: entry)
                    .environmentObject(model)
            }
            .alert(deleteTitle, isPresented: deleteBinding, presenting: entryToDelete) { entry in
                Button("common.cancel", role: .cancel) { entryToDelete = nil }
                Button("common.delete", role: .destructive) {
                    model.deleteEntry(entry)
                    entryToDelete = nil
                }
            } message: { _ in Text(deleteMessage) }
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
                Text(AppDateText.day(entry.day)).font(.subheadline).foregroundStyle(.secondary)
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
        guard let entryToDelete, model.changeAffectsConfirmedReport(from: entryToDelete.day.monthKey) else {
            return String(localized: "history.delete.title")
        }
        return String(localized: "history.delete.report_title")
    }

    private var deleteMessage: String {
        guard let entryToDelete, model.changeAffectsConfirmedReport(from: entryToDelete.day.monthKey) else {
            return String(localized: "history.delete.message")
        }
        return String(localized: "history.change_report_warning")
    }
}

private struct EntryEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let entry: TimeEntry

    @State private var kind: EntryKind
    @State private var date: Date
    @State private var hours: Int
    @State private var minutes: Int
    @State private var note: String
    @State private var showWarning = false

    init(entry: TimeEntry) {
        self.entry = entry
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
                TimeWheelPicker(hours: $hours, minutes: $minutes)
                TextField("entry.note_placeholder", text: $note, axis: .vertical)
            }
            .navigationTitle("history.edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("common.save") { attemptSave() } }
            }
            .alert("history.edit.report_title", isPresented: $showWarning) {
                Button("common.cancel", role: .cancel) {}
                Button("history.edit_anyway") { performSave() }
            } message: {
                Text("history.change_report_warning")
            }
        }
    }

    private func attemptSave() {
        let earliest = min(entry.day.monthKey, MonthKey(date, calendar: .hourleaf))
        if model.changeAffectsConfirmedReport(from: earliest) {
            showWarning = true
        } else {
            performSave()
        }
    }

    private func performSave() {
        if model.updateEntry(entry, kind: kind, date: date, hours: hours, minutes: minutes, note: note) {
            dismiss()
        }
    }
}
