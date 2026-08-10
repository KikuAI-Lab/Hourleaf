import SwiftUI

struct RecentlyDeletedScreen: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var recordToRestore: LedgerEntryRecord?
    @State private var restoringEntryIDs = Set<UUID>()

    private var records: [LedgerEntryRecord] {
        model.deletedEntryRecords
    }

    var body: some View {
        Group {
            if records.isEmpty {
                ContentUnavailableView(
                    "history.recently_deleted.empty.title",
                    systemImage: "trash",
                    description: Text("history.recently_deleted.empty.message")
                )
            } else {
                List(records) { record in
                    entryRow(record)
                        .padding(.vertical, 2)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("history.recently_deleted.title")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            String(localized: "history.restore.report_title"),
            isPresented: restoreConfirmationBinding,
            presenting: recordToRestore
        ) { record in
            Button("common.cancel", role: .cancel) { recordToRestore = nil }
            Button("history.restore") {
                restore(record)
            }
        } message: { _ in
            Text("history.restore.report_message")
        }
    }

    private var restoreConfirmationBinding: Binding<Bool> {
        Binding(get: { recordToRestore != nil }, set: { if !$0 { recordToRestore = nil } })
    }

    private func attemptRestore(_ record: LedgerEntryRecord) {
        guard recordToRestore == nil, !restoringEntryIDs.contains(record.id) else { return }
        if model.changeAffectsConfirmedReport(from: record.entry.day.monthKey) {
            recordToRestore = record
        } else {
            restore(record)
        }
    }

    private func restore(_ record: LedgerEntryRecord) {
        guard restoringEntryIDs.insert(record.id).inserted else { return }
        recordToRestore = nil
        Task { @MainActor in
            _ = await model.restoreEntry(record)
            restoringEntryIDs.remove(record.id)
        }
    }

    @ViewBuilder
    private func entryRow(_ record: LedgerEntryRecord) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    entryIcon(record)
                    entryDetails(record)
                }
                HStack(spacing: 12) {
                    Text(DurationText.format(minutes: record.entry.minutes))
                        .font(.headline.monospacedDigit())
                    Spacer()
                    restoreButton(record)
                }
            }
        } else {
            HStack(spacing: 12) {
                entryIcon(record)
                entryDetails(record)
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Text(DurationText.format(minutes: record.entry.minutes))
                        .font(.headline.monospacedDigit())
                    restoreButton(record)
                }
            }
        }
    }

    private func entryIcon(_ record: LedgerEntryRecord) -> some View {
        Image(systemName: record.entry.kind.systemImage)
            .foregroundStyle(record.entry.kind == .service ? Color.accentColor : Color.orange)
            .frame(width: 30, height: 30)
            .background(
                (record.entry.kind == .service ? Color.accentColor : Color.orange).opacity(0.12),
                in: Circle()
            )
    }

    private func entryDetails(_ record: LedgerEntryRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.entry.kind.localizedName).font(.headline)
            Text(AppDateText.day(record.entry.day))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let note = record.entry.note, !note.isEmpty {
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func restoreButton(_ record: LedgerEntryRecord) -> some View {
        Button("history.restore") {
            attemptRestore(record)
        }
        .buttonStyle(.bordered)
        .disabled(restoringEntryIDs.contains(record.id))
        .accessibilityIdentifier("restoreEntry_\(record.id.uuidString)")
    }
}
